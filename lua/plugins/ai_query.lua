-- ai_query.lua — hotkey-triggered AI prompt with optional shell command execution
--
-- Press the hotkey (Ctrl-G by default) at any prompt to open an "[ai]>" line,
-- type a question, and press Enter. On Windows the prompt opens in a temporary
-- full-screen overlay (see below); on Unix it appears inline. The keystrokes
-- are fully suppressed and never reach the shell, so this works identically on
-- cmd.exe, PowerShell, and POSIX shells (unlike a text prefix, which depended
-- on shell comment syntax).
-- Press Esc or Ctrl-C to cancel. The AI sees recent session history as context,
-- and is told which shell/OS you run so suggested commands use valid syntax.
-- If the AI can provide a runnable command it appends "EXEC: <cmd>" — ttyrell
-- shows it and asks [y/N] before running anything.
--
-- On Windows the transient UI (the "[ai]> " prompt, your typing, and the
-- thinking spinner) is drawn in the terminal's alternate screen buffer, then
-- torn down — restoring the main screen exactly. ConPTY tracks the shell's
-- screen with absolute coordinates, so anything injected onto the main screen
-- desynchronizes the cursor and garbles later shell output. The response is
-- displayed by the SHELL: it's written to %LOCALAPPDATA%\ttyrell\ai_last.txt
-- and a `type <file>` command is typed in, so it lands inline in scrollback
-- with a fresh prompt, no desync, and no extra keypress.
--
-- Change the hotkey with AI_QUERY_HOTKEY (a byte value) in init.lua, e.g.
--   AI_QUERY_HOTKEY = 7   -- Ctrl-G (default);  1 = Ctrl-A, 20 = Ctrl-T, ...
--
-- ── File references ───────────────────────────────────────────────────────────
-- Include file content in context by mentioning @path in the question:
--   [ai]> @src/main.rs why is line 42 failing
--   [ai]> @Cargo.toml @src/lib.rs explain the dependency setup
-- The @ is stripped from the question text; the file content appears in context.
-- Paths resolve relative to the shell's current directory (tracked via OSC 7).
--
-- ── Context settings ─────────────────────────────────────────────────────────
-- AI_CONTEXT_COMMANDS: recent command/output pairs from the session log.
--   0 = disabled (falls back to raw output buffer). Default: 10.
-- AI_CONTEXT_FILE_LINES: max lines read per @file reference. 0 = unlimited.
--   Default: 200. Set lower for small local models.
-- AI_CONTEXT_LINES: raw output buffer depth used when AI_CONTEXT_COMMANDS = 0.
--   Default: 64.
--
-- AI_CONTEXT_COMMANDS  = 10
-- AI_CONTEXT_FILE_LINES = 200
-- AI_CONTEXT_LINES      = 64
--
-- ── LLM provider ─────────────────────────────────────────────────────────────
AI_QUERY_LLM = LLM.local_llama
-- AI_QUERY_LLM = LLM.claude
-- ─────────────────────────────────────────────────────────────────────────────

local llm = require("llm")

local CONTEXT_LINES = (type(AI_CONTEXT_LINES) == "number" and AI_CONTEXT_LINES > 0)
    and AI_CONTEXT_LINES or 64

-- Byte value of the hotkey that opens the "[ai]> " prompt. Default Ctrl-G (7).
local HOTKEY = (type(AI_QUERY_HOTKEY) == "number") and AI_QUERY_HOTKEY or 7

-- Tracks the shell's working directory, updated via OSC 7 from shell integration.
-- Falls back to the directory ttyrell was launched from.
local current_dir = os.getenv("PWD") or "."

proxy.on("cwd_changed", function(dir)
    current_dir = dir
end)

-- Rolling buffer of recent output lines — fallback when AI_CONTEXT_COMMANDS = 0
local history = {}

proxy.on("tui_start", function()
    history = {}
end)

