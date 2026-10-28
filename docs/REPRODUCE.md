# 复现：命令、脚本行为、换卡流程

[README](../README.md) 的「开工顺序」只有步骤和指路，这一份放完整命令与每个脚本的边界。

## 两条硬约束

1. **firmware asset 必须从你自己的 VBIOS 生成。** `booter_load_ad102.bin`、
   `v67-…-four-plm.bin`、GSP 镜像都是从 VBIOS 里解出来的，不同 VBIOS 的 FWSEC
   几何、Booter 签名选择、GSP 载荷都不同。别人的 asset 不能拿来用，也不该刷。
2. **`SS0/SS1` 的目标值是不是 `0x88888888`/`0x8`，要看你自己的卡。** 本卡 `SS1` 冷启动
   恒为 `0x1`、`SS0` 每次冷启动都是新的随机值（见 [EVIDENCE.md](EVIDENCE.md)，
   四个 `RUN` 全不同）；issue #39 那张 Gigabyte 卡报的是 `0x25605026`/`4`，字段布局未必一致。
   `0x88888888` 的含义是「八个 4-bit 字段全填 8」（`vendor/unlock_610.c:28-31`），
   字段划分变了就得重新算目标值。

代码改动在一个 fork 分支上，基于上游 `4e7fefc` 一个 commit：

```
https://github.com/A-XIANGQAQ/gpu-unlock-ada/tree/ad103-2705/windows/ad103-2705
```

## 同型号照抄

分支里已经就是这个卡的移植结果，不需要再跑移植工具：

```powershell
git clone https://github.com/JustAResearcher/gpu-unlock-ada
cd gpu-unlock-ada
git fetch https://github.com/A-XIANGQAQ/gpu-unlock-ada ad103-2705
git checkout FETCH_HEAD
cd windows\ad103-2705

# 1. 写本机的 ESP 标识（这个文件故意不提交；格式见 boot_profile.example.h）
#    本卡：partition size 614400 sectors，自己的 GPT partition GUID
#    照着 example 建 local\boot_profile.h

# 2. 编译（gcc 编核心库 → MSVC link 出 EFI）
.\Build-Experimental.ps1
#    产物 build\AD104-EXPERIMENTAL.EFI，末尾会打印 sha256 与 verify 结果
#    MSVC 找不到就显式给：.\Build-Experimental.ps1 -VcVars64 'C:\...\vcvars64.bat'

# 3. 部署到 FAT32 U 盘（这一步用的是本仓库的脚本，不是分支里的）
cd <本仓库>
tools\deploy-usb.ps1 -Drive H -Profile unlock `
    -efi <gpu-unlock-ada>\windows\ad103-2705\build\AD104-EXPERIMENTAL.EFI

# 4. 开机 F8 选 U 盘，按 U
```

`Build-Experimental.ps1` 的产物哈希是确定的：同样的源码编出同样的文件，
`rebuild-efi.ps1` 靠的就是这一点。`Build.ps1 -RunTests` 还要 `-Prom` 与 `-Assets`
两个参数才跑 host 测试。

`deploy-usb.ps1` 不带参数时只列出可移动卷；`-Profile` 决定建哪个输出目录
（`unlock` → `AD104-UNLOCK`，`probe` → `AD104-PROBE`），不给 `-efi` 就取默认路径。
目标卷上已有 `BOOTX64.EFI` 且与要部署的这份哈希相同，就跳过备份、只打一行说明；
不同才存成 `BOOTX64.EFI.bak-<timestamp>`。它不格式化、不分区、不碰内置 ESP，
非可移动卷没有 `-Force` 直接拒。

## 换一张不同型号的卡

才需要 `tools/patch-target.py`。它把 `windows/ad104-msi` 整棵树复制一份，逐项改写数值型
pin（device id / subsystem / bus / BAR0 / device memory / ESP 几何 / bootmgr 尺寸与哈希 /
PROM 哈希），输出到 `windows/ad103-2705` 并打印 unified diff。

`--constants` 那份由 `gen_profile.py` 从探针抓的 JSON 生成，`profile.c` 也要落到
`build\profile.ad103.c`（`patch-target.py` 从那里取）。其余参数里 ESP 几何要用
`Get-Partition` 自己查，bootmgr 尺寸与哈希对
`C:\Windows\Boot\EFI\Microsoft\Boot\bootmgfw.efi` 算：

```powershell
python tools\gen_profile.py <capture>.json `
    --out build\profile.ad103.c --json-out build\capture-constants.json

python tools\patch-target.py `
    --constants build\capture-constants.json `
    --esp-guid '{0x45c441a7,0xd76a,0x4036,{0xab,0x75,0xec,0x51,0x0f,0xcc,0xa8,0x1e}}' `
    --bootmgr-size 3086680 `
    --bootmgr-sha 2d60a2203865122dad22772136b3d905167d9dcf926d602bb5f48b3b6668abec `
    --bar0-base 0xFB000000 --config-0x78 0x0012b410 `
    --esp-partition 1 --esp-lba 2048 --esp-sectors 614400 `
    --dry-run
