# 交接：从零接手的顺序

这份仓库的目标只有一个：让 AD103 `10de:2705` 在 Windows 下拿到 FP32-累加 tensor 路径的 2×
算力。已经做到了，证据都在这里。下面是不用读完所有文档就能接手的顺序。

## 先读哪三个

1. **[../README.md](../README.md)**：一页结论：结果表、DLSS 无收益、方法三步、开工顺序、
   易失性、硬件、状态。
2. **[README.md](README.md)**：九篇文档的索引，按「想回答什么」选。
3. 要复核数字就翻 **[EVIDENCE.md](EVIDENCE.md)**；要动手就翻 **[REPRODUCE.md](REPRODUCE.md)**。

## 三句关键事实

- 解锁已经成立。`RUN0013`（2026-10-28 07:43）在 320 W VBIOS override 生效的同时完成解锁，
  `f16/f32 ÷ f16/f16 = 1.002`。断电即失效，每次开机走一遍 U 盘。
- 判据只有一个：**`f16/f32 ÷ f16/f16` 的比值**（stock ≈ 0.50，解锁 = 1.00）。绝对值随 SM
  频率整体漂 6%，不能当判据。三次真正解锁过：`RUN0005`（285 W）、`RUN0006`（v1
  override）、`RUN0013`（320 W）。
- 两个 EFI 选一个：`76FEE036` 只能 285 W（没有 blank 入口闸门）；`07052565` 及以后 320 W
  （同时接受 stock 与 blank 两种入口态）。

## 目录地图

| 目录 | 里面是什么 | 先看哪个文件 |
|---|---|---|
| `docs/` | 九篇文档，130 KB | [README.md](README.md) 是索引 |
| `runlogs/` | 13 份 U 盘原始启动日志，`RUN0001`–`RUN0013` | 见下面「日志怎么用」 |
| `results/` | 16 份原始 benchmark 输出 + `SHA256SUMS` | [../results/README.md](../results/README.md) |
| `bench/` | 四个探针源码 + `build.cmd` | [../bench/README.md](../bench/README.md) |
| `tools/` | 六个脚本 | [../tools/README.md](../tools/README.md) |
| `assets/readme/` | README 顶部横幅 | — |

`docs/` 九篇各自回答什么，看 [索引](README.md)。最容易搞混的四处（两批「解锁后」数字不可
跨批比、`e4m3` 是发射率不是 GEMM、`SS0` 不是常量、两个探针源码不在本仓库）也记在那个索引里。

## 日志怎么用

`runlogs/` 是 U 盘 `H:\AD104-UNLOCK` 里那 13 份原始日志的副本，随仓库一起走，换机器不用找
U 盘。`SHA256SUMS` 可复核。判读用本仓库的脚本，显式指到包内目录：

```powershell
.\tools\classify-run.ps1 -LogRoot .\runlogs -All
```

已知结果：`RUN0001`/`RUN0002` = `TX-OK-THEN-HALT`，`RUN0003` = `SKIPPED`，
`RUN0004`/`0005`/`0006`/`0013` = `TRANSACTION-COMPLETE`，`RUN0007`–`0012` =
`ENTRY-REFUSED-SELECTOR`。

`RUN0007`–`0012` 六份各 285 字节、sha256 逐字节相同，是挂着 override 但闸门还没放开时的
六次冷启动，`RUN0013` 就是放开之后那一次。

## 关键数字

`mma_bench`，register-resident 指令发射率，20000 iter，66 SM，sm_89，单位 TF/s。

| 模式 | stock | 解锁 285 W | 解锁 320 W | 倍数 | 角色 |
|---|---:|---:|---:|---:|---|
| `f16/f32` | 88.0 | 176.1 | **181.3** | **2.06×** | 目标 |
| `bf16/f32` | 87.9 | 175.6 | **182.2** | **2.07×** | 目标 |
| `e4m3/f32` ※ | 170.63 | 319.58 | **360.33** | 1.87–2.19× | 目标 |
| `f16/f16` | 175.6 | 175.1 | 180.9 | 1.00× | 对照 |
| `s8/s32` | 352.5 | 348.0 | 367.8 | 0.99× | 对照 |
| `dp4a` | 87.0 | 87.7 | 89.8 | 1.01× | 对照 |
| `ffma` | 41.8 | 41.5 | 41.7 | 0.99× | 对照 |

※ 这一行是 FP8 `mma` 的发射率，**不是 GEMM**。上游在真 GEMM 上量到 FP8 只有 0.3%
（[PRIOR-ART.md](PRIOR-ART.md) 末节）。数值校验 `gemm_check` 六组共 159870 个 cell，全部
`failures=0 max_abs=0`。

## 这个仓库没有的东西

- **EFI 源码**。`windows/ad103-2705` 在 fork 分支
  [`A-XIANGQAQ/gpu-unlock-ada`](https://github.com/A-XIANGQAQ/gpu-unlock-ada) 的
  `ad103-2705` 上，不在这里。
- **EFI 二进制**。在 U 盘：`H:\EFI\BOOT\BOOTX64.EFI`（106496 B，`07052565`）外加 7 份
  `.bak`、`BOOTX64.PREV.EFI`、`BOOTX64.VERIFIED-76FEE036.EFI`。二进制不进仓库，因为它能被
  重新编译出来，哈希稳定（见 [REPRODUCE.md](REPRODUCE.md)）。
- **两个外部探针的源码**。`mma_bench.cu` 在上游 `diagnostics/bench/`（GPL-2.0-only，未随
  本仓库分发，故意的）；`gemm_check` 这台机器上只有 exe。
- **外部仓库的本地副本**。[ECOSYSTEM-2026-10.md](ECOSYSTEM-2026-10.md) 里的第三方数字都是
  转述，没 clone、没编译、没复现。

## 文档里的绝对路径

`docs/` 与 `bench/README.md` 里有若干 `G:\workspace\...` 与 `H:\...` 路径，指的是这台机器。
换机器读文档没问题，按路径取文件要改。`runlogs/` 就是为了让这件事少一处依赖。
