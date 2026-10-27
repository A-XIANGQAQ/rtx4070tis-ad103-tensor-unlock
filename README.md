# RTX 4070 Ti SUPER (AD103, `10de:2705`) — Windows UEFI tensor unlock

把上游 `JustAResearcher/gpu-unlock-ada` 的 **MSI AD104 Windows UEFI 端口**移植到一张
**ASUS B550-I + AD103 4070 Ti SUPER**，在 Windows 下拿到 FP32-累加 tensor 路径的
2× 算力。

上游那台机器只有一个显示节点、一个 xHCI 控制器、一套驱动；这张卡和这块板是两个显示
节点、两个 xHCI、三套驱动。这个差集是移植时几乎所有问题的来源，记在
[docs/PITFALLS.md](docs/PITFALLS.md)。

## 结果

`mma_bench`，register-resident 指令发射率，20000 iter，66 SM，sm_89。表中「解锁后」
是 `RUN0005` 那次开机的采集（5 rep，取 best）：

| 模式 | 解锁前 | 解锁后 | 倍数 | 是否目标 |
|---|---:|---:|---:|---|
| `f16/f32` (FP16 in, FP32 acc) | 88.0 TF/s | **176.1** | **2.00×** | ✅ |
| `bf16/f32` (BF16 in, FP32 acc) | 87.9 TF/s | **175.6** | **2.00×** | ✅ |
| `e4m3/f32` (FP8 in, FP32 acc) ※ | 170.63 TF/s | **319.58** | **1.87×** | ✅ |
| `f16/f16` (FP16 acc) | 175.6 TF/s | 175.1 | 1.00× | 控制组 |
| `s8/s32` (INT8) | 352.5 TF/s | 348.0 | 0.99× | 控制组 |
| `dp4a` | 87.0 TF/s | 87.7 | 1.01× | 控制组 |
| `ffma` (scalar FP32) | 41.8 TF/s | 41.5 | 0.99× | 控制组 |

※ `e4m3/f32` 这一行和上面两行**不是一个仪器**。`f16/f32`、`bf16/f32` 走的 `mma_bench`
和它同属寄存器空转的指令发射率探针，但 `e4m3` 用的是 `mma.m16n8k32.e4m3.e4m3.f32`
（`bench/fp8_mma_bench.cu`），单指令 FLOP 数凑成一样是为了可比。**它是发射率，不是 GEMM。**
上游对同一张卡跑过 matched E4M3 CUTLASS GEMM（`m=n=k=4096`，240 W 帽，同一 profiler
二进制），结果是 **59,325.8 → 59,495 GFLOP/s，即 1.0029×（0.3%）**，
见 `gpu-unlock-ada/docs/ada-2705-report.md:95-107`，作者自己写明「no meaningful FP8 gain」。
两条并不矛盾：发射率翻倍说明这条指令路径的权限位确实开了，而那个特定 GEMM 在 240 W
下是别的瓶颈（带宽/占用率/power）。1.87–2.19× 不等于「FP8 推理快一倍」。

另外四行来自 cuBLAS GEMM（N=8192，含 alpha 宽度校验），没有 stock 对照，只有解锁后的
绝对值。

| 模式 | 解锁后 |
|---|---:|
| `fp16/fp32acc` | 142.85 TF/s |
| `fp16/fp16acc` | 140.44 TF/s |
| `bf16/fp32acc` | 146.84 TF/s |
| `fp32` | 27.72 TF/s |

数值校验（`gemm_check`，3 形状 × FP16/BF16 两种累加）：每个模式 65536 + 6144 + 8255
= 79935 个 cell，两个模式合计 **159870 个**，全部 `failures=0`, `max_abs=0`。

**判据只用比值，不用绝对值。** 同一个 boot 里再测一遍，所有模式整体涨了 6%
（`f16/f16` 175.1→188.0，`f16/f32` 176.1→188.1），比值从 1.006 变成 1.001：变的只有
SM 频率。降频更狠时 `f16/f32` 能落到 88 附近，和没解锁的样子一样。

