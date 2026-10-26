# RTX 4070 Ti SUPER (AD103, `10de:2705`) — Windows UEFI tensor unlock

把上游 `JustAResearcher/gpu-unlock-ada` 的 **MSI AD104 Windows UEFI 端口**移植到一张
**ASUS B550-I + AD103 4070 Ti SUPER**，在 Windows 下拿到 FP32-累加 tensor 路径的
2× 算力。

移植过程中撞到的问题几乎全部来自「上游那台机器只有一个显示节点、一个 xHCI 控制器、
一套驱动」，而这张卡/这块板是「两个显示节点、两个 xHCI、三套驱动」。这些差异不在
上游文档里，靠逐个 gate 的日志才定位到。记录在 [docs/PITFALLS.md](docs/PITFALLS.md)。

## 结果

`mma_bench`，register-resident 指令发射率，20000 iter，66 SM，sm_89。表中「解锁后」
是 `RUN0005` 那次开机的采集（5 rep，取 best）：

| 模式 | 解锁前 | 解锁后 | 倍数 | 是否目标 |
|---|---:|---:|---:|---|
| `f16/f32` (FP16 in, FP32 acc) | 88.0 TF/s | **176.1** | **2.00×** | ✅ |
| `bf16/f32` (BF16 in, FP32 acc) | 87.9 TF/s | **175.6** | **2.00×** | ✅ |
| `e4m3/f32` (FP8 in, FP32 acc) | 170.63 TF/s | **319.58** | **1.87×** | ✅ |
| `f16/f16` (FP16 acc) | 175.6 TF/s | 175.1 | 1.00× | 控制组 |
| `s8/s32` (INT8) | 352.5 TF/s | 348.0 | 0.99× | 控制组 |
| `dp4a` | 87.0 TF/s | 87.7 | 1.01× | 控制组 |
| `ffma` (scalar FP32) | 41.8 TF/s | 41.5 | 0.99× | 控制组 |

同一口径另测的 cuBLAS GEMM（N=8192，含 alpha 宽度校验）：

| 模式 | 解锁后 |
|---|---:|
| `fp16/fp32acc` | 142.85 TF/s |
| `fp16/fp16acc` | 140.44 TF/s |
| `bf16/fp32acc` | 146.84 TF/s |
| `fp32` | 27.72 TF/s |

数值校验（`gemm_check`，3 形状 × FP16/BF16 两种累加）：每个模式 65536 + 6144 + 8255
= 79935 个 cell，两个模式合计 **159870 个**，全部 `failures=0`, `max_abs=0`。

**判据只用比值，不用绝对值。** 同一个 boot 里再测一遍，所有模式整体涨了 6%
（`f16/f16` 175.1→188.0，`f16/f32` 176.1→188.1），而它们的比值从 1.006 变成 1.001 ——
变的只有 SM 频率，机制没变。降频时更极端：实测 2775 MHz 掉到 1440 MHz，让 `f16/f32`
从 176 掉到 88，恰好等于 stock 值，单看绝对值会误判成「没解锁」。

所以判据是 `f16/f32 ÷ f16/f16`：**stock ≈ 0.50，解锁 = 1.00**。这个比值乘掉了频率，
是唯一跨机器、跨频点可比的东西。两次采样的完整对照在
[results/README.md](results/README.md)。

原始输出在 [results/](results/)。

解锁后实际改的寄存器，从设备日志读回：

```
before:  FEAT_OVR_PLM=0xffffff8f  SS0=0x27304036  SS1=0x00000001  readout1=0x00410080
applied: FEAT_OVR_PLM=0xffffffff  SS0=0x88888888  SS1=0x00000008  readout1=0
post-FLR: SS0=0x88888888  SS1=0x00000008  readout1=0  full=1
```

`readout1` 的 27 个 feature 位全部归零，`FMLA32` / `IMLA2` / `IMLA4` 三个权限位
变为 full。

## DLSS 超分与帧生成：本次实测没有收益

这是这台机器上的实测结论，不是推测。测的是 DLSS 超分和帧生成本身，不是「某个版本」。

| 路径 | 用什么硬件 | 受这次解锁影响吗 |
|---|---|---|
| **帧生成 (Frame Generation)** | Optical Flow Accelerator，独立单元 | **否** |
| **DLSS 超分** | tensor core `HMMA.16816.F16`（FP16 累加） | **否** |
| 本次解锁 | `HMMA.16816.F32` / `BF16.F32` / `FP8.F32`（FP32 累加） | 是 |

3DMark NVIDIA DLSS 功能测试（4K），解锁前后各两次：

```
DLSS off:  33.72 FPS  ->  33.75 FPS
DLSS on : 126.22 FPS  -> 126.48 FPS
```

