-- session_log.lua — Full session transcript logger with optional LLM summary
--
-- Every input line and output chunk is written to a JSONL file, one per session.
-- On session_end the log is optionally summarized via llm.query().
--
-- Log:     ~/.local/share/ttyrell/sessions/YYYY-MM-DD_HH-MM-SS.jsonl
-- Summary: ~/.local/share/ttyrell/summaries/YYYY-MM-DD_HH-MM-SS.txt

if TTYRELL_MODE then return end  -- skip in all background modes (summarize, journal, …)

local _ok_sg, _sg = pcall(require, "secret_guard")
local sanitize = (_ok_sg and _sg and _sg.sanitize) or function(t) return t end

local base_dir
if package.config:sub(1, 1) == '\\' then
    local appdata = (os.getenv("LOCALAPPDATA") or os.getenv("APPDATA") or ""):gsub('\\', '/')
    if appdata == "" then
        print("[session_log] LOCALAPPDATA not set; logging disabled")
        return
    end
    base_dir = appdata .. "/ttyrell"
else
    local home = os.getenv("HOME") or ""
    if home == "" then
        print("[session_log] HOME not set; logging disabled")
        return
    end
    base_dir = home .. "/.local/share/ttyrell"
end
local function mkdir_p(path)
    if package.config:sub(1, 1) == '\\' then
        os.execute('mkdir "' .. path:gsub('/', '\\') .. '" 2>nul')
    else
        os.execute('mkdir -p "' .. path .. '"')
    end
end
mkdir_p(base_dir .. "/sessions")
mkdir_p(base_dir .. "/summaries")

local stamp = os.date("%Y-%m-%d_%H-%M-%S")
local session_path = base_dir .. "/sessions/" .. stamp .. ".jsonl"
CURRENT_SESSION_LOG = session_path  -- exposed for other plugins (e.g. workflow_journal)

local f, ferr = io.open(session_path, "w")
if not f then
    print("[session_log] cannot open log: " .. tostring(ferr))
    return
end

local function append(entry)
    if entry.data then entry.data = sanitize(entry.data) end
    entry.t = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local ok, line = pcall(proxy.json_encode, entry)
    if ok then
        f:write(line .. "\n")
        f:flush()
    end
end

proxy.on("session_start", function(host, shell)
    append({ type = "session_start", host = host, shell = shell })
end)

local function clean_output(raw)
    -- Normalize \r\n to \n, then simulate terminal overwrite: drop everything
    -- before each lone \r on the same line (erases echoed input and RPROMPT clearing).
    local s = raw:gsub("\r\n", "\n")
    s = s:gsub("[^\n\r]*\r", "")
    local lines = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("%S") then
            table.insert(lines, line)
        end
    end
    if #lines > 0 then table.remove(lines) end  -- drop trailing shell prompt
    return table.concat(lines, "\n")
end

local input_buf = {}
local output_buf = {}
local tab_pending = false  -- set when Tab is pressed, cleared by next output chunk
local tui_depth = 0        -- incremented on alternate-screen enter, decremented on exit

proxy.on("tui_start", function()
    tui_depth = tui_depth + 1
    output_buf = {}  -- discard any pre-TUI fragments
    input_buf  = {}
end)

proxy.on("tui_end", function()
    tui_depth = math.max(0, tui_depth - 1)
    output_buf = {}  -- discard TUI output garbage
    input_buf  = {}
end)

local function flush_output()
    local response = clean_output(table.concat(output_buf))
    output_buf = {}
    if #response > 0 then
        append({ type = "output", data = response })
    end
end

-- At Enter time, try to recover the full command (including tab completions) from
-- the terminal echo. With syntax-highlighting or other ZLE widgets, zsh redraws the
-- current line via \r; the last \r-preceded segment is the completed command line.
local function get_cmd_from_output()
    local after_cr = table.concat(output_buf):match(".*\r([^\r\n]+)$")
    if not after_cr then return "" end
    -- Strip prompt prefix if present
    local cmd = after_cr:match(".*[%%$#]%s+(.+)$") or after_cr:match(".*[%%$#](.+)$")
    if cmd then return cmd:match("^%s*(.-)%s*$") or "" end
    -- No prompt chars found (prompt was ANSI-stripped): use content directly
    return after_cr:match("^%s*(.-)%s*$") or ""
