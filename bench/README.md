# bench：四个探针在本仓库，两个在上游

`.cu` 与 `build*.cmd` 是本仓库的（MIT，首行带 SPDX）。`.exe` 不进仓库，`.gitignore` 挡着，
换机器要自己编。

## 仓库里的四个

| 源文件 | 产物 | 测什么 | 怎么读 |
|---|---|---|---|
| `fp8_mma_bench.cu` | `fp8_mma_bench.exe` | `mma.m16n8k32.e4m3.e4m3.f32` 的指令发射率，寄存器空转 | **发射率，不是 GEMM**。单指令 FLOPs 与 `mma_bench` 的 `m16n16k16` 都凑成 8192，所以两者可直接对拍：stock 170.63 → 解锁 319.58–374.28 |
| `cublas_gemm.cu` | `cublas_gemm.exe` | 真实 cuBLAS GEMM，`N=8192`，`iters=3 reps=3` | 每个用例末尾的 `nonzero C: …`；输出全零时标 `<-- BROKEN`。这就是 alpha 宽度那个 bug 的现场 |
| `fp8_bench.cu` | `fp8_bench.exe` | 走 cuBLASLt 的 FP8 e4m3 GEMM | 同上，先看 `nonzero C` |
| `probe_f16acc.cu` | `probe_f16acc.exe` | 「float alpha 毁掉 16F 累加 GEMM」的最小复现 | 两个数差一个数量级：全零时 4188.85，正确的 143.77（320 W 下 4668.65 / 152.90）。见 [PITFALLS #12](../docs/PITFALLS.md) |

## 两个不在仓库里的

```powershell
# mma_bench：上游的诊断探针，源码在
#   gpu-unlock-ada/diagnostics/bench/mma_bench.cu   (GPL-2.0-only，未随本仓库分发)
# gemm_check：本机只有 exe，源码不在这台机器上
#   G:\workspace\rtx2705\bench\gemm_check.exe
```

`tools/verify-unlock.ps1` 的 2/4 节拿 `mma_bench.exe` 算 `f16/f32 ÷ f16/f16`，3/4 节拿
`gemm_check.exe` 做数值校验。两者缺一个，那一节就打 `not found` 并判 FAIL；用 `-BenchDir`
和 `-GemmCheck` 指到别处。

## 编译

```powershell
bench\build.cmd all          # 四个全编
bench\build.cmd cublas       # 只编一个：cublas / fp8mma / fp8gemm / f16acc
```

需要 CUDA 与 MSVC。`build.cmd` 自己找 `vcvars64.bat`：先 `%VCVARS64%`，再 `vswhere.exe`，
再两个固定路径，都没有才报 `Could not find vcvars64.bat`。编译参数 `-O3 -arch=sm_89
-std=c++17`；输出写 `%TEMP%\build-<目标>.log`，过滤掉 MSVC 的 C4819（CUDA 头在 936 代码页下
的无关警告），成功打 `BUILD-OK`，失败打 `BUILD-FAILED see …` 并返回 1。编译前先删旧 exe，
所以看到 `BUILD-OK` 时那个 exe 一定是这次编出来的。

`build-cublas.cmd`、`build-f16acc.cmd`、`build-fp8gemm.cmd`、`build-fp8mma.cmd` 是四个薄包装，
内容就是 `build.cmd <目标>`；文档别处按这几个名字引用，别让它们失效。

## 采集之后

一次采集一个 `.txt` 放进 [../results/](../results/)。三条规矩，前两条是踩过的：

1. **GPU 必须空闲**。后台有游戏占着 GPU 的那一次，`cublas_gemm` 的 `fp16/fp32acc` 三个 rep
   是 1.1 / 1.9 / 5.0 TF/s，同一个探针在空闲时是 142.85。那份样本留作
   `cublas-contaminated.txt`（[PITFALLS #11](../docs/PITFALLS.md)）。
2. **首跑偏低要写明怎么处理**。首个 kernel 没进稳态频率，`fp8-baseline` 三次是
   147.6 / 165.4 / 170.6（±16%）。弃首跑取 median 是 1.93×，保留全部报 best 是 1.91×，
   两种都行，写清楚用的哪种。
3. 往 [../results/README.md](../results/README.md) 的表里加一行，重算 `SHA256SUMS`。
