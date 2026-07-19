<#
.SYNOPSIS
  night-watch.ps1 - automatically resume a Claude Code session once the 5-hour
  usage window resets (native auto-resume does not exist; the feature request
  was closed by Anthropic as "not planned").

.DESCRIPTION
  Pattern (after the community example cys1750/claude-auto-resume, own code):
    1. WAIT while the session is active (transcript JSONL freshly written).
    2. Transcript older than StaleMinutes -> PROBE with a cheap `claude -p`
       (haiku). If it reports a usage limit, parse the reset time
       ("resets 3:45pm" style; unofficial format, so a 30-min fallback).
    3. WAIT until reset + buffer, probe again to confirm.
    4. RESUME the newest session of this project once, headless:
       `claude -p "<prompt>" --resume <id>` from the project directory.
       Then stop (MaxResumes=1: no loop that drains fresh windows).

  Safety nets: drop a `stop.flag` file next to this script to stop; a hard
  deadline (default 09:30); everything logged to night-watch.log.
  Session safety: it resumes ONLY after a limit has actually been observed -
  a session that simply finished is never woken unprompted.

  The resumed run's permission mode is an explicit owner choice per run
  (-SkipPermissions). Unattended runs usually need it, but it is off by default.

  This file is deliberately pure ASCII: PowerShell 5.1 reads UTF-8-without-BOM
  as ANSI and turns em-dashes into smart quotes it then mis-parses.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File night-watch.ps1 -SelfTest
  powershell -NoProfile -ExecutionPolicy Bypass -File night-watch.ps1 -SkipPermissions
