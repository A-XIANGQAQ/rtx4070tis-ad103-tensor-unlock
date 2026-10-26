# 这条路停在哪（2026-10-26）

解锁机制本身跑通了，数字在 README。停下来的直接原因是**施加方式**：
没有一种既可靠、又不依赖 U 盘的启动形式。

但回看最后一次 U 盘尝试（`RUN0004`）之后要补一句更准确的话：**那次其实解锁成功了**，
是被自己的一道假失败加一段静默送掉的。详见下面「RUN0004」一节。

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
B、C 是代码路径上的确定事实。**三个修复都还没在硬件上跑过。**
离线回归 `test-app-flow.exe` 272 断言 / 15 场景通过。

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

## 下次重跑时的判据（照这个看日志）

新 EFI 的 preflight 会多出一行，这是 bug A 的修复是否生效的直接判据：

```
preflight[6b] CacheGpuChildren=0 children=2
```

- `children=2` → 缓存了两个显示子节点（本卡实测过 `pci=1 child=2`），修复生效
- `children=1` → 只认出一个，另一个显示节点的边仍会被判成 missing
- `children=0` → 路径匹配整体失效，说明显存/驱动状态和上次不同

接着这两行必须**都不再出现**：

```
GPU graph missing: handle=… protocol=0x387477c2 …
GPU finish after close status=0x8000000000000006
```

出现 `TRANSACTION OK: … handoff check passed …` 之后进程会把控制权交给
`bootmgfw.efi`。**如果这时画面停住，先别按重启** —— 等 10 秒；只要进了 Windows
就立刻跑 benchmark 确认。真的停住了，屏幕现在会打出
`STOPPED. Power OFF fully; …`（bug B 的修复），看到这行说明门是软件拒的，
硬件状态是安全的，不必断电：**直接按 Ctrl+Alt+Del 或走固件菜单选 Windows Boot Manager
进去测**，先别断电，因为断电会清掉 `SS0`/`SS1`。

判据是 `mma_bench.exe 20000 3` 的 `f16/f32`：约 176 = 解锁生效，约 88 = 没生效。

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
  基于上游 `4e7fefc`，HEAD `cb3691b`，`test-app-flow.exe` 272 断言 / 15 场景通过
- 本仓库 `docs/PITFALLS.md`：11 个移植阻塞点 + 3 个「拆完之后还要验证」的坑
  （6b 身份要缓存、10b 停机要可见、10c 关日志≠故障），每条「症状 → 原因 → 改法」
- 本仓库 `docs/PRIOR-ART.md`：邻域实现对比，含本移植做错的两处
- `bench/`：三个 benchmark 源，口径与 `results/` 一致

## 一句话

机制没问题，数字是真的。它停下的原因不是「解锁做不到」，而是**施加方式一直不可靠**：
USB 手动那条会被一道假失败和一段静默送掉，ESP 接管那条还没验证过就不会启动。
在有人跑通其中一条之前，保持 stock 是最优选择。
