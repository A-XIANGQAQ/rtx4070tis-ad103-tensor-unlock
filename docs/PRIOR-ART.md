# 同一赛道的其他实现，以及它们比本移植做得好的地方

## Zagitta/gpu-unlock

原始实现，Linux 内核模块路线。`SS0/SS1` + FLR 的机制、`FEAT_OVR_PLM` 的语义都出自
这里。本移植没有直接读它的代码，机制是通过 `gpu-unlock-ada` 的 `vendor/unlock_610.c`
间接沿用的。

## impacifist/Windows-GPU-UNLOCK

Windows UEFI 路线的原始实现，`gpu-unlock-ada` 的 `windows/ad104-msi` 明确说是从它的
`internal-boot/boot/prepare-console.c` 改编的。**这个项目比本移植成熟的地方：**

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

## 实际代码里的两处出入（`prepare-console.c` / `headless-policy.h`）

### 它的非 aggregate 路线只有 2 个 stage，且不断开 GPU owner

`prepare-console.c` 的文件头：

> All handles are discovered afresh. Only `DisconnectController` on the RTX GOP child and
> two validated `DriverBindingHandle`s is permitted. **The NVIDIA GPU owner and shared AMI
> runtime EDID/input driver are never stopped.**

对应的循环是 `for(UINTN stage=1;stage<=2;stage++)`，即 TextOut、GOP 两个。

`gpu-unlock-ada` 的 `windows/ad104-msi` 改成了 3 个 stage，第三个断开 `Plan.nv_agent`
（GPU 的 PciIo owner），然后靠 `ClaimRestore()` 重新拿独占。

**这台机器实测三个 stage 全部 `status=0` 且事务成功**（`result=0 ... flrs=1`），所以
3-stage 在这里成立。但要注意这是一个**偏离上游的设计**，不是上游验证过的路径。

### `GU_CONSOLE_AGGREGATE` 的判据是「无 path、无 framebuffer 的 GOP」

`headless-policy.h` 里：

```c
#if !GU_CONSOLE_AGGREGATE
  if(... || (handles[i]!=t->ConsoleOutHandle && handles[i]!=t->StandardErrorHandle) ||
     ... || g->Mode->FrameBufferBase || g->Mode->FrameBufferSize)s=EFI_UNSUPPORTED;
#else
  /* Aggregate topology: the AMI combo aggregate GOP is pathless ... */
  if(... || dp || ... || g->Mode->FrameBufferBase || g->Mode->FrameBufferSize)s=EFI_UNSUPPORTED;
#endif
```

两种拓扑都要求释放后**零物理 GOP**。这台机器的 GOP 有真实 framebuffer
（`fb=0x7800000000 fbsz=0x1900000`），且释放后 `Gops()` 在 stage<3 时仍枚举到 1 个，
所以既不是 aggregate，也不是它那两个 profile 的 headless 形态。

**它是第三种形态：单个正常 GOP + ConSplitter 保留。** 本移植的「放宽 `text`/`virtual`
到允许 0」正是在这种形态下过 preflight 的。所以 aggregate 的代码不能照搬。

### 值得抄的一条：残留边断言

```c
/* headless-policy.h */
if(e->handle==Gu.handle)return FALSE; /* No driver/child may remain on GPU. */
```

本移植的 `Expected()`：

```c
for(i...) { if(Removed(&Original.edges[i],stage))continue; ... }
```

`Removed()` 为真的边被直接跳过：它只证明「不该消失的边还在」，从不证明「该消失的
边确实消失了」。stage 3 级联断开后如果 GPU handle 上残留一条 EDID 边，`Expected(3,TRUE)`
照样返回真。

已在 `GuMsiReleased()` 里加了一条只记录不阻断的计数：

```c
GuLog("release: residual edges on GPU handles=%zu expected=0\n",(size_t)residual);
```

不改成硬断言的原因是：这台机器上 3-stage 是偏离上游的路径，把断言收紧会让一个还没被
上游验证过的设计更脆。

### 另外两条不打算抄

- **console 协议完整副本比对**（`outputCopy` / `errorCopy` / `inputCopy` 逐字节）比本移植
  的「只比指针」严格。值得做，但会改变 `Alive()` 的语义，风险大于收益。
- **所有观测都在 `TPL_NOTIFY` 内**。本移植只在 `Snapshot()` 前后 `RaiseTPL`，`Alive()` 和
  `Gops()` 在 TPL 外跑。这是真实缺口，但在单核启动阶段观测到竞态的概率很低。

## 补充：Windows 方向的两个直接对照（2026-10-26）

