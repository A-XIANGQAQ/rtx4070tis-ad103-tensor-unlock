# 这条路走到哪（2026-10-27 更新）

**U 盘手动引导这条路已经走通。** `RUN0005` 是修好的版本第一次跑成功：写寄存器 → FLR →
干净交棒给 `bootmgfw.efi`，Windows 起来后 `f16/f32 ÷ f16/f16 = 1.001`，对照组不动。
同一次 boot 内隔一段时间再测，比值仍是 1.001。

没走通的只有 ESP 接管那条，装上去卡在 boot 阶段，见下。

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

复测那一列整体比首次高约 6%，因为卡跑在 2640 MHz 而不是更低频。变的只有频率：
两轮的 `f16/f32 ÷ f16/f16` 分别是 1.006 和 1.001，比值不动。所以判据只能是比值。

事务日志：`result=0 safe=1 retained=0 started=1 quiesced=1 flrs=1 DMA_live=0`，
FLR 后 `SS0=0x88888888 SS1=0x00000008 readout1=0 full=1`。
数值校验 `failures=0 max_abs=0`（每个模式 79935 个 cell，FP16 与 BF16 两种累加合计
159870 个）。

**这条路径有 Windows 内实测数据的只有两次**：10/25 23:18 那次（`RESULT.md` 记 EFI
`5d5277c2`，100864 B；System 日志 23:15:55 有一次启动，2 分半后就是那批数据，对得上。
但那份 EFI 和它的 `RUNxxxx.TXT` 现在都不在盘上了）和 `RUN0005`（EFI `76FEE036`）。

不算的几次，理由都是实的：

| 日志 | 结果 | 为什么不计数 |
|---|---|---|
| `RUN0001`（00:28:48） / `RUN0002`（00:32:08） | 事务体全绿，但在 `release-exclusive-claim` 被 halt | 两次都没有对应的启动事件：10/25 23:15 之后直到 10/26 20:09 之间系统没启动过，所以它们从未进 Windows |
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
一条都没有，A 那道假失败彻底消失。

注意 `children=3`，比预期的 2 多一个（`Consumers counts: pci=1 child=2` 之外还有一个）。
多出来的那个不影响结果，但说明这里的枚举口径和 `Consumers()` 不完全一致。

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

`W:\AD104-UNLOCK` 有没有被创建过，已经无法确认：`install-esp.ps1 -Rollback` 会删除
该目录。卡住时先挂 ESP 读日志，再决定回不回滚。

## RUN0004：解锁成功了，然后被自己的假失败送掉

第四次 U 盘尝试（`RUN0004.TXT`，2026-10-26 23:04:08）的实际结果与当时的现场判断相反。
现场是「按 U 没反应、画面卡住、按了重启键」。

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
操作者看到的是一帧冻住的画面，合理解读只有「卡死」，于是按了重启键，
而重启正好清掉易失的 `SS0`/`SS1`。**解锁是被这条静默路径送掉的，不是被机制送掉的。**

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
和死机没区别，而死机的习惯处理是重启，重启就把成果清掉了。

**C. 日志关闭被记成硬件故障。** 旧 `GuLog()` 在 `!Log` 时直接 `Gu.fault=TRUE`。
而 `app.c` 的所有 `Gu.fault` 检查都排在 `GuBootClose()` 之后，等于关日志这个
**主动动作**自动污染了后面每一道门。加法：`Sealed` 标志，干净关闭之后
`GuLog` 变静默 no-op，不再置 fault。

把 `GuMsiReadyForWindows()` 挪到关日志之前，这样拒绝的理由能进日志；
否则日志停在 `TRANSACTION OK` 上，什么都没解释。

三处都已在硬件上验证（见上面 RUN0005 一节）。离线回归 `test-app-flow.exe` 15 个场景全绿。

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
的六个静默出口加了屏显。但这个改动从未在 ESP 路径上重测过，是假设，不是结论。
`test_boot_io` 现在把两侧都钉住了：一个无关卷在前面时仍认出 Windows 卷，
十六个 harddrive 节点仍放行，十七个被拒；六条拒绝串连同状态码逐字断言。
不过这些是夹具，不是这台机器的固件枚举结果。

