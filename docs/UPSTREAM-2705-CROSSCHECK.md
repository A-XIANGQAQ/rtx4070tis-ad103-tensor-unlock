# 上游 2705 报告与本仓库的逐项对照（2026-10-28）

一句话：**同一张卡、同一份 payload、同一套探针，比值一致到小数点后两位；绝对值差 4–8%，来源
是 SM 时钟而不是机制。** 引外部数字前先看这里的口径，别把两边的绝对值当成互相矛盾。

## 一、两份样本是什么

| | 上游 `JustAResearcher/gpu-unlock-ada` | 本仓库 `A-XIANGQAQ/rtx4070tis-ad103-tensor-unlock` |
|---|---|---|
| 文档 | [`docs/ada-2705-report.md`](https://github.com/JustAResearcher/gpu-unlock-ada/blob/main/docs/ada-2705-report.md)（11695 B，2026-10-23） | `README.md` 结果表 + [`EVIDENCE.md`](EVIDENCE.md) |
| 路线 | Linux 内核模块（commit `a7bcce01`，`.ko` sha256 `a2afbed0…`） | UEFI 应用（在本 fork 的 `windows/ad103-2705`） |
| 系统 / 驱动 | Linux `5.15.0-177-generic` / NVIDIA `580.178.04` 原版 | Windows 11 build 26300 / `621.01` |
| 功率帽 | **240 W** | **285 W**（无 override）/ **320 W**（override） |
| 卡 | RTX 4070 Ti SUPER `10de:2705`，66 SM | 同型号 `10de:2705`，66 SM，16376 MiB |
| 负载 | 同一套 `sm_89` `mma_bench`：20000 iter、3 次计时、寄存器驻留 HMMA/IMMA/dp4a/FFMA | 同一套 `mma_bench`：20000 iter、`reps=5` |
| 判据 | 同模式解锁/stock 倍数 | 同状态内 `f16/f32 ÷ f16/f16`（绝对值会漂 6%，只看比值） |

两边都加载同一份四写 payload（sha256 `44c36b2d…`，64000 B），都读到 marker `0x67b00001`，
都写 `SS0=0x88888888` / `SS1=0x8` 并做 FLR 后读回。四写的四个目标见
[`ECOSYSTEM-2026-10.md`](ECOSYSTEM-2026-10.md) 第四节，或直接跑：

```powershell
python tools\payload-report.py
```

## 二、同口径逐项对表（TF/s，`mma_bench` 发射率）

| 模式 | 上游 stock | 上游解锁 | 上游倍数 | 我们 stock | 我们 285 W | 我们 320 W | 我们倍数（320 W） |
|---|---:|---:|---:|---:|---:|---:|---:|
| `f16/f32` | 95.0 | 189.9 | 2.00× | 88.0 | 176.1 | 181.3 | 2.06× |
| `bf16/f32` | 95.0 | 189.7 | 2.00× | 87.9 | 175.6 | 182.2 | 2.07× |
| `f16/f16` | 189.9 | 189.9 | 1.00× | 175.6 | 175.1 | 180.9 | 1.03× |
| `s8/s32` | 379.5 | 379.5 | 1.00× | 352.5 | 348.0 | 367.8 | 1.04× |
| `dp4a` | 94.4 | 94.4 | 1.00× | 87.0 | 87.7 | 89.8 | 1.03× |
| `ffma` | 45.4 | 45.5 | 1.00× | 41.8 | 41.5 | 41.7 | 1.00× |

换成我们文档使用的比值判据（同一个状态内 `f16/f32 ÷ f16/f16`）：

| 状态 | 上游 | 我们 |
|---|---|---|
| stock | 95.0 ÷ 189.9 = **0.500** | 88.0 ÷ 175.6 = **0.501** |
| 解锁 | 189.9 ÷ 189.9 = **1.000** | 320 W：181.3 ÷ 180.9 = **1.002**；285 W：176.1 ÷ 175.1 = **1.006** |

这一栏是两边真正可比的东西，**一致到小数点后两位**。上游另外用只读 RM getter 看了三个
3-bit 字段（FMLA32 / IMLA2 / IMLA4 由 1 变 0），我们看的是 `readout1` 的九个字段 —— 同一件事
的两个观测口。

## 三、绝对值差 4–8% 从哪来：SM 时钟，不是功率

我们这边高功率帽（320 W）反而数字更低，所以这不是"功率越大越快"的故事。可核对的三个点：

| 项 | 上游 | 我们 |
|---|---|---|
| 实测 SM 时钟 | stock 2820 MHz；解锁后 2670–2820 MHz | `*-live` 那组 **2640 MHz**（`clocks.max.sm = 3165 MHz`）；`run0005` 那组更低 |
| 归一化后的 `f16/f16` | 189.9 | 175.6 × (2820 / 2640) ≈ **187.6**（差 −1.2%） |

即：把 2640 → 2820 补回去，两边的绝对发射率落在 1% 以内。剩下的差异是驱动与 OS 的调频策略，
不是 unlock 机制。上游自己也写明"采样的 200 ms 间隔不足以给出可持续板卡功率"，我们这边同样
只有 `clocks_throttle_reasons.active = 0x1`（只命中 `gpu_idle`）这一条旁证。

**因此：** 引用时用比值（0.50 → 1.00），不要把两边的 TF/s 直接并排放进同一张表还说"我们更快/更慢"。

## 四、FP8 是两件不同的事，别混

| | 是什么 | 数字 |
|---|---|---|
| 上游 matched E4M3/FP32 **CUTLASS GEMM** | 真 GEMM，`m=n=k=4096`，240 W 帽，10 warmup + 20 迭代 | 59,325.8 → 59,495 GFLOP/s，**1.0029×** |
| 我们的 `e4m3/f32`（`bench/fp8_mma_bench.cu`） | **发射率**，寄存器空转，不是 GEMM | 170.63 → 319.58 → 360.33（随档位） |

两行都对，但回答的问题不同：前者说"这张卡的 FP8 GEMM 撞带宽/墙，解锁没用"，后者说"FP8 指令的
发射限制被解开了"。`results/README.md` 里那句"这些倍数只对发射率探针成立"就是这条边界。同一份
上游报告里 FP16/FP32 的 CUTLASS GEMM 是 **177,543 GFLOP/s**（`4096³`、240 W、无 stock 对照），
也不能当倍数用。

## 五、机制层面逐条对上

| 项 | 上游 2705 报告 | 本仓库 |
|---|---|---|
| 四写 payload | 同一 sha256 `44c36b2d…`、64000 B | `profile.c:19` 钉同一 sha256；`tools/payload-report.py` 可复跑校验 |
| marker | 内核日志记到 `0x67b00001`、SEC2 halted | 每份 `RUN*.TXT` 都有 `AD102 payload result: … marker=0x67b00001 …` |
| 三项权限写 | "the three required permission writes" | `vendor/unlock_610.c:339-341` 列 FBPA / WPR / FEAT，FBPA `required=false` |
| 第四个字段 FBPA | 仍读 `0xffffff0f`，**明确不计入解锁** | 同：观测项，不计必过 |
| `SS0`/`SS1` 写值与 FLR 后保持 | `0x88888888` / `0x8`，post-FLR 读回一致 | RUN0004+ 的 `AD102 permission post-FLR` 行 |
| 已打开 PLM | `da96e3f`：记 skipped，不算失败 | `vendor/unlock_610.c:1301-1303` 返回 `-EALREADY`，RUN0003 已记 `SKIPPED` |
| 断电 | 第二次完整 AC 循环恢复同一组 selector 读回，**吞吐未复测** | RUN0002（`mma-stock-after-poweroff`）确认 `SS0`/`SS1` 被清回 stock |

差别只有一处，是我们独有的：**320 W override 下 `SS0`/`SS1` 读 0 的 blank 入口态闸门**
（[`PITFALLS.md`](PITFALLS.md) #13）。上游报告没有这个入口态，因为那份样本是 stock VBIOS +
Linux 模块直跑，不经过 Windows 侧 VBIOS override。

## 六、引用规则

1. 引**比值**用本仓库的数（0.50 → 1.00，或 2.06×），并注明判据与状态。
2. 引**绝对值**必须带四要素：功率帽、系统/驱动、SM 时钟、探针名。缺一项就只能当线索。
3. 上游 2705 报告的数字一律标"上游自述，单卡 canary"；它的第二次 AC 只复了 selector，没复吞吐。
4. 不要引 `results/cublas-contaminated.txt`（污染样本，见 PITFALLS #11），也不要引
   `fp16/f16acc` 的 4588 / 4744 TF/s（alpha 宽度 bug，见 PITFALLS #12）。

## 七、共同限制

两份都只是一张卡的一次冷启动 canary。上游原话："This does not establish support for every AD103
board." 我们的 [`HANDOFF.md`](HANDOFF.md) 同样只声明这一张卡、这一次 `RUN0013`。跨板型、跨 VBIOS
（`95.03.45.40.c5` 之外）仍是空白。