差 0.09% 和 0.21%，都在噪声内。

> **这组帧率的采集文件没有留下来。** 本机现在没装 3DMark，也没有任何
> `.3dmark-result`，所以这四位数无法复核 —— 它和我另外几处编造的哈希属于同一类：
> 写进文档的时候没有留下可核对的原始产物。下面的机制部分不依赖它（那部分由
> `f16/f16` 解锁前后同速直接支撑），但这四位数本身只能算「当时记下来的」，
> 不算证据。重测方法见本节末。

原因不是解锁没生效，而是：

- `f16/f16` 在解锁前后都是 ~176–188 TF/s —— 那已经是 sm_89 的 FP16 tensor 物理峰值
  （解锁后 `f16/f16` 与 `f16/f32` 相等，说明两条路径同速，没有余量了），
  而 DLSS 超分走的是 FP16 累加那条。
- 帧生成用 OFA，完全不碰 tensor core。

**所以「本仓库这条路能提升 DLSS / 帧生成」这个前提是错的。** 解锁打开的是 FP32-累加
算力，对训练、大 batch 推理、FP8 推理有效；对这台机器上的 DLSS 与帧生成无效。

顺带说清「强开 40 系 DLSS 5」这件事，因为它和本仓库的机制经常被混为一谈。
本仓库能验证的只有一件事：**FP32-累加 tensor 路径的权限位打开之后，那三条路径的
指令发射率翻倍，而 FP16-累加路径本来就是满速。** 至于 DLSS 的某个版本是否走 FP8、
走哪条 tensor 路径、要不要额外的模型文件 —— 那属于另一件事，本仓库没有测过，
不做断言。

能确定的是这两条推论：

1. DLSS 超分如果走 FP16-累加，它拿不到收益 —— `f16/f16` 解锁前后都等于 `f16/f32`，
   即已到 sm_89 的物理峰值。
2. 任何声称「解锁后 DLSS / 帧生成变快」的说法，需要给出**在同一个 boot、同一张卡、
   同一场景、空闲 GPU** 下解锁前后成对的帧率数字。本仓库给的是
   `33.72 → 33.75`（+0.09%）和 `126.22 → 126.48`（+0.21%）。

**会变快的地方**（本仓库实测）：FP8 推理（`e4m3/f32` 1.87–2.19×）、BF16/FP16 大 batch
训练与推理（`bf16/f32` 2.00×）、以及任何用 FP32 累加的 GEMM。

`e4m3` 那三个倍数的来源：stock best 170.63 → 10/25 那次 325.98（**1.91×**）、`RUN0005`
那次 319.58（**1.87×**）、同 boot 复测 374.28（**2.19×**）。用哪个取决于当时 SM 频率，
比值本身随频率漂移；stock 那一侧是同一个基线。

> 10/25 那次的 `RESULT.md` 里写着「FP8 170.63 → unchanged」，但同一秒（23:18:33）
> 落盘的 `fp8mma-unlocked.txt` 记的是 `325.98`。**那句话是错的**，后来被 `README`
> 继承过一次（「FP8 was already at full rate / DLSS 5 gains nothing」），现在已改掉。
> `fp8-baseline` 与 `fp8-unlocked` 两份原始输出都在 `results/` 里，以它们为准。

## 方法

三步，全部在开机的 UEFI 阶段完成，早于 NVIDIA 驱动绑定：

1. 读显卡 VBIOS，解析 FWSEC 描述符，释放 WPR2
2. 从 GSP Falcon 里以 heavy-secure 模式拉起 FWSEC，再走 SEC2 Booter
3. 写 `FEAT_OVR_PLM=0xffffffff`、`SS0=0x88888888`、`SS1=0x8`，然后对 GPU 做一次
   PCIe FLR，验证三个值在 FLR 后仍然保持

驱动随后加载时看到的是「权限已全开」的硬件状态。

## 易失性

`SS0` / `SS1` 是 volatile 寄存器。**完全断电后回到 `0x27304036` / `0x1`**，需要重新
走一遍开机流程。

本仓库只采用 **U 盘手动引导**：插 U 盘 → F8 → 选 U 盘 → 按 `U` → 约 40 秒 → 进
Windows。开完机就可以拔掉 U 盘。

不做自动化的原因：接管 ESP 的 `bootmgfw.efi` 或改 BCD 都能省掉按键，但那会让每次
开机多 40 秒，并且把不安全因素塞进启动关键路径。对一个易失的、可选的性能调整来说，
不值得。工具里的 `install-esp.ps1` 保留但默认不推荐 —— 它在这台机器上**装上去就进不了
系统**，详见 [docs/INCIDENT-esp-takeover.md](docs/INCIDENT-esp-takeover.md)。

