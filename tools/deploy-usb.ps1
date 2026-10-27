# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
  Copy one EFI onto a FAT32 USB stick so the firmware can boot it.

.DESCRIPTION
  Copies the given EFI to <USB>\EFI\BOOT\BOOTX64.EFI, after moving any existing
  BOOTX64.EFI aside as BOOTX64.EFI.bak-<timestamp>, and verifies the copy by hash.
  An EFI is just a file here; this script has no idea which one it is carrying.

  Two EFIs get deployed with it:
    * the diagnostic probe (build\AD103-PROBE.EFI) -- read-only capture, needs an
      AD104-PROBE directory to write its JSON into;
    * the unlock EFI (build\AD104-EXPERIMENTAL.EFI) -- needs an AD104-UNLOCK
      directory for its RUNxxxx.TXT log. Without that directory it prints an
      on-screen refusal, so it is created here as well.

  This script never formats, partitions, or touches the internal ESP. It refuses
  to write to anything that is not a removable FAT32 volume unless -Force is given,
  because the easy way to ruin this experiment is to overwrite the wrong disk.

.PARAMETER Drive
  USB drive letter, e.g. 'H'. Omit to list removable volumes.

.PARAMETER efi
  Path to the EFI to deploy. Aliased as -Probe, which is what this parameter was
  called when the diagnostic probe was the only thing being deployed.

.PARAMETER Profile
  Which output directory to create: 'probe' makes AD104-PROBE, 'unlock' makes
  AD104-UNLOCK. 'auto' infers it from the file name.

.PARAMETER Force
  Allow a non-removable volume. Still never formats.

.EXAMPLE
  .\deploy-usb.ps1                       # list candidates
  .\deploy-usb.ps1 -Drive H              # deploy the probe
  .\deploy-usb.ps1 -Drive H -efi ..\..\gpu-unlock-ada\windows\ad103-2705\build\AD104-EXPERIMENTAL.EFI
#>
param(
    [string]$Drive,
    [Alias('Probe')]
    [string]$efi,
    [ValidateSet('probe', 'unlock', 'auto')]
    [string]$Profile = 'auto',
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

# Only the unlock EFI has a default path, and it is relative to this repo. The
# diagnostic probe is built outside the repo, so it always has to be named.
if (-not $efi) {
    if ($Profile -eq 'probe') {
        throw "The probe EFI has no default path here; pass -efi <path to AD103-PROBE.EFI>."
    }
    $efi = Join-Path (Split-Path $PSScriptRoot -Parent) 'build\AD104-EXPERIMENTAL.EFI'
}
if ($Profile -eq 'auto') {
    $Profile = if ((Split-Path $efi -Leaf) -match 'PROBE') { 'probe' } else { 'unlock' }
}

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
if (-not (Test-Path -LiteralPath $efi)) {
    throw "EFI not found: $efi"
}

$root   = "${Drive}:\"
$efiDir = Join-Path $root 'EFI\BOOT'
$outDir = Join-Path $root $(if ($Profile -eq 'unlock') { 'AD104-UNLOCK' } else { 'AD104-PROBE' })

Write-Host "Source EFI   : $efi" -ForegroundColor Cyan
Write-Host "Profile      : $Profile  (output dir $(Split-Path $outDir -Leaf))"
Write-Host "Size / SHA256: $((Get-Item -LiteralPath $efi).Length) B / $((Get-FileHash -LiteralPath $efi -Algorithm SHA256).Hash.ToLowerInvariant())"
Write-Host "Target volume: $root ($($vol.FileSystemLabel) / $($vol.FileSystem) / $([math]::Round($vol.Size/1GB,2)) GB)"

# Keep the previous EFI, unless it is byte-identical to the one being deployed --
# deploying the same build twice used to leave a 100 KB duplicate on the stick every
# time, and those add up on a FAT32 volume where nothing is ever cleaned up.
$dstEfi = Join-Path $efiDir 'BOOTX64.EFI'
if (Test-Path -LiteralPath $dstEfi) {
    $oldHash = (Get-FileHash -LiteralPath $dstEfi -Algorithm SHA256).Hash
    $newHash = (Get-FileHash -LiteralPath $efi    -Algorithm SHA256).Hash
    if ($oldHash -eq $newHash) {
        Write-Host "Existing BOOTX64.EFI is already this build; no backup made." -ForegroundColor DarkGray
    } else {
        $bak = Join-Path $efiDir ("BOOTX64.EFI.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Copy-Item -LiteralPath $dstEfi -Destination $bak
        Write-Host "Previous BOOTX64.EFI ($($oldHash.Substring(0,16).ToLowerInvariant())) kept as $(Split-Path $bak -Leaf)" -ForegroundColor Yellow
    }
}

New-Item -ItemType Directory -Force -Path $efiDir | Out-Null
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Copy-Item -LiteralPath $efi -Destination (Join-Path $efiDir 'BOOTX64.EFI') -Force

$dst = Join-Path $efiDir 'BOOTX64.EFI'
$h1 = (Get-FileHash -LiteralPath $efi  -Algorithm SHA256).Hash
$h2 = (Get-FileHash -LiteralPath $dst    -Algorithm SHA256).Hash
if ($h1 -ne $h2) { throw "Copy verification failed: hashes differ" }

Write-Host ""
Write-Host "Deployed OK" -ForegroundColor Green
Write-Host "  $dst"
Write-Host "  $outDir\  $(if ($Profile -eq 'unlock') { '(the RUNxxxx.TXT log lands here)' } else { '(capture lands here as CAP000N.JSON)' })"
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  1. Reboot, open the boot menu (F8 on ASUS), pick the USB (UEFI: <label>)"
Write-Host "  2. Secure Boot has to be off; this machine already is"
if ($Profile -eq 'unlock') {
    Write-Host "  3. At the prompt press U for a single run; it then hands off to Windows"
    Write-Host "  4. Afterwards read $outDir\RUNxxxx.TXT, then: tools\classify-run.ps1 -All"
    Write-Host ""
    Write-Host "One shot per boot. SS0/SS1 are volatile, so a failed run leaves the card" -ForegroundColor DarkGray
    Write-Host "stock and the next attempt needs a fresh power-on." -ForegroundColor DarkGray
} else {
    Write-Host "  3. The probe prints progress and halts; then power off, boot Windows"
    Write-Host "  4. Copy $outDir\CAP000N.JSON back into results\"
    Write-Host ""
    Write-Host "The probe performs no GPU writes and never enables bus mastering." -ForegroundColor DarkGray
}
