# Classify one AD104 run log. ASCII output on purpose: this gets pasted into
# issues and diffed, and the portable terminal encoding is not worth fighting.
#
#   powershell -NoProfile -File tools\classify-run.ps1
#   powershell -NoProfile -File tools\classify-run.ps1 -File H:\AD104-UNLOCK\RUN0013.TXT
#   powershell -NoProfile -File tools\classify-run.ps1 -LogRoot H:\AD104-UNLOCK -All
param(
  [string]$LogRoot = 'H:\AD104-UNLOCK',
  [string]$File,
  [switch]$All
)
$ErrorActionPreference = 'Stop'

function Get-Target {
  if ($File) { if (-not (Test-Path -LiteralPath $File)) { throw "no such log: $File" }; return (Get-Item -LiteralPath $File) }
  if (-not (Test-Path -LiteralPath $LogRoot)) { throw "no such directory: $LogRoot" }
  $all = @(Get-ChildItem -LiteralPath $LogRoot -Filter 'RUN*.TXT' -File -ErrorAction SilentlyContinue)
  if ($all.Count -eq 0) { throw "no RUN*.TXT under $LogRoot" }
  return ($all | Sort-Object LastWriteTime | Select-Object -Last 1)
}

function Classify($item) {
  $lines = @(Get-Content -LiteralPath $item.FullName -Encoding UTF8)
  $text  = $lines -join "`n"

  $blankAccepted = @($lines | Where-Object { $_ -match 'cold-profile blank selectors' })
  # app.c runs the entry gate a second time after GuMsiRelease. A refusal there
  # is worse than the first one: the drivers are already detached.
  $coldRefused   = @($lines | Where-Object { $_ -match '^cold-entry' })
  $entryRefused  = @($lines | Where-Object { $_ -match 'cold-profile selector mismatch' })
  $pinRefused    = @($lines | Where-Object { $_ -match 'cold-profile register mismatch' })
  $stop          = @($lines | Where-Object { $_ -match '^STOP: stage=' })
  $txResult      = @($lines | Where-Object { $_ -match '^Transaction result=' })
  $entry         = @($lines | Where-Object { $_ -match '^entry: plm=' })
  $handoff       = @($lines | Where-Object { $_ -match 'handoff check passed' })
  $residual      = @($lines | Where-Object { $_ -match 'release: residual edges' })
  $skipped       = @($lines | Where-Object { $_ -match 'Operator skipped' })
  $bootmgr       = @($lines | Where-Object { $_ -match '^bootmgfw: size=' })

  $verdict = 'UNKNOWN'
  $why     = 'no recognised line'
  if ($txResult.Count -gt 0 -and $stop.Count -gt 0) {
    # The body succeeded and the run then halted anyway. That is what carries the
    # hardware state away from stock, so it is not the same as a clean handoff.
    $verdict = 'TX-OK-THEN-HALT'
    $why     = 'transaction body returned a result, then a stage stopped'
  } elseif ($txResult.Count -gt 0) {
    $verdict = 'TRANSACTION-COMPLETE'
    $why     = 'transaction body returned a result line'
  } elseif ($pinRefused.Count -gt 0) {
    $verdict = 'ENTRY-REFUSED-PIN'
    $why     = 'a stock register pin did not match before the selector check'
  } elseif ($entryRefused.Count -gt 0) {
    $verdict = 'ENTRY-REFUSED-SELECTOR'
    $why     = 'selectors did not match an accepted entry state'
  } elseif ($coldRefused.Count -gt 0) {
    # The first gate passed (otherwise this would read entry-refused) and the run
    # got as far as releasing the GPU, then the same check failed. The message
    # names which sub-check gave way: blocked/Config()/Registers()/selectors.
    $verdict = 'GATE-REFUSED-AFTER-RELEASE'
    $why     = 'the entry gate refused a second time, after the driver let go of the GPU'
  } elseif ($blankAccepted.Count -gt 0 -and $stop.Count -gt 0) {
    # The interesting case: the new gate let the run through, and something after
    # it gave up. The stop line says which stage, so read that before changing code.
    $verdict = 'BLANK-ACCEPTED-THEN-STOP'
    $why     = 'entry gate accepted SS0=0 SS1=0, then a later stage stopped'
  } elseif ($blankAccepted.Count -gt 0) {
    $verdict = 'BLANK-ACCEPTED'
    $why     = 'entry gate accepted SS0=0 SS1=0'
  } elseif ($skipped.Count -gt 0) {
    $verdict = 'SKIPPED'
    $why     = 'operator chose the normal Windows path'
  } elseif ($stop.Count -gt 0) {
    $verdict = 'STOPPED'
    $why     = 'a stage reported STOP'
  } elseif ($lines.Count -le 3) {
    $verdict = 'TRUNCATED'
    $why     = "only $($lines.Count) line(s); the run ended before any gate reported"
  }

  $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.Substring(0,16).ToLower()
  "file      : $($item.FullName)"
  "size      : $($item.Length) B   lines: $($lines.Count)   sha16: $hash"
  "written   : $($item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
  "VERDICT   : $verdict"
  "why       : $why"
  if ($entry.Count     -gt 0) { "entry     : " + ($entry[-1] -replace '^entry: ','') }
  if ($bootmgr.Count   -gt 0) { "bootmgr   : " + ($bootmgr[-1] -replace '^bootmgfw: ','') }
  if ($blankAccepted.Count -gt 0) { "blank     : accepted $($blankAccepted.Count)x" }
  if ($coldRefused.Count   -gt 0) { "gate      : " + ($coldRefused[-1]) }
  if ($txResult.Count  -gt 0) { "tx        : " + ($txResult[-1] -replace '^Transaction result: ','') }
  if ($handoff.Count   -gt 0) { "handoffChk: checked" }
  if ($residual.Count  -gt 0) { "residual  : " + ($residual[-1] -replace '^release: residual edges on GPU handles=','') }
  if ($stop.Count      -gt 0) { "stop      : " + ($stop[-1] -replace '^STOP: ','') }

  # A completed body does not prove the handoff worked. The gap between the last
  # write and the next Windows boot event separates "EFI handed over" from "it sat
  # there until someone held the power button", which is how RUN0004 lost its
  # result even though every transaction readback had passed.
  # Get-WinEvent returns newest first, so take the OLDEST match after the log.
  if ($verdict -eq 'TRANSACTION-COMPLETE') {
    try {
      $boots = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=12; StartTime=$item.LastWriteTime.AddSeconds(-5)} -ErrorAction Stop)
    } catch { $boots = @() }
    if ($boots.Count -gt 0) {
      $boot = $boots | Sort-Object TimeCreated | Select-Object -First 1
      $gap = [int]($boot.TimeCreated - $item.LastWriteTime).TotalSeconds
      $note = if ($gap -le 120) { 'normal handoff' } else { 'SAT THERE - state likely lost' }
      "nextBoot  : +${gap}s after this log  ($note)"
    } else {
      'nextBoot  : no boot event found after this log'
    }
  }

  "--- last 3 lines ---"
  $lines | Select-Object -Last 3 | ForEach-Object { "  $_" }
  ""
  if ($verdict -eq 'TRANSACTION-COMPLETE') { return 0 }
  return 1
}

if ($All) {
  $items = @(Get-ChildItem -LiteralPath $LogRoot -Filter 'RUN*.TXT' -File | Sort-Object Name)
  if ($items.Count -eq 0) { throw "no RUN*.TXT under $LogRoot" }
  foreach ($i in $items) {
    $r = @(Classify $i)
    $name = $i.Name
    $v = ($r | Where-Object { $_ -like 'VERDICT*' }) -replace 'VERDICT\s+:\s*',''
    "{0,-14} {1,7} B  {2}" -f $name, $i.Length, $v
  }
  exit 0
}

# Write the report to the host first: wrapping this call in exit(...) would
# capture the strings into the exit argument and print nothing.
$report = @(Classify (Get-Target))
foreach ($line in $report[0..($report.Count - 2)]) { Write-Host $line }
exit ([int]$report[-1])