所以判据是 `f16/f32 ÷ f16/f16`：**stock ≈ 0.50，解锁 = 1.00**。比值把频率约掉了。
两次采样的完整对照在 [results/README.md](results/README.md)。

原始输出在 [results/](results/)。

解锁后实际改的寄存器，`RUN0005` 日志原文（`H:\AD104-UNLOCK\RUN0005.TXT`，行号照抄）：

```
:110  AD102 permission before-firmware: FEAT[0x823804]=0xffffff8f before=0xffffff8f expected=0xffffffff required=1 valid=1 pci=0x270510de chip=0x193000a1
:111  AD102 before-firmware: readout1=0x410080 fields=0 0 2 0 0 2 0 2 0 valid=1 full=0
:148  AD102 permission after-payload: FEAT[0x823804]=0xffffffff before=0xffffff8f expected=0xffffffff required=1 valid=1 pci=0x270510de chip=0x193000a1
:151  selector read: SS0=0x7300036 expected_unlock=0x88888888
:152  selector write: SS0=0x88888888
:153  selector result: SS0=0x88888888 expected=0x88888888 matched=1
:154  selector read: SS1=0x1 expected_unlock=0x8
:155  selector write: SS1=0x8
:156  selector result: SS1=0x8 expected=0x8 matched=1
:157  AD102 selectors-applied: readout1=0 fields=0 0 0 0 0 0 0 0 0 valid=1 full=1
:170  post-FLR SEC2 reset released, GSP halted, BME=0 pending=0 WPR2=1ffffe00:00000000 SS0=88888888 SS1=00000008
:174  AD102 permission post-FLR: FEAT[0x823804]=0xffffffff before=0xffffff8f expected=0xffffffff required=1 valid=1 pci=0x270510de chip=0x193000a1
```

`readout1`（`FEAT_READOUT_1`，`0x00823818`）是**九个 3-bit 字段**，掩码 `0x07ffffff`
（27 bit），见 `windows/ad103-2705/vendor/unlock_610.c:33`。stock 时
`fields=0 0 2 0 0 2 0 2 0`（其中三个字段是 2 = 1/4 速率），解锁后九项全 0，
`full` 由 `valid && !(value & 0x07ffffff)` 算出（`vendor/unlock_610.c:391`）。

哪三个字段对应哪条指令路径，没有建立。上游 `rtx4090-register-report.md:272-278` 写
「The mapping of those three reduced fields to the named FMLA/IMLA fuse words is not
established」。`FMLA32=1→0`、`IMLA2=1→0`、`IMLA4=1→0` 那张表来自 NVIDIA RM getter 的
另一条读法（`docs/evidence/ada2705/sm-rates.json`），不是从 `readout1` 解出来的；
两者是同一个事实的两种视图，不能互相推导。

`SS0` 的 stock 值**不是常量**。逐次冷启动实测（各 `RUN` 的 `entry:` 行）：

```
RUN0001  ss0=0x6310036   RUN0002  ss0=0x7300036
RUN0004  ss0=0x5305036   RUN0005  ss0=0x7300036
```

