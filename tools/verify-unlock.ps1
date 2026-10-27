# SPDX-License-Identifier: GPL-2.0-only
<#
.SYNOPSIS
  Post-unlock verification: transaction log + instruction issue rate + numerics,
  judged against the recorded stock baseline.

.DESCRIPTION
  Four checks:
    1.  transaction log   result=0 safe=1 ... flrs=1 DMA_live=0
    2.  issue rate        f16/f32 / f16/f16: stock ~0.50, unlocked ~1.00
    2b. FP8               e4m3/f32 ~1.9x (this DOES move -- see the note in section 2b)
    3.  numerics          gemm_check failures=0

  Ratio is the criterion, never the absolute number. A downclocked card reports
  f16/f32 ~= 88 TF/s, which is exactly the stock value; judging on absolutes
  will call a working unlock "not applied".

  The per-mode table against results/mma-baseline.txt is context, not the verdict.
  Every mode on this card shares one SM clock, so a run that is 5% slow moves all
  six columns at once. The recorded baseline was also collected at power.limit
  285 W and this machine now runs a 320 W override, so cross-day absolutes are
  not comparable.

  The last section, "overall", exits 0 when all four pass and 1 otherwise, so the
  script is usable as a CI gate instead of something a human has to read.

.PARAMETER LogRoot
  Drive letter holding AD104-UNLOCK\RUNxxxx.TXT (default H:, the USB stick).

.PARAMETER GpuIndex
  nvidia-smi GPU index, for the clock / throttle readout.

.EXAMPLE
  .\verify-unlock.ps1
  .\verify-unlock.ps1 -RunNumber 5
  .\verify-unlock.ps1 -LogRoot W: -RunNumber 1
#>
param(
    [int]$RunNumber = 0,
    [int]$Iters = 20000,
    [int]$Reps = 5,
    [string]$LogRoot = 'H:',
    [int]$GpuIndex = 0,
    [string]$Work = "$env:TEMP\gpu-verify",
    [string]$BenchDir,
    [string]$GemmCheck
)
$ErrorActionPreference = 'Continue'
$root   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$resDir = Join-Path $root 'results'
$mmaStock = Join-Path $resDir 'mma-baseline.txt'
$fp8Stock = Join-Path $resDir 'fp8-baseline.txt'

function Rule($t) { Write-Host ("`n" + ("=" * 68)); Write-Host "  $t"; Write-Host ("=" * 68) }