proxy.on("output", function(text)
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if #line > 0 then
            history[#history + 1] = line
        end
    end
    local excess = #history - CONTEXT_LINES
    if excess > 0 then
        table.move(history, excess + 1, #history, 1)
        for i = #history - excess + 1, #history do history[i] = nil end
    end
end)

-- ── File reading ──────────────────────────────────────────────────────────────

--- Extract @path tokens from a question string.
-- Strips the @ sigil from each token in-place and returns the cleaned question
-- alongside the list of paths.
local function extract_file_refs(question)
    local paths = {}
    local cleaned = question:gsub("@([^%s]+)", function(path)
        table.insert(paths, path)
        return path  -- keep the path text, just drop the @
    end):match("^%s*(.-)%s*$")
    return cleaned, paths
end

--- Resolve a path relative to the shell's current directory.
local function resolve_path(path)
    if path:sub(1, 1) == "/" then return path end  -- already absolute
    return current_dir .. "/" .. path
end

--- Read a file and return its content as a string, or nil + error message.
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil, "cannot open " .. path end

    local max_lines = (type(AI_CONTEXT_FILE_LINES) == "number" and AI_CONTEXT_FILE_LINES >= 0)
        and AI_CONTEXT_FILE_LINES or 200

    local lines = {}
    local truncated = false
    for line in f:lines() do
        -- Binary file check: NUL byte means not useful as text context
        if line:find("\0") then
            f:close()
            return nil, path .. " appears to be a binary file"
        end
        if max_lines > 0 and #lines >= max_lines then
            truncated = true
            break
        end
        table.insert(lines, line)
    end
    f:close()

    if #lines == 0 then return nil, path .. " is empty" end

    local content = table.concat(lines, "\n")
    if truncated then
        content = content .. "\n\n... (truncated at " .. max_lines .. " lines — set AI_CONTEXT_FILE_LINES to read more)"
    end
    return content, nil
end

-- ── Session log context ───────────────────────────────────────────────────────

--- Read the last n command/output pairs from the current session log.
local function read_session_context(n)
    if n <= 0 then return nil end
    local log_path = CURRENT_SESSION_LOG
    if not log_path then return nil end

    local f = io.open(log_path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()

    local pairs_list = {}
    local current = nil

    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
            local ok, entry = pcall(proxy.json_decode, line)
            if ok and type(entry) == "table" then
                if entry.type == "input" and entry.data then
                    if current then table.insert(pairs_list, current) end
                    current = { cmd = entry.data, outputs = {}, exit_code = nil }
                elseif entry.type == "output" and current then
                    if entry.data then
                        table.insert(current.outputs, entry.data)
                    end
                    if entry.exit_code ~= nil then
                        current.exit_code = entry.exit_code
                    end
                end
            end
        end
    end
    if current then table.insert(pairs_list, current) end

    if #pairs_list == 0 then return nil end

    local start = math.max(1, #pairs_list - n + 1)
    local parts = {}
    for i = start, #pairs_list do
        local p = pairs_list[i]
        local header = "$ " .. p.cmd
        if p.exit_code ~= nil and p.exit_code ~= 0 then
            header = header .. "  (exit " .. tostring(p.exit_code) .. ")"
        end
        local output = table.concat(p.outputs, "\n"):match("^%s*(.-)%s*$") or ""
        table.insert(parts, #output > 0 and (header .. "\n" .. output) or header)
    end

    return "Recent commands:\n\n" .. table.concat(parts, "\n\n")
end

-- ── Query handler ─────────────────────────────────────────────────────────────

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local ESC       = string.char(27)
local ENTER_ALT = ESC .. "[?1049h" .. ESC .. "[H"  -- alt-screen buffer + home
local LEAVE_ALT = ESC .. "[?1049l"                 -- back to the main screen

local pending_cmd = nil   -- awaiting confirmation for an EXEC command
local capturing   = false -- true while reading an "[ai]> " question line
local ai_buf      = {}    -- keystrokes typed while capturing
local input_dirty = false -- shell line likely has pending text the user typed

-- Shared with session_log: while true, the keystrokes belong to the AI prompt and
-- must not be recorded as shell input. session_log is loaded first, so it sees the
-- flag set by the hotkey keypress on every subsequent keystroke of the question.
AI_QUERY_CAPTURING = false

local function sync_capture_flag()
    AI_QUERY_CAPTURING = capturing or (pending_cmd ~= nil)
end

-- ── Windows response display ──────────────────────────────────────────────────
-- ConPTY tracks the shell's screen with absolute coordinates, so any text the
-- proxy injects onto the main screen is invisible to it and desynchronizes the
-- cursor: the next shell output (a prompt redraw, a stray error) then renders at
-- the wrong place and interleaves with ours. So nothing is injected onto the
-- main screen. The question UI lives in the alternate screen buffer (torn down
-- cleanly, leaving the main screen and ConPTY's model untouched), and the
-- response is printed by the SHELL — written to a file and shown with a typed
-- `type <file>` command, so every byte flows through ConPTY, lands in
-- scrollback, and the shell returns a fresh prompt on its own.
--
-- On Unix a PTY is a plain byte stream with no screen model, so plain inline
-- injection works and none of this is needed.

local AI_FILE_DIR  = IS_WINDOWS and ((os.getenv("LOCALAPPDATA") or "") .. "\\ttyrell") or nil
local AI_FILE_PATH = AI_FILE_DIR and (AI_FILE_DIR .. "\\ai_last.txt") or nil
if AI_FILE_DIR then
    os.execute('mkdir "' .. AI_FILE_DIR .. '" 2>nul')
end

local function shell_is_powershell()
    local s = ((proxy.session_info and proxy.session_info.shell) or ""):lower()
    return (s:find("powershell", 1, true) or s:find("pwsh", 1, true)) ~= nil
end

--- The command typed into the shell to display the response file.
local function display_command()
    if shell_is_powershell() then
        return 'type "$env:LOCALAPPDATA\\ttyrell\\ai_last.txt"'
    end
    return 'type "%LOCALAPPDATA%\\ttyrell\\ai_last.txt"'  -- cmd.exe
end

local EXEC_INSTRUCTIONS =
    "If the user asks for a command, or a single shell command would answer or " ..
    "accomplish their request, append exactly one line at the very end of your " ..
    "response in this format:\n" ..
    "EXEC: <command>\n" ..
    "Always include the EXEC line when you can provide the complete command. " ..
    "Do not include explanation after the EXEC line. " ..
    "The user will be shown the command and asked for permission before it runs.\n\n"

--- Tell the model which shell/OS the user runs so suggested commands are valid.
-- session_info is populated by the proxy before any events fire, but not at
-- plugin load time — so this is built lazily at query time.
local function shell_note()
    local shell_path = (proxy.session_info and proxy.session_info.shell) or ""
    local shell_name = shell_path:match("([^/\\]+)$") or shell_path
    if shell_name == "" then shell_name = "an unknown shell" end
    local platform = IS_WINDOWS and "Windows" or "a Unix-like system"
    return "The user's shell is " .. shell_name .. " on " .. platform ..
        ". Every command you suggest, including the EXEC line, must use syntax " ..
        "valid for that shell.\n\n"
end

--- Ask the LLM. Pure — no terminal output.
-- Returns body, exec_cmd, notes, err. notes is a list of non-fatal messages
-- (e.g. unreadable @file refs). On failure body is nil and err is set.
local function query_llm(raw)
    local question, file_refs = extract_file_refs(raw)
    local notes = {}

    -- 1. File context (listed files, in order)
    local context_parts = {}
    for _, path in ipairs(file_refs) do
        local content, err = read_file(resolve_path(path))
        if err then
            table.insert(notes, err)
        else
            table.insert(context_parts,
                "File: " .. path .. "\n```\n" .. content .. "\n```")
        end
    end

    -- 2. Session log context (structured command history)
    local n_cmds = (type(AI_CONTEXT_COMMANDS) == "number") and AI_CONTEXT_COMMANDS or 10
    local session_ctx = read_session_context(n_cmds)
    if session_ctx then
        table.insert(context_parts, session_ctx)
    elseif #history > 0 then
        -- Fallback: raw output buffer
        table.insert(context_parts,
            "Recent terminal output:\n```\n" .. table.concat(history, "\n") .. "\n```")
    end

    local context = #context_parts > 0 and table.concat(context_parts, "\n\n") or nil

    local prompt = shell_note() .. EXEC_INSTRUCTIONS
    if context then
        prompt = prompt .. context .. "\n\nQuestion: " .. question
    else
        prompt = prompt .. "Question: " .. question
    end

    local response, err = llm.query(prompt, AI_QUERY_LLM)
    if err then
        return nil, nil, notes, err
    end

    local exec_cmd = response:match("\nEXEC:%s*([^\n]+)%s*$")
                  or response:match("^EXEC:%s*([^\n]+)%s*$")
    local body = response
    if exec_cmd then
        exec_cmd = exec_cmd:match("^%s*(.-)%s*$")
        body = response:gsub("\n?EXEC:%s*[^\n]+%s*$", ""):gsub("%s*$", "")
    end
    return body, exec_cmd, notes, nil
end

--- Unix: inject the response inline (a Unix PTY has no screen model, so this
-- is safe). Sets pending_cmd when the model suggested a command.
local function show_response_unix(body, exec_cmd, notes, err)
    for _, n in ipairs(notes) do
        proxy.inject_output("[ai] " .. n .. "\r\n")
    end
    if err then
        proxy.inject_output("[ai] error: " .. err .. "\r\n")
        return
    end
    if #body > 0 then
        proxy.inject_output("[ai] " .. body:gsub("\n", "\r\n") .. "\r\n")
    end
    if exec_cmd then
        proxy.inject_output("[ai] run: " .. exec_cmd .. " — run it? [y] ")
        pending_cmd = exec_cmd
    end
end

--- Windows: write the response to a file, leave the alternate screen (restoring
-- the main screen exactly), then type a `type <file>` command into the shell.
-- The shell prints the response (ConPTY stays in sync) and returns a fresh
-- prompt on its own. Sets pending_cmd when the model suggested a command; the
-- run-it hint is part of the displayed text and pressing y/Enter runs it.
local function show_response_windows(question, body, exec_cmd, notes, err)
    local parts = { "[ai] " .. question, "" }
    for _, n in ipairs(notes) do
        table.insert(parts, "note: " .. n)
    end
    if err then
        table.insert(parts, "error: " .. err)
    else
        if #body > 0 then table.insert(parts, body) end
        if exec_cmd then
            table.insert(parts, "")
            table.insert(parts, "run: " .. exec_cmd)
            table.insert(parts, "run it? [y]")
        end
    end

    local text = table.concat(parts, "\n"):gsub("\r\n", "\n"):gsub("\n", "\r\n") .. "\r\n"
    local f = io.open(AI_FILE_PATH, "wb")
    if f then
        -- BOM so PowerShell 5.1's Get-Content reads the file as UTF-8;
        -- cmd.exe's type would print the BOM as garbage, so omit it there.
        if shell_is_powershell() then f:write("\239\187\191") end
        f:write(text)
        f:close()
    end

    -- Return to the main screen, then let the shell display the response.
    proxy.inject_output(LEAVE_ALT)

    -- If the user had typed text at the prompt before pressing the hotkey, it is
    -- still in the shell's line buffer and would glue onto the display command
    -- ("lltype ..."). A leading Ctrl-C cancels that line first, so the display
    -- command runs at a clean prompt.
    local prefix = ""
    if input_dirty then
        prefix = "\3"
        input_dirty = false
    end
    proxy.send_input(prefix .. display_command() .. "\r")

    if not err and exec_cmd then
        pending_cmd = exec_cmd
    end
end

--- Cancel the question line. On Windows leave the alternate screen (the main
-- screen and the shell's prompt reappear untouched); on Unix print a note.
local function cancel_capture(note)
    ai_buf, capturing = {}, false
    if IS_WINDOWS then
        proxy.inject_output(LEAVE_ALT)
    elseif note then
        proxy.inject_output(note)
    end
end

proxy.on("input", function(data)
    -- Awaiting confirmation for a suggested EXEC command.
    -- y or Enter runs it; n/Esc declines; anything else declines AND passes the
    -- keystroke through, so just typing your next command works naturally.
    if pending_cmd then
        local cmd = pending_cmd
        pending_cmd = nil
        local ch = data:sub(1, 1)
        local b  = ch:byte() or 0
        sync_capture_flag()
        if ch == "y" or ch == "Y" or ch == "\r" or ch == "\n" then
            if not IS_WINDOWS then proxy.inject_output("y\r\n") end
            -- \r, not \n: PSReadLine only accepts a line on Enter (\r);
            -- \n is Ctrl-J which is unbound. \r works in readline/zsh too.
            proxy.send_input(cmd .. "\r")
            return "suppress"
        elseif b == 27 or ch == "n" or ch == "N" then
            if not IS_WINDOWS then proxy.inject_output("N\r\n[ai] cancelled\r\n") end
            return "suppress"
        end
        input_dirty = true  -- the forwarded key starts a new shell line
        return  -- decline and forward the keystroke to the shell
    end

    -- Any keystroke that is part of an AI interaction is consumed here and never
    -- forwarded to the shell. suppress starts true if we were already capturing
    -- (the whole chunk is ours) and flips true the moment we see the hotkey.
    local suppress = capturing

    for i = 1, #data do
        local ch = data:sub(i, i)
        local b  = ch:byte()

        if capturing then
            suppress = true
            if ch == "\r" or ch == "\n" then
                local q = table.concat(ai_buf)
                ai_buf, capturing = {}, false
                if q:match("%S") then
                    -- Animated \ - / | spinner while the (blocking) query runs.
                    -- Runs on a Rust thread; guarded for older binaries. On
                    -- Windows this is inside the alternate screen buffer.
                    proxy.inject_output("\r\n[ai] thinking ")
                    if proxy.spinner_start then proxy.spinner_start() end
                    local body, exec_cmd, notes, qerr = query_llm(q)
                    if proxy.spinner_stop then proxy.spinner_stop() end
                    if IS_WINDOWS then
                        show_response_windows(q, body or "", exec_cmd, notes, qerr)
                    else
                        proxy.inject_output("\r\n")
                        show_response_unix(body or "", exec_cmd, notes, qerr)
                    end
                else
                    cancel_capture("\r\n")  -- empty question
                end
            elseif b == 27 then            -- Esc cancels
                cancel_capture("\r\n[ai] cancelled\r\n")
            elseif b == 3 then             -- Ctrl-C cancels
                cancel_capture("^C\r\n[ai] cancelled\r\n")
            elseif b == 127 or b == 8 then -- Backspace: erase one echoed char
                if #ai_buf > 0 then
                    table.remove(ai_buf)
                    proxy.inject_output("\b \b")
                end
            elseif b >= 32 then            -- Printable: buffer and echo it ourselves
                ai_buf[#ai_buf + 1] = ch
                proxy.inject_output(ch)
            end
            -- other control bytes (arrows, etc.) are swallowed while capturing
        elseif b == HOTKEY then
            capturing, suppress = true, true
            ai_buf = {}
            if IS_WINDOWS then
                -- Compose the question in the alternate screen buffer so nothing
                -- touches the main screen (torn down in show_response/cancel).
                proxy.inject_output(
                    ENTER_ALT .. ESC .. "[36m[ai]>" .. ESC .. "[0m Esc cancels\r\n\r\n> ")
            else
                proxy.inject_output("\r\n[ai]> ")
            end
        else
            -- Ordinary keystroke headed for the shell: track whether its line
            -- buffer likely holds uncommitted text (used to ^C-clear it before
            -- typing the response display command).
            if ch == "\r" or ch == "\n" or b == 3 then
                input_dirty = false  -- line submitted or cancelled
            elseif b == 27 then
                input_dirty = false  -- Esc clears the line in PSReadLine/cmd
            elseif b >= 32 or b == 9 then
                input_dirty = true   -- printable, or Tab completion
            end
        end
    end

    sync_capture_flag()
    if suppress then return "suppress" end
end)
