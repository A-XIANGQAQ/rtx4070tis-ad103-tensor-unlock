# 测量条件与可复核性

每个 `.txt` 是一次原始采集，`SHA256SUMS` 是它们的哈希。复核（在 `results/` 下）：

```powershell
Get-Content SHA256SUMS | ForEach-Object {
  $want,$f = $_ -split '\s+',2
  $got = (Get-FileHash $f.Trim() -Algorithm SHA256).Hash.ToLower()
  if($got -ne $want){ "MISMATCH $f" }
}
# 什么都不打印 = 全部一致
```

有 `sha256sum` 的环境直接用 `sha256sum -c SHA256SUMS`。

| 文件 | 探针 | 说明 |
|---|---|---|
| `mma-baseline.txt` | `bench/mma_bench.cu`（f16/bf16/s8/dp4a/ffma） | stock 基线，10/25 采集 |
| `fp8-baseline.txt` | `bench/fp8_mma_bench.cu`，`mma.m16n8k32` e4m3→f32，寄存器空转 | **issue rate**，不是 GEMM；stock 基线 |
| `mma-unlocked.txt` / `fp8-unlocked.txt` | 同上两套 | 10/25 23:18 那次解锁（`RESULT.md` 记 EFI `5d5277c2`，100864 B；**该 EFI 产物与当次 `RUNxxxx.TXT` 均已不在盘上**），`reps=3` |
| `mma-unlocked-run0005.txt` / `fp8-unlocked-run0005.txt` | 同上两套 | `RUN0005`（修好的 EFI）那次开机，`reps=5` |
| `cublas-unlocked-run0005.txt` | `bench/cublas_gemm.cu` GEMM，N=8192 | `RUN0005` 那次开机；每用例带 `nonzero C` 校验行 |
| `mma-unlocked-live.txt` / `fp8-unlocked-live.txt` / `cublas-unlocked-live.txt` | 同上三套 | 同一个 boot 内后来复测（卡跑在 2640 MHz） |
| `cublas-contaminated.txt` | cuBLAS GEMM | **污染样本**：采集时 GPU 有其他负载，保留作为 `docs/PITFALLS.md` #11 的原始证据 |
| `mma-stock-after-poweroff.txt` / `fp8-stock-after-poweroff.txt` | 同上两套 | 10/27 09:33 采集。**断电一夜后第一次上电、没走 U 盘引导**，是易失性的对照组：确认 `SS0`/`SS1` 真的被断电清掉了 |

`*run0005` 与 `*-live` 的 6 行 `#` 头里带 EFI 的 sha256、boot 时刻、日志路径。
拿它和 `H:\AD104-UNLOCK\RUN0005.TXT` 对得上，才能证明这批数字是那次解锁状态下测的。

## 同一状态、两次复测：绝对值随频率走，比值不走

`RUN0005` 那次 boot 内测了两轮，中间没重启：

| | `mma-unlocked-run0005` | `mma-unlocked-live` |
|---|---:|---:|
| `f16/f16` | 175.1 | **188.0** |
| `f16/f32` | 176.1 | **188.1** |
| `bf16/f32` | 175.6 | **187.5** |
| `s8/s32` | 348.0 | 374.9 |
| `dp4a` | 87.7 | 93.3 |
| `ffma` | 41.5 | 44.8 |
| **`f16/f32 ÷ f16/f16`** | **1.006** | **1.001** |

所有模式一起涨了约 6%，因为它们受同一个 SM 频率支配。结论只由最后一行的比值承载，
绝对值只是当时的频率乘一个常数。`README.md` 和 `tools/verify-unlock.ps1` 都用比值判定，
原因就在这里：拿绝对值判会把降频误读成没解锁，也会把升频误读成解锁更强。

## 断电一夜之后再测：易失性的对照组

`mma-stock-after-poweroff.txt` / `fp8-stock-after-poweroff.txt` 是 10/27 09:33 采的，
机器断电一夜后**第一次上电**（boot 07:50:43），走的是正常 Windows Boot Manager，
没有插 U 盘、没有跑解锁 EFI。它们的作用是给「断电真的清掉了吗」一个可核对的答案。

| | 10/25 stock 基线 | 10/27 断电后 | `RUN0005` 解锁态 |
|---|---:|---:|---:|
| `f16/f16` | 175.6 | 182.3 | 175.1 |
| `f16/f32` | 88.0 | **91.4** | **176.1** |
| `bf16/f32` | 87.9 | **91.2** | **175.6** |
| `s8/s32` | 352.5 | 363.6 | 348.0 |
| `dp4a` | 87.0 | 90.0 | 87.7 |
| `ffma` | 41.8 | 42.1 | 41.5 |
| **`f16/f32 ÷ f16/f16`** | **0.501** | **0.501** | **1.006** |
| `e4m3/f32` best | 170.63 | 181.93 | 319.58 |

