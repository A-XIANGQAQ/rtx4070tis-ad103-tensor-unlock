# 生态现状：2026-10 这半个月（2026-10-28 整理）

`gh search repos` 跑了 `gpu-unlock` / `"gpu unlock"` / `tensor unlock` / `tensor cores unlock` /
`ad103 unlock` 五组查询，2026-10-24 之后仍活跃的相关仓库四十多个。这份文档只收与
**AD103 `10de:2705`** 和「Windows 预驱动解锁」直接有关的，其余按类别列名单。

> 数字来源分两档：**（本仓库复核）** 是拿原始日志或 `results/` 核过的；**（对方自述）** 来自
> 对方 README，没在本机复现。

## 一、上游：`4e7fefc` 之后有 84 个提交

本仓库 windows 分支的 base 是上游 `4e7fefc`。`gh api repos/JustAResearcher/gpu-unlock-ada/compare/4e7fefc...main`
给出 **ahead_by = 84**。挑与本卡有关的前十条：

| 日期 | commit | 内容 |
|---|---|---|
| 10-26 | `26fffa6` | 正式接纳 **RTX 4080 SUPER（AD103，`10de:2702`）** 为精确实验目标 |
| 10-26 | `da96e3f` | **PLM 已经是打开状态时记为 skipped，不再当成解锁失败** |
| 10-26 | `d28c485` | 笔记本功耗上限读不到时接受 N/A |
| 10-26 | `5d2867e` | sm_89 以下的构建里 fp8 项打 `n/a` |
| 10-25 | `a13b3ea` | 补测 FP8（E4M3）发射率 —— 与 `results/` 里那条口径同源 |
| 10-25 | `86c28b1` | 新增实验目标 4070 Ti SUPER（`10de:2689`，AD102 家族） |
| 10-25 | `16978f9` `6dfb7d2` | AD103M 4090 Mobile（`10de:2757`）走 AD102 家族的资产与路径 |
| 10-25 | `e807ea3` | 接纳 4070（AD103，`10de:2709`） |
| 10-25 | `cd50969` `18f858f` | 4070 Ti（AD104 `2782`）、4070 SUPER（AD104 `2783`） |
| 10-25 | `b6b0c00` | 3050 6GB（GA107 `2584`）走 GA102 Booter 路径 |

`da96e3f` 那条最值得看：它解决的是「入口态已经不是 stock」这件事，与我们在 `RUN0007`–`RUN0012`
遇到的情况同类，但处理方向相反 —— 上游选择**跳过**，本仓库选择**接受 blank 入口态并继续事务**
（`docs/WHERE-IT-STOPPED.md` 的入口闸门那节）。两条路都能走通，区别是上游不写寄存器，
本仓库写完之后 `SS0`/`SS1` 一定是我们想要的那一对。

## 二、同卡 `10de:2705`：已经有四个移植

| 仓库 | 更新 | 做法 | 与本仓库的关系 |
|---|---|---|---|
| `wyx1277348872-a11y/gpu-unlock-4070tis-ad103-win` | 10-25 | fork `Zihao-Wu06/gpu-unlock-for-windows`（再上游是 Zagitta + gpu-unlock-ada），加了 2705 的 profile 和一处拓扑修复 | **独立复现了我们的 PITFALLS #2**，另有非易失装法（见第五节） |
| `HumbleUser33/gpu-unlock-ada-ad103-2704` | 10-27 | AD103 4080（`10de:2704`，Dell OEM），带 transaction journal 与 stock/unlocked 对照 | 邻卡，journal 结构可与 `RUN*.TXT` 对照 |
| `NeoChen1024/gpu-unlock-ad103` | 10-24 | AD103（4080 / 4080S），带只读 preflight 与已复核的 benchmark | 邻卡，preflight 思路与我们的 `preflight[6]` 同源 |
| `xHeaVeNxyz/gpu-unlock-ada-windows-ad103` | 10-27 | AD103 Windows 移植 | 未读源码，标题级 |

`wyx` 那份的 `PORT-2705.md` 测的是 330 W 上限、cuBLAS 8192³、8 次预热后 25 次取最好**（对方自述）**：

