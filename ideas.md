# Plugin Ideas

## High Value, Low Effort

### `notify.lua`
macOS notification via `osascript` when a command takes longer than N seconds.
Track start time on `input`, fire on the next output flush. Practical for builds,
deploys, and long-running `curl` requests.

### `secret_guard.lua`
Scan `input` for patterns matching AWS keys, GitHub tokens, `export PASSWORD=`, etc.
Warn before secrets land in the session log on disk. Security-critical given that
logs are written to `~/.local/share/ttyrell/sessions/`.

### `command_timer.lua`
Inject elapsed time after commands that exceed a threshold — e.g. `[3.2s]`.
Uses timestamps from `input` → `output`. No external dependencies.

---

## Medium Effort, High Payoff

### `alias_suggest.lua`
Track command frequency within a session. If you type the same long command 3+
times, suggest an alias via `proxy.inject_output`. The session log already has
all the data needed.

### `watchdog.lua`
Scan `output` for patterns like `error:`, `FATAL`, `panic:`, `OOM`, `segfault`
and immediately inject a highlighted warning inline. Useful for catching failures
that scroll past unnoticed.

### `git_context.lua`
On each `input`, detect if we're in a git repo and attach the current branch and
dirty status to the session log entry. Gives the AI session summary significantly
better context about what was being worked on.

---

## Bigger Ideas

### `workflow_journal.lua`
Instead of one flat summary per session, use the AI to group commands into named
tasks ("set up database", "debugged auth flow") and produce a structured work log.
Useful for standups and time tracking.

### `output_capture.lua`
`#save <name>` prefix saves the last command's output to a named file. Simple
state machine similar to `ai_query.lua`. Could also support `#save` with no name
to auto-generate a filename from the command.
