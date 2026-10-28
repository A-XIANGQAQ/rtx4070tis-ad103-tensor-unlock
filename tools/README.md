# tools：六个脚本

`.ps1` 与两个 `.py` 都是操作脚本。除 `gen_profile.py`（GPL-2.0-only，内嵌上游 `profile.c`
的模板）外都是 MIT，首行带 SPDX。

| 脚本 | 做什么 | 会改动什么 | 退出码 |
|---|---|---|---|
| `verify-unlock.ps1` | 四项验证：时钟状态、事务日志、发射率比值、数值校验 | 只读；把 exe 复制到 `%TEMP%\gpu-verify` 再跑 | 0 四项全过 / 1 有不过的 |
| `classify-run.ps1` | 把一份 `RUNxxxx.TXT` 判成十七种结局之一 | 只读 | 「事务跑完」返 0，其余 1；`-All` 总返 0 |
| `deploy-usb.ps1` | 把一份 EFI 放到 FAT32 U 盘，并建好 `AD104-UNLOCK` / `AD104-PROBE` 目录 | 写 U 盘 `\EFI\BOOT\BOOTX64.EFI`，旧的存成 `.bak-<时间戳>`，复制后按哈希复核 | 0 成功 / 非 0 拒绝或失败 |
| `install-esp.ps1` | 接管内置 ESP 的 `bootmgfw.efi` | **改启动盘**：`bootmgfw.efi` 换成解锁 EFI，原版逐字节改名保留为 `bootmgfw.orig.efi`；`-Rollback` 才还原并删 `AD104-ASSETS` / `AD104-UNLOCK` | 0 / 非 0；目录里有 `RUN*.TXT` 时没有 `-Force` 就拒 |
| `gen_profile.py` | 从 `AD104-PROBE` 的 schema-4 capture JSON 生成 `profile.c` 与 `capture-constants.json` | 写 `--out` 与 `--json-out` 两个文件 | Python 异常即失败 |
| `patch-target.py` | 把上游 `windows/ad104-msi` 复制一份、逐项改写数值 pin，产出 `windows/ad103-2705` | **`--out` 目录先删再重建**；`--dry-run` 只打 diff | 九个 `--xxx` 缺一个就报错退出 |

## 三个会动到硬件的

按危险程度递增：

1. `deploy-usb.ps1`：只碰 U 盘。不带参数时只列可移动卷；目标卷已有同哈希的
   `BOOTX64.EFI` 就跳过备份。**从不格式化、不分区、不碰内置 ESP**；非可移动卷没有
   `-Force` 直接拒。
2. `install-esp.ps1`：需要管理员。它改的是固件本来就要启动的那个文件，装上去等于把
   实验代码放进启动关键路径。这台机器上装了就卡在 boot 阶段，事故与恢复见
   [INCIDENT-esp-takeover.md](../docs/INCIDENT-esp-takeover.md)。脚本保留，路线不用。
3. `patch-target.py`：不碰硬件，但 `--out` 指向的目录会被删掉重建。默认写
   `windows/ad103-2705`，跑之前确认那个目录里没有你手改过的东西。

## 判读与验证怎么配

开机前看日志用 `classify-run.ps1`（不给参数时取 `H:\AD104-UNLOCK` 里最新那份，`-All`
把历史压成一行一份）；进 Windows 后验算力用 `verify-unlock.ps1`。

```powershell
tools\classify-run.ps1 -All
tools\verify-unlock.ps1
```

后者不带 `-RunNumber` 就是最新那份日志，而
`-RunNumber 5` 永远指着 `RUN0005`，那是没有 override 时跑成功的一次，拿它验证新一轮会把
旧结果当成新结果。

`verify-unlock.ps1` 的 2/4 与 3/4 需要 `mma_bench.exe` 和 `gemm_check.exe`，这两个不在本仓库
里，见 [bench/README.md](../bench/README.md)。
