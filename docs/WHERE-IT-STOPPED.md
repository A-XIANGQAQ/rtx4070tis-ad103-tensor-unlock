# 这条路走到哪（2026-10-27 更新）

**U 盘手动引导这条路已经走通。** `RUN0005` 是修好的版本第一次跑成功：写寄存器 → FLR →
干净交棒给 `bootmgfw.efi`，Windows 起来后 `f16/f32 ÷ f16/f16 = 1.001`，对照组不动。
同一次 boot 内隔一段时间再测，比值仍是 1.001。

**没走通的只有 ESP 接管那条**（装上去卡在 boot 阶段，见下）。这份文件记录位置，目的是
让接手的人不必重走。所有结论都标了证据等级。

## 已验证成立的

`mma_bench`，register-resident 发射率。两轮都取 best，同一 boot 内、中间没重启：

| 模式 | stock | `RUN0005` 首次 | 同 boot 复测 |
|---|---:|---:|---:|
| `f16/f32` | 88.0 | 176.1 | **188.1** |
| `bf16/f32` | 87.9 | 175.6 | **187.5** |
| `e4m3/f32` | 170.63 | 319.58 | **374.28** |
| `f16/f16` | 175.6 | 175.1 | 188.0 |
| `s8/s32` | 352.5 | 348.0 | 374.9 |
| `dp4a` | 87.0 | 87.7 | 93.3 |
| `ffma` | 41.8 | 41.5 | 44.8 |

复测那一列整体比首次高约 6%，因为卡跑在 2640 MHz 而不是更低频。**变的只有频率**：
两轮的 `f16/f32 ÷ f16/f16` 分别是 1.006 和 1.001，比值不动。这就是为什么判据只能是比值。

事务日志：`result=0 safe=1 retained=0 started=1 quiesced=1 flrs=1 DMA_live=0`，
FLR 后 `SS0=0x88888888 SS1=0x00000008 readout1=0 full=1`。
数值校验 `failures=0 max_abs=0`（每个模式 79935 个 cell，FP16 与 BF16 两种累加合计
159870 个）。

**这条路径有 Windows 内实测数据的只有两次**：10/25 23:18 那次（`RESULT.md` 记 EFI
`5d5277c2`，100864 B；System 日志 23:15:55 有一次启动，2 分半后就是那批数据 —— 对得上。
但那份 EFI 和它的 `RUNxxxx.TXT` 现在都不在盘上了）和 `RUN0005`（EFI `76FEE036`）。

不算的几次，理由都是实的：

| 日志 | 结果 | 为什么不计数 |
|---|---|---|
| `RUN0001`（00:28:48） / `RUN0002`（00:32:08） | 事务体全绿，但在 `release-exclusive-claim` 被 halt | 两次都没有对应的启动事件 —— 10/25 23:15 之后直到 10/26 20:09 之间系统没启动过，所以它们从未进 Windows |
| `RUN0003`（20:09:26） | 按了跳过键 | 没有事务；20:09:30 那次启动是 stock |
| `RUN0004`（23:04:08） | **解锁成功**（`result=0`，`SS0`/`SS1` matched），但交棒假失败 → 静默 halt | 卡了 144 秒（23:04:08 → 启动事件 23:06:32）后用户按重启，成果丢掉 |

判据：`f16/f32 ÷ f16/f16`，stock ≈ 0.50，解锁 = 1.00。这个比值乘掉了频率，跨频点可比。

## RUN0005：跑通的这一次

`H:\AD104-UNLOCK\RUN0005.TXT`，13143 B，2026-10-26 23:45:42；Windows 启动 23:45:44
（间隔 2 秒 = 干净交棒，没有卡）。184 行。

三处修复的判据都在这份日志里：

```
:19  preflight[6] Snapshot=0 edges=180
:20  GPU children cached: count=3
:21  preflight[6b] CacheGpuChildren=0 children=3     ← A 生效
:184 TRANSACTION OK: … handoff check passed; …        ← C 生效（拒绝理由已被记进日志）
```

全文没有 `graph missing` / `finish incomplete` / `GPU finish after close` / `STOP:`，
一条都没有 —— A 那道假失败彻底消失。

注意 `children=3`，比预期的 2 多一个（`Consumers counts: pci=1 child=2` 之外还有一个）。
多出来的那个不影响结果，但说明这里的枚举口径和 `Consumers()` 不完全一致，值得留意。

