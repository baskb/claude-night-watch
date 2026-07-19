<#
.SYNOPSIS
  night-watch.ps1 - automatically resume a Claude Code session once the 5-hour
  usage window resets (native auto-resume does not exist; the feature request
  was closed by Anthropic as "not planned").

.DESCRIPTION
  Pattern (after the community example cys1750/claude-auto-resume, own code):
    1. WAIT while the session is active (transcript JSONL freshly written).
    2. Transcript older than StaleMinutes -> PROBE with a cheap `claude -p`
       (haiku). If it reports a usage limit, PIN that session and parse the
       reset time ("resets 3:45pm" / "in 3 hours"; unofficial format, so a
       30-min fallback when unparseable).
    3. WAIT until the reset, then probe again. Only a CLEAN, successful,
       non-limited reply (exit 0 + an "OK" body) counts as "window open" - a
       CLI/auth/network error is NOT mistaken for an open window.
    4. RESUME the PINNED session once, headless, after a final freshness
       re-check: `claude -p "<prompt>" --resume <id>` from the project dir.
       Then clear the observed-limit flag: a further resume (MaxResumes > 1)
       requires observing a NEW limit first - it never re-runs finished work.

  Safety nets: drop a `stop.flag` file next to this script to stop; a hard
  deadline (default 09:30, also enforced during sleeps); everything logged to
  night-watch.log. It resumes ONLY after a limit has actually been observed,
  and only the session that hit it - a merely-finished session is never woken.

  The resumed run's permission mode is an explicit owner choice per run
  (-SkipPermissions). Unattended runs usually need it, but it is off by default.
  NOTE: with -SkipPermissions the resumed run can write files, commit and push
  with no human in the loop, and its full output is appended to night-watch.log
  (which may capture secrets). Your -ResumePrompt is the only guardrail - be
  explicit about what the run must NOT do, and do not point it at a repo whose
  contents you would not want touched.

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
  Add-Content -LiteralPath $logFile -Value $line
  Write-Host $line
}

# Claude Code encodes the project directory into a transcript folder name by
# replacing ':' '\' '/' and space with '-'. Resolve to an absolute path first so
# a relative -ProjectDir works. NOTE: this mirrors an internal Claude Code layout
# that could change - Get-LatestSession returning $null is the visible symptom.
function Get-TranscriptDir([string]$dir) {
  $abs = $dir
  try { $abs = (Resolve-Path -LiteralPath $dir -ErrorAction Stop).Path } catch { }
  $enc = $abs -replace '[:\\/ ]', '-'
  return Join-Path $env:USERPROFILE ".claude\projects\$enc"
}

