# 证据：测量条件、寄存器原文、判据怎么来的

[README](../README.md) 里的结果表只放结论。这一份放结论背后的东西：仪器、全量数字、
日志原文、以及为什么判据是一个比值而不是绝对值。

## 测量条件

`mma_bench`，register-resident 指令发射率，20000 iter，66 SM，sm_89。每次 5 rep 取 best。

| 列 | 来源 | 功耗 |
|---|---|---|
| stock | 10/25 那条基线 + 10/27 断电后复测 | 285 W（出厂） |
| 解锁 285 W | `RUN0005`（无 override） | 285 W |
| 解锁 320 W | `RUN0013`（2026-10-28 07:43，override 生效） | 320 W |

`e4m3/f32` 这一行和其余六行**不是一个仪器**。`f16/f32`、`bf16/f32` 走的 `mma_bench`
和它同属寄存器空转的发射率探针，但 `e4m3` 用的是 `mma.m16n8k32.e4m3.e4m3.f32`
（[`bench/fp8_mma_bench.cu`](../bench/fp8_mma_bench.cu)），单指令 FLOP 数凑成一样是为了可比。
**它是发射率，不是 GEMM。**

上游对同一张卡跑过 matched E4M3 CUTLASS GEMM（`m=n=k=4096`，240 W 帽，同一 profiler
二进制），结果是 **59,325.8 → 59,495 GFLOP/s，即 1.0029×（0.3%）**，见
`gpu-unlock-ada/docs/ada-2705-report.md:95-107`，作者自己写明
「no meaningful FP8 gain」。两条并不矛盾：发射率翻倍说明这条指令路径的权限位确实开了，
而那个特定 GEMM 在 240 W 下是别的瓶颈（带宽/占用率/power）。1.87–2.19× 不等于「FP8 推理快一倍」。

`e4m3` 那三个倍数的来源：stock best 170.63 → 10/25 那次 325.98（**1.91×**）、`RUN0005`
那次 319.58（**1.87×**）、同 boot 复测 374.28（**2.19×**）。用哪个取决于当时 SM 频率，
比值本身随频率漂移；stock 那一侧是同一个基线。

> `RESULT.md`（10/25 23:18:33）写「FP8 170.63 → unchanged」，但同一秒落盘的
> `fp8mma-unlocked.txt` 记的是 `325.98`。以后者为准。

## 全量表

`RUN0013` 同一个 `mma_bench` 20000/3，连跑四次，下表是最后一次，原始输出在
[`results/mma-unlocked-320w-run0013.txt`](../results/mma-unlocked-320w-run0013.txt)：

| 模式 | stock | 解锁 285 W | 解锁 320 W |
|---|---:|---:|---:|
| `f16/f32` | 88.0 | 176.1 | **181.3** |
| `bf16/f32` | 87.9 | 175.6 | **182.2** |
| `f16/f16` | 175.6 | 175.1 | 180.9 |
| `s8/s32` | 352.5 | 348.0 | 367.8 |
| `dp4a` | 87.0 | 87.7 | 89.8 |
| `ffma` | 41.8 | 41.5 | 41.7 |
| `e4m3/f32` ※ | 170.63 | 319.58 | 360.33 |

同一次开机的 `fp8_mma_bench` 给 `e4m3/f32 = 360.33`
（[`results/fp8-unlocked-320w-run0013.txt`](../results/fp8-unlocked-320w-run0013.txt)）。

另外四行来自 cuBLAS GEMM（N=8192，含 alpha 宽度校验），没有 stock 对照，只有解锁后的绝对值：

| 模式 | 解锁后 |
|---|---:|
| `fp16/fp32acc` | 142.85 TF/s |
| `fp16/fp16acc` | 140.44 TF/s |
| `bf16/fp32acc` | 146.84 TF/s |
| `fp32` | 27.72 TF/s |

## 数值校验

`gemm_check`，3 形状 × FP16/BF16 两种累加。每个模式 65536 + 6144 + 8255 = 79935 个 cell，
两个模式合计 **159870 个**，全部 `failures=0`, `max_abs=0`
（[`results/gemm-check-320w-run0013.txt`](../results/gemm-check-320w-run0013.txt)）。

## 判据为什么是比值

同一个 boot 里再测一遍，所有模式整体涨了 6%（`f16/f16` 175.1→188.0，`f16/f32`
176.1→188.1），而 `f16/f32 ÷ f16/f16` 只在 1.006 与 1.001 之间动：变的是 SM 频率。

降频更狠时 `f16/f32` 能落到 88 附近，和没解锁的样子一样，光看数字分不出来。所以判据是
**stock ≈ 0.50、解锁 = 1.00** 的这个比值，它把频率约掉了。两次采样的完整对照在
[`results/README.md`](../results/README.md)。

`RUN0013` 连跑四次，`f16/f16` 分别落在 180.6–183.8，每次比值都在 1.00 上下。这个量级的
波动是频率，不是门。

## 日志原文

`RUN0005` 解锁后实际改的寄存器（`H:\AD104-UNLOCK\RUN0005.TXT`，行号照抄）：

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

## `readout1` 是九个 3-bit 字段

`FEAT_READOUT_1`，`0x00823818`，掩码 `0x07ffffff`（27 bit），见
`windows/ad103-2705/vendor/unlock_610.c:33`。stock 时 `fields=0 0 2 0 0 2 0 2 0`
（其中三个字段是 2 = 1/4 速率），解锁后九项全 0，`full` 由
`valid && !(value & 0x07ffffff)` 算出（`vendor/unlock_610.c:391`）。

哪三个字段对应哪条指令路径，**没有建立**。上游 `rtx4090-register-report.md:272-278` 写
「The mapping of those three reduced fields to the named FMLA/IMLA fuse words is not
established」。`FMLA32=1→0`、`IMLA2=1→0`、`IMLA4=1→0` 那张表来自 NVIDIA RM getter 的
另一条读法（`docs/evidence/ada2705/sm-rates.json`），不是从 `readout1` 解出来的；
两者是同一个事实的两种视图，不能互相推导。

## `SS0` 的 stock 值不是常量

逐次冷启动实测（各 `RUN` 的 `entry:` 行）：

```
RUN0001  ss0=0x6310036   RUN0002  ss0=0x7300036
RUN0004  ss0=0x5305036   RUN0005  ss0=0x7300036
```

`SS1` 恒为 `0x1`；`SS0` 逐次不同，且差异不是只在高位（`0x6310036` 和 `0x5305036`
低 16 位是 `0x0036` 和 `0x5036`）。上游也记了同一件事：
`rtx4090-register-report.md:277-278`「The high byte of cold SS0 varied between earlier
power-ons while all override enable bits stayed clear; its meaning is unverified」。

只读探针 `CAP0002.JSON`（本机 `G:\workspace\rtx2705\captures\`，10/25 20:31，
`gpu_writes:false`）那次采到 `SS0=0x27304036` / `SS1=0x1`，那是**一次采样**，不是固定值。

所以「断电后回到 stock」这个判断，别拿 `SS0` 的等号去验；看 `SS1==0x1` 加 `readout1`
的 `full=0` 就够了。

## 断电后回到 stock 的实测

**同 boot 内**隔十几分钟再测，解锁仍在（两轮对照见
[`results/README.md`](../results/README.md)）。

**断电一夜后**（10/27 09:33，boot 07:50:43）实测回到 stock：`f16/f32` 91.4、
`f16/f32 ÷ f16/f16 = 0.501`，和 10/25 那条 stock 基线（0.501）分毫不差。原始输出是
`results/mma-stock-after-poweroff.txt` / `fp8-stock-after-poweroff.txt`。