`release: residual edges on GPU handles=1 expected=0` 仍然出现，被容忍，不致命。

## ESP 接管：已验证失败

**ESP 接管**：把 `\EFI\Microsoft\Boot\bootmgfw.efi` 换成解锁 EFI，让它解锁后
`StartImage` 原版（改名成 `bootmgfw.orig.efi`）。装上去之后，在固件启动菜单里
**选 Windows Boot Manager，卡在 boot 阶段进不去**。断电重试同样。

现场状态（回滚前）：

```
ESP bootmgfw.efi       = 解锁 EFI（哈希未记录；install state 被 -Rollback 一起删了）
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

## RUN0004：解锁成功了，然后被自己的假失败送掉

这一条是回看第四次 U 盘尝试（`RUN0004.TXT`，2026-10-26 23:04:08）才读出来的，
它改变了上面对「失败」的判断。当时现场是「按 U 没反应、画面卡住、按了重启键」。

**事务体全绿**。`RUN0004.TXT` 第 189 行：

```
Transaction result=0 safe=1 retained=0 started=1 quiesced=1 flrs=1 DMA_live=0
```

加上 `selector result: SS0=0x88888888 matched=1`、`SS1=0x8 matched=1`、
`post-FLR … SS0=88888888 SS1=00000008 WPR2=1ffffe00:00000000`。
**那次是真的解锁成功了的**，寄存器写进去了，FLR 也扛住了。

死在后面两道纯软件的门上：

```
GPU finish after close status=0x8000000000000006 graph=160
finish incomplete status=0x8000000000000006 owned=0 safe=1
TRANSACTION OK: …                                    ← 漏出来这一行，之后彻底静默
```

`owned=0 safe=1` → `app.c` 的容忍分支放行 → 打 `TRANSACTION OK` → 关日志 →
`GuMsiReadyForWindows()` 返回 FALSE → `goto failed` → `GuBootHalt()`。
而 `GuBootHalt()` 跑在 `GuBootSilence()` 之后，那行 `STOPPED.` **被吞掉了**。
操作者看到的是一帧冻住的画面，合理解读只有「卡死」，于是按了重启键 ——
重启正好清掉易失的 `SS0`/`SS1`。**解锁是被这条静默路径送掉的，不是被机制送掉的。**

### 三个 bug（都已修，`cb3691b`）

**A. `GpuChild()` 依赖 device path，而 stage 3 正好把它拆掉。**

`Removed()` 的 stage 3 分支是 `e->handle==Plan.pci || GpuChild(e->handle)`，
意思是「GPU 根和它所有显示子节点上的边都该消失」。`GpuChild()` 靠
`HandleProtocol(h, &DevicePathGuid)` 拿路径再比 24 字节 PCI 前缀。但
stage 3 的 `DisconnectController(Plan.pci, nv_agent)` 会先卸载 console/GOP 驱动，
**CDC 解绑时把 device path 从这些 handle 上摘掉**，然后级联才释放 handle。
于是 `GpuChild()` 返 FALSE，那条边不再被算作「计划内消失」，
`Expected(3,FALSE)` 就把它判成 missing。日志里的自证：

```
GPU graph missing: handle=0xc6b2bb18 agent=0xc8684918 controller=0xc6b2bb18
                   protocol=0x387477c2 attributes=0x10 count=1