读法：
- 绝对值这一列整体比 10/25 那次高约 4%（`f16/f16` 175.6 → 182.3），是频率差异，不是状态差异。
- **比值一模一样**（0.501 对 0.501），而解锁态是 1.006。断电确实把 `SS0`/`SS1` 清回了冷启动值。
- `e4m3` 也跟着在 181.93（stock 档）而不是 319 以上，与发射率口径一致。

这条和 `README.md`「易失性」一节说的是同一件事，只是现在有文件可查了。

## 采集条件（`RUN0005` 那次开机，已补全）

| 项 | 值 |
|---|---|
| GPU | RTX 4070 Ti SUPER，AD103，`10de:2705`，16376 MiB，66 SM，sm_89 |
| 迭代/重复 | `iters=20000`，`reps=5`（FP8 与 MMA 两套同参数）；cuBLAS 为 `N=8192 iters=3 reps=3` |
| 驱动 / 系统 | `621.01` / Windows 11 专业工作站版 `10.0.26300` Build 26300 |
| VBIOS | `95.03.45.40.c5` |
| 功耗上限 | 285 W（default 285 W / max 285 W，未被改过） |
| 采集时是否受功率墙 | 否。`clocks_throttle_reasons.active = 0x1`，只命中 `gpu_idle`；`sw_power_cap` / `hw_slowdown` / `hw_thermal_slowdown` 全为 Not Active。`clocks.max.sm = 3165 MHz` |
| 桌面/后台负载 | 空闲。显卡无游戏/推理进程占用 |
| PCIe | Gen4 ×16 |

`mma-baseline.txt` / `fp8-baseline.txt` 是更早（10/25）采的，桌面负载情况没有记录；
它们的用途只是和同口径的 unlocked 对照，绝对值不作跨日比较。

## 方法学注意：首跑污染

`fp8-baseline.txt` 的三次是 **147.6 / 165.4 / 170.6 TF/s（±16%）**，而 unlocked 是
326.0 / 323.9 / 307.4（±6%）。首个样本明显偏低，符合「首个 kernel 未进入稳态频率」的常见现象。

两种处理都可接受，但要**写清楚**：

1. 弃首跑，用后两次的 median（baseline 168.0 / unlocked 323.9 → 1.93×）；
2. 保留全部，但报告 best 与 median 并注明首跑偏低的原因（当前采用的 best 口径：170.63 → 325.98，1.91×）。

无论哪种，结论都落在 **1.9× 附近**，与「发射率翻倍」一致；`f16/f16`、`s8/s32`、`dp4a`、`ffma`
在两侧基本不变，是这条结论的对照组。

（后来又测到 `e4m3/f32` 在 319.58 与 374.28 两档，差异同样来自 SM 频率而不是机制：
`*-live` 那组跑在 2640 MHz，`*run0005` 那组跑在更低频。三档相对同一个 stock 基线
170.63 的倍数分别是 **1.91× / 1.87× / 2.19×**。）

> 这些倍数只对发射率探针成立。同一张架构上真实的 FP8 GEMM，Goldlionren 的 AD103
> 4080S 是 199.4 → 310.4 / 298.7（1.50–1.56×），上游的 matched E4M3 CUTLASS 在
> 4070 Ti SUPER `m=n=k=4096`、240 W 帽下是 59,325.8 → 59,495（1.003×）。
> 三个仪器差出一倍以上，原因在访存与功率墙，不是谁测错。详见
> [../docs/PRIOR-ART.md](../docs/PRIOR-ART.md) 末节。

## 两条必须记住的口径

**一、比值是判据，绝对值不是。** 见上面那张两轮对照表。同一台机器、同一次 boot，
绝对值能整体漂 6%；降频再狠一点就能把 `f16/f32` 压回 88 附近，那里和 stock 长得一模一样，
光看数字分不出「没解锁」和「解锁了但被降频」。这一档我们没留下采集文件（当时 GPU 被别的
负载占着，只看了屏幕上的数字），所以不引用具体时钟；只把结论留着：**比 `f16/f32 ÷ f16/f16`，
stock ≈ 0.50，解锁 = 1.00。**

**二、数字大得离谱时先怀疑自己。** `cublas_gemm.cu` 曾报出 `fp16/fp16acc` 4588 / 4744 TF/s
（约 4000–4700，比物理峰值高一个数量级）。原因是 cuBLAS 按 `computeType` 的宽度读
`alpha`，`float 1.0f` 的低两字节是 `0x0000`，被当成 `__half 0.0` → 每个 GEMM 输出全零
矩阵 → 工作量塌掉、计时器被自己的 bug 缩短。详见 `docs/PITFALLS.md` #12。
修好之后同一个用例是 140–151 TF/s，每行都带 `nonzero C: 67108854 / 67108864` 自证。