end

proxy.on("input", function(data)
    if tui_depth > 0 then return end
    if AI_QUERY_CAPTURING then return end  -- keystrokes belong to the AI prompt, not the shell
    for i = 1, #data do
        local ch = data:sub(i, i)
        local b = ch:byte()
        if ch == "\r" or ch == "\n" then
            local cmd = get_cmd_from_output()
            if #cmd == 0 then cmd = table.concat(input_buf) end
            flush_output()
            if #cmd > 0 then
                append({ type = "input", data = cmd })
            end
            input_buf = {}
            tab_pending = false
        elseif b == 9 then  -- Tab
            tab_pending = true
        elseif b == 127 or b == 8 then
            if #input_buf > 0 then table.remove(input_buf) end
        elseif b >= 32 then
            table.insert(input_buf, ch)
        end
    end
end)

proxy.on("command_start", function()
    output_buf = {}
end)

proxy.on("output", function(text)
    if tui_depth > 0 then return end
    table.insert(output_buf, text)

    if tab_pending then
        tab_pending = false
        if not text:find("[\r\n]") then
            -- No line reset: zsh appended or replaced the current word via ANSI cursor
            -- movement (stripped). Figure out what the completion produced and patch
            -- input_buf so the logged command includes the completed text.
            local typed   = table.concat(input_buf)
            local trimmed = text:match("^%s*(.-)%s*$") or text
            if trimmed:sub(1, #typed) == typed then
                -- Output starts with everything typed so far → it's the full command.
                input_buf = {}
                for ch in text:gmatch(".") do
                    if ch:byte() >= 32 then table.insert(input_buf, ch) end
                end
            else
                local last_word = typed:match("[^%s]*$") or typed
                if trimmed:sub(1, #last_word) == last_word then
                    -- Output starts with the current word → full-word replacement.
                    local before = typed:sub(1, #typed - #last_word)
                    input_buf = {}
                    for ch in (before .. text):gmatch(".") do
                        if ch:byte() >= 32 then table.insert(input_buf, ch) end
                    end
                else
                    -- Output is just the suffix → append.
                    for ch in text:gmatch(".") do
                        if ch:byte() >= 32 then table.insert(input_buf, ch) end
                    end
                end
            end
        end
        -- If text has \r or \n, get_cmd_from_output() at Enter time handles it.
    end

    -- Flush as soon as the shell prompt appears so output lands in the log
    -- immediately after a command finishes, not on the next keypress.
    -- Prompts are drawn after \r and end with "% ", "$ ", or "# ".
    local after_cr = text:match(".*\r([^\r\n]*)$")
    if after_cr and after_cr:match("[%%$#]%s*$") then
        flush_output()
    end
end)

proxy.on("command_exit", function(exit_code)
    local response = clean_output(table.concat(output_buf))
    local entry = { type = "output", exit_code = tonumber(exit_code) }
    if #response > 0 then entry.data = response end
    append(entry)
    output_buf = {}
end)

proxy.on("session_end", function()
    flush_output()
    append({ type = "session_end" })
    f:close()

    -- Kick off summarization in a background process so the user gets their
    -- prompt back immediately. The child re-invokes ttyrell in --summarize mode,
    -- which loads init.lua (for LLM config) and calls llm.query(), then exits.
    local ok, llm = pcall(require, "llm")
    if not (ok and llm) then return end

    local summary_path = base_dir .. "/summaries/" .. stamp .. ".txt"
    local bin = (TTYRELL_BIN or "ttyrell"):gsub('"', '')
    proxy.spawn(string.format('"%s" --summarize "%s" "%s"',
        bin, session_path, summary_path))
    proxy.inject_output(
        "\r\n[session_log] summarizing in background → summaries/" .. stamp .. ".txt\r\n"
    )
end)