```

九个 `--xxx` 参数缺一个就报错退出（`--dry-run` 只打 diff 不写盘，`--keep-existing`
不重拷树）。上面这组值就是本卡的，换卡要换掉；`--out` 默认写 `windows/ad103-2705`，
会先删掉再从头拷。

它只覆盖数值型 pin，[PITFALLS.md](PITFALLS.md) 里那些结构性改动（双显示节点、双 xHCI、
级联断开、启动失败不再 halt、身份缓存、关机可见、关日志不置 fault）得手改，或者参照分支
里已有的写法。`profile.c` 是生成文件，重新生成前读 [PITFALLS #16](PITFALLS.md)。

## 从某个提交重建

想知道手上这份 EFI 是哪次提交编出来的，或者要把某次提交重编一遍，用
`windows/ad103-2705/rebuild-efi.ps1`。每次构建都可复现，哈希稳定：

```powershell
# 从任意提交重建并打印哈希（内部开一个临时 worktree，用完删掉）
# 注意 local/boot_profile.h 被 git 忽略，脚本会从主检出复制过去
windows\ad103-2705\rebuild-efi.ps1 -Commit cb3691b
# 列出可以选的提交
windows\ad103-2705\rebuild-efi.ps1 -List
```

每次构建的产物哈希和「有没有上过机」都在 [WHERE-IT-STOPPED.md](WHERE-IT-STOPPED.md)，
十七行，含几个提交共用同一份二进制的合并行。

## 验证

benchmark 的 `.exe` 不进仓库，需要本机编；四个探针各自测什么、哪两个在上游，见
[`bench/README.md`](../bench/README.md)。

```powershell
bench\build.cmd all         # 四个探针，需要 CUDA + MSVC
bench\build.cmd cublas      # cuBLAS GEMM，N / iters / reps
bench\build.cmd fp8mma      # FP8 e4m3 发射率，mma.m16n8k32
bench\build.cmd fp8gemm     # FP8 e4m3 GEMM，走 cuBLASLt
bench\build.cmd f16acc      # 为什么 float alpha 会毁掉 16F 累加的 GEMM

# mma_bench / gemm_check 的源码在上游 diagnostics\bench\ 下，或用 -BenchDir 指到你现有的目录

# 判据：比值，不看绝对值。不带 -RunNumber 就是最新那份日志
tools\verify-unlock.ps1
tools\verify-unlock.ps1 -BenchDir 'G:\path\to\your\exes' -GemmCheck 'G:\path\to\gemm_check.exe'
```

`build.cmd` 自己找 `vcvars64.bat`：先看 `%VCVARS64%`，没有就用 `vswhere.exe` 问 Visual
Studio 装在哪，再退到两个固定路径，都找不到才报 `Could not find vcvars64.bat`。编译输出
写进 `%TEMP%\build-<目标名>.log` 后过滤掉 MSVC 的 C4819（CUDA 头文件在 936 代码页下的
无关警告），成功打 `BUILD-OK`，失败打 `BUILD-FAILED see …` 并返回 1。它在编译前会先删掉
旧的 `.exe`，所以看到 `BUILD-OK` 时那个 exe 一定是这次编出来的。`build-cublas.cmd` 与
`build-fp8mma.cmd` 是薄包装，内容就是 `build.cmd cublas` / `build.cmd fp8mma`。

`verify-unlock.ps1` 先读 `nvidia-smi` 的频率/功耗/降频原因，会明确告诉你这次采样的绝对值
能不能用；然后算 `f16/f32 ÷ f16/f16` 这个「活比值」（stock ~0.50，解锁 1.00），判定就看它。
日志里没有 `Transaction result=` 时它会多说一句 `why:`，按日志自己的措辞分出五种情况：
旧版 EFI（打 `wantSS1=`，没有 blank 闸门）、有闸门但仍拒（打 `stockSS1=`，选通器落到第三种
状态）、19 个 pin 有一个不对、按了跳过键、以及认不出来的。对 `results/mma-baseline.txt` 的
逐模式比值只作为表格上下文打印；那批基线是在 285 W 下采的，本机现在跑 320 W，跨日跨功耗的
绝对值不可比；控制项一旦漂过 15%，脚本会单独提示「这是频率，不是门」。

最后有一节 `overall` 汇总四项并通过 `exit` 返回：0 = 四项全过，1 = 有不过的。可以直接拿它
当 CI 判据：

```powershell
tools\verify-unlock.ps1; "exit=$LASTEXITCODE"
```

`-RunNumber` 只用来复查历史日志：`-RunNumber 5` 永远指着 `RUN0005`，那是没有 override 时
跑成功的一次。拿它验证新一轮会把旧结果当成新结果，所以别带这个参数。