注：这台机器的 ESP 是 disk 3 分区 1，300 MB。`Inspect()` 的多盘容忍和上面三个
bug 的修复在同一个 EFI 里。`H:\EFI\BOOT\BOOTX64.EFI` 现在是 104448 B /
`bfc70ff1…`（blank 入口态 + `Sealed` 复位 + 撤掉移植期的图抖动容忍 + release 后两种
拒绝分开命名），上一版 104960 B / `64d70365…` 留作 `BOOTX64.PREV.EFI`。走 U 盘这一路不需要 ESP 那部分；
只有回头试 ESP 时才用得上。

## 320 W VBIOS override 与 SM 解锁的冲突（改在解锁侧，未上硬件）

用 `vbios-loader.exe` 载入改过功率表的 VBIOS 之后，六次冷启动（`RUN0007`–`RUN0012`）
全部停在同一个地方，六份日志 sha256 逐字节相同（`8F61DB14…`），只有三行：

```
AD104 MSI EXPERIMENTAL v0.5.4: hardware unvalidated; ...
cold-profile selector mismatch: SS0=0 SS1=0 wantSS1=0x1
STOP: stage=read-only-cold-profile status=0x8000000000000006 mutated=0 retained=0 fault=0
```

几点实测结论：

- `cold-profile selector mismatch` 是 19 个 pin **全匹配之后**才打的；`fault=0`。
  所以 `0` 是真读出来的值，不是读失败的兜底。
- 四个 payload 加原厂 ROM 逐字节比过：`0xBF89` 是 `power_default_w`、`0xBF8D` 是
  `power_max_w`（u32，mW）。`v2` 与 `v1` 差 7 字节 / 4 段：`0xBF89` 的默认档
  （285000→320000）、两处输入电流槽 `0xC206` 与 `0xC261` 各 `546f→d084`
  （28500→34000 mA）、`0xFBFF` 一个 additive checksum；只差 3 字节的是
  `v1 → b320`（默认档加校验和，没动电流槽）。四个镜像里搜
  `0x0082381c` / `0x00823820` / `0x00823804` / `0x27304036` / `0x00410080` /
  `0x00000233` 全部 0 命中，**override 里没有 SM 寄存器初值**。冲突不在覆盖，
  在初始化路径。
- `RUN0006`（10-27 20:54:40）读到 `ss0=0x27104036 ss1=0x1`，事务一路跑通；此后
  六次全部读 0。但那次开机挂着哪一份 override 没有直接证据：`load-v2.log`
  （21:06:32）的 `before.vbios` 是 v1 的窗口哈希，证明那一刻注册表里是 v1，而
  `loader-payload.bin` 的 mtime 是 20:44，20:44 到 21:06 之间没有任何 load 日志；
  唯一的注册表快照是 23:21:37 取的，里面已经是 v2。所以「v1 能过、v2 不能过」
  只有时间顺序的旁证。

改法在解锁侧，`320 W` 那一侧一个字节都没动：入口接受两种状态，stock 是 `SS1==1`，
blank 是 `SS0==0 && SS1==0`。改动落在

- `profile.c` 的 `Registers()`
- `vendor/unlock_610.c` 的主闸门

全链路本来就不写死 `SS1` 的值，所以 blank 态 latch 之后能自洽：`GuEntrySelectorsMatch`
比的是 `Ss1==EntrySs1`（不是 `==1`）、`GuLatchEntrySelectors` 的上界是 `Ss1>0xfU`、
`GuSelectorPhase` 比的是 `ss1==entry1`、`check_entry_selectors` 比的是
`b!=work->ss1_entry`，pre/post-FLR 要求的是写入后的目标值 `0x88888888`/`0x8`，与入口态无关。

验证方式是 `test_efi_transaction`：30 个场景 × 4 组 permutation（3 个 stock 变体 +
1 个 blank），共 120 条 `EFI integration` 行，`TEST_EXIT=0`。数条数而不是看日志文本，
成功的 permutation 是静默的。

