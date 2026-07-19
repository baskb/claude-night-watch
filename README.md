# Session Auto-Resume for Claude Code (night-watch)

Automatically resume a headless **Claude Code** session **once** after the
5-hour usage window resets, so a long unattended run finishes on its own.

Claude Code has no native auto-resume across the usage limit (Anthropic closed
that feature request as *"not planned"*). This is a small, safe PowerShell
watcher that fills the gap — plus a packaged [Agent Skill](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/overview)
so Claude itself knows when and how to set it up.

> **One-shot safety net, not a loop.** It resumes **only** after it has actually
> observed a usage limit, exactly once, and never wakes a session that simply
> finished. It cannot silently drain fresh windows.

---

## Why

You kick off a long autonomous task list (an overnight batch, a multi-item
build), then the 5-hour window runs out at 2am. Without this, the run just
stops until you come back and restart it by hand. With this, a watcher notices
the limit, waits for the reset, and resumes the same session with a prompt you
wrote — so the work continues while you sleep.

## How it works

1. **Watch** the active session's transcript
   (`~/.claude/projects/<encoded-path>/*.jsonl`). While it is being written to
   (fresh within `-StaleMinutes`), do nothing.
2. **Probe** when the transcript goes stale: run a cheap `claude -p` on Haiku and
   check the reply for a usage-limit message. Parse the reset time
   (`resets 3:45pm` style — an unofficial format, so there is a 30-minute
   fallback when it cannot be parsed).
3. **Wait** until the reset time plus a small buffer, then probe again to confirm.
4. **Resume** the newest session of the project once, headless:
   `claude -p "<your prompt>" --resume <id>` from the project directory. Then
   stop (`-MaxResumes 1` by default).

## Safety model (the important part)

- **Only resumes after a limit was actually observed.** A session that simply
  finished, or is waiting on you, is never woken unprompted.
- **`stop.flag`** — drop an empty file of that name next to the script to stop it
  immediately.
- **Hard `-Deadline`** (default next 09:30) ends the watch no matter what.
- **`-MaxResumes 1`** by default — no loop.
- **Everything is logged** to `night-watch.log` next to the script.
- **The resumed run's permission mode is an explicit opt-in per run**
  (`-SkipPermissions`). Unattended runs usually need it (otherwise they hang on
  the first permission prompt), but it is **off by default** — so the choice,
  and the risk, is always yours. When you do use it, your `-ResumePrompt` is the
  only guardrail; say plainly what the run must **not** do.

## Requirements

- **Windows** with **PowerShell** (5.1 or 7+).
- The **`claude` CLI** on `PATH` ([Claude Code](https://docs.claude.com/en/docs/claude-code)).
- A Claude Code session that has run at least once in the target project (so a
  transcript exists).

> The watcher is Windows/PowerShell only. macOS/Linux users would need a bash
> port — see [Adapting to another OS](#adapting-to-another-os).

## Install

### As a Claude Code Agent Skill (recommended)

Copy the skill folder so Claude discovers it:

```bash
# project-scoped (this repo -> a project's .claude/skills/)
cp -r . <your-project>/.claude/skills/session-auto-resume

# or user-scoped, available in every project
cp -r . ~/.claude/skills/session-auto-resume
```

Then just ask Claude something like *"set up night watch so my session
auto-resumes when the usage window reopens"* — the skill triggers and walks you
through the self-test and launch. (A pre-built `.skill` package can also be
attached to a GitHub release for one-file installs.)

### Standalone (just the script)

You do not need the skill layer to use the watcher — `scripts/night-watch.ps1`
runs on its own.

## Usage

**1. Self-test first** (checks the transcript path, the CLI, and the reset-time
parser — no side effects):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/night-watch.ps1 -SelfTest
```

**2. Launch the watcher** in a separate, long-lived terminal (it must outlive
the Claude Code session — do not run it as a background job inside the chat):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/night-watch.ps1 `
  -ProjectDir "C:\path\to\project" `
  -ResumePrompt "Resume the agreed task list. Read PROGRESS.md and continue. Commit + push per item on <branch>. No deploys, no merge to main, no force-push. Stop cleanly when the list is done or an item needs a human decision." `
  -SkipPermissions
```

Leave `-ProjectDir` off to use the current directory.

### Writing the resume prompt (this matters most)

The resume prompt is the entire instruction the fresh headless run receives — it
has **no memory of the earlier conversation**. Write it like a careful handoff:

- Point it at durable state: *"Read PROGRESS.md and continue the agreed list."*
- Name the exact scope and branch; forbid destructive actions explicitly (no
  deploys, no merge to main, no force-push) unless you want them.
- Tell it to work per item (build, run gates, record, commit, push) and to
  **stop cleanly** when the list is done or an item needs a human decision — so
  it never invents work or waits silently.
- Make sure your state file (e.g. `PROGRESS.md`) is actually current before you
  walk away; that is all the resumed run has to go on.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `-ProjectDir` | current directory | Project whose newest session gets resumed. |
| `-ResumePrompt` | generic "read PROGRESS.md and continue" | The full instruction for the resumed run. |
| `-SkipPermissions` | off | Pass `--dangerously-skip-permissions` to the resumed run (usually needed for truly unattended runs; explicit opt-in). |
| `-PollMinutes` | 10 | How often to check while the session is active. |
| `-StaleMinutes` | 15 | Transcript idle time before probing for a limit. |
| `-MaxResumes` | 1 | How many times to resume before stopping. |
| `-MaxTurns` | 400 | `--max-turns` passed to the resumed run. |
| `-Deadline` | next 09:30 | Hard stop for the whole watch. |
| `-SelfTest` | - | Run checks and exit; no watching, no side effects. |

## Stopping it

- Create an empty file `stop.flag` next to the script, **or**
- close the terminal, **or**
- let the `-Deadline` pass.

## Adapting to another OS

This is Windows/PowerShell. Two machine-specific pieces to re-check if you port
it or if Claude Code changes its internals:

- **Transcript directory encoding** — Claude Code maps a project path to a
  transcript folder by replacing `:` `\` and space with `-` under
  `~/.claude/projects/`.
- **Reset-message wording** — the parser expects `resets <time>am/pm`; adjust the
  regex if the limit message changes.

A bash port (`scripts/night-watch.sh`) is a welcome contribution.

## How it was tested

- Reset-time parser: 10 cases incl. edge cases (`12am`, `12pm`, `11:59pm`,
  `at 9am`, day-of-week, and non-matching text) via the built-in `-SelfTest`.
- Control-flow guards proven to exit fast and safely: `stop.flag`, past
  `-Deadline`, and `-MaxResumes 0` — each without calling `claude` or hanging.
- Pure ASCII (PowerShell 5.1 reads UTF-8-without-BOM as ANSI and mis-parses
  smart quotes) and zero parse errors.

## Credit

The pattern follows the community example
[cys1750/claude-auto-resume](https://github.com/cys1750/claude-auto-resume);
this is an independent implementation with a stricter safety model (resume only
after an observed limit, one-shot, deadline, stop-flag) and packaged as an Agent
Skill.

## License

[MIT](LICENSE) © 2026 Bastiaan Kortenbout.
