# 这条路停在哪（2026-10-26）

解锁机制本身跑通了，数字在 README。停下来的原因不是机制，是**施加方式**：
没有一种既可靠、又不依赖 U 盘的启动形式。

这份文件记录停止时的确切位置，目的是让接手的人不必重走。所有结论都标了证据等级。

## 已验证成立的

`mma_bench`，register-resident 发射率，20000 iter × 3 rep：

| 模式 | stock | 解锁后 | 倍数 |
|---|---:|---:|---:|
| `f16/f32` | 88.0 | 176.6 | 2.01× |
| `bf16/f32` | 87.9 | 176.2 | 2.00× |
| `e4m3/f32` | 170.63 | 325.98 | 1.91× |
| `f16/f16` / `s8` / `dp4a` / `ffma` | — | 不变 | 对照组 |

事务日志：`result=0 safe=1 retained=0 started=1 quiesced=1 flrs=1 DMA_live=0`，
FLR 后 `SS0=0x88888888 SS1=0x00000008 readout1=0 full=1`。
数值校验 `failures=0 max_abs=0`。

**这条路径用 U 盘手动引导成功过两次**（`5D5277C2` 和 `CF349D28`）。

## 已验证失败的

**ESP 接管**：把 `\EFI\Microsoft\Boot\bootmgfw.efi` 换成解锁 EFI，让它解锁后
`StartImage` 原版（改名成 `bootmgfw.orig.efi`）。装上去之后，在固件启动菜单里
**选 Windows Boot Manager，卡在 boot 阶段进不去**。断电重试同样。

现场状态（回滚前）：

```
ESP bootmgfw.efi       = FC9A5367（解锁 EFI）
ESP bootmgfw.orig.efi  = 3086680 B / 2d60a220…（原版，完好）
ESP 容量               = 300 MB
AD104-ASSETS           = 5 个文件，80.5 MB
```

**排除掉的原因**：

| 候选 | 结论 | 依据 |
|---|---|---|
| ESP 空间不足（INCIDENT 第 3 条） | **排除** | 300 MB，资产只占 80.5 MB |
| 启动项顺序把 USB 排前面 | **排除** | 是主动选 Windows Boot Manager 时卡住 |
| 自我链接（链式目标指向自己） | **排除** | `bootmgfw.orig.efi` 两轮都完整（3086680 / `2d60a220`） |
| `#9` 的三处改动没打 | **排除** | 允许内置卷、允许同卷、链式改名都在装的版本里 |

**未采集的证据（已丢失）**：`W:\AD104-UNLOCK` 是否被创建过。回滚脚本
`install-esp.ps1 -Rollback` 会删除该目录，所以"EFI 到底跑没跑到写日志"这一步
再也无法确认。**这是本次取证上的最大失误**——先建议回滚，回滚顺手毁掉了判据。

## 唯一的存活线索（假设，未验证）

USB 与 ESP 的唯一已知路径差异在 `boot_io.c` 的 `Inspect()`：

```c
/* 改前 */
if(n!=sizeof(HARDDRIVE_DEVICE_PATH)||++hd!=1)return FALSE;
```

`++hd!=1` 会**拒绝第二个 `MEDIA_HARDDRIVE_DP` 节点**。

- 从 U 盘启动：路径里是 `USB()` 节点，`hd=0`，这段不触发 → 能过
- 从 ESP 启动：路径里有 `HD()` 节点，多盘机器上可能不止一个 → `Inspect()` 返回
  `FALSE` → `GuBootOpen` 返回 `EFI_ACCESS_DENIED` → `app.c` 第 39 行
  `if(s!=EFI_SUCCESS)return s;` → **静默返回，屏幕无提示，无日志**

`c9f215d` 已改成接受多个 harddrive 节点（`hd>16` 为上界），并给 `GuBootOpen`
的六个静默出口加了屏显。**但这个改动从未在 ESP 路径上重测过** —— 是假设，不是结论。

## 重试前必须先做的事

1. **先建立退路**。在做任何 ESP 改动之前，确认 BIOS 有 `Boot From File`，能选到
   `\EFI\Microsoft\Boot\bootmgfw.orig.efi`。这是不依赖外部介质的唯一恢复路径。
2. **不要先回滚再看日志**。`install-esp.ps1 -Rollback` 删 `AD104-UNLOCK`。
   卡住后先挂 ESP 读日志（`mountvol W: /S`），再决定是否回滚。
3. **U 盘留作救援**，不作为日常介质。U 盘会坏，这是它不适合当唯一路径的原因。

## 更值得走的方向

`docs/PRIOR-ART.md` 记过：三种独立实现里，ESP 接管是最不成熟的那条。
`MatchaCake` 把它明确标为"未测试，仅设计文档"；`MarvinFS` 干脆不走这条路。

**要非易失，换形状**：独立 FAT32 分区 + 固件启动项，**不劫持 `bootmgfw.efi`**。
按 `MarvinFS` 给出的数字：

- 资产需要 ~85 MB（GSP 固件压不小，xz 也只到 70 MB）
- 专用分区最小 128 MB，4K 扇区盘要 272 MB
- 用现有 ESP 需 ≥117 MB 空闲（85 + 32 保留）

这个形状的好处是：解锁 EFI 挂了，Windows Boot Manager 那条路完全没被碰过，
固件菜单里选一下就能进系统。

## 拉起来需要什么

- `windows/ad103-2705` 分支：`https://github.com/A-XIANGQAQ/gpu-unlock-ada/tree/ad103-2705/windows/ad103-2705`
  基于上游 `4e7fefc`，`test_app_flow` 271 断言 / 15 场景通过
- 本仓库 `docs/PITFALLS.md`：11 个移植阻塞点，每条「症状 → 原因 → 改法」
- 本仓库 `docs/PRIOR-ART.md`：邻域实现对比，含本移植做错的两处
- `bench/`：三个 benchmark 源，口径与 `results/` 一致

## 一句话

机制没问题，数字是真的，问题是**没有一个不依赖 U 盘又不会把机器卡死的施加方式**。
在有人验证出可靠的启动形状之前，保持 stock 是最优选择。
