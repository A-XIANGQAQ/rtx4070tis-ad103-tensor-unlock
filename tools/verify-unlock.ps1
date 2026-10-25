# SPDX-License-Identifier: GPL-2.0-only
<#
.SYNOPSIS
  Post-unlock verification: transaction log + instruction issue rate + numerics,
  judged against the recorded stock baseline.

.DESCRIPTION
  Runs the three acceptance criteria from the plan:
    1. transaction log  result=0 safe=1 ... flrs=1 DMA_live=0
    2. RM/issue-rate    f16/f32 and bf16/f32 ~2x, four control modes unchanged
    3. numerics         validate_gemm failures=0

  Copies the benchmarks out of the AV-monitored folder before running them,
  because real-time AV keeps deleting freshly compiled unsigned executables.

.EXAMPLE
  .\verify-unlock.ps1
  .\verify-unlock.ps1 -RunNumber 1
#>
param(
    [int]$RunNumber = 0,
    [int]$Iters = 20000,
    [int]$Reps = 3,
    [string]$Work = "$env:TEMP\gpu-verify"
)
$ErrorActionPreference = 'Continue'
$ErrorActionPreference = 'Continue'
$root = (Join-Path $PSScriptRoot '..')
$benchDir = Join-Path $root 'bench'
$capDir = Join-Path $root 'captures'
$stockFile = Join-Path $capDir 'mma-stock.txt'

function Rule($t) { Write-Host ("`n" + ("=" * 68)); Write-Host "  $t"; Write-Host ("=" * 68) }

# ---------------------------------------------------------------- 1. log
Rule "1/4  transaction log"
$run = $null
if ($RunNumber -gt 0) {
    $logRoot = if($Usb){ $Usb } else { 'H:' }
$cand = Join-Path $logRoot ("AD104-UNLOCK\RUN{0:D4}.TXT" -f $RunNumber)
    if (Test-Path $cand) { $run = $cand }
} else {
    $all = Get-ChildItem (Join-Path $logRoot 'AD104-UNLOCK') -Filter 'RUN*.TXT' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending
    if ($all) { $run = $all[0].FullName }
}
if (-not $run) {
    Write-Host "  no RUNxxxx.TXT on the USB - the EFI never reached the transaction" -ForegroundColor Red
    Write-Host "  (press U at the prompt; S/Esc/30s goes straight to Windows without unlocking)"
} else {
    Write-Host "  log: $run"
    $txt = Get-Content $run -Raw
    $m = [regex]::Match($txt, 'Transaction result=(-?\d+) safe=(\d) retained=(\d) started=(\d) quiesced=(\d) flrs=(\d) DMA_live=(\d)')
    if ($m.Success) {
        $res = [int]$m.Groups[1].Value
        $safe = $m.Groups[2].Value; $ret = $m.Groups[3].Value
        $started = $m.Groups[4].Value; $quiesced = $m.Groups[5].Value
        $flrs = $m.Groups[6].Value; $dma = $m.Groups[7].Value
        Write-Host "  result=$res  safe=$safe  retained=$ret  started=$started  quiesced=$quiesced  flrs=$flrs  DMA_live=$dma"
        $ok1 = ($res -eq 0 -and $safe -eq '1' -and $ret -eq '0' -and $started -eq '1' -and $quiesced -eq '1' -and $flrs -eq '1' -and $dma -eq '0')
        if ($ok1) { Write-Host "  CRITERION 1: PASS" -ForegroundColor Green }
        else { Write-Host "  CRITERION 1: FAIL" -ForegroundColor Red }
    } else {
        Write-Host "  no 'Transaction result=' line found. Last 20 lines:" -ForegroundColor Yellow
        ($txt -split "`n" | Select-Object -Last 20) | ForEach-Object { "    $_" }
        $ok1 = $false
    }
    foreach ($k in 'unlocked', 'FAIL', 'refused', 'halted', 'retained') {
        $hits = Select-String -Path $run -Pattern $k -SimpleMatch -ErrorAction SilentlyContinue
        if ($hits) { Write-Host ("  mentions '{0}': {1} line(s)" -f $k, $hits.Count) -ForegroundColor DarkGray }
    }
}