- [Goldlionren/gpu-unlock-4080s](https://github.com/Goldlionren/gpu-unlock-4080s)：单块 AD103
  4080 SUPER 的 **Windows/UEFI** 移植，走完整流程（自签 EFI + 证书登记进固件 db + Secure Boot
  开启），并给出 matched 性能表。对本移植最有参考价值的一点：它把 FP8 E4M3 GEMM 也纳入了测量
  （199.4 → 310.4 TF/s 与 199.4 → 298.7，两次），但作者自己注明 FP8 波动大、**不用于**判定。
- [miounet11/gpu-unlock-site](https://github.com/miounet11/gpu-unlock-site)：gpu-unlock.com
  文档站（Ampere/Ada/Turing，7 语言），适合作为给别人的入口页，而不是代码参考。

本仓库与上游都用 `mma.m16n8k32` e4m3 的寄存器探针量 FP8 发射率，与 GEMM 数字不可
混比。三处实测：

| 仪器 | 数据 | 倍数 |
|---|---|---|
| 寄存器发射率探针（本仓库） | 170.63 → 319.58 / 374.28 TF/s | 1.87–2.19× |
| Goldlionren 的 FP8 E4M3 GEMM（AD103 4080S） | 199.4 → 310.4 与 199.4 → 298.7 TF/s | 1.56× / 1.50× |
| 上游的 matched E4M3 CUTLASS GEMM（AD103 4070 Ti S，`m=n=k=4096`，240 W 帽） | 59,325.8 → 59,495 GFLOP/s | 1.003× |

同一张架构、同一个权限位，三个倍数差了一倍以上。发射率探针把访存和占用率全拿掉了，
看到的是纯上限；GEMM 要真读 A/B、写 C，240 W 帽下先撞功率墙（上游那次撞到 0.3%，那个
kernel 在这个形状与功耗下 FP8 通路不是瓶颈）。

「FP8 快 N 倍」这句话得说清是哪个仪器、什么形状、什么功耗帽；本仓库只提供第一行，
不是对任何真实 FP8 工作负载的预测。

## 2026-10-28 增补：四个新对照

2026-10-24 之后这个方向冒出很多仓库。只收与本移植会出现**实质分歧**的四个；全景与排除项见
[ECOSYSTEM-2026-10.md](ECOSYSTEM-2026-10.md)。

### `physicsdolphin/nv-uefi-unlocker`（Rust，★52）

链条与我们的完全一致（SEC2 scrubber → FWSEC-FRTS/WPR2 → 签名 Booter 起 GSP-RM → 四写 payload
→ 读回 → FLR → 链回 Windows Boot Manager），**四写那份 payload 就是我们在跑的那份**
（sha256 `44c36b2d…`，见 `tools/payload-report.py`）。所以它值钱的不是机制，是周边四件：

1. **回放/诊断模式**：不放 `v67-*.bin` 就走完整链、零写入。我们想做同类的事目前只能自己注释
   payload —— 这是本移植最该抄的一条。
2. **多卡**：逐张处理，`EALREADY` 让位下一张，单张失败只对那张 emergency FLR；`tx-select-bdf.txt`
   钉卡，对不上就拒绝猜测。
3. **武装模式**：`i_know_what_i_am_doing.txt` 存在时确认变 5 秒倒计时。
4. **链回目标钉定**：`chain-target.txt` 可链到 Limine 而非 Windows Boot Manager。

两条负面结论我们文档里没有：**Linux RTD3 会擦掉解锁**（issue #9）、**Thunderbolt/热插拔 eGPU
是易失解锁的敌对环境**（`4f8b9ab`）。跨系统使用前必须先补这两条。

### `wyx1277348872-a11y/gpu-unlock-4070tis-ad103-win`（同卡 `10de:2705`）

fork 自 `Zihao-Wu06/gpu-unlock-for-windows`（Zagitta + gpu-unlock-ada 的 Windows 移植再移植）。
两条对照：

- **拓扑坑独立撞上**：他们的 `PORT-2705.md` 记录同一 root port 下两个子控制器、其中一个没有
  GOP，`DisplayChild()` 返回 `EFI_UNSUPPORTED`，修 `ownership.c` 约 90 行 / 3 文件。见
  [PITFALLS.md](PITFALLS.md) #2 的外部复现段。
- **非易失换形状已成实现**：安装器建隐藏 300 MiB FAT32（无盘符）+ 固件启动项 `GPU Unlock (auto)`，
  见 [INCIDENT-esp-takeover.md](INCIDENT-esp-takeover.md) 结论节。

数字也一致：330 W 上限下 FP16→FP32 84.92 → 149.67（1.76×），FP32 CUDA core 对照 0.99× —— 与
本仓库「GEMM 撞功率墙、只有发射率才是 2×」同一结论。

### `impacifist/Windows-GPU-UNLOCK` 的 `c403e8f`

「把 GPU 家族特征、共享固件、机器 profile pin 分开」。本移植现在 19 个 pin 全塞在
`profile.c` 一个函数里（`tools/gen_profile.py` 的 `Registers()`），换一张卡就要重跑生成器、重核
全部 19 项。按它那刀切下去，家族级（`PMC_BOOT_0` 形状、FEAT 偏移）、固件级（FWSEC 几何、
WPR2 区间）、机器级（BAR、device、分区 GUID）各一层，换卡时只需要换最后一层。这是结构性建议，
不是 bug 修复，代价是 `profile.c` 的生成模板要重写一遍。

### `Zagitta/gpu-unlock`：Release 2.0 + recipe driven

`09305c4` 把 driver 重构成「一张卡一份 recipe」，不再改代码；`0532473` 是 Release 2.0，
`1fc6d62` 加 Unraid 支持。与本移植的关系：我们的等价物是 `tools/patch-target.py`（从
`windows/ad104-msi` 复制并改写 pin）—— 同一思路的雏形，但还没到「数据与代码分离」。

### 上游自己的 2705 报告

`JustAResearcher/gpu-unlock-ada` 的 `docs/ada-2705-report.md` 是我们这张卡的 Linux 侧 canary
（240 W 帽、驱动 580.178.04、FP16/FP32 95.0 → 189.9）。逐项对表与差异解释另开一篇：
[UPSTREAM-2705-CROSSCHECK.md](UPSTREAM-2705-CROSSCHECK.md)。**引外部绝对数字前先看那篇。**