```

`0xc6b2bb18` 就是第 47 行打印的 `gop`，`0xc8684918` 是 `out_agent`，
`0x387477c2` 是 Simple Text Output 的 GUID。**这正是 stage 3 按计划拆掉的那条
TextOut 边**。修法：preflight 里路径还活着的时候扫一遍 `AllHandles` 记进
`Plan.gpu_child[]`（`CacheGpuChildren()`），`GpuChild()` 先查缓存、未命中再回退到
路径匹配。

**B. halt 时的提示被自己的静默吞掉。** `GuBootHalt()` 加了 `GuBootWake()`
（新增的 `GuBootWake()` / `Silent=FALSE`）再打 `STOPPED.`。看不到的停机
和死机没区别，而死机的习惯处理是重启 —— 重启清掉成果。

**C. 日志关闭被记成硬件故障。** 旧 `GuLog()` 在 `!Log` 时直接 `Gu.fault=TRUE`。
而 `app.c` 的所有 `Gu.fault` 检查都排在 `GuBootClose()` 之后，等于关日志这个
**主动动作**自动污染了后面每一道门。加法：`Sealed` 标志，干净关闭之后
`GuLog` 变静默 no-op，不再置 fault。

顺带把 `GuMsiReadyForWindows()` 挪到关日志**之前**，这样拒绝的理由能进日志 ——
否则日志停在 `TRANSACTION OK` 上，什么都没解释。

**证据等级**：A 是对已观测日志行的代码级解释，自洽且能定位到具体 handle；
B、C 是代码路径上的确定事实。**三处都已在硬件上验证**（见上面 RUN0005 一节）。
离线回归 `test-app-flow.exe` 15 个场景全绿。

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

注：这台机器的 ESP 是 disk 3 分区 1，300 MB。`Inspect()` 的多盘容忍和上面三个
bug 的修复在同一个 EFI 里，部署在 `H:\EFI\BOOT\BOOTX64.EFI`（104448 B，
`76fee036…`）。走 U 盘这一路不需要它；只有回头试 ESP 时才用得上。

## 开机后怎么确认（照这个做）

进 Windows 后立刻跑：

```powershell
# 判据：f16/f32 ÷ f16/f16 的比值，而不是绝对值
G:\workspace\rtx2705\bench\mma_bench.exe 20000 5
```

比值 ≈ 1.00 = 解锁在；≈ 0.50 = 不在（stock）。**别用绝对值判断** —— 降频能把绝对值
从 188 打到 88，看上去跟没解锁一模一样。

想更省事：

```powershell
G:\workspace\repo-ad103\tools\verify-unlock.ps1 -RunNumber 5
```

它会先读 `nvidia-smi` 的频率/功耗/降频原因（不是 `0x1` 就打「本次绝对值不可用」），
再算比值，并单独打印 `f16/f32 ÷ f16/f16` 这个活比值。

真出现 `STOPPED. Power OFF fully; …` 说明门是软件拒的，硬件安全，**不用断电**：
直接 Ctrl+Alt+Del 走 Windows Boot Manager 进去测，先别断电，断电会清掉 `SS0`/`SS1`。
（这条提示以前是看不见的 —— bug B。现在能看见了。）

## 踩过的坑里有一条和机制无关、但会骗过所有人

`bench/cublas_gemm.cu` 原来对 `fp16/fp16acc` 也传 `float alpha=1.0f`。cuBLAS 的
`cublasGemmEx` 按 `computeType` 的**宽度**读这个 `const void*`，于是它把 `1.0f` 的低
两字节 `0x0000` 读成 `__half 0.0` —— 每个 GEMM 输出全零矩阵，实际工作量塌成几乎零，
计时器于是报出 **4588 / 4744 TF/s**。

这个数字一度写进了 README 的结果表。它比这张卡的物理峰值高一个数量级，本该第一时间
被怀疑。现在的每个用例末尾都打 `nonzero C: …`，全零会直接标 `<-- BROKEN`。
细节见 [PITFALLS.md](PITFALLS.md) #12。**教训：数字大得离谱时先怀疑自己没干活。**

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
  基于上游 `4e7fefc`；三个 bug 的修复在 `cb3691b`，之后 `c794f3e` 只改文档
- 本仓库 `docs/PITFALLS.md`：11 个移植阻塞点 + 4 个「拆完之后还要验证」的坑
  （6b 身份要缓存、10b 停机要可见、10c 关日志≠故障、10d `%p` 会静默整份日志），
  外加 #12 cuBLAS alpha 宽度，每条「症状 → 原因 → 改法」
- 本仓库 `docs/PRIOR-ART.md`：邻域实现对比，含本移植做错的两处
- `bench/`：四个 benchmark 源（`mma_bench` 在上游 `diagnostics/bench/` 下），
  口径与 `results/` 一致

## 一句话

机制成立，数字是真的，U 盘手动那条有两次 Windows 内实测（其中 `RUN0005` 的 EFI 还在盘上）。剩下的只有两件：ESP 接管那条一直
没验证（它的线索 `Inspect()` 已改但没重测），和 U 盘本身的可靠性。

想要非易失，别在 ESP 接管上加补丁 —— 换独立分区那条形状。