**这一步只在离线仿真里过了，没有上硬件。** 真机上要冷启动一次才知道 blank 态到底
能不能走完事务。

### 哪一版 EFI 上过机（每次构建都能重算，不是回忆）

`windows/ad103-2705/rebuild-efi.ps1 -Commit <hash>` 从任意提交重建并打印哈希，
脚本里带着这张对照表。本地可达的七个提交，2026-10-28 全部重编过一遍：

| commit | 大小 | sha256 前 8 | 上过机吗 |
|---|---|---|---|
| `cb3691b` | 104448 | `76FEE036` | **是。`RUN0005` 解锁成功，`RUN0006`（v1 override）也成功** |
| `c794f3e` | 104448 | `76FEE036` | 同上。这提交只改了 README，二进制没动 |
| `cef0935` | 104960 | `EE440D7F` | 没上过。第一版接受 blank 入口态 |
| `cdd55be` | 104960 | `EE440D7F` | 没上过。与 `cef0935` 同一份二进制 |
| `6df9735` | 104960 | `64D70365` | 没上过 |
| `6a82336` | 104448 | `950689CB` | 没上过。撤掉九处图抖动容忍 |
| `6adb3ee` | 104448 | `AFB6524A` | 没上过。改掉 blank 那句注释的措辞 |
| `e2e99c2` .. `a96c26a` | 104448 | `AFB6524A` | 没上过。四个提交只动 rebuild-efi.ps1 与两个测试文件，产物没变 |
| `68ee8c9` | 104448 | `9092110A` | 没上过。`boot_io.c` 那句话改成不声称 pin，产物跟着变 |
| `1ecaf35` | 104448 | `9092110A` | 没上过。只动了 rebuild-efi.ps1 |
| `dcda05c` .. `c80b09f` | 104448 | `BFC70FF1` | 没上过。`app.c` 里 release 之后两种拒绝拆成两个 stage，`app.c` 是编进镜像的 |

**只有 `76FEE036` 真正解锁过这块卡。** 从 `cef0935` 往后每一版都没上过机，
所以「能解锁的那版」和「肯接受 320 W override 留下的 blank 态的那版」之间，
只隔一个提交：`c794f3e` → `cef0935`。

`H:\EFI\BOOT\BOOTX64.EFI` 现在是 `BFC70FF1`（含 blank 入口态；与 `9092110A` 的差别
是 release 之后那两种拒绝各有一个 stage 名，与 `AFB6524A` 的差别再加上
`Windows image staged` 那句日志不再声称 pin 了摘要）。
`RUN0013` 是这一版的第一次硬件尝试。`76FEE036` 那份同时留在
`H:\EFI\BOOT\BOOTX64.VERIFIED-76FEE036.EFI`。

它随时能换回去，但换回去之后只有一种情况能用：注册表里没挂 VBIOS override。
`76FEE036` 的二进制里没有 blank 入口态那道闸门（搜 `blank selectors` 命中 0，
搜 `wantSS1=` 命中 1），所以挂着 320 W override 开机时，它读到 `SS0=0 SS1=0` 一样会拒，
结果就是 `RUN0007`..`RUN0012` 那六份 285 字节的日志。也就是说「换回能解锁的那版」
和「保留 320 W」这两件事目前是互斥的。

日志自己会说明是哪一版打的。blank 闸门是 `cef0935`（10-28 01:05）才进的代码，之前那版
匹配失败时打 `wantSS1=0x1`，之后那版打 `stockSS1=0x1`。`RUN0007`–`RUN0012` 六份全是
`wantSS1=`，也就是说那六次跑的是**还没有 blank 闸门**的版本 —— 它们证明的是「320 W
override 下 `SS0`/`SS1` 读 0」，不是「blank 闸门不管用」。带 `stockSS1=` 的版本一次都
没上过机，`RUN0013` 才是它的第一次。翻日志先看这一处，能省一轮冷启动。

判读用 `tools\classify-run.ps1`，不用自己数长度：

