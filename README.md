# RTX 4070 Ti SUPER (AD103, `10de:2705`) — Windows UEFI tensor unlock

把上游 `JustAResearcher/gpu-unlock-ada` 的 **MSI AD104 Windows UEFI 端口**移植到一张
**ASUS B550-I + AD103 4070 Ti SUPER**，在 Windows 下拿到 FP32-累加 tensor 路径的
2× 算力。

移植过程中撞到的问题几乎全部来自「上游那台机器只有一个显示节点、一个 xHCI 控制器、
一套驱动」，而这张卡/这块板是「两个显示节点、两个 xHCI、三套驱动」。这些差异不在
上游文档里，靠逐个 gate 的日志才定位到。记录在 [docs/PITFALLS.md](docs/PITFALLS.md)。

## 结果

`mma_bench`，register-resident 指令发射率，20000 iter × 3 rep，66 SM，sm_89：

| 模式 | 解锁前 | 解锁后 | 倍数 | 是否目标 |
|---|---:|---:|---:|---|
| `f16/f32` (FP16 in, FP32 acc) | 88.0 TF/s | **176.6** | **2.01×** | ✅ |
| `bf16/f32` (BF16 in, FP32 acc) | 87.9 TF/s | **176.2** | **2.00×** | ✅ |
| `e4m3/f32` (FP8 in, FP32 acc) | 170.63 TF/s | **325.98** | **1.91×** | ✅ |
| `f16/f16` (FP16 acc) | 175.6 TF/s | 176.0 | 1.00× | 控制组 |
| `s8/s32` (INT8) | 352.5 TF/s | 350.7 | 0.99× | 控制组 |
| `dp4a` | 87.0 TF/s | 88.6 | 1.02× | 控制组 |
| `ffma` (scalar FP32) | 41.8 TF/s | 42.1 | 1.01× | 控制组 |

数值校验（`validate_gemm`，3 形状 × 2 模式）：`failures=0`, `max_abs=0`。

原始输出在 [results/](results/)。

解锁后实际改的寄存器，从设备日志读回：

```
before:  FEAT_OVR_PLM=0xffffff8f  SS0=0x27304036  SS1=0x00000001  readout1=0x00410080
applied: FEAT_OVR_PLM=0xffffffff  SS0=0x88888888  SS1=0x00000008  readout1=0
post-FLR: SS0=0x88888888  SS1=0x00000008  readout1=0  full=1
```

`readout1` 的 27 个 feature 位全部归零，`FMLA32` / `IMLA2` / `IMLA4` 三个权限位
变为 full。

## 对 DLSS 和帧生成：没有收益

这是实测结论，不是推测。

| 路径 | 用什么硬件 | 受这次解锁影响吗 |
|---|---|---|
| **帧生成 (Frame Generation)** | Optical Flow Accelerator，独立单元 | **否** |
| **DLSS 超分** | tensor core `HMMA.16816.F16`（FP16 累加） | **否** |
| 本次解锁 | `HMMA.16816.F32` / `BF16.F32` / `FP8.F32`（FP32 累加） | 是 |

3DMark NVIDIA DLSS 功能测试（4K，DLSS 1.5 路径）连续两次结果：

```
DLSS off:  33.72 FPS  ->  33.75 FPS
DLSS on : 126.22 FPS  -> 126.48 FPS
```

差 0.2%，在噪声内。原因不是解锁没生效，而是：

- `f16/f16` 在解锁前后都是 ~176 TF/s —— 那已经是 sm_89 的 FP16 tensor 物理峰值，
  没有可解锁的余量，而 DLSS 超分正好走这条。
- 帧生成用 OFA，完全不碰 tensor core。

**所以「解锁能提升 DLSS / 帧生成」这个前提是错的。** 解锁打开的是 FP32-累加算力，
对训练、大 batch 推理、FP8 推理有效；对游戏里的 DLSS 无效。

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
不值得。工具里的 `install-esp.ps1` 保留但默认不推荐。

普通重启（不断电）不会清掉；只有真正断电才需要重来。

## 硬件

| 项 | 值 |
|---|---|
| GPU | NVIDIA RTX 4070 Ti SUPER，AD103，`10de:2705`，16376 MiB |
| VBIOS | `95.03.45.40.c5` |
| 驱动 | 621.01 |
| 主板 | ASUS ROG STRIX B550-I GAMING，BIOS 4304 |
| CPU | AMD Ryzen 7 5700X3D |
| OS | Windows 11，Secure Boot 关闭 |
| PCI | `0000:08:00.0`，BAR0 `0xFB000000` (16 MiB)，BAR1 16 GiB（Re-BAR 开） |

## 复现

上游代码和移植说明以 `JustAResearcher/gpu-unlock-ada` 的 `windows/ad104-msi` 为起点。
本仓库不重复上游代码，只补本卡的差异：

```powershell
# 1. 拿上游
git clone https://github.com/JustAResearcher/gpu-unlock-ada

# 2. 用本仓库的补丁工具把 MSI AD104 目录改成本卡（device id / bus / BAR0 / 路径）
python tools/patch-target.py

# 3. 需要改的代码点见 docs/PITFALLS.md —— 那些是编译期必须的，工具覆盖不到

# 4. 编译并放到 FAT32 U 盘的 \EFI\BOOT\BOOTX64.EFI
tools\deploy-usb.ps1

# 5. 开机 F8 选 U 盘，按 U
```

验证：

```powershell
cd bench
.\build-cublas.cmd          # 需要 CUDA + MSVC
.\cublas_gemm.exe 8192 5 3
tools\verify-unlock.ps1
```

## 关于本仓库的代码

`bench/` 下的三个 `.cu` 和 `tools/` 下的脚本是自己写的，MIT。上游 GPL-2.0 的代码没有
复制进来，用法是在上游仓库上打本仓库记录的补丁。

`results/` 里是原始 benchmark 输出。`cublas-contaminated.txt` 是后台有游戏占用 GPU
时跑的，不作为结论，留着是因为它说明了一件有用的事：`f16/f32` 峰值仍是 180，
但后续 rep 会塌到 2.0 —— 测量必须在空闲 GPU 上做。

## 致谢

- [`JustAResearcher/gpu-unlock-ada`](https://github.com/JustAResearcher/gpu-unlock-ada)
  — 本移植的上游，MSI AD104 Windows UEFI 端口的原作者
- [`impacifist/Windows-GPU-UNLOCK`](https://github.com/impacifist/Windows-GPU-UNLOCK)
  — 上游的 snapshot/delta 策略来源
- [`unitypit71/rtx4070tisuper-tensor-unlock`](https://github.com/unitypit71/rtx4070tisuper-tensor-unlock)
  — 同型号的 Linux 侧完整案例，FWSEC/SEC2 流程的交叉参考