#>
param(
  [string]$ProjectDir = (Get-Location).Path,
  [string]$ResumePrompt = 'Resume after the usage-window reset. Read PROGRESS.md (or the project state file) and continue the agreed task list. Work per item: build, run the gates, record the result, commit and push. Do not deploy, do not merge to main, do not force-push. Stop cleanly when the list is done or an item needs a human decision.',
  [int]$PollMinutes = 10,
  [int]$StaleMinutes = 15,
  [int]$MaxResumes = 1,
  [int]$MaxTurns = 400,
  [datetime]$Deadline = $(if ((Get-Date).Hour -ge 12) { (Get-Date).Date.AddDays(1).AddHours(9.5) } else { (Get-Date).Date.AddHours(9.5) }),
  [switch]$SkipPermissions,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile   = Join-Path $scriptDir 'night-watch.log'
$stopFlag  = Join-Path $scriptDir 'stop.flag'
$ResumeArgs = @()
if ($SkipPermissions) { $ResumeArgs = @('--dangerously-skip-permissions') }

function Log([string]$msg) {
  $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg
  Add-Content -Path $logFile -Value $line
  Write-Host $line
}

# Claude Code encodes the project directory into a transcript folder name:
# ':' '\' ' ' -> '-'
function Get-TranscriptDir([string]$dir) {
  $enc = $dir -replace '[:\\ ]', '-'
  return Join-Path $env:USERPROFILE ".claude\projects\$enc"
}

function Get-LatestSession {
  $tdir = Get-TranscriptDir $ProjectDir
  if (-not (Test-Path $tdir)) { return $null }
  Get-ChildItem $tdir -Filter '*.jsonl' -File |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# "resets 3:45pm" / "resets 12am" / "resets Mon 12:00am" -> datetime (today or tomorrow)
function Parse-ResetTime([string]$text) {
  $m = [regex]::Match($text, 'reset[s]?\s+(?:at\s+)?(?:(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\w*\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)', 'IgnoreCase')
  if (-not $m.Success) { return $null }
  $h = [int]$m.Groups[2].Value % 12
  if ($m.Groups[4].Value -ieq 'pm') { $h += 12 }
  $min = 0
  if ($m.Groups[3].Success) { $min = [int]$m.Groups[3].Value }
  $t = (Get-Date).Date.AddHours($h).AddMinutes($min)
  if ($t -le (Get-Date)) { $t = $t.AddDays(1) }
  return $t
}

# Cheap probe; returns @{ limited = bool; reset = datetime|null; raw = text }
function Probe-Limit {
  $out = ''
  try {
    $out = (& claude -p 'Reply with exactly: OK' --model claude-haiku-4-5-20251001 2>&1 | Out-String).Trim()
  } catch { $out = ($_ | Out-String).Trim() }
  $limited = $out -match 'usage limit|limit reached|out of.*usage|resets\s'
  return @{ limited = $limited; reset = (Parse-ResetTime $out); raw = $out }
}

function Sleep-Until([datetime]$until) {
  while ((Get-Date) -lt $until) {
    if (Test-Path $stopFlag) { Log 'stop.flag seen while waiting - exiting.'; exit 0 }
    $rest = [Math]::Min(300, [Math]::Max(5, ($until - (Get-Date)).TotalSeconds))
    Start-Sleep -Seconds $rest
  }
}

if ($SelfTest) {
  Write-Host '== night-watch self-test =='
  $cases = @(
    @{ intxt = 'Your limit will reset at 3:45pm (Europe/Amsterdam).'; expectHour = 15 },
    @{ intxt = 'usage limit reached - resets 12am'; expectHour = 0 },
    @{ intxt = 'resets Mon 7:30am'; expectHour = 7 },
    @{ intxt = 'resets 12pm'; expectHour = 12 },
    @{ intxt = 'resets at 9am'; expectHour = 9 },
    @{ intxt = 'your usage limit resets 11:59pm tonight'; expectHour = 23 },
    @{ intxt = 'resets 1am'; expectHour = 1 },
    @{ intxt = 'resets Sun 6pm'; expectHour = 18 },
    @{ intxt = 'limit reached, try again later'; expectHour = $null },
    @{ intxt = 'just a normal reply'; expectHour = $null }
  )
  $fail = 0
  foreach ($c in $cases) {
    $r = Parse-ResetTime $c.intxt
    if ($null -eq $c.expectHour) { $ok = ($null -eq $r) } else { $ok = ($r -and $r.Hour -eq $c.expectHour) }
    if (-not $ok) { $fail++ }
    $verdict = 'FAIL'; if ($ok) { $verdict = 'PASS' }
    Write-Host ("  {0}  parse '{1}' -> {2}" -f $verdict, $c.intxt, $r)
  }
  $tdir = Get-TranscriptDir $ProjectDir
  $v1 = 'FAIL'; if (Test-Path $tdir) { $v1 = 'PASS' }
  Write-Host ("  {0}  transcript folder exists: {1}" -f $v1, $tdir)
  $sess = Get-LatestSession
  $v2 = 'FAIL'; $sname = '-'
  if ($sess) { $v2 = 'PASS'; $sname = $sess.Name }
  Write-Host ("  {0}  newest session: {1}" -f $v2, $sname)
  $ver = (& claude --version 2>&1 | Out-String).Trim()
  $v3 = 'FAIL'; if ($ver -match '\d') { $v3 = 'PASS' }
  Write-Host ("  {0}  claude CLI: {1}" -f $v3, $ver)
  if ($fail -gt 0 -or -not (Test-Path $tdir) -or -not $sess) { exit 1 }
  Write-Host '== self-test OK =='
  exit 0
}

$permNote = 'default permissions'
if ($SkipPermissions) { $permNote = 'skip-permissions' }
Log "night-watch started. Project: $ProjectDir | poll ${PollMinutes}m | stale ${StaleMinutes}m | deadline $Deadline | max $MaxResumes resume(s) | $permNote."
$resumes = 0
$limitSeen = $false

while ($true) {
  if (Test-Path $stopFlag) { Log 'stop.flag seen - exiting.'; break }
  if ((Get-Date) -gt $Deadline) { Log 'deadline reached - exiting.'; break }
  if ($resumes -ge $MaxResumes) { Log 'max resumes reached - exiting.'; break }

  $sess = Get-LatestSession
  if (-not $sess) { Log 'no session transcript found; waiting.'; Sleep-Until (Get-Date).AddMinutes($PollMinutes); continue }

  $age = ((Get-Date) - $sess.LastWriteTime).TotalMinutes
  if ($age -lt $StaleMinutes) {
    # Session is actively working - do nothing.
    Sleep-Until (Get-Date).AddMinutes($PollMinutes); continue
  }

  $probe = Probe-Limit
  if ($probe.limited) {
    $limitSeen = $true
    if ($probe.reset) {
      Log ("limit active; reset parsed at {0:HH:mm}. Waiting until reset + 5m." -f $probe.reset)
      Sleep-Until $probe.reset.AddMinutes(5)
    } else {
      $rawShort = $probe.raw.Substring(0, [Math]::Min(120, $probe.raw.Length))
      Log "limit active; reset time not parseable - retrying in 30m. (raw: $rawShort)"
      Sleep-Until (Get-Date).AddMinutes(30)
    }
    continue
  }

  if (-not $limitSeen) {
    # Transcript is quiet but no limit was ever seen: the session is simply done
    # or waiting on the owner. Never wake it unprompted.
    Sleep-Until (Get-Date).AddMinutes($PollMinutes); continue
  }

  # Window is open after a previously observed limit -> resume once.
  $sessionId = [IO.Path]::GetFileNameWithoutExtension($sess.Name)
  $resumes++
  Log "window open - resuming session $sessionId (attempt $resumes/$MaxResumes, max $MaxTurns turns)."
  Push-Location $ProjectDir
  try {
    & claude -p $ResumePrompt --resume $sessionId --max-turns $MaxTurns @ResumeArgs *>> $logFile
    Log "resume finished (exit $LASTEXITCODE)."
  } catch {
    Log "resume ERROR: $($_ | Out-String)"
  } finally {
    Pop-Location
  }
}
Log 'night-watch stopped.'
