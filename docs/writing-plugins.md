# Writing ttyrell plugins

Plugins are Lua files in `lua/plugins/`. They are loaded once at startup and register callbacks via `proxy.on()`. Everything runs on the proxy's main thread — callbacks fire synchronously as events arrive.

---

## Table of contents

- [How plugins are loaded](#how-plugins-are-loaded)
- [Your first plugin](#your-first-plugin)
- [Event reference](#event-reference)
- [proxy API reference](#proxy-api-reference)
- [Input suppression](#input-suppression)
- [The llm module](#the-llm-module)
- [HTTP calls](#http-calls)
- [JSON encoding and decoding](#json-encoding-and-decoding)
- [Module system](#module-system)
- [Error handling](#error-handling)
- [Cross-platform considerations](#cross-platform-considerations)
- [Example plugins](#example-plugins)

---

## How plugins are loaded

`lua/init.lua` is the entry point. It sets up `package.path`, configures the LLM provider, then calls `try_load()` for each plugin:

```lua
for _, name in ipairs({ "session_log", "ai_query", "workflow_journal" }) do
    try_load(plugins .. "/" .. name)
end
```

`try_load` calls `loadfile` then `pcall`, so a broken plugin does not crash the proxy or affect other plugins. Missing files are silently skipped.

Add your plugin name to that list. Order matters — plugins registered first receive events first.

---

## Your first plugin

Create `lua/plugins/hello.lua`:

```lua
-- hello.lua — greet the user at startup
proxy.on("session_start", function(host, shell)
    proxy.inject_output(string.format(
        "\r\n[hello] welcome to %s running %s\r\n\r\n",
        host, shell
    ))
end)
```

Add `"hello"` to the plugin list in `init.lua`, restart the terminal, and the greeting appears above the first prompt.

---

## Event reference

All events fire on the main thread. Handlers run one at a time, in registration order.

---

### session_start

```lua
proxy.on("session_start", function(host, shell) end)
```

Fires once immediately at proxy startup, before the first prompt.

| Argument | Type | Description |
|----------|------|-------------|
| `host` | string | Hostname of the local machine |
| `shell` | string | Full path of the shell being run (e.g. `/bin/zsh`, `powershell.exe`) |

Also available at any time via the `proxy.session_info` table.

---

### session_end

```lua
proxy.on("session_end", function() end)
```

Fires when the shell exits or the terminal is closed. Use this to flush files, write summaries, or send notifications. The PTY is already closed at this point; `proxy.inject_output` writes to stdout which may or may not still be connected to a terminal.

---

### input

```lua
proxy.on("input", function(data) end)
```

Fires for every chunk of data the user types. In interactive use each chunk is typically one keypress or a pasted line, but this is not guaranteed — data can arrive in arbitrary sizes.

| Argument | Type | Description |
|----------|------|-------------|
| `data` | string | Raw bytes received from stdin |

**Return `"suppress"` (or `"drop"`) to block the input from reaching the shell.** Any other return value (including `nil`) lets the input through.

```lua
proxy.on("input", function(data)
    if data:byte(1) == 7 then   -- Ctrl-G
        -- handle it here
        return "suppress"   -- don't forward to shell
    end
    -- implicit nil return — input passes through
end)
```

If multiple handlers are registered and any returns `"suppress"`, the input is blocked.

---

### output

```lua
proxy.on("output", function(text) end)
```

Fires for every chunk of terminal output after ANSI/VT escape sequences have been stripped. The text is human-readable but may include partial lines, carriage returns (`\r`), and other control characters.

| Argument | Type | Description |
|----------|------|-------------|
| `text` | string | ANSI-stripped text from the PTY |

> The raw bytes are written to the terminal *before* this event fires, so the output event is purely for observation — you cannot modify or suppress PTY output.

---

### command_start

```lua
proxy.on("command_start", function() end)
```

Fires when the shell reports that a command is about to execute. **Requires shell integration** — the shell must source `shell/integration.bash` (or `.zsh` / `.fish`) to emit OSC 133 C sequences.

Not available in PowerShell or `cmd.exe`.

---

### command_exit

```lua
proxy.on("command_exit", function(exit_code) end)
```

Fires when the shell reports that a command has finished. **Requires shell integration.**

| Argument | Type | Description |
|----------|------|-------------|
| `exit_code` | string | Exit code as a string, e.g. `"0"`, `"127"` |

Always convert with `tonumber()`:
```lua
proxy.on("command_exit", function(exit_code)
    local code = tonumber(exit_code) or -1
    if code ~= 0 then
        -- handle failure
    end
end)
```

---

### prompt_start

```lua
proxy.on("prompt_start", function() end)
```

Fires just before the shell renders a new prompt. **Requires shell integration.** Useful for per-prompt work like checking whether a daily summary is due.

---

## proxy API reference

---

### proxy.on(event, fn)

Register an event handler. Multiple handlers for the same event are called in registration order.

```lua
proxy.on("input", function(data)
    -- ...
end)
```

Handlers can be registered from within other handlers (e.g., inside `session_start`). The registry lock is released before callbacks are invoked, so this is safe.

---

### proxy.inject_output(text)

Write text directly to the terminal, bypassing the shell. The text appears inline in the terminal output.

```lua
proxy.inject_output("\r\n[plugin] hello\r\n")
```

**Always use `\r\n` for line breaks**, not `\n` alone. The terminal is in raw PTY mode on all platforms, and `\n` without `\r` will advance the cursor down but not return it to the left margin.

---

### proxy.http_post(url, body [, headers])

Make a blocking HTTP POST request. Returns two values: the HTTP status code (integer) and the response body (string).

```lua
local status, body = proxy.http_post(
    "https://api.example.com/endpoint",
    '{"key":"value"}',
    { ["Authorization"] = "Bearer " .. api_key }
)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `url` | string | Full URL including scheme |
| `body` | string | Request body (sent as-is) |
| `headers` | table (optional) | Additional headers. `Content-Type: application/json` is set automatically. |

**Return values:**

| Value | Type | Description |
|-------|------|-------------|
| `status` | integer | HTTP status code (200, 404, 500, etc.) |
| `body` | string | Response body |

HTTP 4xx and 5xx responses are **not** errors — they return the status and body normally. Only transport failures (connection refused, timeout, DNS failure) raise a Lua error. Always use `pcall`:

```lua
local ok, status, body = pcall(proxy.http_post, url, payload, headers)
if not ok then
    -- status contains the error message string here
    print("connection failed: " .. tostring(status))
    return
end
if status ~= 200 then
    print("HTTP error: " .. status)
    return
end
-- use body
```

The timeout is 30 seconds.

---

### proxy.json_encode(value)

Encode a Lua value as a JSON string. Raises a Lua error on failure.

```lua
local json = proxy.json_encode({
    name = "test",
    values = { 1, 2, 3 },
    active = true,
})
-- '{"active":true,"name":"test","values":[1,2,3]}'
```

Lua types map to JSON as follows:

| Lua | JSON |
|-----|------|
| `nil` | `null` |
| `boolean` | `true` / `false` |
| `number` | number |
| `string` | string |
| `table` (array) | array |
| `table` (hash) | object |

---

### proxy.json_decode(string)

Decode a JSON string into a Lua value. Raises a Lua error on invalid JSON.

```lua
local data = proxy.json_decode('{"name":"test","count":42}')
print(data.name)   -- "test"
print(data.count)  -- 42
```

Use `pcall` when decoding untrusted input:

```lua
local ok, data = pcall(proxy.json_decode, raw_json)
if not ok then
    print("invalid JSON: " .. tostring(data))
    return
end
```

---

### proxy.session_info

A table populated at startup with information about the current session. Available from the moment `session_start` fires.

```lua
proxy.session_info.host     -- "my-macbook"
proxy.session_info.shell    -- "/bin/zsh"
proxy.session_info.version  -- "0.3.0"
proxy.session_info.pid      -- 12345
```

---

## Input suppression

Returning `"suppress"` from an `input` handler blocks the data from being forwarded to the shell. Use this to implement custom commands that the shell never sees.

```lua
proxy.on("input", function(data)
    -- Intercept lines starting with "!!"
    if data:match("^!!") then
        local cmd = data:gsub("^!!%s*", ""):gsub("%s+$", "")
        proxy.inject_output("\r\n[custom] running: " .. cmd .. "\r\n")
        -- do something with cmd...
        return "suppress"
    end
end)
```

The `data` argument is the raw bytes received from stdin. In interactive use this is typically one line (including the newline character), but terminal pastes and programmatic input can arrive in larger or smaller chunks. Match on line content with care.

---

## The llm module

`lua/llm.lua` provides a provider-agnostic wrapper around `proxy.http_post`. Require it from any plugin:

```lua
local llm = require("llm")
```

### llm.setup(opts)

Configure the active provider. Must be called in `init.lua` before plugins that use `llm.query` are loaded. See [docs/llm-providers.md](llm-providers.md) for all provider configurations.

```lua
llm.setup({
    endpoint     = "http://localhost:8083/v1/chat/completions",
    model        = "default",
    system_prompt = "You are a helpful assistant.",  -- optional
})
```

### llm.query(prompt)

Send a prompt and return the response. **Blocking** — the proxy event loop pauses until the LLM responds. Keep usage to user-initiated or infrequent events.

```lua
local response, err = llm.query("explain exit code 127")
if err then
    proxy.inject_output("\r\n[plugin] LLM error: " .. err .. "\r\n")
else
    proxy.inject_output("\r\n[plugin] " .. response .. "\r\n")
end
```

Returns `response, nil` on success or `nil, error_string` on failure. Always check for `err` before using `response`.

---

## HTTP calls

`proxy.http_post` gives you a general-purpose HTTP primitive. You can use it to call any API, not just LLMs — webhooks, monitoring endpoints, Slack, etc.

```lua
-- POST to a webhook
local ok, status, _ = pcall(proxy.http_post,
    "https://hooks.slack.com/services/...",
    proxy.json_encode({
        text = "ttyrell: command failed with code " .. exit_code
    })
)
```

Only POST is supported. For GET requests, encode parameters in the URL. If you need GET support, consider adding it to `lua_api.rs` as `proxy.http_get(url [, headers])` — it would be ~10 lines of Rust following the same pattern.

---

## JSON encoding and decoding

`proxy.json_encode` and `proxy.json_decode` handle all JSON needs within plugins. You do not need a separate JSON library.

**Encoding a log entry:**
```lua
local entry = proxy.json_encode({
    type      = "event",
    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    data      = { host = proxy.session_info.host },
})
```

**Decoding an API response:**
```lua
local ok, parsed = pcall(proxy.json_decode, response_body)
if not ok then return nil, "bad JSON" end
local text = parsed.choices and parsed.choices[1].message.content
```

---

## Module system

`lua/init.lua` adds the `lua/` directory to `package.path` before loading plugins:

```lua
package.path = package.path .. ";" .. base .. "/?.lua"
```

This means any `.lua` file in `lua/` can be `require`d by name. The built-in `llm` module (`lua/llm.lua`) works this way:

```lua
local llm = require("llm")
```

You can create your own shared modules the same way:

```lua
-- lua/utils.lua
local M = {}

function M.home()
    return os.getenv("HOME") or os.getenv("USERPROFILE") or ""
end

function M.log_dir()
    return M.home() .. "/.local/share/ttyrell"
end

return M
```

```lua
-- lua/plugins/my_plugin.lua
local utils = require("utils")
local log_dir = utils.log_dir()
```

`require` caches modules — `require("llm")` called from multiple plugins returns the same table. `llm.setup()` in `init.lua` configures it once for all.

---

## Error handling

Errors inside event handlers are caught by the proxy and printed to stderr. The proxy keeps running and other plugins are unaffected.

```
Lua error in input handler: attempt to index a nil value (global 'llm')
```

For expected failures (network calls, file I/O, optional dependencies), use `pcall`:

```lua
local ok, result = pcall(require, "llm")
if not ok then
    -- llm module not available, degrade gracefully
    return
end
```

For user-visible errors, inject them into the terminal:

```lua
local ok, status, body = pcall(proxy.http_post, url, payload)
if not ok then
    proxy.inject_output("\r\n[plugin] request failed: " .. tostring(status) .. "\r\n")
    return
end
```

---

## Cross-platform considerations

### Line endings in inject_output

Always use `\r\n`, not `\n`, when injecting multi-line text. Raw PTY mode on all platforms requires the carriage return:

```lua
proxy.inject_output("\r\nline one\r\nline two\r\n")
```

### Home directory

`os.getenv("HOME")` is unset on some Windows configurations. Always fall back to `USERPROFILE`:

```lua
local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
if home == "" then
    -- handle missing home
    return
end
```

### Directory creation

`os.execute("mkdir -p path")` works on macOS and Linux but not Windows. For cross-platform directory creation:

```lua
local function mkdir(path)
    if package.config:sub(1,1) == '\\' then
        -- Windows
        os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
    else
        os.execute("mkdir -p '" .. path .. "'")
    end
end
```

### Path separators

Use `/` in paths — Lua's `io` functions accept forward slashes on all platforms including Windows. Only use `\\` when constructing paths for `os.execute` shell commands on Windows.

### Shell availability

`os.execute` and `io.popen` invoke a shell (`sh` on Unix, `cmd.exe` on Windows). Commands must be appropriate for the platform. Wrap platform-specific calls:

```lua
local is_windows = package.config:sub(1,1) == '\\'

if is_windows then
    os.execute('powershell -command "..."')
else
    os.execute('osascript -e "..."')
end
```

### command_start availability

`command_start` requires shell integration. It is not available in PowerShell, `cmd.exe`, or on remote machines without the integration script sourced. Plugins that depend on it should degrade gracefully when it does not fire.

---

## Example plugins

### Command timer

Prints elapsed time for any command that takes more than 5 seconds. Requires shell integration.

```lua
-- lua/plugins/timer.lua
local start_time = nil

proxy.on("command_start", function()
    start_time = os.time()
end)

proxy.on("command_exit", function()
    if not start_time then return end
    local elapsed = os.time() - start_time
    start_time = nil
    if elapsed >= 5 then
        proxy.inject_output(
            string.format("\r\n[timer] %ds\r\n", elapsed)
        )
    end
end)
```

---

### SSH session logger

Detects when you SSH into a remote machine and logs the connection.

```lua
-- lua/plugins/ssh_log.lua
local home  = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
local logf  = home ~= "" and io.open(home .. "/.local/share/ttyrell/ssh.log", "a") or nil
local active_host = nil

local function log(msg)
    if logf then
        logf:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. msg .. "\n")
        logf:flush()
    end
end

proxy.on("input", function(data)
    -- Detect: ssh user@host  or  ssh host
    local host = data:match("^%s*ssh%s+[^@%s]+@(%S+)")
                 or data:match("^%s*ssh%s+([%w%.%-]+)%s*[\r\n]")
    if host then
        active_host = host
        log("connected to " .. host)
    end
    -- Detect exit / logout from the current session
    if active_host and data:match("^%s*exit%s*[\r\n]") then
        log("disconnected from " .. active_host)
        active_host = nil
    end
end)

proxy.on("session_end", function()
    if logf then logf:close() end
end)
```

---

### Desktop notification on long command

Sends a native OS notification when a command runs longer than 30 seconds. Requires shell integration.

```lua
-- lua/plugins/notify.lua
local THRESHOLD = 30
local start_time = nil
local is_windows = package.config:sub(1,1) == '\\'

local function notify(msg)
    if is_windows then
        os.execute(string.format(
            'powershell -WindowStyle Hidden -command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show(\'%s\')" 2>nul',
            msg:gsub("'", "")
        ))
    elseif os.execute("which osascript >/dev/null 2>&1") == 0 then
        os.execute(string.format("osascript -e 'display notification \"%s\"' 2>/dev/null", msg))
    else
        os.execute(string.format("notify-send 'ttyrell' '%s' 2>/dev/null", msg))
    end
end

proxy.on("command_start", function()
    start_time = os.time()
end)

proxy.on("command_exit", function(exit_code)
    if not start_time then return end
    local elapsed = os.time() - start_time
    start_time = nil
    if elapsed >= THRESHOLD then
        notify(string.format("Done in %ds (exit %s)", elapsed, exit_code))
    end
end)
```

---

### Webhook on failure

POSTs a JSON payload to a webhook URL whenever a command exits non-zero. Set `TTYRELL_WEBHOOK` in your environment.

```lua
-- lua/plugins/webhook.lua
local url = os.getenv("TTYRELL_WEBHOOK") or ""
if url == "" then return end  -- disabled

proxy.on("command_exit", function(exit_code)
    local code = tonumber(exit_code) or -1
    if code == 0 then return end

    local ok, body = pcall(proxy.json_encode, {
        host      = proxy.session_info.host,
        shell     = proxy.session_info.shell,
        exit_code = code,
        time      = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    })
    if not ok then return end

    pcall(proxy.http_post, url, body)
end)
```

---

### Custom LLM command

Adds a `#ask:` prefix that uses a different system prompt than the built-in `ai_query`.

```lua
-- lua/plugins/ask_senior.lua
local llm = require("llm")

proxy.on("input", function(data)
    if not data:match("^#ask:") then return end

    local question = data:gsub("^#ask:%s*", ""):gsub("%s+$", "")
    if question == "" then return "suppress" end

    proxy.inject_output("\r\n[ask] thinking...\r\n")

    local response, err = llm.query(
        "You are a senior systems engineer reviewing a junior's work. " ..
        "Be direct, precise, and explain the 'why'. Question: " .. question
    )

    if err then
        proxy.inject_output("[ask] error: " .. err .. "\r\n")
    else
        proxy.inject_output("[ask] " .. response .. "\r\n")
    end

    return "suppress"
end)
```

---

### Prompt-based daily summary

Checks on each `prompt_start` whether today's summary has been generated. Requires shell integration and an LLM provider.

```lua
-- lua/plugins/daily_summary.lua
local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
if home == "" then return end

local base_dir    = home .. "/.local/share/ttyrell"
local session_dir = base_dir .. "/sessions"
local summary_dir = base_dir .. "/summaries"
local last_check  = nil

proxy.on("prompt_start", function()
    local today = os.date("%Y-%m-%d")
    local hour  = tonumber(os.date("%H"))

    -- Only run once per day, after 5pm
    if hour < 17 or last_check == today then return end
    last_check = today

    local summary_file = summary_dir .. "/" .. today .. "_daily.txt"
    -- Skip if already done today
    local existing = io.open(summary_file, "r")
    if existing then existing:close(); return end

    -- Collect all session files from today
    local lines = {}
    -- Note: Lua doesn't have a built-in glob; use io.popen as a platform-specific fallback
    local is_windows = package.config:sub(1,1) == '\\'
    local find_cmd = is_windows
        and string.format('dir /b "%s\\%s_*.jsonl" 2>nul', session_dir:gsub("/","\\"), today)
        or  string.format('ls "%s"/%s_*.jsonl 2>/dev/null', session_dir, today)

    local pipe = io.popen(find_cmd)
    if not pipe then return end

    for fname in pipe:lines() do
        local path = is_windows and fname or (session_dir .. "/" .. fname)
        local f = io.open(path, "r")
        if f then
            for line in f:lines() do table.insert(lines, line) end
            f:close()
        end
    end
    pipe:close()

    if #lines == 0 then return end

    local ok, llm = pcall(require, "llm")
    if not (ok and llm) then return end

    proxy.inject_output("\r\n[daily] generating summary for " .. today .. "...\r\n")

    local summary, err = llm.query(
        "Summarize today's terminal activity in plain English. " ..
        "Note what machines were accessed, what was accomplished, and any errors. " ..
        "The input is JSONL session logs — each line has type, data, and timestamp.\n\n" ..
        table.concat(lines, "\n")
    )

    if err then
        proxy.inject_output("[daily] error: " .. err .. "\r\n")
        return
    end

    os.execute((is_windows and "mkdir " or "mkdir -p ") .. summary_dir)
    local sf = io.open(summary_file, "w")
    if sf then
        sf:write("# Daily summary — " .. today .. "\n\n" .. summary .. "\n")
        sf:close()
        proxy.inject_output("[daily] summary written → " .. summary_file .. "\r\n")
    end
end)
```