function Get-LatestSession {
  $tdir = Get-TranscriptDir $ProjectDir
  if (-not (Test-Path -LiteralPath $tdir)) { return $null }
  Get-ChildItem -LiteralPath $tdir -Filter '*.jsonl' -File |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# Reset-time text -> datetime. Handles a relative duration ("in 3 hours"), and
# an absolute clock time with optional weekday ("resets [at] [Mon] 3:45pm").
# Timezone text in the message is ignored: times are treated as machine-local,
# which matches how Claude Code renders the limit notice for the local user.
function Parse-ResetTime([string]$text) {
  # Relative duration first: "try again in 3 hours" / "in 45 minutes".
  $rel = [regex]::Match($text, '\bin\s+(\d{1,3})\s*(hours?|hrs?|minutes?|mins?)\b', 'IgnoreCase')
  if ($rel.Success) {
    $n = [int]$rel.Groups[1].Value
    if ($rel.Groups[2].Value -imatch '^h') { return (Get-Date).AddHours($n) }
    return (Get-Date).AddMinutes($n)
  }
  $m = [regex]::Match($text, 'reset[s]?\s+(?:at\s+)?(?:(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\w*\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)', 'IgnoreCase')
  if (-not $m.Success) { return $null }
  $h = [int]$m.Groups[2].Value % 12
  if ($m.Groups[4].Value -ieq 'pm') { $h += 12 }
  $min = 0
  if ($m.Groups[3].Success) { $min = [int]$m.Groups[3].Value }
  if ($m.Groups[1].Success) {
    # Named weekday: schedule the next occurrence of that day at that time.
    $map = @{ sun = 0; mon = 1; tue = 2; wed = 3; thu = 4; fri = 5; sat = 6 }
    $want = $map[$m.Groups[1].Value.Substring(0, 3).ToLower()]
    $cur = [int](Get-Date).DayOfWeek
    $delta = ((($want - $cur) % 7) + 7) % 7
    $t = (Get-Date).Date.AddDays($delta).AddHours($h).AddMinutes($min)
    if ($t -le (Get-Date)) { $t = $t.AddDays(7) }
    return $t
  }
  $t = (Get-Date).Date.AddHours($h).AddMinutes($min)
  if ($t -le (Get-Date)) { $t = $t.AddDays(1) }
  return $t
}

# Cheap probe. Returns @{ limited; ok; reset; raw; code }.
#   limited = the reply looks like a usage-limit message.
#   ok      = a CLEAN success signal: exit 0, not limited, and an "OK" body.
#             Only `ok` is treated as "window open"; a CLI/auth/network error
#             (non-zero exit, empty/garbled output) is neither limited nor ok,
#             so it never triggers a resume - it just retries.
function Probe-Limit {
  $out = ''
  $code = -1
  try {
    $out = (& claude -p 'Reply with exactly: OK' --model claude-haiku-4-5-20251001 2>&1 | Out-String).Trim()
    $code = $LASTEXITCODE
  } catch { $out = ($_ | Out-String).Trim(); $code = -1 }
  $limited = $out -match 'usage limit|limit reached|out of.*usage|resets\s|try again in'
  $ok = (-not $limited) -and ($code -eq 0) -and ($out -match '(?im)^\s*OK\b')
  return @{ limited = $limited; ok = $ok; reset = (Parse-ResetTime $out); raw = $out; code = $code }
}

function Sleep-Until([datetime]$until) {
  while ((Get-Date) -lt $until) {
    if (Test-Path -LiteralPath $stopFlag) { Log 'stop.flag seen while waiting - exiting.'; exit 0 }
    if ((Get-Date) -gt $Deadline) { Log 'deadline reached while waiting - exiting.'; exit 0 }
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
    @{ intxt = 'resets Fri 8am'; expectHour = 8 },
    @{ intxt = 'You are out of usage. Try again in 3 hours.'; expectRelHours = 3 },
    @{ intxt = 'limit reached, try again later'; expectHour = $null },
    @{ intxt = 'just a normal reply'; expectHour = $null }
  )
  $fail = 0
  foreach ($c in $cases) {
    $r = Parse-ResetTime $c.intxt
    if ($c.ContainsKey('expectRelHours')) {
      $ok = $r -and ([Math]::Abs(($r - (Get-Date).AddHours($c.expectRelHours)).TotalMinutes) -lt 3)
    } elseif ($null -eq $c.expectHour) {
      $ok = ($null -eq $r)
    } else {
      $ok = ($r -and $r.Hour -eq $c.expectHour)
    }
    if (-not $ok) { $fail++ }
    $verdict = 'FAIL'; if ($ok) { $verdict = 'PASS' }
    Write-Host ("  {0}  parse '{1}' -> {2}" -f $verdict, $c.intxt, $r)
  }
  $tdir = Get-TranscriptDir $ProjectDir
  $v1 = 'FAIL'; if (Test-Path -LiteralPath $tdir) { $v1 = 'PASS' }
  Write-Host ("  {0}  transcript folder exists: {1}" -f $v1, $tdir)
  $sess = Get-LatestSession
  $v2 = 'FAIL'; $sname = '-'
  if ($sess) { $v2 = 'PASS'; $sname = $sess.Name }
  Write-Host ("  {0}  newest session: {1}" -f $v2, $sname)
  $ver = (& claude --version 2>&1 | Out-String).Trim()
  $v3 = 'FAIL'; if ($ver -match '\d') { $v3 = 'PASS' }
  Write-Host ("  {0}  claude CLI: {1}" -f $v3, $ver)
  if ($fail -gt 0 -or -not (Test-Path -LiteralPath $tdir) -or -not $sess) { exit 1 }
  Write-Host '== self-test OK =='
  exit 0
}

$permNote = 'default permissions'
if ($SkipPermissions) { $permNote = 'skip-permissions' }
Log "night-watch started. Project: $ProjectDir | poll ${PollMinutes}m | stale ${StaleMinutes}m | deadline $Deadline | max $MaxResumes resume(s) | $permNote."
$resumes = 0
$limitSeen = $false
$pinned = $null

while ($true) {
  if (Test-Path -LiteralPath $stopFlag) { Log 'stop.flag seen - exiting.'; break }
  if ((Get-Date) -gt $Deadline) { Log 'deadline reached - exiting.'; break }
  if ($resumes -ge $MaxResumes) { Log 'max resumes reached - exiting.'; break }

  $sess = Get-LatestSession
  if (-not $sess) { Log 'no session transcript found; waiting.'; Sleep-Until (Get-Date).AddMinutes($PollMinutes); continue }

  $age = ((Get-Date) - $sess.LastWriteTime).TotalMinutes
  if ($age -lt $StaleMinutes) {
    # Active. If we were mid-limit-episode and the session is alive again
    # (the window reopened and work resumed, by us or the owner), the episode
    # is over - clear the pending resume so a later idle period cannot trigger
    # an unwanted wake of already-continued work.
    if ($limitSeen) { Log 'session active again - clearing the pending resume.'; $limitSeen = $false; $pinned = $null }
    Sleep-Until (Get-Date).AddMinutes($PollMinutes); continue
  }

  $probe = Probe-Limit
  if ($probe.limited) {
    $limitSeen = $true
    $pinned = $sess   # pin the session that actually hit the wall
    if ($probe.reset) {
      Log ("limit active; reset parsed at {0:yyyy-MM-dd HH:mm}. Waiting until reset + 5m." -f $probe.reset)
      Sleep-Until $probe.reset.AddMinutes(5)
    } else {
      $rawShort = $probe.raw.Substring(0, [Math]::Min(120, $probe.raw.Length))
      Log "limit active; reset time not parseable - retrying in 30m. (raw: $rawShort)"
      Sleep-Until (Get-Date).AddMinutes(30)
    }
    continue
  }

  if (-not $limitSeen) {
    # Quiet transcript but no limit was ever observed: the session is simply
    # done or waiting on the owner. Never wake it unprompted.
    Sleep-Until (Get-Date).AddMinutes($PollMinutes); continue
  }

  # A limit was observed earlier. Require a POSITIVE, clean reply before treating
  # the window as open - a transient CLI/auth/network error must not resume.
  if (-not $probe.ok) {
    $rawShort = $probe.raw.Substring(0, [Math]::Min(120, $probe.raw.Length))
    Log "post-limit probe was not a clean OK (exit $($probe.code)) - not resuming; retry in ${PollMinutes}m. (raw: $rawShort)"
    Sleep-Until (Get-Date).AddMinutes($PollMinutes); continue
  }

  # Final freshness re-check on the PINNED session: if it came back to life
  # during the wait, someone/something already continued it - do not double-run.
  $target = if ($pinned) { $pinned } else { $sess }
  $fresh = Get-Item -LiteralPath $target.FullName -ErrorAction SilentlyContinue
  if ($fresh -and (((Get-Date) - $fresh.LastWriteTime).TotalMinutes -lt $StaleMinutes)) {
    Log 'pinned session became active before resume - not resuming.'; $limitSeen = $false; $pinned = $null; continue
  }

  $sessionId = [IO.Path]::GetFileNameWithoutExtension($target.Name)
  $resumes++
  Log "window open - resuming pinned session $sessionId (attempt $resumes/$MaxResumes, max $MaxTurns turns)."
  Push-Location -LiteralPath $ProjectDir
  try {
    & claude -p $ResumePrompt --resume $sessionId --max-turns $MaxTurns @ResumeArgs *>> $logFile
    Log "resume finished (exit $LASTEXITCODE)."
  } catch {
    Log "resume ERROR: $($_ | Out-String)"
  } finally {
    Pop-Location
  }
  # A further resume must observe a NEW limit first - never re-run finished work.
  $limitSeen = $false
  $pinned = $null
}
Log 'night-watch stopped.'
