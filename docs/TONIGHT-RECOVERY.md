# 今晚恢复手册：引导进入系统之后要做的

> 给 agent 的说明：本文件是**恢复与取证**清单，不改代码、不刷固件。所有命令在 Windows 上用管理员
> PowerShell 或 cmd 执行；Linux live 环境的命令标了 `[linux]`。
> **不要**在本机跑 `start_strata_kill_gui.sh` 之类的模型启动脚本（那是另一台机器的事），
> 也不要删 `bootmgfw.orig.efi`——它是唯一的退路。

## 0. 先进系统：三条路，按成功率排

| 路线 | 前提 | 动作 |
|---|---|---|
| A. U 盘跳过事务 | U 盘上的 EFI 链到 `bootmgfw.orig.efi`（`CF349D28` 之后的版本），且该文件存在 | BIOS 启动菜单（ASUS 多为 **F8**）选 U 盘 → **不要按 `U`**，按 `S`/`Esc` 或等 30 秒 → 走 stock Windows |
| B. Linux live U 盘 | 无（不依赖任何 EFI 版本） | `[linux]` `lsblk -f` 找 vfat ~100–500 MB 分区 → `sudo mount /dev/nvme0n1pX /mnt/esp` → `ls -l /mnt/esp/EFI/Microsoft/Boot/bootmgfw*.efi` → 确认 `bootmgfw.orig.efi` 在 → `sudo cp -a .../bootmgfw.orig.efi .../bootmgfw.efi` → `sync && sudo umount /mnt/esp && reboot` |
| C. Windows 安装盘 | 有安装 U 盘 | Shift+F10 → `diskpart` → `list vol` → 选 FAT32 100–500 MB → `assign letter=W` → `copy /y W:\EFI\Microsoft\Boot\bootmgfw.orig.efi W:\EFI\Microsoft\Boot\bootmgfw.efi` |

**先做 A，失败再 B。** 若 U 盘 EFI 是旧版（链到 `bootmgfw.efi`），A 会链回被接管的那份自己 → 直接走 B。

## 1. 进系统后 5 分钟：五项核对

```powershell
# 1) bootmgfw 是否已是原版（长度与哈希都要对上）
$bm = "C:\Windows\Boot\EFI\bootmgfw.efi"   # 仅供参考；实际看 ESP
# ESP 通常没盘符，用 diskpart 临时挂载后核对：
#   diskpart → list vol → 选 FAT32 → assign letter=W
$p = "W:\EFI\Microsoft\Boot\bootmgfw.efi"
(Get-Item $p).Length                       # 期望 3086680
(Get-FileHash $p -Algorithm SHA256).Hash   # 期望 2d60a2203865122dad22772136b3d905167d9dcf926d602bb5f48b3b6668abec

# 2) 启动项有没有残留（被接管/被接管后没清干净都会在这里暴露）
bcdedit /enum '{fwbootmgr}'
bcdedit /enum all | Select-String -Pattern 'unlock','AD104','4090'

# 3) ESP 上的残留目录（恢复后应已不存在）
dir W:\AD104-ASSETS
dir W:\AD104-UNLOCK
```

```powershell
# 4) BitLocker 状态（改动启动链会触发恢复密钥；先确认状态，必要时挂起）
manage-bde -status C:
# 若打算再次改启动项：Suspend-BitLocker -MountPoint C: -RebootCount 3

# 5) Fast Startup（开着会让"关机"变成休眠，显卡可能回 stock）
powercfg /a
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').HiberbootEnabled
```

## 2. 顺手采集现场数据（用来补 `INCIDENT-esp-takeover.md` 的 `待补`）

```powershell
# a) ESP 的剩余空间 —— 这是判断"昨天是不是空间不足"的关键
Get-Volume | Where-Object FileSystem -eq 'FAT32' | Select-Object DriveLetter,FileSystemLabel,Size,SizeRemaining
# b) 资产清单（install-esp.ps1 需要这 5 个，缺一个都会让 EFI 在写日志前就中止）
dir W:\AD104-ASSETS
#   booter_load_ad102.bin / v67-ad102-610.43.03-four-plm.bin / gsp_ga10x.bin
#   gsp_boot_ad102.bin / gsp_boot_desc_ad102.bin
# c) EFI 有没有真的跑起来过（有日志 = 跑到了写日志这一步）
dir W:\AD104-UNLOCK
# d) 原始启动管理器
(Get-Item W:\EFI\Microsoft\Boot\bootmgfw.orig.efi).Length
(Get-FileHash W:\EFI\Microsoft\Boot\bootmgfw.orig.efi -Algorithm SHA256).Hash
# e) 装上去的是哪一版 EFI（与本地 build 产物对比哈希）
(Get-FileHash W:\EFI\Microsoft\Boot\bootmgfw.efi -Algorithm SHA256).Hash
```

