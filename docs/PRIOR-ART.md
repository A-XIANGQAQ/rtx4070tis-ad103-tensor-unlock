# 同一赛道的其他实现，以及它们比本移植做得好的地方

写这个文件是因为一开始只读了 `gpu-unlock-ada` 一个项目的代码。后来补读邻域项目，
发现有两处别人已经解决得比这里好。

## Zagitta/gpu-unlock

原始实现，Linux 内核模块路线。`SS0/SS1` + FLR 的机制、`FEAT_OVR_PLM` 的语义都出自
这里。本移植没有直接读它的代码，机制是通过 `gpu-unlock-ada` 的 `vendor/unlock_610.c`
间接沿用的。

## impacifist/Windows-GPU-UNLOCK

Windows UEFI 路线的原始实现，`gpu-unlock-ada` 的 `windows/ad104-msi` 明确说是从它的
`internal-boot/boot/prepare-console.c` 改编的。**这个项目在两点上比本移植成熟：**

### 1. 显示子节点的数量不是固定的

它的 v0.3.1 变更记录写：

> Fixed preflight rejection when ASUS firmware exposes **three** RTX display children
> instead of exactly two. The wrapper now discovers and validates **up to four** unique
> RTX display children, then releases each guarded EDID connection before the NVIDIA GOP.

本移植的 `GpuChild()` 用 `PciPath` 24 字节前缀加 ACPI ADR 尾节点做匹配，本身不限数量，
但 `Consumers()` 里还留着计数假设：

```c
if(pci!=1||child<1||gfx!=1||text>1||virtual>1|| ...) return EFI_ACCESS_DENIED;
```

`gfx!=1` 和 `text>1` 在 3 个以上 display child 的固件上会误拒。实测这台 B550-I 是
1–2 个，稳定通过；换到同一厂商暴露 3 个的板子上就会撞墙。

**要移植到 3+ child 的机器，应该照它的做法**：先枚举全部 RTX display child，对每一个
单独校验，逐个释放 EDID 连接，最后才动 NVIDIA GOP。计数改成集合校验而不是等于 1。

### 2. 没有第二个显示 GPU 时的 console 拓扑

它的 v0.3.0 变更记录：

> New aggregate-console headless topology (`GU_CONSOLE_AGGREGATE`) for hosts **without a
> second display GPU**: nvgop owns the target PCI function, the AMI GOP combo splitter
> serves the console through an aggregate GOP, and the wrapper releases the
> nvgop/EDID/combo/text chain instead of the two-child nvgop console used on the B650M profile.

本移植的目标机器（Ryzen 7 5700X3D）没有核显，正是这个拓扑。本移植的通过方式是把
`Consumers()` 的 `text` / `virtual` 计数放宽到允许 0，靠「记录不断言」过关，而不是
真的理解 aggregate console 的所有权链。

**这是一个真实的技术债**：现在的做法是在这台机器上观测到 `text=1 virtual=1` 才过的，
如果固件的 ConSplitter 行为变一点点，就会退回 `text=0` 然后依赖放宽逻辑。它的做法是
显式建模 aggregate 链并逐个释放。

### 3. headless 模式不需要按键

它的 headless 路线：显示器全接 RTX，独立 1 GiB ESP，F8 启动项，**不按 T/U/Enter**，
自动解锁后直接进 Windows。本移植保留了 `U` 确认。

保留 `U` 是一个刻意的选择（见 README 的易失性一节），不是能力差距。

## unitypit71/rtx4070tisuper-tensor-unlock

同型号（RTX 4070 Ti SUPER）的 Linux 路线，韩文。本移植交叉参考了它的
`CASE-STUDY.md`，特别是：

- FWSEC 描述符 → Booter 头 → GSP 镜像的解析顺序
- 「selector 是 volatile，热重启不能代替冷启动」这个结论
- 睡眠/唤醒后 selector 不保持

它明确排除了 VBIOS 刷写、内核模块和驱动补丁，和本移植的边界一致。

## bjrasmussen-jpg/windows_rtx3090_unlock

`impacifist` 的 EVGA RTX 3090 再移植。没细读，作为「同一套代码换板卡要重做一遍
machine profile」的佐证。

## NeoChen1024/gpu-unlock-ad103

AD103（4080 / 4080 SUPER）的只读 preflight。没细读。同芯片家族，如果要扩展到 4080
值得对照它的 PCI/display 描述。

## 结论

| 问题 | 本移植 | impacifist |
|---|---|---|
| 多个显示子节点 | 前缀匹配，计数放宽 | **显式枚举最多 4 个，逐个释放 EDID** |
| 无第二显示 GPU | 靠观测值放宽计数 | **`GU_CONSOLE_AGGREGATE` 显式建模** |
| 需要按键 | 需要 `U` | headless 不需要（可选） |
| 机器 profile | 单个目标，pin 写在 `port.h` | 编译期 profile 常量，多机器 |

前两项是真实差距。本移植能在这台机器上跑通，但那两处是靠「放宽断言」过的，不是靠
「理解拓扑」过的。
