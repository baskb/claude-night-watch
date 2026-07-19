# night-watch - Claude Code session auto-resume

Automatically resume a headless **Claude Code** session **once** after the
5-hour usage window resets, so a long unattended run finishes on its own.

Claude Code has no native auto-resume across the usage limit (Anthropic closed
that feature request as *"not planned"*). This is a small, safe PowerShell
watcher that fills the gap — plus a packaged [Agent Skill](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/overview)
so Claude itself knows when and how to set it up.

> **One-shot safety net, not a loop.** It resumes **only** after it has actually
> observed a usage limit, only the **session that hit it**, and only on a clean
> successful probe (a CLI/auth/network error is never mistaken for a reset).
> After a resume it needs a fresh observed limit before running again, so it does
> not re-run finished work or drain windows. A session that simply finished is
> never woken.

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
2. **Probe + pin** when the transcript goes stale: run a cheap `claude -p` on
   Haiku and check the reply for a usage-limit message. If limited, **pin that
   session** and parse the reset time (`resets 3:45pm` or `in 3 hours` — an
   unofficial format, so there is a 30-minute fallback when it cannot be parsed).
3. **Wait** until the reset, then probe again. Only a **clean, successful,
   non-limited reply** (exit 0 with an `OK` body) counts as "window open"; a
   transient CLI/auth/network error does not.
4. **Resume** the **pinned** session once, headless, after a final freshness
   re-check: `claude -p "<your prompt>" --resume <id>` from the project
   directory. Then clear the observed-limit flag — a further resume
   (`-MaxResumes > 1`) requires observing a **new** limit first.

## Safety model (the important part)

- **Only resumes after a limit was actually observed** — and only the **session
  that hit it** (pinned when the limit is seen). A session that simply finished,
  is waiting on you, or came back to life during the wait is never woken.
- **"Window open" needs a positive signal**, not merely the absence of a limit:
  the confirm-probe must exit 0 with an `OK` reply. A transient CLI/auth/network
  error is neither "limited" nor "open", so it cannot trigger a resume — it just
  retries.
- **No re-running finished work.** After each resume the observed-limit flag is
  reset, so even with `-MaxResumes > 1` a further resume requires a **new**
  observed limit.
- **`stop.flag`** — drop an empty file of that name next to the script to stop it
  immediately (honoured during waits too).
- **Hard `-Deadline`** (default next 09:30) ends the watch no matter what,
  including mid-sleep.
- **`-MaxResumes 1`** by default — no loop.
- **Everything is logged** to `night-watch.log` next to the script.
- **The resumed run's permission mode is an explicit opt-in per run**
  (`-SkipPermissions`). Unattended runs usually need it (otherwise they hang on
  the first permission prompt), but it is **off by default**. **With it on, the
  resumed run can write files, commit and push with no human in the loop, and
  its full output is appended to `night-watch.log` — which may capture secrets.**
  Your `-ResumePrompt` is the only guardrail: say plainly what the run must
  **not** do, and do not point it at a repo you would not want touched
  unattended.

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
cp -r . <your-project>/.claude/skills/night-watch

# or user-scoped, available in every project
cp -r . ~/.claude/skills/night-watch
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

- Reset-time parser: 12 cases via the built-in `-SelfTest`, incl. edge cases
  (`12am`, `12pm`, `11:59pm`, `at 9am`), weekday scheduling (`Sun 6pm`,
  `Fri 8am` -> the next occurrence of that day), a relative duration
  (`try again in 3 hours`), and non-matching text.
- Control-flow guards proven to exit fast and safely: `stop.flag`, past
  `-Deadline`, and `-MaxResumes 0` — each without calling `claude` or hanging.
- Pure ASCII (PowerShell 5.1 reads UTF-8-without-BOM as ANSI and mis-parses
  smart quotes) and zero parse errors.

The `evals/` folder holds **manual** trigger/behaviour prompts (skill-creator
format) for reviewing how the skill responds — they are expectations, not
automated assertions. The parser and guard checks above are the automated part.

## Credit

The pattern follows the community example
[cys1750/claude-auto-resume](https://github.com/cys1750/claude-auto-resume);
this is an independent implementation with a stricter safety model (resume only
after an observed limit, one-shot, deadline, stop-flag) and packaged as an Agent
Skill.

## License

[MIT](LICENSE) © 2026 Bastiaan Kortenbout.