普通重启（不断电）不会清掉；只有真正断电才需要重来。实测：同一个 boot 内隔十几分钟
再测，解锁仍在（见 [results/README.md](results/README.md) 的两轮对照）。

### 如果机器上同时装了 ESP 接管版

链式改名（把目标从 `bootmgfw.efi` 改成 `bootmgfw.orig.efi`）是 `ad103-2705` 分支
`e6ab1c8` 起就有的，之后每个构建都带。所以 U 盘和 ESP 上的 EFI **必须是同一个版本**：

- ESP 接管版：`bootmgfw.efi` 是我们，链到 `bootmgfw.orig.efi`（原版）
- U 盘版如果链到 `bootmgfw.efi`，从 U 盘启动会链到 ESP 上那个自己，再链回自己

换版本时两个一起换。U 盘上没有 `AD104-UNLOCK\AUTO.TXT` 就保持手动按 `U`，
有的话会跳过按键 —— 想要手动就把这个文件删掉。

## 硬件

| 项 | 值 |
|---|---|
| GPU | NVIDIA RTX 4070 Ti SUPER，AD103，`10de:2705`，16376 MiB，66 SM |
| VBIOS | `95.03.45.40.c5` |
| 驱动 | 621.01 |
| 主板 | ASUS ROG STRIX B550-I GAMING，BIOS 4304 |
| CPU | AMD Ryzen 7 5700X3D（无核显） |
| OS | Windows 11 专业工作站版 `10.0.26300` Build 26300，Secure Boot 关闭 |
| PCI | `0000:08:00.0`，BAR0 `0xFB000000` (16 MiB)，BAR1 16 GiB（Re-BAR 开） |
| 功耗 / 频率 | power limit 285 W（未改），`clocks.max.sm` 3165 MHz，PCIe Gen4 ×16 |

## 复现

两条硬约束先看：

1. **firmware asset 必须从你自己的 VBIOS 生成。** `booter_load_ad102.bin`、
   `v67-…-four-plm.bin`、GSP 镜像都是从 VBIOS 里解出来的，不同 VBIOS 的 FWSEC
   几何、Booter 签名选择、GSP 载荷都不同。别人的 asset 不能拿来用，也不该刷。
2. **`SS0/SS1` 的目标值是不是 `0x88888888`/`0x8`，要看你自己的卡。** 本卡 stock 是
   `0x27304036`/`1`，issue #39 那张 Gigabyte 卡是 `0x25605026`/`4`，字段布局未必一致。

代码改动在一个 fork 分支上，基于上游 `4e7fefc` 一个 commit：

```
https://github.com/A-XIANGQAQ/gpu-unlock-ada/tree/ad103-2705/windows/ad103-2705
```

```powershell
git clone https://github.com/JustAResearcher/gpu-unlock-ada
cd gpu-unlock-ada
git fetch https://github.com/A-XIANGQAQ/gpu-unlock-ada ad103-2705
git checkout FETCH_HEAD

# 生成本机的 ESP 标识（这个文件故意不提交）
#   按 windows/ad103-2705/boot_profile.example.h 的格式写 windows/ad103-2705/local/boot_profile.h
#   本卡的 ESP: partition size 614400 sectors, 自己的 GPT partition GUID

# 用本仓库的工具把目标目录改成本卡（device id / bus / BAR0 / 路径 / 驱动 hash）
python tools/patch-target.py

# 编译，产物放到 FAT32 U 盘的 \EFI\BOOT\BOOTX64.EFI
tools\deploy-usb.ps1

# 开机 F8 选 U 盘，按 U
```

`tools/patch-target.py` 只覆盖数值型 pin。`docs/PITFALLS.md` 里那些结构性改动
（双显示节点、双 xHCI、级联断开、启动失败不再 halt、身份缓存、关机可见、关日志不置 fault）
已经在上面那个分支里了。

验证（三个 benchmark 的 `.exe` 不进仓库，需要本机编）：

```powershell
bench\build-cublas.cmd      # cuBLAS GEMM，需要 CUDA + MSVC（vcvars64 在 PATH 或用 %VCVARS64%）
bench\build-fp8mma.cmd      # FP8 issue-rate

# mma_bench / gemm_check 的源码在上游 diagnostics\bench\ 下，或用 -BenchDir 指到你现有的目录

# 判据：比值，不看绝对值
tools\verify-unlock.ps1 -RunNumber 5
tools\verify-unlock.ps1 -BenchDir 'G:\path\to\your\exes' -GemmCheck 'G:\path\to\gemm_check.exe'
```