```powershell
# 最新那份日志
powershell -NoProfile -ExecutionPolicy Bypass -File tools\classify-run.ps1
# 指定某一轮
powershell -NoProfile -ExecutionPolicy Bypass -File tools\classify-run.ps1 -File H:\AD104-UNLOCK\RUN0013.TXT
# 全部历史，一行一份
powershell -NoProfile -ExecutionPolicy Bypass -File tools\classify-run.ps1 -All
```

它给十一种判决。五种在真实日志上出现过，其余六种只有合成样例（`blank` 那两种要等
`RUN0013` 才可能有真实样本，`ENTRY-REFUSED-PIN`、`GATE-REFUSED-AFTER-RELEASE`、
`CLAIM-NOT-HELD` 与 `TRUNCATED` 至今没在真机上出现过）：

| 判决 | 含义 | 出处 |
|---|---|---|
| `TRANSACTION-COMPLETE` | 事务跑完了，进 Windows 后验算力 | `RUN0004`–`RUN0006` |
| `TX-OK-THEN-HALT` | 事务体出结果，但随后某段 `STOP` | `RUN0001` / `RUN0002` |
| `ENTRY-REFUSED-SELECTOR` | 那版 EFI 还没有 blank 闸门，`SS0=0 SS1=0` 是它正常的拒绝 | `RUN0007`–`RUN0012` |
| `ENTRY-REFUSED-NEITHER-STATE` | 这版已接受两种入口态，选通器落到了第三种状态 | 合成样例 |
| `SKIPPED` | 按了跳过键，没做事 | `RUN0003` |
| `BLANK-ACCEPTED-THEN-STOP` | blank 态过了，后面某段 `STOP` | 合成样例 |
| `BLANK-ACCEPTED` | blank 态过了，没有 `STOP` | 合成样例 |
| `ENTRY-REFUSED-PIN` | 19 个 pin 里有一个不对，没走到选通器 | 合成样例 |
| `CLAIM-NOT-HELD` | 驱动放开 GPU 之后独占声明没拿住，事务一次都没跑 | 合成样例 |
| `GATE-REFUSED-AFTER-RELEASE` | 入口闸门在驱动放开 GPU 之后又跑了一次并拒绝 | 合成样例 |
| `TRUNCATED` | 日志三行以内，任何闸门都没来得及报 | 合成样例 |

对 `TRANSACTION-COMPLETE` 它还会打 `nextBoot`：日志写完到下一个 Windows 启动事件的秒数。
`+3s` / `+4s` 是正常交棒；`RUN0004` 是 `+144s`，那 144 秒就是它拿着已经成功的硬件状态
干等、最后被按了重启键。光看 `Transaction result=0` 看不出这件事。

如果停在 `blank selectors` 之后，说明被拒的位置在 `unlock_610.c` 的主闸门或更后面，
`STOP:` 行里的 `stage=` 会指明是哪一段。

`CLAIM-NOT-HELD` 与 `GATE-REFUSED-AFTER-RELEASE` 都发生在驱动解绑之后、事务之前，
所以都不会去启动 Windows；区别在拒绝发生在哪一步。前者是 `GuMsiReleased()` 报 false，
即独占声明没拿住；后者是日志里出现 `cold-entry ...`，即入口闸门复检没过。这两种拒绝
以前共用 `stage=MSI-release` 这个标签，与 `GuMsiRelease()` 本身同名，`STOP` 行读不出
是哪一种——`app.c` 现在把它们拆成 `release-not-held` 与 `post-release-gate`，
`refusedAt :` 那一行直接给出 stage 名。

`gate :` 行只在后者出现，带上具体是哪一项没过（`blocked` / `Config()` / `Registers()` /
`GuEntrySelectorsMatch`），四种原因的处置完全不同：`blocked` 看 `started/fault/retained`，
`Registers()` 是 19 个 pin 不对，`GuEntrySelectorsMatch` 是选通器在 release 之后变了。

## 开机后怎么确认（照这个做）

进 Windows 后立刻跑：

