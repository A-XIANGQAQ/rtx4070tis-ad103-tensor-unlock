#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Install the AD103 unlock EFI onto the internal ESP by taking over the file the
  firmware already boots, so no BCD or NVRAM boot entry has to be edited.

.DESCRIPTION
  How it works:

    firmware -> \EFI\Microsoft\Boot\bootmgfw.efi   (now the unlock EFI)
              -> unlock, then StartImage()
              -> \EFI\Microsoft\Boot\bootmgfw.orig.efi  (the real boot manager)
              -> Windows

  The original file is preserved byte-for-byte as bootmgfw.orig.efi. AUTO.TXT in
  \AD104-UNLOCK\ makes the EFI unlock without the U prompt.

  Because the firmware target never changes, Secure Boot off is the only
  requirement, and nothing in the boot configuration is touched. A Windows
  update that rewrites bootmgfw.efi simply restores the stock file, which
  disables the unlock but cannot break the boot.

.PARAMETER Rollback
  Restore bootmgfw.orig.efi over bootmgfw.efi and delete the installed files.

.EXAMPLE
  .\install-esp.ps1
  .\install-esp.ps1 -Rollback
#>
param(
    [switch]$Rollback,
    [switch]$Force,
    [string]$EfiSource = (Join-Path $PSScriptRoot '..\build\AD104-EXPERIMENTAL.EFI'),
    [string]$AssetDir  = "$env:USERPROFILE\.cache\gpu-unlock\assets",
    [string]$EspGuid   = 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b',
    [string]$Mount     = 'W:'
)
$ErrorActionPreference = 'Stop'

function Say($m){ Write-Host "[esp] $m" }
function Warn($m){ Write-Host "[esp] $m" -ForegroundColor Yellow }
function Fail($m){ Write-Host "[esp] ERROR: $m" -ForegroundColor Red; exit 1 }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if(-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)){ Fail 'run this in an elevated PowerShell' }

# Boot manager the unlock EFI must chain to. The EFI logs the real value at run
# time, so this is only used to warn about an unexpected starting state.
$BOOTMGR_LEN  = 3086680
$BOOTMGR_HASH = '2d60a2203865122dad22772136b3d905167d9dcf926d602bb5f48b3b6668abec'

$BM_DIR   = 'EFI\Microsoft\Boot'
$BM_MAIN  = "$Mount\$BM_DIR\bootmgfw.efi"
$BM_ORIG  = "$Mount\$BM_DIR\bootmgfw.orig.efi"
$ASSETS   = "$Mount\AD104-ASSETS"
$LOGDIR   = "$Mount\AD104-UNLOCK"
$stateFile = Join-Path $PSScriptRoot '..\results\esp-install-state.json'

