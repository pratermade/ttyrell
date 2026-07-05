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
-- shows it and asks before running anything.
--
-- ── File editing ──────────────────────────────────────────────────────────────
-- Ask to create/edit a file and the AI returns the full new contents; ttyrell
-- shows a unified diff and writes it only if you confirm ([y]/Enter). Reference
-- the current file with @path so the AI can edit it. Overwrites are backed up to
-- <data>/ttyrell/backups/ first, and each write is logged so the daily journal
-- summarizes what changed.
--   [ai]> @notes.md add a "Done" section
--   [ai]> create scripts/build.sh that runs cargo build --release
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

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local CONTEXT_LINES = (type(AI_CONTEXT_LINES) == "number" and AI_CONTEXT_LINES > 0)
    and AI_CONTEXT_LINES or 64

-- Byte value of the hotkey that opens the "[ai]> " prompt. Default Ctrl-G (7).
local HOTKEY = (type(AI_QUERY_HOTKEY) == "number") and AI_QUERY_HOTKEY or 7

-- Tracks the shell's working directory, updated via OSC 7 from shell integration.
-- Falls back to the directory ttyrell was launched from.
local current_dir = os.getenv("PWD") or "."

proxy.on("cwd_changed", function(dir)
    -- OSC 7 delivers a file URI path; on Windows that arrives as "/C:/Users/..."
    -- — strip the leading slash so it's a native path io.open accepts.
    if IS_WINDOWS then dir = dir:gsub("^/(%a:)", "%1") end
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
    if path:sub(1, 1) == "/" then return path end                  -- POSIX absolute
    if IS_WINDOWS and path:match("^%a:[/\\]") then return path end  -- Windows absolute (C:\ or C:/)
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

local ESC       = string.char(27)
local ENTER_ALT = ESC .. "[?1049h" .. ESC .. "[H"  -- alt-screen buffer + home
local LEAVE_ALT = ESC .. "[?1049l"                 -- back to the main screen

local pending_cmd   = nil -- awaiting confirmation for an EXEC command
local pending_write = nil -- awaiting confirmation for a proposed file write
local capturing     = false -- true while reading an "[ai]> " question line
local ai_buf        = {}  -- keystrokes typed while capturing
local cursor        = 0   -- current cursor position in ai_buf (0 = start)
local input_dirty   = false -- shell line likely has pending text the user typed

-- Shared with session_log: while true, the keystrokes belong to the AI prompt and
-- must not be recorded as shell input. session_log is loaded first, so it sees the
-- flag set by the hotkey keypress on every subsequent keystroke of the question.
AI_QUERY_CAPTURING = false

local function sync_capture_flag()
    AI_QUERY_CAPTURING = capturing or (pending_cmd ~= nil) or (pending_write ~= nil)
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

--- Write text to the Windows display file (BOM for PowerShell, CRLF line ends).
local function write_display_file(text)
    local body = text:gsub("\r\n", "\n"):gsub("\n", "\r\n")
    local f = io.open(AI_FILE_PATH, "wb")
    if f then
        if shell_is_powershell() then f:write("\239\187\191") end
        f:write(body)
        f:close()
    end
end

-- ── File editing (create / edit with diff, backup, and logging) ───────────────

-- ttyrell's data dir (session_log uses the same layout); backups live under it.
local DATA_DIR = IS_WINDOWS
    and ((os.getenv("LOCALAPPDATA") or os.getenv("APPDATA") or ""):gsub("\\", "/") .. "/ttyrell")
    or ((os.getenv("HOME") or ".") .. "/.local/share/ttyrell")
local BACKUP_DIR = DATA_DIR .. "/backups"

local function mkdir_p(path)
    if IS_WINDOWS then
        os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
    else
        os.execute('mkdir -p "' .. path .. '"')
    end
end

--- Read a whole file's contents, or nil if it doesn't exist / can't be opened.
local function read_file_raw(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

--- Colored, unified-style line diff between two texts. A new file (old == "")
-- shows every line as an addition. Long unchanged runs collapse to a "…".
local MAX_DIFF_LINES = 1500
local function unified_diff(old_text, new_text)
    local function split(s)
        local t = {}
        if s ~= "" then
            for line in (s .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = line end
        end
        return t
    end
    local a, b = split(old_text or ""), split(new_text or "")

    if #a > MAX_DIFF_LINES or #b > MAX_DIFF_LINES then
        return string.format("(file too large to diff — %d → %d lines)", #a, #b)
    end

    -- Suffix-LCS table: dp[i][j] = LCS length of a[i+1..] and b[j+1..].
    local dp = {}
    for i = 0, #a do dp[i] = {}; dp[i][#b] = 0 end
    for j = 0, #b do dp[#a][j] = 0 end
    for i = #a - 1, 0, -1 do
        for j = #b - 1, 0, -1 do
            if a[i + 1] == b[j + 1] then
                dp[i][j] = dp[i + 1][j + 1] + 1
            else
                dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1])
            end
        end
    end

    local rows = {}
    local i, j = 0, 0
    while i < #a and j < #b do
        if a[i + 1] == b[j + 1] then
            rows[#rows + 1] = { " ", a[i + 1] }; i = i + 1; j = j + 1
        elseif dp[i + 1][j] >= dp[i][j + 1] then
            rows[#rows + 1] = { "-", a[i + 1] }; i = i + 1
        else
            rows[#rows + 1] = { "+", b[j + 1] }; j = j + 1
        end
    end
    while i < #a do rows[#rows + 1] = { "-", a[i + 1] }; i = i + 1 end
    while j < #b do rows[#rows + 1] = { "+", b[j + 1] }; j = j + 1 end

    -- Keep changed lines plus a few lines of context around each.
    local CTX, keep = 3, {}
    for idx, r in ipairs(rows) do
        if r[1] ~= " " then
            for k = math.max(1, idx - CTX), math.min(#rows, idx + CTX) do keep[k] = true end
        end
    end

    local RED, GRN, DIM, RST = ESC .. "[31m", ESC .. "[32m", ESC .. "[90m", ESC .. "[0m"
    local out, gap = {}, false
    for idx, r in ipairs(rows) do
        if keep[idx] then
            gap = false
            if r[1] == "+" then
                out[#out + 1] = GRN .. "+" .. r[2] .. RST
            elseif r[1] == "-" then
                out[#out + 1] = RED .. "-" .. r[2] .. RST
            else
                out[#out + 1] = DIM .. " " .. r[2] .. RST
            end
        elseif not gap then
            out[#out + 1] = DIM .. "…" .. RST
            gap = true
        end
    end
    if #out == 0 then return "(no changes)" end
    return table.concat(out, "\n")
end

--- Save old contents to a timestamped backup; returns the backup path or nil.
local function backup_file(orig_path, old_content)
    mkdir_p(BACKUP_DIR)
    local flat = orig_path:gsub("[/\\:]", "_"):gsub("^_+", "")
    local bpath = BACKUP_DIR .. "/" .. os.date("%Y-%m-%d_%H-%M-%S") .. "__" .. flat
    local f = io.open(bpath, "wb")
    if not f then return nil end
    f:write(old_content or "")
    f:close()
    return bpath
end

--- Apply a confirmed write: back up the old file, create/overwrite it, and log
-- the change so the session summary / journal picks it up. Returns a status line.
local function apply_write(w)
    local backup = nil
    if w.existed then backup = backup_file(w.resolved, w.old) end

    local dir = w.resolved:match("^(.*)[/\\][^/\\]+$")
    if dir and dir ~= "" then mkdir_p(dir) end

    local f, ferr = io.open(w.resolved, "wb")
    if not f then return "[ai] write failed: " .. tostring(ferr) end
    f:write(w.content)
    f:close()

    if SESSION_LOG_RECORD then
        pcall(SESSION_LOG_RECORD, {
            type   = "file_write",
            path   = w.path,
            action = w.existed and "edit" or "create",
            backup = backup,
        })
    end

    local msg = "[ai] " .. (w.existed and "updated " or "created ") .. w.path
    if backup then msg = msg .. "  (backup: " .. backup .. ")" end
    return msg
end

local FILE_WRITE_INSTRUCTIONS =
    "If the user asks you to create, edit, or update a file, output the file's " ..
    "COMPLETE new contents at the very end of your response, wrapped EXACTLY like " ..
    "this, with nothing after the end marker and no surrounding code fences:\n" ..
    "<<<FILE relative/path.ext>>>\n" ..
    "<the entire new file contents>\n" ..
    "<<<ENDFILE>>>\n" ..
    "Use a path relative to the working directory (absolute also works). For an " ..
    "edit, include the whole file with your changes applied — the current contents " ..
    "are provided above when the user references the file with @. Only include a " ..
    "FILE block when a file should actually be written; the user sees a diff and " ..
    "confirms before anything is saved. Do not also include an EXEC line.\n\n"

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

    local prompt = shell_note() .. FILE_WRITE_INSTRUCTIONS .. EXEC_INSTRUCTIONS
    if context then
        prompt = prompt .. context .. "\n\nQuestion: " .. question
    else
        prompt = prompt .. "Question: " .. question
    end

    local response, err = llm.query(prompt, AI_QUERY_LLM)
    if err then
        return nil, nil, nil, notes, err
    end

    -- A file-write proposal takes precedence over EXEC.
    -- Lua's . metacharacter does not match newlines, so a single match() cannot
    -- capture multi-line content. Use find() with a position-capture trick to
    -- locate the boundaries, then sub() to extract the file content.
    local wpath, wcontent = nil, nil
    local p1, _, cap_path, content_start = response:find("<<<FILE%s+(.-)%s*>>>\n()")
    if p1 and cap_path ~= "" then
        local content_end = response:find("\n<<<ENDFILE>>>", content_start, true)
        if content_end then
            wpath = cap_path
            wcontent = response:sub(content_start, content_end - 1)
        end
    end
    if wpath and wpath ~= "" then
        -- Defensive: strip a wrapping code fence if the model added one anyway.
        wcontent = wcontent:gsub("^```[%w]*\n", ""):gsub("\n```%s*$", "")
        local body = response:gsub("<<<FILE.-<<<ENDFILE>>>", ""):gsub("%s*$", "")
        local resolved = resolve_path(wpath)
        local old = read_file_raw(resolved)  -- nil ⇒ new file
        local write = {
            path = wpath, resolved = resolved, content = wcontent,
            existed = old ~= nil, old = old, diff = unified_diff(old or "", wcontent),
        }
        return body, nil, write, notes, nil
    end

    local exec_cmd = response:match("\nEXEC:%s*([^\n]+)%s*$")
                  or response:match("^EXEC:%s*([^\n]+)%s*$")
    local body = response
    if exec_cmd then
        exec_cmd = exec_cmd:match("^%s*(.-)%s*$")
        body = response:gsub("\n?EXEC:%s*[^\n]+%s*$", ""):gsub("%s*$", "")
    end
    return body, exec_cmd, nil, notes, nil
end

--- Unix: inject the response inline (a Unix PTY has no screen model, so this
-- is safe). Sets pending_cmd / pending_write when the model proposes an action.
local function show_response_unix(body, exec_cmd, write, notes, err)
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
    if write then
        proxy.inject_output("[ai] " .. (write.existed and "edit " or "create ")
            .. write.path .. ":\r\n")
        proxy.inject_output(write.diff:gsub("\n", "\r\n") .. "\r\n")
        proxy.inject_output("[ai] apply change? [y] ")
        pending_write = write
    elseif exec_cmd then
        proxy.inject_output("[ai] run: " .. exec_cmd .. " — run it? [y] ")
        pending_cmd = exec_cmd
    end
end

--- Windows: write the response to a file, leave the alternate screen (restoring
-- the main screen exactly), then type a `type <file>` command into the shell.
-- The shell prints the response (ConPTY stays in sync) and returns a fresh
-- prompt on its own. Sets pending_cmd when the model suggested a command; the
-- run-it hint is part of the displayed text and pressing y/Enter runs it.
local function show_response_windows(question, body, exec_cmd, write, notes, err)
    local parts = { "[ai] " .. question, "" }
    for _, n in ipairs(notes) do
        table.insert(parts, "note: " .. n)
    end
    if err then
        table.insert(parts, "error: " .. err)
    else
        if #body > 0 then table.insert(parts, body) end
        if write then
            table.insert(parts, "")
            table.insert(parts, (write.existed and "── edit " or "── create ")
                .. write.path .. " ──")
            table.insert(parts, write.diff)
            table.insert(parts, "")
            table.insert(parts, "apply change? [y]")
        elseif exec_cmd then
            table.insert(parts, "")
            table.insert(parts, "run: " .. exec_cmd)
            table.insert(parts, "run it? [y]")
        end
    end

    write_display_file(table.concat(parts, "\n") .. "\n")

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

    if not err then
        if write then
            pending_write = write
        elseif exec_cmd then
            pending_cmd = exec_cmd
        end
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
    -- Awaiting confirmation for a proposed action (an EXEC command or a file
    -- write). y/Enter applies; n/Esc declines; any other key declines AND passes
    -- through, so you can just start typing your next command.
    if pending_cmd or pending_write then
        local ch = data:sub(1, 1)
        local b  = ch:byte() or 0
        local accept  = (ch == "y" or ch == "Y")
        local decline = (b == 27 or ch == "n" or ch == "N")

        if pending_write then
            local w = pending_write
            pending_write = nil
            sync_capture_flag()
            if accept or decline then
                local msg = accept and apply_write(w) or "[ai] discarded"
                if IS_WINDOWS then
                    write_display_file(msg .. "\r\n")
                    proxy.send_input(display_command() .. "\r")
                else
                    proxy.inject_output("\r\n" .. msg .. "\r\n")
                end
                return "suppress"
            end
            input_dirty = true  -- forwarded key starts a new shell line
            return
        end

        local cmd = pending_cmd
        pending_cmd = nil
        sync_capture_flag()
        if accept then
            if not IS_WINDOWS then proxy.inject_output("y\r\n") end
            -- \r, not \n: PSReadLine only accepts a line on Enter (\r);
            -- \n is Ctrl-J which is unbound. \r works in readline/zsh too.
            proxy.send_input(cmd .. "\r")
            return "suppress"
        elseif decline then
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

    -- Process byte-by-byte using a while loop so we can skip remaining bytes
    -- of multi-byte escape sequences (e.g. arrow keys: ESC [ A/B/C/D)
    local pos = 1
    while pos <= #data do
        local ch = data:sub(pos, pos)
        local b  = ch:byte()

        if capturing then
            suppress = true
            if ch == "\r" or ch == "\n" then
                local q = table.concat(ai_buf)
                ai_buf, capturing, cursor = {}, false, 0
                if q:match("%S") then
                    -- Animated \ - / | spinner while the (blocking) query runs.
                    -- Runs on a Rust thread; guarded for older binaries. On
                    -- Windows this is inside the alternate screen buffer.
                    proxy.inject_output("\r\n[ai] thinking ")
                    if proxy.spinner_start then proxy.spinner_start() end
                    local body, exec_cmd, write, notes, qerr = query_llm(q)
                    if proxy.spinner_stop then proxy.spinner_stop() end
                    if IS_WINDOWS then
                        show_response_windows(q, body or "", exec_cmd, write, notes, qerr)
                    else
                        proxy.inject_output("\r\n")
                        show_response_unix(body or "", exec_cmd, write, notes, qerr)
                    end
                else
                    cancel_capture("\r\n")  -- empty question
                end
            elseif b == 27 then
                -- Check if ESC is part of an arrow key sequence (ESC [ A/B/C/D)
                local n1 = data:sub(pos + 1, pos + 1)
                local n2 = data:sub(pos + 2, pos + 2)
                if n1 == "[" and (n2 == "A" or n2 == "B" or n2 == "C" or n2 == "D") then
                    -- Arrow key — move cursor in the query buffer
                    if n2 == "D" and cursor > 0 then
                        -- Left arrow: move cursor back
                        cursor = cursor - 1
                        proxy.inject_output("\b")
                    elseif n2 == "C" and cursor < #ai_buf then
                        -- Right arrow: move cursor forward
                        cursor = cursor + 1
                        proxy.inject_output("\027[C")
                    end
                    -- Up (A) / Down (B) are ignored in the query buffer
                    pos = pos + 3  -- skip ESC [ <letter>
                else
                    -- Standalone ESC cancels
                    cancel_capture("\r\n[ai] cancelled\r\n")
                end
            elseif b == 3 then             -- Ctrl-C cancels
                cancel_capture("^C\r\n[ai] cancelled\r\n")
            elseif b == 127 or b == 8 then -- Backspace: erase at cursor
                if cursor > 0 then
                    cursor = cursor - 1
                    table.remove(ai_buf, cursor + 1)
                    proxy.inject_output("\b \b")
                end
            elseif b >= 32 then            -- Printable: insert at cursor
                table.insert(ai_buf, cursor + 1, ch)
                cursor = cursor + 1
                proxy.inject_output(ch)
            end
            -- other control bytes are swallowed while capturing
        elseif b == HOTKEY then
            capturing, suppress, cursor = true, true, 0
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
        pos = pos + 1
    end

    sync_capture_flag()
    if suppress then return "suppress" end
end)
