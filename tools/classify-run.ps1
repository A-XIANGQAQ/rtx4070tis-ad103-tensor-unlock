# SPDX-License-Identifier: MIT
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
  # The mismatch line itself says which build printed it. Before the blank gate
  # existed it ended with wantSS1=; after, with stockSS1=. Same verdict text,
  # two different findings, so the log alone has to tell them apart.
  $entryRefused  = @($lines | Where-Object { $_ -match 'cold-profile selector mismatch' })
  $mismatchOld   = @($entryRefused | Where-Object { $_ -match 'wantSS1=' })
  $mismatchNew   = @($entryRefused | Where-Object { $_ -match 'stockSS1=' })
  $pinRefused    = @($lines | Where-Object { $_ -match 'cold-profile register mismatch' })
  # GuAd104Prepare used to fold eleven conditions into one status code with no
  # message. From 250C7EA1 onward each refusal names itself, so the verdict can
  # say why instead of just "it refused".
  $prepareRefused = @($lines | Where-Object { $_ -match '^cold-prepare: ' })
  $stop          = @($lines | Where-Object { $_ -match '^STOP: stage=' })
  # app.c split one ambiguous label into two after the driver let go, so the stage
  # name alone now says which refusal it was.
  $stopStage     = if ($stop.Count -gt 0) { $stop[-1] -replace '^STOP: stage=([^ ]+).*','$1' } else { '' }
  $txResult      = @($lines | Where-Object { $_ -match '^Transaction result=' })
  # The line exists whether the body succeeded or failed, so the verdict has to
  # read the number. A run that failed at result=-5 and then stopped used to be
  # filed under TX-OK-THEN-HALT, which says OK about a body that returned -5.
  $txCode        = $null
  if ($txResult.Count -gt 0) {
    if ($txResult[-1] -match '^Transaction result=(-?\d+)') { $txCode = [int]$Matches[1] }
  }
  $entry         = @($lines | Where-Object { $_ -match '^entry: plm=' })
  $handoff       = @($lines | Where-Object { $_ -match 'handoff check passed' })
  $residual      = @($lines | Where-Object { $_ -match 'release: residual edges' })
  $skipped       = @($lines | Where-Object { $_ -match 'Operator skipped' })
  $bootmgr       = @($lines | Where-Object { $_ -match '^bootmgfw: size=' })

  $verdict = 'UNKNOWN'
  $why     = 'no recognised line'
  if ($null -ne $txCode -and $txCode -ne 0) {
    # A body that returned non-zero did not unlock anything; whether a stage then
    # stopped is secondary. Keep the two separate so a failure is never mistaken
    # for the RUN0004 shape (body OK, handoff lost).
    if ($stop.Count -gt 0) {
      $verdict = 'TRANSACTION-FAILED-THEN-STOP'
      $why     = "transaction body returned $txCode, then a stage stopped"
    } else {
      $verdict = 'TRANSACTION-FAILED'
      $why     = "transaction body returned $txCode"
    }
  } elseif ($txResult.Count -gt 0 -and $stop.Count -gt 0) {
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
  } elseif ($mismatchNew.Count -gt 0) {
    $verdict = 'ENTRY-REFUSED-NEITHER-STATE'
    $why     = 'this build accepts stock and blank, so the selectors were a third state'
  } elseif ($mismatchOld.Count -gt 0) {
    $verdict = 'ENTRY-REFUSED-SELECTOR'
    $why     = 'an EFI without the blank gate; SS0=0 SS1=0 is the expected refusal here'
  } elseif ($entryRefused.Count -gt 0) {
    $verdict = 'ENTRY-REFUSED-SELECTOR'
    $why     = 'selectors did not match an accepted entry state'
  } elseif ($stopStage -eq 'release-not-held') {
    # The claim did not stay held after the release, so the run never reached the
    # transaction. Nothing about the card changed; this is a host-side refusal.
    $verdict = 'CLAIM-NOT-HELD'
    $why     = 'the exclusive claim was not held after the driver let go, so nothing ran'
  } elseif ($prepareRefused.Count -gt 0) {
    # The first cold-entry gate refused and said why. Earlier builds only gave
    # EFI_NOT_READY here, so this branch is also how you tell the two apart.
    $verdict = 'ENTRY-REFUSED-PREPARE'
    $why     = 'the cold-entry preparation refused before any selector was read'
  } elseif ($stopStage -eq 'post-release-gate' -or $coldRefused.Count -gt 0) {
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
  if ($prepareRefused.Count -gt 0) { "prepare   : " + ($prepareRefused[-1]) }
  if ($stopStage) { "refusedAt : " + $stopStage }
  if ($txResult.Count  -gt 0) { "tx        : " + ($txResult[-1] -replace '^Transaction result=','') }
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
