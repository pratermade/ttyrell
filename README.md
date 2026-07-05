# ttyrell

A transparent PTY proxy with Lua scripting, session logging, and LLM integration. It sits between your terminal emulator and your shell and is completely invisible unless a plugin acts on something.

```
┌──────────────┐       ┌──────────────────────────────────┐       ┌─────────────────┐
│   Terminal   │◄─────►│            ttyrell             │◄─────►│  Shell / SSH    │
│  (any GUI)   │       │                                  │       │  (any shell)    │
└──────────────┘       │  intercepts input & output       │       └─────────────────┘
                       │  fires Lua events                │
                       │  logs full session transcript    │
                       │  calls LLM on demand             │
                       └──────────────────────────────────┘
```

SSH sessions are captured the same as local shells — all bytes flow through the proxy regardless of what's running inside.

---

## Table of contents

- [Installation](#installation)
- [Terminal setup](#terminal-setup)
- [Shell integration](#shell-integration)
- [LLM setup](#llm-setup)
- [Built-in plugins](#built-in-plugins)
- [Writing plugins](#writing-plugins)
- [API reference](#api-reference)
- [Log files](#log-files)
- [Cross-platform notes](#cross-platform-notes)
- [Troubleshooting](#troubleshooting)

---

## Installation

Requires Rust stable. No system Lua installation needed — Lua 5.5 is compiled from source.

```bash
git clone <repo>
cd ttyrell
cargo build --release
```

The binary is at `target/release/ttyrell` (or `ttyrell.exe` on Windows). **Run it once to launch the setup wizard:**

```
$ ./target/release/ttyrell

ttyrell installer  v0.3.0
══════════════════════════════════════════

  This will:
    • Copy ttyrell to ~/.local/bin/ttyrell
    • Write Lua config to ~/.config/ttyrell/lua
    • Create session log directory

  ? Proceed? [Y/n]:
```

The wizard:
- Copies the binary to your bin directory and warns if it isn't on `PATH`
- Prompts for an LLM provider (Local/OpenAI-compatible, OpenAI, Anthropic, or skip)
- Optionally sets up Obsidian vault integration for `workflow_journal`
- Offers to add shell integration to your rc file

To re-run the wizard (e.g. to change providers or reinstall): `ttyrell --install`

---

## Terminal setup

Tell your terminal to use `ttyrell` as its shell. It spawns your real shell internally: `$SHELL` on macOS/Linux. On Windows it uses `TTYRELL_SHELL` if set, otherwise detects the shell you launched it from (e.g. PowerShell), falling back to `%COMSPEC%` (cmd.exe).

**Ghostty** (`~/.config/ghostty/config`):

Open your Ghostty config with `ghostty +open-config` (or `Cmd+,` on macOS), then add:

```
command = /usr/local/bin/ttyrell
```

Verify the path first — if you used the installer, it's probably `~/.local/bin/ttyrell`:

```
command = /home/you/.local/bin/ttyrell
```

Ghostty natively supports OSC 133 shell integration sequences, so the `command_start`, `command_exit`, and `prompt_start` events work without any extra configuration once you source the [shell integration script](#shell-integration).

After saving, reload the config with `Cmd+Shift+,` (or restart Ghostty). Open a new tab or window to pick up the change — existing tabs continue using the old shell.

**WezTerm** (`~/.wezterm.lua`):
```lua
config.default_prog = { '/home/you/.local/bin/ttyrell' }
```

**Alacritty** (`~/.config/alacritty/alacritty.toml`):
```toml
[shell]
program = "/home/you/.local/bin/ttyrell"
```

**iTerm2**: Preferences → Profiles → General → Command → Custom shell → `/home/you/.local/bin/ttyrell`

**Windows Terminal** — open `settings.json` and add a new profile:
```json
{
  "name": "ttyrell",
  "commandline": "C:\\Users\\you\\AppData\\Local\\Programs\\ttyrell.exe",
  "hidden": false
}
```

Launched this way there is no invoking shell to detect, so ttyrell falls back to `cmd.exe`. To run PowerShell inside instead, set the shell explicitly — either add `"environment": { "TTYRELL_SHELL": "powershell.exe" }` to the profile, or set `TTYRELL_SHELL` as a user environment variable.

### Using ttyrell with tmux

ttyrell and tmux can be combined so that every tmux pane runs through the proxy. The recommended chain is:

```
Terminal → tmux (session manager) → ttyrell (per pane) → shell
```

This gives you tmux's session management and ttyrell's logging and AI features in every pane. Do **not** put ttyrell before tmux — it would only see raw tmux control bytes and shell integration events would not fire across pane boundaries.

**Setup:**

1. Keep your terminal's command set to launch tmux as normal. For Ghostty:
   ```
   command = /bin/zsh -c "tmux -f ~/.tmux.conf attach || tmux -f ~/.tmux.conf new-session"
   ```

2. Tell tmux to use `ttyrell` as the shell inside each pane. Add to `~/.tmux.conf`:
   ```
   set -g default-shell /home/you/.local/bin/ttyrell
   ```

3. Kill and reopen your tmux session to pick up the change. New panes will use ttyrell; existing panes will not.

ttyrell reads `$SHELL` to find your real shell, so zsh (or whichever shell you use) is still what runs inside each pane. Shell integration in `~/.zshrc` continues to work normally.

---

## Shell integration

Shell integration is **optional**. Without it, `session_log` and `ai_query` still work — you just won't get per-command boundaries, accurate exit codes, or CWD tracking. Source the integration script for your shell to enable those.

All scripts guard themselves with the `TTYRELL` environment variable and are inert when sourced outside the proxy.

The installer can add shell integration automatically. To add it manually:

### bash

Add to `~/.bashrc`:
```bash
export TTYRELL=1
source /path/to/ttyrell/shell/integration.bash
```

### zsh

Add to `~/.zshrc`:
```zsh
export TTYRELL=1
source /path/to/ttyrell/shell/integration.zsh
```

### fish

Copy or symlink to `~/.config/fish/conf.d/ttyrell.fish`:
```fish
cp /path/to/ttyrell/shell/integration.fish ~/.config/fish/conf.d/ttyrell.fish
```
Also add `set -x TTYRELL 1` to your fish config.

### PowerShell

Add to your `$PROFILE` (open with `notepad $PROFILE`):
```powershell
$env:TTYRELL = "1"
. C:\path\to\ttyrell\shell\integration.ps1
```

> **Note:** PowerShell has no pre-execution hook equivalent to bash's `PS0`, so `command_start` events are not emitted. `command_exit` and `prompt_start` work correctly.

### SSH sessions

Source the integration script on each remote machine you regularly SSH into. OSC 133 sequences are transparent to SSH — the proxy on your local machine receives them correctly.

```bash
# On the remote machine, add to ~/.bashrc:
export TTYRELL=1
source /path/to/ttyrell/shell/integration.bash
```

You do **not** need `ttyrell` installed on the remote machine. Only the shell integration script needs to be there.

---

## LLM setup

Edit `lua/init.lua` (in your config directory) to define your LLM providers in the `LLM` palette table. Plugins pick from this palette by name, so you can use different providers for different plugins.

```lua
LLM = {
    local_llama = {
        endpoint = "http://localhost:8083/v1/chat/completions",
        model    = "default",
    },
    claude = {
        endpoint = "https://api.anthropic.com/v1/messages",
        api_key  = os.getenv("ANTHROPIC_API_KEY"),
        model    = "claude-opus-4-8",
        headers  = function(cfg)
            return {
                ["x-api-key"]         = cfg.api_key,
                ["anthropic-version"] = "2023-06-01",
            }
        end,
        build_request = function(cfg, prompt, context)
            return {
                model      = cfg.model,
                max_tokens = 1024,
                system     = cfg.system_prompt,
                messages   = {{ role = "user", content = prompt .. (context and "\n\n" .. context or "") }},
            }
        end,
        parse_response = function(parsed)
            if not parsed.content or #parsed.content == 0 then return nil, "no content" end
            return parsed.content[1].text, nil
        end,
    },
}
```

Each plugin file declares which provider it uses at the top:

```lua
-- lua/plugins/ai_query.lua
AI_QUERY_LLM = LLM.local_llama

-- lua/plugins/workflow_journal.lua
JOURNAL_LLM = LLM.claude
```

The default provider table format is OpenAI-compatible. Override `headers`, `build_request`, and `parse_response` for APIs that differ (see the Anthropic example above).

---

## Built-in plugins

Plugins are loaded from `lua/plugins/` at startup. Each is optional — if the file is missing, it is silently skipped.

### session_log

Writes a full session transcript to the [session log directory](#session-log-locations). Captures every input line and every output chunk with timestamps. SSH sessions are captured automatically.

TUI applications (vim, htop, claude, etc.) are detected via the alternate screen buffer escape sequence and their output is not logged — only the command that launched the TUI and its exit code are recorded.

### ai_query

Press the hotkey (**Ctrl-G** by default) at any prompt to open an `[ai]> ` line. Type a question and press Enter; the query is sent to the LLM with recent session context and the response is printed inline. Press Esc or Ctrl-C to cancel.

```
[ai]> why is my Dockerfile build slow
[ai] thinking...
[ai] The most common cause is a large build context...
```

The keystrokes are intercepted and never reach the shell, so this works identically on cmd.exe, PowerShell, and POSIX shells. (Earlier versions used a `#ai:` text prefix, which relied on the line being a shell comment — that broke on cmd.exe, where `#` is not a comment.)

The model is told which shell and OS you are running, so suggested commands use the right syntax (PowerShell vs. bash, etc.). If the LLM can provide a complete runnable command it appends `EXEC: <cmd>` — ttyrell shows it and asks for confirmation (`y` or Enter to run) before running anything.

On Windows, ConPTY tracks the shell's screen with absolute coordinates, so anything ttyrell draws directly onto the main screen desynchronizes the cursor and garbles later output. To avoid that, the question prompt opens in a temporary full-screen overlay (the alternate screen buffer, like `less`); when you press Enter it's torn down, restoring your screen exactly. The response is then displayed *by the shell itself*: the answer is written to `%LOCALAPPDATA%\ttyrell\ai_last.txt` and ttyrell types a `type <file>` command at your prompt, so it lands inline in your scrollback with a fresh prompt automatically. When the response includes a runnable command, press `y` or Enter at that prompt to run it; `n`/Esc declines, and any other key just types normally.

Change the hotkey with `AI_QUERY_HOTKEY` (a byte value) in `init.lua`, e.g. `AI_QUERY_HOTKEY = 20` for Ctrl-T.

#### File references

Include file content in context by prefixing a path with `@`:

```
[ai]> @src/main.rs why is line 42 failing
[ai]> @Cargo.toml @src/lib.rs explain the dependency setup
[ai]> @logs/error.log what went wrong here
```

Paths are resolved relative to your shell's current working directory (tracked automatically via shell integration). Absolute paths also work.

#### Context settings

Set these in `init.lua` before the plugin loads (or in the plugin file itself):

| Variable | Default | Description |
|----------|---------|-------------|
| `AI_CONTEXT_COMMANDS` | `10` | Recent command/output pairs from the session log sent as context. `0` = disabled (falls back to raw output buffer). Lower for small local models. |
| `AI_CONTEXT_FILE_LINES` | `200` | Max lines read per `@file` reference. `0` = no limit. |
| `AI_CONTEXT_LINES` | `64` | Size of the raw output buffer used when `AI_CONTEXT_COMMANDS = 0` or no session log is available. |

```lua
-- init.lua — tune for a small local model
AI_CONTEXT_COMMANDS  = 5
AI_CONTEXT_FILE_LINES = 100
```

#### LLM provider

```lua
AI_QUERY_LLM = LLM.local_llama
```

### workflow_journal

At session end, spawns a background process that reads the session log, asks the LLM to group commands into named tasks, and appends the result to a running journal file.

Optional Obsidian integration writes each entry to a daily note in your vault.

```lua
JOURNAL_LLM            = LLM.claude
JOURNAL_OBSIDIAN_VAULT = "/path/to/your/vault"
JOURNAL_OBSIDIAN_DIR   = "Work Journal"   -- subdirectory inside the vault
```

The prompt that guides the journal entries is editable via `JOURNAL_PROMPT` in the plugin file — no Rust rebuild required.

---

## Writing plugins

See **[docs/writing-plugins.md](docs/writing-plugins.md)** for the full guide including event reference, API reference, module system, cross-platform considerations, and example plugins.

Quick start:

```lua
-- lua/plugins/my_plugin.lua
proxy.on("input", function(line)
    if line:match("^hello") then
        proxy.inject_output("\r\nHi there!\r\n")
        return "suppress"   -- don't forward to shell
    end
end)
```

Add `"my_plugin"` to the plugin list in `lua/init.lua`:
```lua
for _, name in ipairs({ "session_log", "ai_query", "workflow_journal", "my_plugin" }) do
    try_load(plugins .. "/" .. name)
end
```

---

## API reference

### Events

| Event | Arguments | Notes |
|-------|-----------|-------|
| `session_start` | `host, shell` | Fires once at proxy startup |
| `session_end` | — | Fires before proxy exits |
| `input` | `data` | Every stdin chunk. Return `"suppress"` to block. |
| `output` | `text` | ANSI-stripped PTY output chunks |
| `command_start` | — | Requires shell integration |
| `command_exit` | `exit_code` | Requires shell integration |
| `prompt_start` | — | Requires shell integration |
| `tui_start` | — | TUI app entered alternate screen (`ESC[?1049h`) |
| `tui_end` | — | TUI app left alternate screen (`ESC[?1049l`) |
| `cwd_changed` | `path` | Shell reported new CWD via OSC 7 (requires shell integration) |

### proxy global

```lua
proxy.on(event, fn)                       -- register event handler
proxy.on_task(name, fn)                    -- register a `ttyrell --task <name>` handler
proxy.inject_output(text)                 -- write text to terminal
proxy.spawn(cmd)                          -- run a shell command in the background (detached)
proxy.send_input(text)                    -- write text to the PTY as if typed
proxy.http_post(url, body [, headers])    -- returns status_code, body_string
proxy.json_encode(value)                  -- Lua value → JSON string
proxy.json_decode(string)                 -- JSON string → Lua value
proxy.spinner_start() / spinner_stop()    -- animated "thinking" indicator at the cursor
proxy.session_info.host                   -- hostname of local machine
proxy.session_info.shell                  -- shell path (e.g. /bin/zsh)
proxy.session_info.version                -- ttyrell version string
proxy.session_info.pid                    -- ttyrell process ID
```

### llm module

```lua
local llm = require("llm")

-- prompt  : the instruction or question
-- cfg     : a provider table from the LLM palette (e.g. LLM.local_llama)
-- context : optional data blob appended after the prompt (log output, file content, etc.)
local response, err = llm.query(prompt, cfg, context)
```

Provider tables support these fields:

| Field | Type | Default |
|-------|------|---------|
| `endpoint` | string | required |
| `model` | string | required |
| `api_key` | string | nil |
| `system_prompt` | string | `"You are a helpful terminal assistant. Be concise."` |
| `headers(cfg)` | function | Bearer token auth |
| `build_request(cfg, prompt, context)` | function | OpenAI chat completions format |
| `parse_response(parsed)` | function | OpenAI choices[0].message.content |

---

## Log files

### Config file locations

ttyrell loads `lua/init.lua` from the first path that exists:

| Platform | Path | Notes |
|----------|------|-------|
| macOS | `~/Library/Application Support/ttyrell/lua/init.lua` | checked first |
| macOS | `~/.config/ttyrell/lua/init.lua` | checked second |
| Linux | `~/.config/ttyrell/lua/init.lua` | |
| Windows | `%APPDATA%\ttyrell\lua\init.lua` | |
| Fallback | `~/.ttyrell/lua/init.lua` | |
| Dev fallback | `./lua/init.lua` (current directory) | |

### Session log locations

| Platform | Path |
|----------|------|
| macOS / Linux | `~/.local/share/ttyrell/sessions/` |
| Windows | `%LOCALAPPDATA%\ttyrell\sessions\` |

### Log format

Each session file is JSONL. One JSON object per line:

```json
{"type":"session_start","host":"mybox","shell":"/bin/zsh","t":"2025-01-15T14:23:01Z"}
{"type":"input","data":"ssh dev@server","t":"2025-01-15T14:23:05Z"}
{"type":"output","data":"Welcome to Ubuntu 22.04","exit_code":0,"t":"2025-01-15T14:23:06Z"}
{"type":"session_end","t":"2025-01-15T14:45:22Z"}
```

TUI commands (vim, htop, etc.) produce an `output` entry with no `data` field — the screen content is intentionally not logged.

---

## Cross-platform notes

### Windows

- Use `\r\n` in `proxy.inject_output` for correct line breaks in the terminal.
- Home directory is `os.getenv("USERPROFILE")` — `os.getenv("HOME")` may be unset.
- Data files (session logs, journal) are written to `%LOCALAPPDATA%\ttyrell\`.
- Path separator is `\` but Lua's `io` functions accept `/` on Windows.
- `os.execute("mkdir -p path")` does not work; use `os.execute("mkdir path 2>nul")`.
- `command_start` events are not available in PowerShell (no PS0 equivalent).
- `cmd.exe` has no shell integration support.

### macOS / Linux

- Home directory is `os.getenv("HOME")`.
- `\r\n` and `\n` both work in `proxy.inject_output` but `\r\n` is safer in raw PTY mode.
- On Linux, `fish` conf.d path respects `$XDG_CONFIG_HOME` if set.

### SSH sessions

Shell integration on remote machines is optional. Without it, all input and output is still captured via the `input` and `output` events — just without per-command boundaries or CWD tracking. The remote hostname appears naturally in prompt output (e.g. `user@remote:~$`), making sessions self-documenting in the log.

---

## Troubleshooting

**proxy.inject_output text appears on the wrong line**
Use `\r\n` instead of `\n`. The terminal is in raw mode.

**Lua errors appear on stderr but the proxy keeps running**
This is expected. Each handler error is caught and printed; it does not crash the proxy or affect other plugins.

**init.lua is not loading**
Check that the file exists at one of the config paths above. The proxy prints `Failed to load init.lua: ...` to stderr on error.

**ai_query / workflow_journal does nothing**
Each plugin needs an LLM provider assigned. Check that the `LLM` palette in `init.lua` has an entry for the provider the plugin references, and that the plugin file sets its `*_LLM` variable. Test by pressing Ctrl-G and asking `hello`.

**`@file` says "cannot open"**
Paths resolve relative to the shell's CWD, which requires shell integration to be loaded. Without it, paths resolve relative to where ttyrell was launched. Use an absolute path to confirm the file is readable.

**Session log is not being created**
Check that `$HOME` (macOS/Linux) or `%LOCALAPPDATA%` (Windows) is set. Check stderr for `[session_log] cannot open log:` messages.

**Shell integration not firing command_exit**
Verify `TTYRELL=1` is exported before sourcing the integration script. Check that the script is being sourced, not executed (`source integration.bash`, not `./integration.bash`).

**Journal not writing after session ends**
Check stderr for `[journal] JOURNAL_PROMPT not set` — this means `workflow_journal.lua` was not loaded. Verify it appears in the plugin list in `init.lua`.

**TUI apps (vim, claude, etc.) leave garbage in the session log**
This should not happen — ttyrell detects alternate screen entry (`ESC[?1049h`) and suppresses output buffering automatically. If you see garbage, the TUI may not be using the alternate screen buffer.