把 a–e 的输出贴进 `docs/INCIDENT-esp-takeover.md` 对应位置，并把"屏幕停在哪一屏"写进 `待补`。

## 3. 判据：昨晚到底卡在哪

| 现场 | 结论 | 依据 |
|---|---|---|
| ESP 剩余空间接近 0，或 `AD104-ASSETS` 少于 5 个文件 | **空间不足**（本仓库 `install-esp.ps1` 没有任何剩余空间检查） | 上游端口 MarvinFS 要求 FAT32 上 **~85 MB** 余量；用 ESP 时要 **≥117 MB 空闲**（85 + 保留 32 MB） |
| `AD104-UNLOCK` 为空/不存在 | EFI 没跑到写日志那步：问题在更早（加载、资源、固件属性） | 日志目录是 EFI 自己创建的 |
| `bootmgfw.orig.efi` 不存在或长度 ≠ 3086680 | 链式目标缺失 → 自我链接/加载失败 | `install-esp.ps1` 里写死的 stock 常量 |
| 三者都正常 | 才轮到"补丁打了仍失败"，需要单独分析 | 该分支三处补丁（允许内置卷/同卷交接/链式改名）已在代码里 |

## 4. 恢复后的性能复核（Windows 侧，确认当前是 stock 还是已解锁）

```powershell
# 用本仓库自带的探针（与仓库 results/ 里的口径一致；issue rate，不是 GEMM）
cd bench
.\build-fp8mma.cmd          # 产出 fp8_mma_bench.exe
.\fp8_mma_bench.exe
# stock 期望：FP8 e4m3/f32 ≈ 165 TF/s；已解锁 ≈ 324 TF/s
```

也可用 `cublas_gemm.exe`（`build-cublas.cmd`）看 GEMM 侧：stock 约 199 TF/s，解锁约 300–310。

判据：**两边差 ~1.9–2× → 处于解锁态；差 <10% → stock**。Windows 下读不到 SS0/SS1，
所以只能用性能比值判定，这一点 `MarvinFS` 的 `Test-Gpu4090Unlock.ps1`（比值 ≥0.85）用的也是同一思路。

## 5. 决策树：恢复之后怎么走

1. **只求稳** → 保持易失方案（U 盘 + 手动 `U`）。代价：每次开机按一次键、开机多 ~40 秒。
2. **要非易失，换形状**：不要修 `install-esp.ps1` 的接管逻辑，改成
   **固件启动项 + 专用 FAT32 分区**（`MarvinFS/rtx4090-uefi` 的形态，仓库里有源码可参考）：
   - 需要 **~85 MB**（GSP 固件不可压到更小，xz 也只到 70 MB）；
   - 专用分区最小 128 MB，4K 扇区盘要 272 MB；
   - 用 ESP 的话需要 **≥117 MB 空闲**，否则只会把 Windows 服务空间挤掉；
   - 装前 `Suspend-BitLocker`，装后核对 `bcdedit /enum {fwbootmgr}`。
3. **放弃非易失**：只用 U 盘。已确认这是三种独立实现里唯一"全量验证过"的形态
   （`MatchaCake` 把 ESP 接管明确标为"未测试，仅设计文档"）。

## 6. 别做的四件事

1. **不要删 `bootmgfw.orig.efi`**——那是唯一的恢复来源。
2. **不要在 Secure Boot 开着时装未签名的 EFI**；要用就先自签并入 db（`Goldlionren` 有完整流程）。
3. **不要在失败后 `rmmod`/强杀**——若 EFI 报"固件未停"，只能断电。
4. **不要用 `kill -9` 停推理引擎**（另一套脚本的教训）：先 `SIGTERM`，再等显存降到 <1000 MiB。
