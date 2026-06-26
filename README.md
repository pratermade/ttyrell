# ttyrell

[![CI](https://github.com/your-repo/ttyrell/actions/workflows/ci.yml/badge.svg)](https://github.com/your-repo/ttyrell/actions/workflows/ci.yml)

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
# binary: target/release/ttyrell  (target/release/ttyrell.exe on Windows)
```

Copy the binary somewhere on your PATH, then copy `lua/` to your config directory (see [Config file locations](#config-file-locations)).

---

## Terminal setup

Tell your terminal to use `ttyrell` as its shell. It spawns your real `$SHELL` (or `%COMSPEC%` on Windows) internally.

**Ghostty** (`~/.config/ghostty/config`):

Open your Ghostty config with `ghostty +open-config` (or `Cmd+,` on macOS), then add:

```
command = /usr/local/bin/ttyrell
```

Verify the path first — if you installed from source, use `which ttyrell` and substitute the output:

```
command = /Users/you/.cargo/bin/ttyrell
```

Ghostty natively supports OSC 133 shell integration sequences, so the `command_start`, `command_exit`, and `prompt_start` events work without any extra configuration once you source the [shell integration script](#shell-integration).

After saving, reload the config with `Cmd+Shift+,` (or restart Ghostty). Open a new tab or window to pick up the change — existing tabs continue using the old shell.

**WezTerm** (`~/.wezterm.lua`):
```lua
config.default_prog = { '/usr/local/bin/ttyrell' }
```

**Alacritty** (`~/.config/alacritty/alacritty.toml`):
```toml
[shell]
program = "/usr/local/bin/ttyrell"
```

**iTerm2**: Preferences → Profiles → General → Command → Custom shell → `/usr/local/bin/ttyrell`

**Windows Terminal** — open `settings.json` and add a new profile:
```json
{
  "name": "ttyrell",
  "commandline": "C:\\Users\\you\\bin\\ttyrell.exe",
  "hidden": false
}
```

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
   set -g default-shell /usr/local/bin/ttyrell
   ```
   Verify the path with `which ttyrell` and substitute if different.

3. Kill and reopen your tmux session to pick up the change. New panes will use ttyrell; existing panes will not.

ttyrell reads `$SHELL` to find your real shell, so zsh (or whichever shell you use) is still what runs inside each pane. Shell integration in `~/.zshrc` continues to work normally.

---

## Shell integration

Shell integration is **optional**. Without it, `session_log`, `ai_query`, and `error_help` all work — you just won't get per-command boundaries or accurate exit codes. Source the integration script for your shell to enable those.

All scripts guard themselves with the `TTYRELL` environment variable and are inert when sourced outside the proxy.

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

Edit `lua/init.lua` (in your config directory) and uncomment a provider block:

```lua
local llm = require("llm")

-- Local llama-server (no auth, OpenAI-compatible):
llm.setup({
    endpoint = "http://localhost:8083/v1/chat/completions",
    model    = "default",
})
```

See [docs/llm-providers.md](docs/llm-providers.md) for OpenAI, Anthropic, Ollama, and custom provider configuration.

---

## Built-in plugins

Plugins are loaded from `lua/plugins/` at startup. Each is optional — if the file is missing, it is silently skipped.

### session_log

Writes a full session transcript to `~/.local/share/ttyrell/sessions/YYYY-MM-DD_HH-MM-SS.jsonl`. Captures every input line and every output chunk with timestamps. SSH sessions are captured automatically.

On session end, if an LLM provider is configured, reads the log back, sends it with a structured summary prompt, and writes the result to `~/.local/share/ttyrell/summaries/`.

### ai_query

Type `#ai: <question>` at any prompt. The line is intercepted, sent to the LLM, and the response is printed inline. The line is never forwarded to the shell.

```
$ #ai: why is my Dockerfile build slow
[ai] thinking...
[ai] The most common cause is a large build context...
```

Requires an LLM provider to be configured in `init.lua`.

### error_help

On any non-zero exit code, sends the last 40 lines of terminal output to the LLM and prints a specific suggestion. Ignores commands where non-zero is routine: `grep`, `diff`, `test`, `false`, `[`, `:`.

Requires an LLM provider to be configured in `init.lua`.

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
for _, name in ipairs({ "session_log", "ai_query", "error_help", "my_plugin" }) do
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

### proxy global

```lua
proxy.on(event, fn)                       -- register event handler
proxy.inject_output(text)                 -- write text to terminal
proxy.http_post(url, body [, headers])    -- returns status_code, body_string
proxy.json_encode(value)                  -- Lua value → JSON string
proxy.json_decode(string)                 -- JSON string → Lua value
proxy.session_info.host                   -- hostname of local machine
proxy.session_info.shell                  -- shell path (e.g. /bin/zsh)
proxy.session_info.version                -- ttyrell version string
proxy.session_info.pid                    -- ttyrell process ID
```

### llm module

```lua
local llm = require("llm")
llm.setup({ endpoint, model, api_key, system_prompt, headers, build_request, parse_response })
local response, err = llm.query("your prompt")
```

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

The first path that exists on disk is used.

### Session log locations

| Platform | Path |
|----------|------|
| macOS / Linux | `~/.local/share/ttyrell/sessions/` |
| Windows | `%USERPROFILE%\.local\share\ttyrell\sessions\` |

### Log format

Each session file is JSONL. One JSON object per line:

```json
{"type":"session_start","host":"mybox","shell":"/bin/zsh","t":"2025-01-15T14:23:01Z"}
{"type":"input","data":"ssh dev@server\n","t":"2025-01-15T14:23:05Z"}
{"type":"output","data":"dev@server:~$ ","t":"2025-01-15T14:23:06Z"}
{"type":"command_exit","exit_code":0,"t":"2025-01-15T14:23:10Z"}
{"type":"session_end","t":"2025-01-15T14:45:22Z"}
```

---

## Cross-platform notes

### Windows

- Use `\r\n` in `proxy.inject_output` for correct line breaks in the terminal.
- Home directory is `os.getenv("USERPROFILE")` — `os.getenv("HOME")` may be unset.
- Path separator is `\` but Lua's `io` functions accept `/` on Windows.
- `os.execute("mkdir -p path")` does not work; use `os.execute("mkdir path 2>nul")` or check existence first.
- `command_start` events are not available in PowerShell (no PS0 equivalent).
- `cmd.exe` has no shell integration support.

### macOS / Linux

- Home directory is `os.getenv("HOME")`.
- `\r\n` and `\n` both work in `proxy.inject_output` but `\r\n` is safer in raw PTY mode.

### SSH sessions

Shell integration on remote machines is optional. Without it, all input and output is still captured via the `input` and `output` events — just without per-command boundaries. The remote hostname appears naturally in prompt output (e.g. `user@remote:~$`), making sessions self-documenting in the log.

---

## Troubleshooting

**proxy.inject_output text appears on the wrong line**
Use `\r\n` instead of `\n`. The terminal is in raw mode.

**Lua errors appear on stderr but the proxy keeps running**
This is expected. Each handler error is caught and printed; it does not crash the proxy or affect other plugins.

**init.lua is not loading**
Check that the file exists at one of the config paths above. The proxy prints `Failed to load init.lua: ...` to stderr on error.

**ai_query / error_help does nothing**
An LLM provider must be configured. Uncomment and edit the `llm.setup()` block in `init.lua`. Test with `#ai: hello`.

**Session log is not being created**
Check that `$HOME` (macOS/Linux) or `%USERPROFILE%` (Windows) is set. Check stderr for `[session_log] cannot open log:` messages.

**Shell integration not firing command_exit**
Verify `TTYRELL=1` is exported before sourcing the integration script. Check that the script is being sourced, not executed (`source integration.bash`, not `./integration.bash`).