| 路径 | stock | 解锁 | 比值 |
|---|---:|---:|---:|
| FP32（CUDA core，对照） | 29.70 TFLOPS | 29.42 | **0.99×** |
| FP16 → FP32 累加 | 84.92 | 149.67 | **1.76×** |
| FP16 → FP16 累加（对照） | 85.96 | 149.08 | 1.73× |

两个对照是重点：标量 FP32 不动，解锁后 FP32 累加追平本来就没被限速的 FP16 累加。
GEMM 比值低于发射率的 2×，因为 cuBLAS 还受显存带宽与调度限制 —— 和 `docs/PRIOR-ART.md`
里对三个仪器的解释一致。

## 三、PITFALLS #2 的第三方复现

`wyx` 的原文：

> This board's firmware binds **two** child controllers to the target GPU. One exposes a Graphics
> Output Protocol and drives the console; the other exposes **no GOP at all**, even with a monitor on
> that connector. Upstream's `DisplayChild()` required every child to be a valid GOP display and
> returned `EFI_UNSUPPORTED` for the second one, which made `GuFindReleaseOwner()` fail, which aborted
> the run at `stage=ownership` before any GPU write.

对应我们 `docs/PITFALLS.md` #2：同一 GPU root port 下两个显示子节点，ACPI ADR `0x4003` 与 `0x7003`，
上游的前缀匹配差一字节。他们的修法在 `efi/windows/uefi/ownership.c`，三个文件约 90 行，
`vendor/` 一个字没动。我们走的是 `GpuChild()` 前缀匹配 + 结构校验 + `CacheGpuChildren()` 缓存。

两边独立撞同一处，说明这块板的拓扑不是个例，值得把这句写进 PITFALLS #2 的「症状」里当外部佐证。

他们另一条也与我们重合：`SS0`/`SS1` **扛过 FLR 和 GOP 重连**（`POST-GOP SS0=0x88888888 SS1=0x00000008`），
且没有 `NVRM Xid`、`nvidia-smi` 正常、两台显示器都回来了。我们是靠 `verify-unlock.ps1` 的
`throttle 0x1` + live 比值证明同一件事。

## 四、机制对照：`physicsdolphin/nv-uefi-unlocker`

Rust 写的 UEFI 解锁器，★52，10-27 仍在更新。链条：

```
SEC2 scrubber → FWSEC-FRTS（WPR2）→ 签名 Booter 启动 GSP-RM
  →（门控后）V67 四写 payload → 读回验证 → FLR → 链式交回 Windows Boot Manager
```

