# 事故记录：ESP 接管导致开机卡住（2026-10-25/26）

> 状态：**已决定不再使用 ESP 接管**，恢复方式已确认。本文记录现象与判据。
> 恢复步骤见下；标 `待补` 的字段在恢复后采集回填。

## 现象

把易失方案（U 盘手动引导）改成"接入内置 ESP 自动执行"之后，机器在 boot 阶段停住，
无法进入 Windows。断电后重试仍然是同一现象。

## 做了什么（可复核）

`tools/install-esp.ps1` 的做法是接管固件本来就启动的那个文件：

```
firmware -> \EFI\Microsoft\Boot\bootmgfw.efi      (被换成解锁 EFI)
          -> 解锁事务，然后 StartImage()
          -> \EFI\Microsoft\Boot\bootmgfw.orig.efi  (原版启动管理器，逐字节保留)
          -> Windows
```

`-Rollback` 的动作是 `bootmgfw.orig.efi` 覆盖回 `bootmgfw.efi`，并删掉
`\AD104-ASSETS`、`\AD104-UNLOCK`（含 `AUTO.TXT`）。**原版文件在安装时被逐字节保留**，
所以这不是"变砖"，是启动路径被劫持。

## 两个候选原因（`docs/PITFALLS.md` 都已预言）

1. **`#9` 内置卷被拒**：上游 `boot_io.c` 里有 `...||!usb) return EFI_ACCESS_DENIED;`
   和 `volume==OwnVolume → EFI_NOT_FOUND`。从 ESP 自身启动时这两道闸都会命中，
   表现正是"程序什么都不做就退出，连 Windows 都不启动"。要装 ESP 必须先落三处改动：
   允许内置卷 / 允许同卷交接 / 链式目标改名。
2. **版本混用自我链接**：`CF349D28` 之后链式目标才改成 `bootmgfw.orig.efi`。
   若 U 盘上的 EFI 是旧版（链到 `bootmgfw.efi`），而 ESP 上的 `bootmgfw.efi` 已经是
   解锁 EFI，就会"自己链自己"。

3. **ESP 空间不足**（本仓库原先没列出的一条，但机制最硬）：`install-esp.ps1` 要往 ESP 里放
   5 个固件资产共 **80.7 MB**（`booter_load_ad102.bin`、`v67-ad102-610.43.03-four-plm.bin`、
   `gsp_ga10x.bin`、`gsp_boot_ad102.bin`、`gsp_boot_desc_ad102.bin`），而脚本**没有任何剩余空间检查**。
   上游另一个 Windows 端口（`MarvinFS/rtx4090-uefi`）给出的硬阈值是：FAT32 上需要 **~85 MB** 余量，
   且只有在 ESP 还剩 **32 MB 保留空间（即 ≥117 MB 空闲）** 时才把资产放 ESP；它明确写"100 MB 的 ESP 通常不够"。
   若本机 ESP 就是默认 100 MB，这条足以解释"什么都没发生就停在 boot"。

旁证：三种独立实现里，ESP 接管都是最不成熟的那条——
`MatchaCake/ad102-windows-unlock` 把"ESP 常驻 + `bcdedit` 接管"标为 **❌ 未测试，仅设计文档**；
`MarvinFS/rtx4090-uefi` 干脆不走这条路（独立启动项 + 专用分区，是它唯一验证过的形态）；
`wyx1277-.../gpu-unlock-4070tis-ad103-win` 走固件启动项 + 开关，并提供 boot log 的 `FINAL` 行用于定位。

待补（恢复后采集）：`屏幕停在哪一屏 / 有没有 RUNxxxx.TXT / 安装的 EFI 版本 /
ESP 剩余空间 / AD104-ASSETS 文件数`。

## 恢复步骤（已确认可用）

目标只有一个：**把 `bootmgfw.orig.efi` 复制回 `bootmgfw.efi`**。

### 路线 1：能从 U 盘进 Windows

BIOS 启动菜单选 U 盘 → **不要按 U**，按 `S`/`Esc` 或等 30 秒（跳过事务，走 stock Windows）
→ 进系统后在管理员 PowerShell：

```powershell
cd tools
.\install-esp.ps1 -Rollback
```

### 路线 2：Linux live U 盘（不依赖那份 EFI，最稳）

```bash
lsblk -f                                   # 找 vfat、100–500MB 的 ESP
sudo mount /dev/nvme0n1pX /mnt/esp
ls -l /mnt/esp/EFI/Microsoft/Boot/bootmgfw*.efi        # 必须看到 bootmgfw.orig.efi
sudo cp -a /mnt/esp/EFI/Microsoft/Boot/bootmgfw.orig.efi \
           /mnt/esp/EFI/Microsoft/Boot/bootmgfw.efi
sha256sum /mnt/esp/EFI/Microsoft/Boot/bootmgfw.efi     # 应为下方 stock 值
sudo rm -rf /mnt/esp/AD104-UNLOCK /mnt/esp/AD104-ASSETS
sync && sudo umount /mnt/esp && sudo reboot
```

stock `bootmgfw.efi` 的期望值（取自 `install-esp.ps1` 的常量）：

```
长度   3086680 字节
sha256 2d60a2203865122dad22772136b3d905167d9dcf926d602bb5f48b3b6668abec
```

### 路线 3：Windows 安装盘 → Shift+F10

```
diskpart → list vol → 选中那个 FAT32 100–500MB 的 ESP → select volume N → assign letter=W → exit
copy /y W:\EFI\Microsoft\Boot\bootmgfw.orig.efi W:\EFI\Microsoft\Boot\bootmgfw.efi
```

若 `bootmgfw.orig.efi` 不存在（安装中途失败），从 Windows ISO 的
`\EFI\Microsoft\Boot\bootmgfw.efi` 取一份覆盖即可；BCD 未被修改过。

## 结论

- **保留易失（U 盘手动）方案**。ESP 接管的代价不只是每次开机多 ~40 秒，而是把实验代码
  放进启动关键路径；一旦它的 gate 拒绝执行，机器就停在 boot 阶段。
- 要做非易失，前置条件是：先落 `PITFALLS #9` 的三处改动，并保证 U 盘与 ESP 上的 EFI
  同版本；然后在一台可以随时用 live USB 恢复的机器上验证。
- 恢复不需要重新安装 Windows，也不需要动 BCD。