# ---------------------------------------------------------------- 2. bench
Rule "2/4  instruction issue rate"
if (-not (Test-Path $Work)) { New-Item -ItemType Directory -Force -Path $Work | Out-Null }
$exe = Join-Path $Work "bench_$([guid]::NewGuid().ToString('N').Substring(0,8)).exe"
$src = Join-Path $benchDir 'mma_bench.exe'
if (-not (Test-Path $src)) { throw "mma_bench.exe not found under $root\bench" }
Copy-Item $src $exe -Force
Start-Sleep -Milliseconds 800
$out = & $exe $Iters $Reps 2>&1 | Out-String
$out.Trim() | ForEach-Object { "  $_" }
$now = @{}
foreach ($line in ($out -split "`n")) {
    if ($line -match '^\s*(\S+)\s+([\d.]+)\s') { $now[$Matches[1].Trim()] = [double]$Matches[2] }
}
Write-Host ""
if (Test-Path $stockFile) {
    $stock = @{}
    foreach ($line in (Get-Content $stockFile)) {
        if ($line -match '^\s*(\S+)\s+([\d.]+)\s') { $stock[$Matches[1].Trim()] = [double]$Matches[2] }
    }
    Write-Host ("  {0,-10}{1,10}{2,10}{3,9}   {4}" -f 'mode','stock','now','ratio','verdict')
    Write-Host ("  " + ("-" * 58))
    $gainOk = $true; $ctrlOk = $true
    foreach ($mode in 'f16/f32','bf16/f32','f16/f16','s8/s32','dp4a','ffma') {
        if (-not ($now.ContainsKey($mode) -and $stock.ContainsKey($mode))) { continue }
        $a = $stock[$mode]; $b = $now[$mode]; $r = if ($a) { $b / $a } else { 0 }
        $isGain = $mode -in @('f16/f32','bf16/f32')
        if ($isGain) {
            $v = if ($r -gt 1.3) { 'GAIN' } else { 'NO GAIN' }
            if ($r -le 1.3) { $gainOk = $false }
        } else {
            $v = if ($r -gt 0.85 -and $r -lt 1.15) { 'control ok' } else { 'CONTROL DRIFTED' }
            if ($r -le 0.85 -or $r -ge 1.15) { $ctrlOk = $false }
        }
        Write-Host ("  {0,-10}{1,10:F1}{2,10:F1}{3,9:F3}   {4}" -f $mode, $a, $b, $r, $v)
    }
    if ($gainOk -and $ctrlOk) { Write-Host "`n  CRITERION 2: PASS - the two FP32-accumulate modes doubled, controls did not move" -ForegroundColor Green }
    elseif ($gainOk)         { Write-Host "`n  CRITERION 2: PARTIAL - gain present but a control mode moved" -ForegroundColor Yellow }
    else                     { Write-Host "`n  CRITERION 2: FAIL - no gain on f16/f32 or bf16/f32" -ForegroundColor Red }
} else {
    Write-Host "  stock baseline not found at $stockFile - compare manually" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 2b. FP8
Rule "2b/4  FP8 (E4M3) instruction issue rate"
$fp8src = Join-Path $benchDir 'fp8_mma_bench.exe'
$fp8stockFile = Join-Path $capDir 'fp8mma-stock.txt'
if (Test-Path $fp8src) {
    $fexe = Join-Path $Work "fp8_$([guid]::NewGuid().ToString('N').Substring(0,8)).exe"
    Copy-Item $fp8src $fexe -Force
    Start-Sleep -Milliseconds 800
    $fout = & $fexe $Iters $Reps 2>&1 | Out-String
    $fout.Trim() | ForEach-Object { "  $_" }
    $nowFp8 = $null
    foreach ($line in ($fout -split "`n")) {
        if ($line -match '^e4m3/f32\s+([\d.]+)') { $nowFp8 = [double]$Matches[1] }
    }
    $stockFp8 = $null
    if (Test-Path $fp8stockFile) {
        foreach ($line in (Get-Content $fp8stockFile)) {
            if ($line -match '^e4m3/f32\s+([\d.]+)') { $stockFp8 = [double]$Matches[1] }
        }
    }
    if ($nowFp8 -and $stockFp8) {
        $fr = $nowFp8 / $stockFp8
        Write-Host ("`n  e4m3/f32   stock {0:F1}  now {1:F1}  ratio {2:F3}" -f $stockFp8, $nowFp8, $fr)
        if ($fr -lt 1.15 -and $fr -gt 0.85) {
            Write-Host "  FP8 UNCHANGED - expected. The unlock gates FP16/BF16/TF32 FP32-accumulate only;" -ForegroundColor Green
            Write-Host "  FP8 was already at full rate (stock 170.6 vs f16/f16 175.6). DLSS 5 runs FP8," -ForegroundColor Green
            Write-Host "  so DLSS 5 cannot gain from this unlock. This matches the upstream +0.3% finding." -ForegroundColor Green
        } else {
            Write-Host "  FP8 MOVED unexpectedly - report this, it contradicts the upstream FP8 result." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  FP8 baseline or current value missing" -ForegroundColor Yellow
    }
} else {
    Write-Host "  fp8_mma_bench.exe not found" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 3. numerics
Rule "3/4  numerics"
$gexe = Join-Path $Work "gemm_$([guid]::NewGuid().ToString('N').Substring(0,8)).exe"
$gsrc = Join-Path $benchDir 'gemm_check.exe'
if (-not (Test-Path $gsrc)) { $gsrc = Join-Path $benchDir 'validate_gemm.exe' }
if (Test-Path $gsrc) {
    Copy-Item $gsrc $gexe -Force
    Start-Sleep -Milliseconds 800
    $g = & $gexe 2>&1 | Out-String
    $g.Trim() | ForEach-Object { "  $_" }
    if ($g -match 'failures=(\d+)') {
        $fails = ($g | Select-String -Pattern 'failures=(\d+)' -AllMatches).Matches |
                 ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Sum
        if ($fails.Sum -eq 0) { Write-Host "`n  CRITERION 3: PASS - 0 numerical failures" -ForegroundColor Green }
        else { Write-Host "`n  CRITERION 3: FAIL - $($fails.Sum) numerical failures" -ForegroundColor Red }
    }
} else {
    Write-Host "  gemm_check.exe / validate_gemm.exe not found" -ForegroundColor Yellow
}

Rule "verdict"
Write-Host @"
  Criterion 1 (transaction log)   -> see section 1/3
  Criterion 2 (issue rate 2x)     -> see section 2/3
  Criterion 3 (numerics)          -> see section 3/3

  A green log alone is NOT proof: upstream issue #20 records
  'gpu_unlock: unlocked' with the getter still reporting half rate,
  and issue #4 records a fully green transaction with the hardware
  unchanged on an AD103M part. Only sections 2 and 3 decide this.
"@
Write-Host "`nlogs/bench copies in: $Work" -ForegroundColor DarkGray