**先纠正本文档早前的一处判断**：曾写过「我们只写 `FEAT_OVR_PLM` 一个寄存器，它是四写」，这
不成立。本仓库的 EFI 钉住并加载的就是同一份四写 payload —— `profile.c:19` 的 Pins、
`boot_io.c:179-181` 的 `\AD104-ASSETS\` 加载表、`vendor/unlock_610.c:38` 的 `V67_FILE_AD102`，
sha256 `44c36b2d…`、64000 B；RUN0001–RUN0013 每份日志都有
`asset result: …four-plm.bin … bytes=64000`。四写目标由本地 payload 逐字节解出（值字/地址字成对）：

| # | payload 偏移（值 / 地址） | 写值 | 目标寄存器 |
|---|---|---|---|
| 1 | `0xf948` / `0xf960` | `0xfffff0ff` | WPR_CFG `0x1fa7cc` |
| 2 | `0xf974` / `0xf984` | `0xffffffff` | FBPA `0x9a0148` |
| 3 | `0xf998` / `0xf9a8` | `0xffffffff` | WPR `0x1fa7c4` |
| 4 | `0xf9bc` / `0xf9cc` | `0xffffffff` | FEAT_OVR_PLM `0x823804` |

payload 随后在 mailbox0 置 marker `0x67b00001`（`0xf9e0`）并跳 cleanup（`0xf9fc`）。我们的读回
检查（`vendor/unlock_610.c:337-342` 的 `ad102_permissions[]`）列的正是这四项，其中 `FBPA` 的
`required=false` —— 是观测项、不计必过，与上游 `docs/ada-2705-report.md` 的「第四个 FBPA 字段
仍读 `0xffffff0f`、不计入解锁」一致。

这四个目标里**没有** `SS0`（`0x82381c`）/`SS1`（`0x823820`），所以四写与 `PITFALLS.md` #13 的
blank 入口态**正交**：它既不是 blank 的成因，也绕不开 blank。§九 第 1 条的问法作废 —— 答案在
本地清单里，不在 Rust 仓库里。

它自己的实测两代（对方自述）：

| 卡 | 结果 | 档位 |
|---|---|---|
| RTX 4060 Laptop `28e0`（AD107M） | FP16 GEMM 29.89 → 49.33 TFLOPS（1.65×），四 PLM 读回一致 | （对方自述） |
| RTX 2070 `1f07`（TU106） | FP32 累加 GEMM 36 → 60–63 TFLOPS（+67~75%） | （对方自述） |
| RTX 2060 Super `1f06` | 同链通过（issue #12，社区实测） | （对方自述） |

它的周边设计比我们完整，四条可以直接借：

- **回放/诊断模式**：不放 `v67-*.bin` 就走完全链、零写入。我们想做同类的事只能自己注释 payload。
- **多卡**：逐张处理，`EALREADY` 让位给下一张，单张失败只对那张卡 emergency FLR；`tx-select-bdf.txt`
  钉卡（内容 `bb:dd.f`，对不上就拒绝猜测、本轮零事务）。
- **武装模式**：`i_know_what_i_am_doing.txt` 存在时确认环节变 5 秒倒计时（无人值守用）。
- **链回目标钉定**：`chain-target.txt` 可以链到 Limine 而不是 Windows Boot Manager。

它记录的负面结论也有用：**Linux RTD3 会擦掉解锁**（issue #9）、**Thunderbolt / 热插拔 eGPU 属于
「易失解锁敌对环境」**（`4f8b9ab`）。这两条我们文档里没有，若要跨系统使用就该补。

Turing 与 Ada 的机制差异它列了表：FEAT 块在 `0x4096xx`、**FLR 会重锁 PLM**、Windows 侧需要先切
GSP 模式。对只做 Ada 的我们没有直接影响，但「FLR 会重锁 PLM」这条值得在本卡上复核一次 ——
我们的 `POST-FLR SS0/SS1` 是读回来的，不是假设。

## 五、非易失那条路，已经有人实现

`docs/INCIDENT-esp-takeover.md` 的结论是：要非易失就换形状，独立 FAT32 分区 + 固件启动项，
别劫持 `bootmgfw.efi`。`Zihao-Wu06` / `wyx` 这条线的安装器做的就是这件事：

> The installer creates a hidden 300 MiB FAT32 partition with no drive letter, or uses a FAT32 USB
> drive you choose. It copies a small UEFI program there and adds a firmware boot entry,
> `GPU Unlock (auto)`, ahead of Windows.

能力边界要说清：解锁本身仍然易失 —— 断电清 `SS0`/`SS1` 这一点没变，它省掉的是「每次插 U 盘、
按 F8 选盘、按 U」。我们的 INCIDENT 结论没被推翻，只是从「建议」变成「有人在做」。

## 六、生态侧

| 仓库 / 变化 | 日期 | 内容 |
|---|---|---|
| `Zagitta/gpu-unlock` | 10-26 / 10-27 | `09305c4` driver 重构成 **recipe driven**（一张卡一份 recipe）；`0532473` **Release 2.0**；`1fc6d62` 加 Unraid 支持 |
| `impacifist/Windows-GPU-UNLOCK` | 10-27 | `c403e8f` **把 GPU 家族特征、共享固件与机器 profile pin 分开**；同期合并 3080 显示路由研究（PR #39）与 B660M + 3090 Ti profile（PR #77） |
| `miounet11/gpuunlock` | 10-27 | 把 gpu-unlock-ada（AD102/AD103）与 gpu-unlock（GA10x + resume）**合并成一个内核模块**；文档站 gpuunlock.com |
| `hdcdn/rtx40-ada-unlock-notes` | 10-26 | 逐卡实测整理 + 三处辟谣；写明 4070 Ti SUPER 的 E4M3 GEMM 只有 **59.326 → 59.495（+0.3%）**，与 `PRIOR-ART.md` 引的上游数一致 |
| `lemonaide152/gpu-unlock-3070-lhr` | 10-28 | 3070 LHR，判据写成 **mma ratio 0.507 → 1.000** —— 与我们 `f16/f32 ÷ f16/f16` 的口径相同 |
| `RainbowWizard-coder/gpu-unlock` | 10-28 | fork Zagitta，带只读 SM 发射率诊断 + **Blackwell 研究笔记** |
| Linux 集成 | 10 月 | `nonkronk/unraid-3090-unlock`、`tabilzad/gpu-unlock-unraid`、`wickeddoc/gpu-unlock-unraid`、`sw1313/synology-gpu-unlock-ada`、`Sticzu/nixos-gpu-unlock`、`Yunor743/gpu-unlock.nix`、`rPlakama/gpu-unlock-nix`、`Twilight0/nouveau-dkms` |
| 安装器 / GUI | 10-26 | `Zihao-Wu06/gpu-unlock-for-windows`（一键安装 + GUI，`wyx` 的上游）、`EEEEgoose/unlockGPU4Unraid` |
| 研究笔记 | 10-27 | `kael-odin/tu102-22g-unlock-notes`（TU102，FWSEC 家族标定法、15 个坑、4096³ GEMM 95.87 TFLOPS）、`SSS-Sunshine/rtx4090-gpu-unlock-evaluation`（4090 48G，FP8/BF16/NCCL 遥测） |
| Blackwell | 9–10 月 | `IzzieBoopers/5080-Unlock_Linux`、`SuperMewio/5080-unlock-linux`（尝试，未成） |

噪声（搜索里混进来的，与 SM 速率无关）：`ShyVortex/dlss-unlocked`（DLSS 功能解锁）、
`sabre64fury/*` 与 `maxthegamer257/*`（driver 下载站）、`nicoyxb/*` 与 `Shijiuwei/gpu-unlock-mirror-494`
（纯镜像）、`jtskxx/NVPARADISE`（SM 数 / fusing，另一个方向）。

## 七、目录对照：同一件事，四种摆法

四个仓库解决同一个问题，目录切法不一样。看这层比看 README 更快知道别人怎么拆的。

| 仓库 | 顶层 | 说明 |
|---|---|---|
| 本仓库 `repo-ad103` | `bench/` `build/` `docs/` `results/` `tools/` | 源码与 EFI 不在本仓库（只在 fork 分支）；`results/` 放原始采集 + `SHA256SUMS` |
| 本仓库的 fork 分支 `A-XIANGQAQ/gpu-unlock-ada @ ad103-2705` | `app.c` `boot_io.c` `checks.c` `compat.c` `format.c` `msi_release.c` + `compat/` `diagnostic/` `LICENSES/` + `Build-Experimental.ps1` `Test-Experimental.ps1` `benchmark.py` `compare.py` | 真正的 EFI 源码；`boot_profile.h` 是机器 profile，`profile.c` 由 `tools/gen_profile.py` 生成 |
| `wyx1277348872-a11y/gpu-unlock-4070tis-ad103-win` | `docs/` `efi/` `installer/` `tools/` | **把安装器单独一层**，`efi/windows/uefi/*.c` 按阶段分文件（我们同名文件在 fork 里是平铺的） |
| `physicsdolphin/nv-uefi-unlocker` | `loader/` `sim/` `docs/` `tools/` `release/` `assets/` + `Cargo.toml` | 有 **`sim/`（宿主侧仿真）** 和 **`release/`（发版产物）** 两层，`loader/` 才是 UEFI 代码 |

值得抄的是后两行：`installer/` 与 `sim/` 这两层我们都没有 —— 我们的等价物是
`tools/deploy-usb.ps1`（散在 tools）与 `windows/ad103-2705` 下的离线测试套件（散在源码树里）。

## 八、本仓库里落这次调研的位置

| 位置 | 要补什么 |
|---|---|
| `docs/PITFALLS.md` #2 | 「第二个 child 没有 GOP」的外部复现（`wyx` 的 `ownership.c`，90 行） |
| `docs/PITFALLS.md` #13 附近 | 上游 `da96e3f` 的相反处理（已打开 PLM 就跳过），与本仓库 blank 闸门的取舍写清 |
| `docs/INCIDENT-esp-takeover.md` 结论节 | 「独立 FAT32 分区 + 固件启动项」已有人实现（300 MiB、`GPU Unlock (auto)`） |
| `docs/WHERE-IT-STOPPED.md` 「拉起来需要什么」 | 上游 base 从「基于 `4e7fefc`」改成「基于 `4e7fefc`（落后 main 84 个提交，2026-10-28 核对）」 |
| `docs/PRIOR-ART.md` | 新增邻域：`nv-uefi-unlocker`（Rust、四写、`sim/`）、`wyx`（同卡、拓扑修复）、`impacifist` 的家族/机器 pin 分离、`Zagitta` 2.0 recipe |

## 九、四件事的处理结果（2026-10-28）

| # | 原议题 | 结论 |
|---|---|---|
| 1 | 读四写 payload 写的是哪四个 PLM，能否绕开 blank 入口态 | **已解**：WPR_CFG / FBPA / WPR / FEAT_OVR_PLM，与我们已在跑的是同一份 payload；不含 `SS0`/`SS1`，与 #13 正交。解码脚本见 `tools/payload-report.py`（可复跑、带 sha 与偏移校验） |
| 2 | 是否 rebase 到上游 main | **已落，且验收通过**。改动集不相交：本 fork 33 个提交只碰 `windows/ad103-2705/**`（159 文件），上游 84 个提交在 `windows/` 下 **0 个文件**、`firmware/` 下也是 0 个（228 文件集中在 `docs/`、`diagnostics/bench`、`kernel/gpu_unlock`、各卡报告）。2026-10-28 已 rebase `517930f` → `d28c485`，干净重放 33 个提交，tip 变 `5cc799c`，原 tip 打成 tag `ad103-2705-pre-rebase-20261028`（未 force-push）。硬验收：`windows/ad103-2705` 子树哈希前后同为 `70a027c1`；重建的 EFI 仍为 **106496 B / `0705256564e57690…`**，与 rebase 前逐字节相同。结果同时记在 fork 的 `CHANGES.md` 与 `docs/WHERE-IT-STOPPED.md` |
| 3 | 给 PITFALLS #2 补外部佐证 | **已落** `docs/PITFALLS.md` #2：`wyx` 的 `PORT-2705.md` 独立撞上同一 root port 下第二个 child 无 GOP，修法是改 `ownership.c`（约 90 行 / 3 文件） |
| 4 | 补 `docs/PRIOR-ART.md` 的邻域表 | **已落**：新增 `nv-uefi-unlocker`、`wyx`、`impacifist c403e8f`、`Zagitta 2.0` 四节，并指向新的 `docs/UPSTREAM-2705-CROSSCHECK.md` |

跨系统数据核对另开一篇：`docs/UPSTREAM-2705-CROSSCHECK.md`（上游 Linux 240 W 与我们 Windows
320 W 逐项对表，解释差异来源，避免把两边绝对值当成互相矛盾）。

## 附：这份文档没做的事

- 没有 clone 任何外部仓库，也没编译过别人的代码。所以上表「对方自述」的数字都是转述。
- `hdcdn` 那条 `59.326 → 59.495` 已用一次源核对：它就是上游 `docs/ada-2705-report.md` 里
  「matched E4M3/FP32 CUTLASS GEMM，`m=n=k=4096`，240 W 帽，1.0029×」那一组，转述无误。
  上游 2705 报告本身没被读过之前，这里写的是「未核对」；现已核对，见
  `docs/UPSTREAM-2705-CROSSCHECK.md`。
- 没有追 `Goldlionren/gpu-unlock-4080s`（`PRIOR-ART.md` 已收）与 `unitypit71`（`README.md` 致谢里已有）
  的后续，两者的最后更新都早于 2026-10-24。