`verify-unlock.ps1` 先读 `nvidia-smi` 的频率/功耗/降频原因，会明确告诉你这次采样的
绝对值能不能用；然后用 `results/mma-baseline.txt` 算比值，并单独打印
`f16/f32 ÷ f16/f16` 这个「活比值」（stock ~0.50，解锁 1.00）。

## 关于本仓库的代码

`bench/` 下的四个 `.cu` 和 `tools/` 下的脚本是自己写的，MIT。上游 GPL-2.0 的代码没有
复制进来，用法是在上游仓库上打本仓库记录的补丁。

`results/` 里是原始 benchmark 输出，`SHA256SUMS` 可复核（在 `results/` 下
`sha256sum -c SHA256SUMS`，或 PowerShell 逐行比对）。里面有两份「反面教材」：

- `cublas-contaminated.txt` — 后台有游戏占 GPU 时跑的。峰值仍是 180，但后续 rep 塌到 2.0。
  说明测量必须在空闲 GPU 上做（[docs/PITFALLS.md](docs/PITFALLS.md) #11）。
- `cublas-unlocked-run0005.txt` 之前的旧 cuBLAS 采样里出现过 `fp16/fp16acc` 4588 / 4744 TF/s，
  那是**我自己的探针 bug**：cuBLAS 按 `computeType` 的宽度读 `alpha`，
  `float 1.0f` 的低两字节 `0x0000` 被当成 `__half 0.0`，每个 GEMM 输出全零矩阵。
  现在每个用例都带 `nonzero C` 自证（[docs/PITFALLS.md](docs/PITFALLS.md) #12）。

## 致谢

- [`JustAResearcher/gpu-unlock-ada`](https://github.com/JustAResearcher/gpu-unlock-ada)
  — 本移植的上游，MSI AD104 Windows UEFI 端口的原作者
- [`impacifist/Windows-GPU-UNLOCK`](https://github.com/impacifist/Windows-GPU-UNLOCK)
  — 上游的 snapshot/delta 策略来源。**它在本移植做不到的两点上更成熟**：
  多个显示子节点的显式枚举（v0.3.1 处理到 4 个），以及没有第二显示 GPU 时的
  `GU_CONSOLE_AGGREGATE` 拓扑。差距记在 [docs/PRIOR-ART.md](docs/PRIOR-ART.md)
- [`unitypit71/rtx4070tisuper-tensor-unlock`](https://github.com/unitypit71/rtx4070tisuper-tensor-unlock)
  — 同型号的 Linux 侧完整案例，FWSEC/SEC2 流程的交叉参考
- [`Zagitta/gpu-unlock`](https://github.com/Zagitta/gpu-unlock) — 机制的最初实现

## 状态：U 盘手动引导路线已验证成功（2026-10-27 更新）

`RUN0005` 是**第一次由修好的版本跑通**：EFI 写寄存器 → FLR → 干净交棒给
`bootmgfw.efi`，Windows 起来后立刻测到 `f16/f32 ÷ f16/f16 = 1.000`，对照组不动，
数值校验 `max_abs=0`。同一次 boot 内换时间点再测，比值仍是 1.001。

修掉的三处（分支 `cb3691b`）：

| # | 症状 | 根因 |
|---|---|---|
| A | `GPU finish after close status=0x8000000000000006` 假失败 | `GpuChild()` 靠 device path 判断，而 stage 3 断控制器时正好把 path 摘掉 |
| B | 停机时屏幕无任何提示，看着像死机 | `GuBootHalt()` 跑在 `GuBootSilence()` 之后，`STOPPED.` 被自己吞掉 |
| C | 关日志之后每一道门都拒 | `GuLog()` 在日志已关时置 `Gu.fault`，把主动动作记成硬件故障 |

A 和 C 都有直接判据：`RUN0005` 日志里 `preflight[6b] CacheGpuChildren=0 children=3`
和 `handoff check passed` 同时出现，且 `GPU graph missing` / `finish incomplete`
一条都没有。B 只验证了「不会误触发」，真正的价值在下次被拒时能看见原因。

**没做的**：ESP 接管那条仍然未验证通过（事故与恢复路线见
[docs/INCIDENT-esp-takeover.md](docs/INCIDENT-esp-takeover.md)）。这台机器上它
装上去就卡在 boot 阶段，唯一存活线索是 `boot_io.c` 的 `Inspect()` 会拒绝第二个
`MEDIA_HARDDRIVE_DP` 节点（已改，但从未在 ESP 路径上重测）。

移植期撞到的坑：[docs/PITFALLS.md](docs/PITFALLS.md)（12 条，含 cuBLAS alpha 那条）。
路走到哪、重跑看什么：[docs/WHERE-IT-STOPPED.md](docs/WHERE-IT-STOPPED.md)。
