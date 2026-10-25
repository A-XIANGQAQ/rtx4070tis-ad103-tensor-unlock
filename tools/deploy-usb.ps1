# SPDX-License-Identifier: GPL-2.0-only
<#
.SYNOPSIS
  Deploy the AD103/2705 diagnostic probe to a FAT32 USB stick.

.DESCRIPTION
  Copies AD103-PROBE.EFI to <USB>\EFI\BOOT\BOOTX64.EFI and creates the
  AD104-PROBE output directory. The probe refuses to run unless it was loaded
  from a USB device path, and it writes only to its own USB.
  This script never formats, partitions, or touches the internal ESP.

.PARAMETER Drive
  USB drive letter, e.g. 'F'. Omit to list removable volumes.

.PARAMETER Probe
  Path to the EFI. Defaults to build\AD103-PROBE.EFI next to this script's parent.

.EXAMPLE
  .\deploy-usb.ps1                 # list candidates
  .\deploy-usb.ps1 -Drive F        # deploy
#>
param(
    [string]$Drive,
    [string]$Probe = (Join-Path (Split-Path $PSScriptRoot -Parent) 'build\AD103-PROBE.EFI'),
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

if (-not $Drive) {
    Write-Host "Removable volumes:" -ForegroundColor Cyan
    $rem = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter }
    if (-not $rem) {
        Write-Host "  (none detected - insert a USB stick)" -ForegroundColor Yellow
        return
    }
    $rem | Select-Object DriveLetter, FileSystemLabel, FileSystem,
        @{n='SizeGB'; e={[math]::Round($_.Size/1GB,2)}} | Format-Table -AutoSize
    Write-Host "Re-run with -Drive <letter>" -ForegroundColor Cyan
    return
}

$Drive = $Drive.TrimEnd(':')
$vol = Get-Volume -DriveLetter $Drive -ErrorAction SilentlyContinue
if (-not $vol) { throw "No volume on drive ${Drive}:" }
if ($vol.DriveType -ne 'Removable' -and -not $Force) {
    throw "${Drive}: is $($vol.DriveType), not Removable. Refusing without -Force."
}
if ($vol.FileSystem -ne 'FAT32' -and $vol.FileSystem -ne 'FAT') {
    throw "${Drive}: is $($vol.FileSystem). The probe needs FAT32; it cannot write NTFS."
}
if (-not (Test-Path -LiteralPath $Probe)) {
    throw "Probe not found: $Probe  (build it first: build\compile.cmd)"
}

$root   = "${Drive}:\"
$efiDir = Join-Path $root 'EFI\BOOT'
$outDir = Join-Path $root 'AD104-PROBE'

Write-Host "Source probe : $Probe" -ForegroundColor Cyan
Write-Host "SHA256       : $((Get-FileHash -LiteralPath $Probe -Algorithm SHA256).Hash.ToLowerInvariant())"
Write-Host "Target volume: $root ($($vol.FileSystemLabel) / $($vol.FileSystem) / $([math]::Round($vol.Size/1GB,2)) GB)"

if (Test-Path -LiteralPath (Join-Path $efiDir 'BOOTX64.EFI')) {
    $bak = Join-Path $efiDir ("BOOTX64.EFI.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath (Join-Path $efiDir 'BOOTX64.EFI') -Destination $bak
    Write-Host "Existing BOOTX64.EFI preserved as $(Split-Path $bak -Leaf)" -ForegroundColor Yellow
}

New-Item -ItemType Directory -Force -Path $efiDir | Out-Null
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Copy-Item -LiteralPath $Probe -Destination (Join-Path $efiDir 'BOOTX64.EFI') -Force

$dst = Join-Path $efiDir 'BOOTX64.EFI'
$h1 = (Get-FileHash -LiteralPath $Probe  -Algorithm SHA256).Hash
$h2 = (Get-FileHash -LiteralPath $dst    -Algorithm SHA256).Hash
if ($h1 -ne $h2) { throw "Copy verification failed: hashes differ" }

Write-Host ""
Write-Host "Deployed OK" -ForegroundColor Green
Write-Host "  $dst"
Write-Host "  $outDir\  (capture lands here as CAP0000.JSON)"
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  1. Reboot, enter firmware setup (Del/F2 on ASUS)"
Write-Host "  2. Disable Secure Boot   (Security > Secure Boot > OS Type: Other OS)"
Write-Host "  3. Save & exit, open the boot menu (F8), pick the USB (UEFI: <label>)"
Write-Host "  4. The probe prints progress and halts; then power off, boot Windows"
Write-Host "  5. Copy $outDir\CAP0000.JSON back into results\"
Write-Host ""
Write-Host "The probe performs no GPU writes and never enables bus mastering." -ForegroundColor DarkGray
