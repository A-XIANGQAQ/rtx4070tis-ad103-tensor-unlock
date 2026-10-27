# 事故记录：ESP 接管导致开机卡住（2026-10-25/26）

> 状态：**已决定不再使用 ESP 接管**，恢复方式已确认。本文记录现象与判据。
> 2026-10-27 补记：恢复后测到了现场事实，下面「三个候选原因」里两条被排除、一条降级为
> 待验证假设。结论没变，但排除过程和丢失的证据链要留着。

## 现象

把易失方案（U 盘手动引导）改成「接入内置 ESP 自动执行」之后，机器在 boot 阶段停住，
进不了 Windows。断电后重试仍然是同一现象。

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
所以这不是变砖，是启动路径被劫持。

## 回滚前的现场（2026-10-27 实测）

```
ESP                    disk 3 分区 1，300 MB（614400 扇区），Type=System，无盘符
ESP bootmgfw.efi       解锁 EFI（哈希未记录，见下）
ESP bootmgfw.orig.efi  3086680 B / 2d60a220…（原版，逐字节完好）
ESP AD104-ASSETS       5 个文件，共 80.5 MB
```

`bootmgfw.efi` 那个版本的哈希**没有留下来**：`install-esp.ps1` 装的时候会把
`efi_sha256` 写进 `esp-install-state.json`，而 `-Rollback` 顺手把这个文件删了。
这是一次自己造成的证据丢失：想知道当时跑的是哪版，只能从安装时间反推
（回滚前 ESP 上那个文件的 mtime），而这条也没记。

## 三个候选原因，现在的结果

1. **~~`#9` 内置卷被拒~~ 已排除。** 上游 `boot_io.c` 里那两道闸
   （`...||!usb) return EFI_ACCESS_DENIED;` 和 `volume==OwnVolume → EFI_NOT_FOUND`）
   装上去的版本里三处改动全都在（允许内置卷 / 允许同卷交接 / 链式改名
   `bootmgfw.orig.efi`）。
2. **~~版本混用自我链接~~ 已排除。** `bootmgfw.orig.efi` 两轮都完整（3086680 B /
   `2d60a220`），不存在自己链自己。链式改名从 `ad103-2705` 分支的 `e6ab1c8` 起就有，
   之后每个构建都链到 `.orig`，所以装上去的那版目标是对的。
3. **~~ESP 空间不足~~ 已排除。** ESP 是 300 MB，资产只占 80.5 MB，余量 200 MB 以上，
   远超 `MarvinFS` 给的 117 MB 阈值。这一条当初是「机制最硬」的猜测，结果是错的。

也排除了启动项顺序：不是 USB 排在前面导致没走 ESP，而是主动在固件菜单里选
Windows Boot Manager 时卡住。

所以三条候选原因全错。剩下的唯一存活线索是 `boot_io.c` 的 `Inspect()` 会拒绝第二个
`MEDIA_HARDDRIVE_DP` 节点，这是 USB 路径与 ESP 路径唯一已知的代码差异：

```c
/* 改前 */
if(n!=sizeof(HARDDRIVE_DEVICE_PATH)||++hd!=1)return FALSE;
```

`c9f215d` 已改成接受多个 harddrive 节点（`hd>16` 为上界），并给 `GuBootOpen` 的六个
静默出口加了屏显。但这个改动从未在 ESP 路径上重测过，是假设，不是结论。

### 丢失的证据（这次取证上的最大失误）

回滚脚本 `install-esp.ps1 -Rollback` 会删除 `\AD104-UNLOCK`。所以「EFI 到底有没有跑到
写日志那一步」这个问题再也无法回答。卡住之后先挂 ESP 读日志（`mountvol W: /S`），
再决定要不要回滚；顺序反了，判据就没了。

旁证：三种独立实现里，ESP 接管都是最不成熟的那条。
`MatchaCake/ad102-windows-unlock` 把「ESP 常驻 + `bcdedit` 接管」标为「未测试，仅设计文档」；
`MarvinFS/rtx4090-uefi` 干脆不走这条路（独立启动项 + 专用分区，是它唯一验证过的形态）；
`wyx1277-.../gpu-unlock-4070tis-ad103-win` 走固件启动项 + 开关，并提供 boot log 的 `FINAL` 行用于定位。

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

- **保留易失（U 盘手动）方案。** 这条路有 Windows 内实测数据的是 `RUN0005`（EFI
  `76FEE036`）和 10/25 那次（EFI `5d5277c2`，该产物已不在盘上），判据见
  [WHERE-IT-STOPPED.md](WHERE-IT-STOPPED.md)。
- ESP 接管的代价不只是每次开机多 ~40 秒，而是把实验代码放进启动关键路径；一旦它的
  gate 拒绝执行，机器就停在 boot 阶段。这台机器上它就是没跑通，原因还没查清。
- 要非易失，别在 ESP 接管上加补丁，换形状：独立 FAT32 分区 + 固件启动项，不劫持
  `bootmgfw.efi`。按 `MarvinFS` 的数字：资产 ~85 MB，专用分区最小 128 MB（4K 扇区盘
  272 MB），用现有 ESP 需 ≥117 MB 空闲。这个形状的好处是解锁 EFI 挂了，
  Windows Boot Manager 那条路完全没被碰过。
- 恢复不需要重新安装 Windows，也不需要动 BCD。