`SS1` 恒为 `0x1`；`SS0` 逐次不同，且差异不是只在高位（`0x6310036` 和 `0x5305036`
低 16 位是 `0x0036` 和 `0x5036`）。上游也记了同一件事：`rtx4090-register-report.md:277-278`
「The high byte of cold SS0 varied between earlier power-ons while all override enable bits
stayed clear; its meaning is unverified」。只读探针 `CAP0002.JSON`（本机
`G:\workspace\rtx2705\captures\`，10/25 20:31，`gpu_writes:false`）那次采到
`SS0=0x27304036` / `SS1=0x1`，那是**一次采样**，不是固定值。

所以「断电后回到 stock」这个判断，别拿 `SS0` 的等号去验；看 `SS1==0x1` 加
`readout1` 的 `full=0` 就够了。

## DLSS 超分与帧生成：本次解锁对它们没有可测量的收益

| 路径 | 用什么硬件 | 受这次解锁影响吗 |
|---|---|---|
| **帧生成 (Frame Generation)** | Optical Flow Accelerator，独立单元 | **否** |
| **DLSS 超分** | tensor core `HMMA.16816.F16`（FP16 累加） | **否** |
| 本次解锁 | `HMMA.16816.F32` / `BF16.F32` / `FP8.F32`（FP32 累加） | 是 |

3DMark（Steam app 223850），DLSS 开与关各测解锁前后一次：

```
DLSS off:  33.72 FPS  ->  33.75 FPS     +0.09%
DLSS on : 126.22 FPS  -> 126.48 FPS     +0.21%
```

两个差值都在噪声内。原始结果文件没有留存，只有这四个数。

这两条路径都不在 FP32-累加这条线上：

- `f16/f16` 解锁前后都是 176–188 TF/s，已是 sm_89 的 FP16 tensor 峰值；解锁后它和
  `f16/f32` 同速，说明这条路径没有余量。DLSS 超分走的是 FP16 累加那条。
- 帧生成用 OFA，不碰 tensor core。`s8/s32` 解锁前后不动，INT8 也满速。

所以这条路不提升 DLSS 和帧生成。DLSS 的某个版本是否走 FP8、走哪条 tensor 路径、要不要
额外的模型文件，本仓库没有测过。

会变快的是 FP32 累加的 tensor 路径：`f16/f32`、`bf16/f32` 各 2.00×，`e4m3/f32` 的
指令发射率 1.87–2.19×。最后这个是发射率不是 GEMM，上游那张卡上真实的 FP8 GEMM 只有
0.3%（见上面 ※）。FP8 推理实际能快多少，取决于 kernel 卡在哪一环。

`e4m3` 那三个倍数的来源：stock best 170.63 → 10/25 那次 325.98（**1.91×**）、`RUN0005`
那次 319.58（**1.87×**）、同 boot 复测 374.28（**2.19×**）。用哪个取决于当时 SM 频率，
比值本身随频率漂移；stock 那一侧是同一个基线。

> `RESULT.md`（10/25 23:18:33）写「FP8 170.63 → unchanged」，但同一秒落盘的
> `fp8mma-unlocked.txt` 记的是 `325.98`。以后者为准，`fp8-baseline` 与 `fp8-unlocked`
> 两份原始输出都在 `results/` 里。

### 想自己测帧率的话

1. **两组数据分开开机测。** 解锁在断电后就没了，所以 stock 那组必须先测、测完再解锁；
   或者先测解锁组、断电、再测 stock。两组之间只允许解锁这一项不同：同驱动、同 VBIOS、
   同分辨率、同测试项、同一张表。
2. **每组开测前先记解锁状态。** 跑 `tools\verify-unlock.ps1 -RunNumber <最近那次>`，
   看 `f16/f32 / f16/f16` 这个比值：0.50 附近是 stock，1.00 附近是解锁。这个比值是
   自比的，所以不受绝对频率影响；但如果它落在两档中间，说明那一轮的频率不稳，重测。
3. **跑测试的时候把结果存下来。** 3DMark 的 `Results` 目录
   （`C:\ProgramData\UL\3DMark\Results`）跑完会有 `.3dmark-result`，把它连同当时的
   `nvidia-smi --query-gpu=clocks.sm,power.draw,temperature.gpu --format=csv`
   一起留着。没有这两个文件，数字就还是「记下来的」。
4. **只用同一个测试项的同一张表比。** 25 个 DLC 里只有 `nvidia-dlss-test` 是 DLSS
   专项；`port-royal-test` 是光线追踪，跟 DLSS 无关。

## 方法

三步，全部在开机的 UEFI 阶段完成，早于 NVIDIA 驱动绑定：

1. 读显卡 VBIOS，解析 FWSEC 描述符，释放 WPR2
2. 从 GSP Falcon 里以 heavy-secure 模式拉起 FWSEC，再走 SEC2 Booter
3. 写 `FEAT_OVR_PLM=0xffffffff`、`SS0=0x88888888`、`SS1=0x8`，然后对 GPU 做一次
   PCIe FLR，验证三个值在 FLR 后仍然保持

驱动随后加载时看到的是「权限已全开」的硬件状态。

## 易失性

`SS0` / `SS1` 是 volatile 寄存器。**完全断电后 `SS1` 回到 `0x1`、`SS0` 回到某个新的
随机值**，需要重新走一遍开机流程。`SS0` 的冷启动值每次都不同（上面四个 `RUN` 的
`entry:` 行为证），所以别把它当常量去比对；要比就比 `SS1==0x1` 和 `readout1` 的
`full=0`。

本仓库只采用 **U 盘手动引导**：插 U 盘 → F8 → 选 U 盘 → 按 `U` → 约 40 秒 → 进 Windows。
开完机就可以拔掉 U 盘。

接管 ESP 的 `bootmgfw.efi` 或改 BCD 都能省掉按键，代价是每次开机多 40 秒，并把实验代码
放进启动关键路径。这条在这台机器上装上去就进不了系统，`install-esp.ps1` 保留但不用，
详见 [docs/INCIDENT-esp-takeover.md](docs/INCIDENT-esp-takeover.md)。

普通重启（不断电）不会清掉；只有真正断电才需要重来。两头都有实测：

- **同 boot 内**隔十几分钟再测，解锁仍在（两轮对照见 [results/README.md](results/README.md)）。
- **断电一夜后**（10/27 09:33，boot 07:50:43）实测回到 stock：`f16/f32` 91.4、
  `f16/f32 ÷ f16/f16 = 0.501`，和 10/25 那条 stock 基线（0.501）分毫不差。
  原始输出是 `results/mma-stock-after-poweroff.txt` / `fp8-stock-after-poweroff.txt`。

### 如果机器上同时装了 ESP 接管版

链式改名（把目标从 `bootmgfw.efi` 改成 `bootmgfw.orig.efi`）是 `ad103-2705` 分支
`e6ab1c8` 起就有的，之后每个构建都带。所以 U 盘和 ESP 上的 EFI **必须是同一个版本**：

- ESP 接管版：`bootmgfw.efi` 是解锁 EFI，链到 `bootmgfw.orig.efi`（原版）
- U 盘版如果链到 `bootmgfw.efi`，从 U 盘启动会链到 ESP 上那个自己，再链回自己

换版本时两个一起换。U 盘上没有 `AD104-UNLOCK\AUTO.TXT` 就保持手动按 `U`，
有的话会跳过按键；想要手动就把这个文件删掉。

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

两条硬约束：

1. **firmware asset 必须从你自己的 VBIOS 生成。** `booter_load_ad102.bin`、
   `v67-…-four-plm.bin`、GSP 镜像都是从 VBIOS 里解出来的，不同 VBIOS 的 FWSEC
   几何、Booter 签名选择、GSP 载荷都不同。别人的 asset 不能拿来用，也不该刷。
2. **`SS0/SS1` 的目标值是不是 `0x88888888`/`0x8`，要看你自己的卡。** 本卡 `SS1` 冷启动
   恒为 `0x1`、`SS0` 每次冷启动都是新的随机值（详见上面「解锁后实际改的寄存器」一节，
   四个 `RUN` 全不同）；issue #39 那张 Gigabyte 卡报的是 `0x25605026`/`4`，字段布局未必一致。
   `0x88888888` 的含义是「八个 4-bit 字段全填 8」（`vendor/unlock_610.c:28-31`），
   字段划分变了就得重新算目标值。

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
`sha256sum -c SHA256SUMS`，或 PowerShell 逐行比对）。里面有两份标记为异常的样本：

- `cublas-contaminated.txt`：后台有游戏占 GPU 时跑的。峰值仍是 180，但后续 rep 塌到 2.0。
  说明测量必须在空闲 GPU 上做（[docs/PITFALLS.md](docs/PITFALLS.md) #11）。
- `cublas-unlocked-run0005.txt` 之前的旧 cuBLAS 采样里出现过 `fp16/fp16acc` 4588 / 4744 TF/s，
  那是探针的 bug：cuBLAS 按 `computeType` 的宽度读 `alpha`，
  `float 1.0f` 的低两字节 `0x0000` 被当成 `__half 0.0`，每个 GEMM 输出全零矩阵。
  现在每个用例都带 `nonzero C` 自证（[docs/PITFALLS.md](docs/PITFALLS.md) #12）。

## 致谢

- [`JustAResearcher/gpu-unlock-ada`](https://github.com/JustAResearcher/gpu-unlock-ada)：
  本移植的上游，MSI AD104 Windows UEFI 端口的原作者
- [`impacifist/Windows-GPU-UNLOCK`](https://github.com/impacifist/Windows-GPU-UNLOCK)：
  上游的 snapshot/delta 策略来源。它在本移植做不到的两点上更成熟：
  多个显示子节点的显式枚举（v0.3.1 处理到 4 个），以及没有第二显示 GPU 时的
  `GU_CONSOLE_AGGREGATE` 拓扑。差距记在 [docs/PRIOR-ART.md](docs/PRIOR-ART.md)
- [`unitypit71/rtx4070tisuper-tensor-unlock`](https://github.com/unitypit71/rtx4070tisuper-tensor-unlock)：
  同型号的 Linux 侧完整案例，FWSEC/SEC2 流程的交叉参考
- [`Zagitta/gpu-unlock`](https://github.com/Zagitta/gpu-unlock)：机制的最初实现

## 状态：U 盘手动引导路线已验证成功（2026-10-27 更新）

`RUN0005` 是**第一次由修好的版本跑通**：EFI 写寄存器 → FLR → 干净交棒给
`bootmgfw.efi`，Windows 起来后立刻测到 `f16/f32 ÷ f16/f16 = 1.000`，对照组不动，
数值校验 `max_abs=0`。同一次 boot 内换时间点再测，比值仍是 1.001。

修掉的三处（分支 `cb3691b`；之后的 `c794f3e` 只改文档）：

| # | 症状 | 根因 |
|---|---|---|
| A | `GPU finish after close status=0x8000000000000006` 假失败 | `GpuChild()` 靠 device path 判断，而 stage 3 断控制器时正好把 path 摘掉 |
| B | 停机时屏幕无任何提示，看着像死机 | `GuBootHalt()` 跑在 `GuBootSilence()` 之后，`STOPPED.` 被自己吞掉 |
| C | 关日志之后每一道门都拒 | `GuLog()` 在日志已关时置 `Gu.fault`，把主动动作记成硬件故障 |

A 和 C 都有直接判据：`RUN0005` 日志里 `preflight[6b] CacheGpuChildren=0 children=3`
和 `handoff check passed` 同时出现，且 `GPU graph missing` / `finish incomplete`
一条都没有。B 只验证了不会误触发，它的用处是下次被拒时能看见原因。

**没做的**：ESP 接管那条仍然未验证通过（事故与恢复路线见
[docs/INCIDENT-esp-takeover.md](docs/INCIDENT-esp-takeover.md)）。这台机器上它
装上去就卡在 boot 阶段，唯一存活线索是 `boot_io.c` 的 `Inspect()` 会拒绝第二个
`MEDIA_HARDDRIVE_DP` 节点（已改，但从未在 ESP 路径上重测）。

移植期撞到的坑：[docs/PITFALLS.md](docs/PITFALLS.md)（12 条，含 cuBLAS alpha 那条）。
路走到哪、重跑看什么：[docs/WHERE-IT-STOPPED.md](docs/WHERE-IT-STOPPED.md)。