# The .exe files are deliberately not in this repo (unsigned binaries in git are a
# nuisance). Look in the obvious places and say where the found one came from.
function Find-Bench([string]$name) {
    $roots = @($BenchDir, (Join-Path $root 'bench'), 'G:\workspace\rtx2705\bench') |
             Where-Object { $_ } | Select-Object -Unique
    foreach ($d in $roots) {
        $p = Join-Path $d $name
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    return $null
}
$probe = Find-Bench 'mma_bench.exe'
if ($probe) { $benchDir = Split-Path $probe -Parent }
else        { $benchDir = if ($BenchDir) { $BenchDir } else { Join-Path $root 'bench' } }
Write-Host "`nbench dir: $benchDir" -ForegroundColor DarkGray

function Copy-And-Run($src, [string[]]$argv) {
    if (-not (Test-Path $src)) { return $null }
    if (-not (Test-Path $Work)) { New-Item -ItemType Directory -Force -Path $Work | Out-Null }
    # AV keeps deleting freshly compiled unsigned exes; run from a copy.
    $exe = Join-Path $Work ("$([IO.Path]::GetFileNameWithoutExtension($src))_" +
                            "$([guid]::NewGuid().ToString('N').Substring(0,8)).exe")
    Copy-Item $src $exe -Force
    Start-Sleep -Milliseconds 800
    return (& $exe @argv 2>&1 | Out-String)
}

function Parse-Bench($text) {
    $h = @{}
    if (-not $text) { return $h }
    foreach ($line in ($text -split "`n")) {
        if ($line -match '^\s*(\S+)\s+([\d.]+)\s') { $h[$Matches[1].Trim()] = [double]$Matches[2] }
    }
    return $h
}

# ---------------------------------------------------------------- 0. clocks
Rule "0/4  clock state (decides whether the numbers are usable at all)"
$throttled = $false
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smi) {
    $q = & nvidia-smi --query-gpu=clocks.sm,clocks.max.sm,power.draw,power.limit,clocks_throttle_reasons.active `
                      --format=csv,noheader -i $GpuIndex 2>&1 | Out-String
    Write-Host ("  " + $q.Trim().Replace("`n", "`n  "))
    if ($q -match '0x0*[1-9a-fA-F][0-9a-fA-F]*' -and $q -notmatch ', 0x0\b') {
        # active != 0 means at least one reason is asserted
        $reason = [regex]::Match($q, '(0x[0-9a-fA-F]+)\s*$').Groups[1].Value
        if ($reason -and $reason -ne '0x0' -and $reason -ne '0x0000000000000001') {
            $throttled = $true
        }
    }
    if ($throttled) {
        Write-Host "  WARNING: throttle reasons assert something other than gpu_idle." -ForegroundColor Yellow
        Write-Host "  Absolute TF/s will be depressed. Ratio is still valid; absolutes are not." -ForegroundColor Yellow
    }
} else {
    Write-Host "  nvidia-smi not on PATH - skipping the clock readout" -ForegroundColor DarkGray
}
$busy = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match '^(ffmpeg|python|pythonw|ollama|lmstudio|comfyui|java|chrome)$' }
if ($busy) {
    Write-Host ("  WARNING: possibly GPU-busy processes: " + (($busy.ProcessName | Sort-Object -Unique) -join ', ')) -ForegroundColor Yellow
    Write-Host "  See docs/PITFALLS.md #11 -- a game holding the GPU once made f16/f32 collapse to 2.0." -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 1. log
Rule "1/4  transaction log"
$run = $null
$logDir = Join-Path $LogRoot 'AD104-UNLOCK'
if ($RunNumber -gt 0) {
    $cand = Join-Path $logDir ("RUN{0:D4}.TXT" -f $RunNumber)
    if (Test-Path $cand) { $run = $cand }
} else {
    $all = Get-ChildItem $logDir -Filter 'RUN*.TXT' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending
    if ($all) { $run = $all[0].FullName }
}
$ok1 = $false
if (-not $run) {
    Write-Host "  no RUNxxxx.TXT under $logDir" -ForegroundColor Red
    Write-Host "  Either the EFI never reached the transaction, or you booted without pressing U."
} else {
    Write-Host "  log: $run  ($((Get-Item $run).Length) B, $((Get-Item $run).LastWriteTime))"
    $txt = Get-Content $run -Raw
    $m = [regex]::Match($txt, 'Transaction result=(-?\d+) safe=(\d) retained=(\d) started=(\d) quiesced=(\d) flrs=(\d) DMA_live=(\d)')
    if ($m.Success) {
        $res = [int]$m.Groups[1].Value
        $safe = $m.Groups[2].Value; $ret = $m.Groups[3].Value
        $started = $m.Groups[4].Value; $quiesced = $m.Groups[5].Value
        $flrs = $m.Groups[6].Value; $dma = $m.Groups[7].Value
        Write-Host "  result=$res  safe=$safe  retained=$ret  started=$started  quiesced=$quiesced  flrs=$flrs  DMA_live=$dma"
        $ok1 = ($res -eq 0 -and $safe -eq '1' -and $ret -eq '0' -and $started -eq '1' -and
                $quiesced -eq '1' -and $flrs -eq '1' -and $dma -eq '0')
        if ($ok1) { Write-Host "  CRITERION 1: PASS" -ForegroundColor Green }
        else      { Write-Host "  CRITERION 1: FAIL" -ForegroundColor Red }
    } else {
        Write-Host "  no 'Transaction result=' line. Last 20 lines:" -ForegroundColor Yellow
        ($txt -split "`n" | Select-Object -Last 20) | ForEach-Object { "    $_" }
        Write-Host "  CRITERION 1: FAIL - the transaction never reported a result" -ForegroundColor Red
    }
    # The three historical failure shapes -- any of these means the run did not hand off.
    foreach ($k in 'graph missing', 'finish incomplete', 'GPU finish after close', 'STOP:') {
        $hits = Select-String -Path $run -Pattern $k -SimpleMatch -ErrorAction SilentlyContinue
        if ($hits) { Write-Host ("  mentions '{0}': {1} line(s)" -f $k, $hits.Count) -ForegroundColor Red }
    }
    foreach ($k in 'handoff check passed', 'CacheGpuChildren') {
        $hits = Select-String -Path $run -Pattern $k -SimpleMatch -ErrorAction SilentlyContinue
        if ($hits) { Write-Host ("  mentions '{0}': yes" -f $k) -ForegroundColor DarkGray }
    }
}

