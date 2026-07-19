---
name: night-watch
description: >-
  Automatically resume a headless Claude Code session after the 5-hour usage
  window resets, so a long unattended run continues on its own. Use when the
  user wants work to keep going across a usage-limit reset without a manual
  restart - overnight batches, long autonomous task lists, "auto-resume",
  "night watch", "keep going overnight", "continue after the limit resets",
  "pick up where you left off when the window reopens". Windows / PowerShell.
  Never wakes a session that simply finished - it only resumes after it has
  actually observed a usage limit.
---

# night-watch - Claude Code session auto-resume

Claude Code has no native auto-resume across the 5-hour usage window (Anthropic
closed that feature request as "not planned"). This skill packages a small,
safe PowerShell watcher that resumes a headless session **once** after the
window reopens, so a long unattended task list finishes on its own.

## When to use this

- The user is about to leave a long autonomous run going (an overnight batch,
  a multi-item task list) and wants it to continue after the usage window resets.
- The user says things like "keep going overnight", "auto-resume", "night watch",
  "pick it back up when the limit resets", "don't make me restart it manually".

Do **not** use it to poll for ordinary background work, to bypass a limit, or to
run more than the single agreed resume - it is a one-shot safety net, not a loop.

## How it works (the pattern)

1. **Watch** the active session's transcript (`~/.claude/projects/<encoded-path>/*.jsonl`).
   While it is being written to (fresh within `-StaleMinutes`), do nothing.
2. **Probe + pin** when the transcript goes stale: run a cheap `claude -p` on
   Haiku and check the reply for a usage-limit message. If limited, **pin that
   session** as the one to resume, and parse the reset time ("resets 3:45pm" or
   "in 3 hours"; an unofficial format, so there is a 30-minute fallback when it
   cannot be parsed).
3. **Wait** until the reset, then probe again. Only a **clean, successful,
   non-limited reply** (the CLI exits 0 with an `OK` body) counts as
   "window open" - a CLI/auth/network error is *not* mistaken for a reset.
4. **Resume** the **pinned** session once, headless, after a final freshness
   re-check: `claude -p "<prompt>" --resume <id>` from the project directory.
   Then clear the observed-limit flag - with `-MaxResumes > 1`, a further resume
   requires observing a **new** limit first, so finished work is never re-run.

**Safety model (do not weaken):**
- Resumes **only** after a usage limit was actually observed, and only the
  **session that hit it** (pinned) - a session that simply finished, is waiting
  on the owner, or came back to life during the wait is never woken.
- "Window open" requires a **positive** clean reply, not merely the absence of a
  limit - so a transient CLI/auth/network error cannot trigger a resume.
- After each resume the observed-limit flag is reset: no loop, and no re-run of
  completed work even with `-MaxResumes > 1`.
- `stop.flag` file beside the script stops it immediately (also honoured during
  waits). Hard `-Deadline` (default next 09:30) ends the watch no matter what.
- Everything is logged to `night-watch.log`.
- The resumed run's **permission mode is an explicit owner choice per run**
  (`-SkipPermissions`). Unattended runs usually need it (otherwise they hang on
  the first prompt), but the owner must opt in - it is off by default. **With it
  on, the resumed run can write files, commit and push with no human in the
  loop, and its full output is appended to `night-watch.log` (which may capture
  secrets).** Your `-ResumePrompt` is the only guardrail - be explicit about
  what the run must NOT do, and do not point it at a repo you would not want
  touched unattended.

The script is deliberately **pure ASCII**: PowerShell 5.1 reads UTF-8-without-BOM
as ANSI and turns em-dashes into smart quotes it then mis-parses.

## Running it

The script lives at `scripts/night-watch.ps1` in this skill.

**Always self-test first** (checks the transcript path, the CLI, and the
reset-time parser - no side effects):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/night-watch.ps1 -SelfTest
```

**Then launch the watcher** in a separate, long-lived terminal (not through the
agent - it must outlive the current session):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/night-watch.ps1 `
  -ProjectDir "C:\path\to\project" `
  -ResumePrompt "Resume the agreed task list. Read PROGRESS.md and continue. Commit + push per item on <branch>. No deploys, no merge to main, no force-push. Stop cleanly when the list is done or an item needs a human decision." `
  -SkipPermissions
```

Leave `-ProjectDir` off to use the current directory. Tune with `-PollMinutes`,
`-StaleMinutes`, `-MaxResumes`, `-MaxTurns`, `-Deadline`.

## Writing the resume prompt (this matters most)

The resume prompt is the whole instruction the fresh headless run gets - write it
like a careful handoff:
- Point it at durable state: "Read PROGRESS.md and continue the agreed list."
- Name the exact scope and the branch; forbid destructive actions explicitly
  (no deploys, no merge to main, no force-push) unless the owner wants them.
- Tell it to work per item (build, run gates, record, commit, push) and to
  **stop cleanly** when the list is done or an item needs a human decision -
  so it never invents work or waits silently.

## Stopping it

- Create an empty file `stop.flag` next to the script, or
- close the terminal, or
- let the `-Deadline` pass.

## Adapting for another machine / OS

This is Windows/PowerShell. The transcript-directory encoding
(`project path with ':' '\' ' ' replaced by '-'`) and the reset-time regex are
the machine-specific parts to re-check if Claude Code changes its transcript
layout or the limit-message wording.
