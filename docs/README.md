# 文档索引

十篇，各管一件事。按要回答的问题选。

| 文档 | 回答什么 | 什么时候翻 |
|---|---|---|
| [HANDOFF.md](HANDOFF.md) | 从零接手的顺序：先读哪三个、三句关键事实、目录地图、日志怎么用 | 第一次打开这个仓库 |
| [EVIDENCE.md](EVIDENCE.md) | 结论背后的东西：仪器条件、全量数字、日志原文、判据为什么是比值 | 想复核某个数、怀疑测量条件时 |
| [REPRODUCE.md](REPRODUCE.md) | 完整命令、每个脚本的边界、换卡流程、从任意提交重建 | 动手之前 |
| [DLSS.md](DLSS.md) | 为什么 DLSS 与帧生成没有收益，以及怎么自己测帧率 | 想知道游戏会不会变快 |
| [PITFALLS.md](PITFALLS.md) | 移植期撞到的 19 个坑，每条「症状 → 原因 → 改法」 | 改硬件枚举、改闸门、换卡、日志莫名静默时 |
| [WHERE-IT-STOPPED.md](WHERE-IT-STOPPED.md) | 路走到哪：每次 `RUN` 的结果、每次构建的哈希与上机记录、十七种判决怎么读 | 开机前后判读日志、决定换哪一版 EFI 时 |
| [INCIDENT-esp-takeover.md](INCIDENT-esp-takeover.md) | ESP 接管那次事故：现象、逐个排除、三条恢复路线 | 想省掉按 `U` 之前 |
| [PRIOR-ART.md](PRIOR-ART.md) | 邻域实现对比：上游、impacifist、Zagitta、同型号 Linux 案例 | 想知道某处设计是抄的还是自己加的 |
| [APPLICATIONS.md](APPLICATIONS.md) | 第三方现场报告汇总：哪些负载变快、哪些没变、数据怎么分级 | 判断这张卡上什么会变快 |
| [ECOSYSTEM-2026-10.md](ECOSYSTEM-2026-10.md) | 外部生态盘点（2026-10-28）：上游 84 个提交、同卡四个移植、四写机制变体 | 想看去别人怎么做的、要不要 rebase 上游 |

仓库根的 [README.md](../README.md) 是入口与结果表，[results/README.md](../results/README.md)
是每份原始采集的条件与统计口径，[bench/README.md](../bench/README.md) 与
[tools/README.md](../tools/README.md) 分别讲探针和脚本。[runlogs/](../runlogs/) 是 13 份
U 盘原始日志的副本，`SHA256SUMS` 可复核。

## 四处容易搞混的

- **「解锁后」有两批数字**：285 W 那批与 320 W 那批，跨批不可比。判据是
  `f16/f32 ÷ f16/f16`，不是绝对值。全量表与推导见 [EVIDENCE.md](EVIDENCE.md)。
- **`e4m3/f32` 是发射率探针，不是 GEMM**。同一张架构上真实的 FP8 GEMM，上游同卡只有
  1.003×（见 [PRIOR-ART.md](PRIOR-ART.md) 末节）。
- **`SS0` 的 stock 值每次都不同**，别拿等号验「断电后回到 stock」；看 `SS1==0x1` 加
  `readout1` 的 `full=0`。
- **`mma_bench` 与 `gemm_check` 的源码不在本仓库**，`verify-unlock.ps1` 的 2/4、3/4 两节
  靠它们，见 [bench/README.md](../bench/README.md)。