# ---------------------------------------------------------------- 2. bench
Rule "2/4  instruction issue rate (criterion = ratio, not absolute)"
$out = Copy-And-Run (Find-Bench 'mma_bench.exe') @($Iters, $Reps)
if (-not $out) {
    Write-Host "  mma_bench.exe not found under $benchDir" -ForegroundColor Red
    $ok2 = $false
} else {
    $out.Trim() | ForEach-Object { "  $_" }
    $now = Parse-Bench $out
    if (Test-Path $mmaStock) {
        $stock = Parse-Bench (Get-Content $mmaStock -Raw)
        Write-Host ""
        Write-Host ("  {0,-10}{1,10}{2,10}{3,9}   {4}" -f 'mode', 'stock', 'now', 'ratio', 'verdict')
        Write-Host ("  " + ("-" * 58))
        $ctrlOk = $true
        foreach ($mode in 'f16/f32', 'bf16/f32', 'f16/f16', 's8/s32', 'dp4a', 'ffma') {
            if (-not ($now.ContainsKey($mode) -and $stock.ContainsKey($mode))) { continue }
            $a = $stock[$mode]; $b = $now[$mode]; $r = if ($a) { $b / $a } else { 0 }
            if ($mode -in @('f16/f32', 'bf16/f32')) {
                $v = if ($r -gt 1.3) { 'GAIN' } else { 'no gain' }
            } else {
                $v = if ($r -gt 0.85 -and $r -lt 1.15) { 'control ok' } else { 'CONTROL DRIFTED' }
                if ($r -le 0.85 -or $r -ge 1.15) { $ctrlOk = $false }
            }
            Write-Host ("  {0,-10}{1,10:F1}{2,10:F1}{3,9:F3}   {4}" -f $mode, $a, $b, $r, $v)
        }
        # Absolute-free verdict: the two FP32-accumulate modes should be as fast as
        # the FP16-accumulate mode once unlocked. That comparison survives a downclock
        # because both sides move together. This is the criterion; the ratio against a
        # recorded baseline is only a sanity check, because it is measured against a
        # different power cap and a different day.
        $liveVerdict = 'UNKNOWN'
        if ($now.ContainsKey('f16/f32') -and $now.ContainsKey('f16/f16') -and $now['f16/f16']) {
            $live = $now['f16/f32'] / $now['f16/f16']
            Write-Host ("`n  live ratio f16/f32 / f16/f16 = {0:F3}   (stock ~0.50, unlocked 1.00)" -f $live)
            if ($live -ge 0.90)      { $liveVerdict = 'UNLOCKED'; Write-Host "  UNLOCKED" -ForegroundColor Green }
            elseif ($live -le 0.60)  { $liveVerdict = 'STOCK';    Write-Host "  STOCK" -ForegroundColor Yellow }
            else                     { $liveVerdict = 'AMBIGUOUS'; Write-Host "  AMBIGUOUS - rerun on an idle GPU" -ForegroundColor Yellow }
        }
        # The live ratio decides. The table above is context, not the verdict, because
        # every mode on this card shares one SM clock: a run that is 5% slow shifts all
        # six columns at once, which moves the baseline ratios without saying anything
        # about the gate. The recorded baseline was also collected at power.limit 285 W
        # and this machine now runs a 320 W override, so cross-day absolutes are not
        # comparable in the first place.
        $ok2 = ($liveVerdict -eq 'UNLOCKED')
        if ($ok2) {
            Write-Host "`n  CRITERION 2: PASS" -ForegroundColor Green
        } elseif ($liveVerdict -eq 'STOCK') {
            Write-Host "`n  CRITERION 2: FAIL - the FP32-accumulate modes are at half rate" -ForegroundColor Red
        } else {
            Write-Host "`n  CRITERION 2: FAIL - the ratio is neither stock nor unlocked; rerun on an idle GPU" -ForegroundColor Red
        }
        if (-not $ctrlOk) {
            Write-Host "  note: a control mode moved more than 15% against the recorded baseline." -ForegroundColor Yellow
            Write-Host "  That is the SM clock, not the gate -- see the clock readout in 0/4 and" -ForegroundColor Yellow
            Write-Host "  docs/PITFALLS.md #11. It does not change the verdict, which is the ratio." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  baseline missing at $mmaStock" -ForegroundColor Yellow
        $ok2 = $false
    }
}

# ---------------------------------------------------------------- 2b. FP8
Rule "2b/4  FP8 (E4M3) instruction issue rate"
# NOTE: FP8 e4m3->f32 IS an FP32-accumulate path and it DOES double.
# Earlier versions of this script said "FP8 UNCHANGED - expected" and reasoned
# about DLSS 5 from that. That was wrong: measured 170.63 -> 319.58 TF/s (1.87x).
$okFP8 = $false
$fout = Copy-And-Run (Find-Bench 'fp8_mma_bench.exe') @($Iters, $Reps)
if (-not $fout) {
    Write-Host "  fp8_mma_bench.exe not found" -ForegroundColor Yellow
} else {
    $fout.Trim() | ForEach-Object { "  $_" }
    $nowFp8 = $null
    foreach ($line in ($fout -split "`n")) {
        if ($line -match '^e4m3/f32\s+([\d.]+)') { $nowFp8 = [double]$Matches[1] }
    }
    $stockFp8 = $null
    if (Test-Path $fp8Stock) {
        foreach ($line in (Get-Content $fp8Stock)) {
            if ($line -match '^e4m3/f32\s+([\d.]+)') { $stockFp8 = [double]$Matches[1] }
        }
    }
    if ($nowFp8 -and $stockFp8) {
        $fr = $nowFp8 / $stockFp8
        Write-Host ("`n  e4m3/f32   stock {0:F2}  now {1:F2}  ratio {2:F3}" -f $stockFp8, $nowFp8, $fr)
        if ($fr -gt 1.5) { $okFP8 = $true;  Write-Host "  FP8 DOUBLED - consistent with the FMLA32/IMLA gate opening" -ForegroundColor Green }
        else             { $okFP8 = $false; Write-Host "  FP8 did NOT double - contradicts the expected gate behaviour" -ForegroundColor Red }
    } else {
        Write-Host "  FP8 baseline ($fp8Stock) or current value missing" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- 3. numerics
Rule "3/4  numerics"
$ok3 = $false
if (-not $GemmCheck) {
    $GemmCheck = @(
        (Find-Bench 'gemm_check.exe'),
        'G:\workspace\rtx2705\bench\gemm_check.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $GemmCheck) {
    Write-Host "  gemm_check.exe not found. Pass -GemmCheck <path>." -ForegroundColor Yellow
} else {
    Write-Host "  using: $GemmCheck"
    $g = Copy-And-Run $GemmCheck @()
    if ($g) {
        $g.Trim() | ForEach-Object { "  $_" }
        if ($g -match 'failures=(\d+)') {
            $fails = ($g | Select-String -Pattern 'failures=(\d+)' -AllMatches).Matches |
                     ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Sum
            $ok3 = ($fails.Sum -eq 0)
            if ($ok3) { Write-Host "`n  CRITERION 3: PASS - 0 numerical failures" -ForegroundColor Green }
            else      { Write-Host "`n  CRITERION 3: FAIL - $($fails.Sum) numerical failures" -ForegroundColor Red }
        }
    }
}

Rule "verdict"
Write-Host @"
  Criterion 1 (transaction log)  -> see section 1/4
  Criterion 2 (issue rate)       -> see section 2/4
  Criterion 3 (numerics)         -> see section 3/4

  A green log alone is NOT proof: upstream issue #20 records
  'gpu_unlock: unlocked' with the getter still reporting half rate,
  and issue #4 records a fully green transaction with the hardware
  unchanged on an AD103M part. Only sections 2 and 3 decide this.

  And a big number alone is NOT proof either: see docs/PITFALLS.md #12.
  bench/cublas_gemm.cu once reported ~4600 TF/s because alpha was read
  as zero and every GEMM returned an all-zero matrix.
"@
if ($Work -and (Test-Path $Work)) { Write-Host "`nbench copies in: $Work" -ForegroundColor DarkGray }

Rule "overall"
Write-Host ("  log       : {0}" -f $(if ($ok1) { 'PASS' } else { 'FAIL' }))
Write-Host ("  issue rate: {0}" -f $(if ($ok2) { 'PASS' } else { 'FAIL' }))
Write-Host ("  FP8       : {0}" -f $(if ($okFP8) { 'PASS' } else { 'FAIL' }))
Write-Host ("  numerics  : {0}" -f $(if ($ok3) { 'PASS' } else { 'FAIL' }))
$overall = $ok1 -and $ok2 -and $okFP8 -and $ok3
if ($overall) {
    Write-Host "`n  UNLOCK CONFIRMED by all four criteria." -ForegroundColor Green
    exit 0
}
Write-Host "`n  NOT CONFIRMED. A failing criterion above says which part is missing;" -ForegroundColor Red
Write-Host "  the log alone is never the answer (see the note above)." -ForegroundColor Red
exit 1


