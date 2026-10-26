# 测量条件与可复核性

每个 `.txt` 是一次原始采集，`SHA256SUMS` 是它们的哈希（在 `results/` 下执行
`sha256sum -c SHA256SUMS` 复核）。

| 文件 | 探针 | 说明 |
|---|---|---|
| `fp8-baseline.txt` / `fp8-unlocked.txt` | `bench/fp8_mma_bench.cu`，`mma.m16n8k32` e4m3→f32，寄存器空转 | **issue rate**，不是 GEMM；与 `mma-baseline/unlocked.txt` 同一进程口径，可直接比 |
| `mma-baseline.txt` / `mma-unlocked.txt` | `mma_bench` 系列（f16/bf16/s8/dp4a/ffma） | 同一次会话采集 |
| `cublas-contaminated.txt` | cuBLAS GEMM | **污染样本**：采集时 GPU 有其他负载，保留作为 `docs/PITFALLS.md` 那个坑的原始证据 |

## 采集条件（补记）

| 项 | 值 |
|---|---|
| GPU | RTX 4070 Ti SUPER，AD103，`10de:2705`，16376 MiB，66 SM，sm_89 |
| 迭代/重复 | `iters=20000`，`reps=3`（FP8 与 MMA 两套同参数） |
| 驱动 / 系统 | 待补（`nvidia-smi` 的 driver version + Windows 版本或 Linux 内核） |
| 功耗上限 | 待补（`nvidia-smi -q -d POWER` 的 Power Limit） |
| 采集时是否受功率墙 | 待补（`clocks_throttle_reasons.active` 是否出现 `SW Power Cap`） |
| 桌面/后台负载 | 待补 |

## 方法学注意：首跑污染

`fp8-baseline.txt` 的三次是 **147.6 / 165.4 / 170.6 TF/s（±16%）**，而 unlocked 是
326.0 / 323.9 / 307.4（±6%）。首个样本明显偏低，符合"首个 kernel 未进入稳态频率"的常见现象。

两种处理都可接受，但要**写清楚**：

1. 弃首跑，用后两次的 median（baseline 168.0 / unlocked 323.9 → 1.93×）；
2. 保留全部，但报告 best 与 median 并注明首跑偏低的原因（当前采用的 best 口径：170.63 → 325.98，1.91×）。

无论哪种，结论都落在 **1.9× 附近**，与"发射率翻倍"一致；`f16/f16`、`s8/s32`、`dp4a`、`ffma`
在两侧基本不变，是这条结论的对照组。