```powershell
# 判据：f16/f32 ÷ f16/f16 的比值，而不是绝对值
G:\workspace\rtx2705\bench\mma_bench.exe 20000 5
```

比值 ≈ 1.00 = 解锁在；≈ 0.50 = 不在（stock）。别用绝对值判断：降频能把绝对值
从 188 打到 88，看上去跟没解锁一模一样。

想更省事：

```powershell
G:\workspace\repo-ad103\tools\verify-unlock.ps1 -RunNumber 5
```

它会先读 `nvidia-smi` 的频率/功耗/降频原因（不是 `0x1` 就打「本次绝对值不可用」），
再算 `f16/f32 ÷ f16/f16` 这个活比值并据此判定；末节 `overall` 汇总四项，
`exit 0` 表示全过、`exit 1` 表示有不过的。

真出现 `STOPPED. Power OFF fully; …` 说明门是软件拒的，硬件安全，**不用断电**：
直接 Ctrl+Alt+Del 走 Windows Boot Manager 进去测。断电会清掉 `SS0`/`SS1`。

## 一条与机制无关的测量陷阱

`bench/cublas_gemm.cu` 原来对 `fp16/fp16acc` 也传 `float alpha=1.0f`。cuBLAS 的
`cublasGemmEx` 按 `computeType` 的**宽度**读这个 `const void*`，于是它把 `1.0f` 的低
两字节 `0x0000` 读成 `__half 0.0`，于是每个 GEMM 输出全零矩阵、实际工作量塌成几乎零，
计时器报出 **4588 / 4744 TF/s**。

这个数字比这张卡的物理峰值高一个数量级。现在每个用例末尾都打 `nonzero C: …`，全零
直接标 `<-- BROKEN`，细节见 [PITFALLS.md](PITFALLS.md) #12。

## 重试前必须先做的事

1. **先建立退路**。在做任何 ESP 改动之前，确认 BIOS 有 `Boot From File`，能选到
   `\EFI\Microsoft\Boot\bootmgfw.orig.efi`。这是不依赖外部介质的唯一恢复路径。
2. **先看日志再回滚**。`install-esp.ps1 -Rollback` 要删 `AD104-UNLOCK`，现在它会先
   把里面每个 `RUN*.TXT` 的名字、大小、时间打出来再拒绝，除非给 `-Force`——那是这种事
   发生过一次之后才加上的。卡住时先挂 ESP 读日志（`mountvol W: /S`），再决定是否回滚。
3. **U 盘留作救援**，不作为日常介质。U 盘会坏，这是它不适合当唯一路径的原因。

要非易失，换形状：独立 FAT32 分区 + 固件启动项，不劫持 `bootmgfw.efi`。容量要求与
代价见 [INCIDENT-esp-takeover.md](INCIDENT-esp-takeover.md) 结论节。

## 拉起来需要什么

- `windows/ad103-2705` 分支：`https://github.com/A-XIANGQAQ/gpu-unlock-ada/tree/ad103-2705/windows/ad103-2705`
  基于上游 `4e7fefc`；三个 bug 的修复在 `cb3691b`，`c794f3e` 只改文档，
  `6a82336` 恢复九处图检查的硬失败并加 blank 入口态
- 本仓库 `docs/PITFALLS.md`：18 条，每条「症状 → 原因 → 改法」。移植阻塞点之外
  还有 4 个「拆完之后还要验证」的坑（6b 身份要缓存、10b 停机要可见、10c 关日志≠故障、
  10d `%p` 会静默整份日志）、#12 cuBLAS alpha 宽度、#13 override 让 SS0/SS1 读 0、
  #14 `Sealed` 从不复位、#15 为绕过 `GpuChild()` 而放宽的图检查、
  #16 `profile.c` 是生成文件手改会丢、#17 工作区里启动的进程写不了工作区外、
  #18 改注释行数会通过 `__LINE__` 改变产物哈希
- 本仓库 `docs/PRIOR-ART.md`：邻域实现对比，含本移植做错的两处
- `bench/`：四个 benchmark 源（`mma_bench` 在上游 `diagnostics/bench/` 下），
  口径与 `results/` 一致