function Get-EspPartition {
    $p = Get-Partition | Where-Object { $_.GptType -eq "{$EspGuid}" -and $_.Size -gt 100MB } |
         Sort-Object Size | Select-Object -First 1
    if(-not $p){ Fail 'no EFI System Partition found' }
    $p
}
function Mount-Esp($part){
    if(Test-Path "$Mount\EFI\"){ Say "$Mount already mounted"; return }
    & mountvol $Mount /S 2>&1 | Out-Null
    if(-not (Test-Path "$Mount\EFI\")){ Fail "mountvol $Mount /S failed" }
    Say "ESP mounted at $Mount"
}
function Dismount-Esp { & mountvol $Mount /D 2>&1 | Out-Null; Say "ESP dismounted" }

# ------------------------------------------------------------------ rollback
if($Rollback){
    Say 'rollback requested'
    Mount-Esp (Get-EspPartition)
    if(-not (Test-Path $BM_ORIG)){ Fail "no $BM_ORIG to restore" }
    Copy-Item $BM_ORIG $BM_MAIN -Force
    $h = (Get-FileHash $BM_MAIN -Algorithm SHA256).Hash.ToLowerInvariant()
    $l = (Get-Item $BM_MAIN).Length
    Say "restored bootmgfw.efi: $l bytes  sha256: $h"
    if($l -ne $BOOTMGR_LEN -or $h -ne $BOOTMGR_HASH){
        Warn 'restored file does not match the expected stock bootmgr; verify before rebooting'
    } else {
        Say 'stock boot manager verified'
    }
    foreach($d in @($ASSETS,$LOGDIR)){
        if(Test-Path $d){ Remove-Item $d -Recurse -Force; Say "removed $d" }
    }
    Dismount-Esp
    if(Test-Path $stateFile){ Remove-Item $stateFile -Force }
    Say 'rollback complete: firmware boots the stock Windows Boot Manager again'
    exit 0
}

# ------------------------------------------------------------------ preflight
if(-not (Test-Path $EfiSource)){ Fail "EFI not found: $EfiSource" }
$efiLen  = (Get-Item $EfiSource).Length
$efiHash = (Get-FileHash $EfiSource -Algorithm SHA256).Hash
Say "EFI : $EfiSource"
Say "size: $efiLen  sha256: $efiHash"
if($efiLen -lt 90000 -or $efiLen -gt 200000){ Warn "unexpected EFI size $efiLen" }

$need = @('booter_load_ad102.bin','v67-ad102-610.43.03-four-plm.bin','gsp_ga10x.bin',
          'gsp_boot_ad102.bin','gsp_boot_desc_ad102.bin')
foreach($n in $need){ if(-not (Test-Path (Join-Path $AssetDir $n))){ Fail "asset missing: $n" } }

$part = Get-EspPartition
Say "ESP : disk $($part.DiskNumber) partition $($part.PartitionNumber)  $([math]::Round($part.Size/1MB,0)) MB"

Mount-Esp $part

# ---------------------------------------------------------------- sanity
if(-not (Test-Path $BM_MAIN)){ Fail "$BM_MAIN not found - this does not look like a Windows ESP" }
$curLen  = (Get-Item $BM_MAIN).Length
$curHash = (Get-FileHash $BM_MAIN -Algorithm SHA256).Hash.ToLowerInvariant()
Say "current bootmgfw.efi: $curLen bytes  sha256: $curHash"

if(Test-Path $BM_ORIG){
    $origLen  = (Get-Item $BM_ORIG).Length
    $origHash = (Get-FileHash $BM_ORIG -Algorithm SHA256).Hash.ToLowerInvariant()
    Say "already installed: bootmgfw.orig.efi present ($origLen bytes)"
    if($curLen -eq $BOOTMGR_LEN -and $curHash -eq $BOOTMGR_HASH){
        Warn 'bootmgfw.efi is the STOCK file again (likely a Windows update replaced it)'
        Warn 'proceeding will re-take over; the preserved .orig stays untouched'
    }
} else {
    if($curLen -ne $BOOTMGR_LEN -or $curHash -ne $BOOTMGR_HASH){
        Warn "current bootmgfw is NOT the expected stock file ($curLen / $curHash)"
        if(-not $Force){ Fail 'refusing to overwrite an unrecognised boot manager; rerun with -Force if you are sure' }
    }
    Copy-Item $BM_MAIN $BM_ORIG -Force
    $vLen  = (Get-Item $BM_ORIG).Length
    $vHash = (Get-FileHash $BM_ORIG -Algorithm SHA256).Hash.ToLowerInvariant()
    if($vLen -ne $curLen -or $vHash -ne $curHash){ Fail 'backup verification failed' }
    Say "backed up bootmgfw.efi -> bootmgfw.orig.efi ($vLen bytes, verified)"
}

# ---------------------------------------------------------------- install
Copy-Item $EfiSource $BM_MAIN -Force
$iLen  = (Get-Item $BM_MAIN).Length
$iHash = (Get-FileHash $BM_MAIN -Algorithm SHA256).Hash.ToLowerInvariant()
if($iHash -ne $efiHash){ Fail 'installed EFI does not match source' }
Say "installed unlock EFI -> bootmgfw.efi ($iLen bytes, verified)"

New-Item -ItemType Directory -Force -Path $ASSETS | Out-Null
foreach($n in $need){ Copy-Item (Join-Path $AssetDir $n) (Join-Path $ASSETS $n) -Force }
Say "copied $($need.Count) assets -> $ASSETS"

New-Item -ItemType Directory -Force -Path $LOGDIR | Out-Null
Set-Content -Path (Join-Path $LOGDIR 'AUTO.TXT') -Value "unattended unlock`n" -Encoding ascii -NoNewline
Say "created AUTO.TXT (unattended mode)"

Dismount-Esp

@{ efi_sha256 = $efiHash; efi_size = $efiLen; stock_len = $curLen; stock_sha256 = $curHash;
   installed_at = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content $stateFile -Encoding utf8
Say "state saved -> $stateFile"

Write-Host ""
Write-Host "Boot path now:" -ForegroundColor Green
Write-Host "  firmware -> bootmgfw.efi (unlock, AUTO) -> bootmgfw.orig.efi -> Windows" -ForegroundColor Green
Write-Host ""
Write-Host "Next reboot will unlock without any prompt." -ForegroundColor Green
Write-Host "Log: W:\AD104-UNLOCK\RUNxxxx.TXT (mount the ESP to read it from Windows)" -ForegroundColor DarkGray
Write-Host "Undo: .\install-esp.ps1 -Rollback" -ForegroundColor Green
Write-Host "Rescue: boot the USB stick with the manual U prompt; it uses the same EFI." -ForegroundColor DarkGray
