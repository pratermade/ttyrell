-- session_log.lua — Full session transcript logger with optional LLM summary
--
-- Every input line and output chunk is written to a JSONL file, one per session.
-- On session_end the log is optionally summarized via llm.query().
--
-- Log:     ~/.local/share/ttyrell/sessions/YYYY-MM-DD_HH-MM-SS.jsonl
-- Summary: ~/.local/share/ttyrell/summaries/YYYY-MM-DD_HH-MM-SS.txt

local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
if home == "" then
    print("[session_log] HOME not set; logging disabled")
    return
end

local base_dir = home .. "/.local/share/ttyrell"
os.execute("mkdir -p " .. base_dir .. "/sessions")
os.execute("mkdir -p " .. base_dir .. "/summaries")

local stamp = os.date("%Y-%m-%d_%H-%M-%S")
local session_path = base_dir .. "/sessions/" .. stamp .. ".jsonl"

local f, ferr = io.open(session_path, "w")
if not f then
    print("[session_log] cannot open log: " .. tostring(ferr))
    return
end

local function append(entry)
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

local function flush_output()
    local response = clean_output(table.concat(output_buf))
    output_buf = {}
    if #response > 0 then
        append({ type = "output", data = response })
    end
end

-- At Enter time, try to recover the full command (including tab completions) from
-- the terminal echo. Tab completion causes zsh to redraw the current line via \r,
-- so the last \r-preceded segment in output_buf is the completed command line.
local function get_cmd_from_output()
    local after_cr = table.concat(output_buf):match(".*\r([^\r\n]+)$")
    if not after_cr then return "" end
    local cmd = after_cr:match(".*[%%$#]%s+(.+)$") or after_cr:match(".*[%%$#](.+)$")
    return cmd and cmd:match("^%s*(.-)%s*$") or ""
end

proxy.on("input", function(data)
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
    table.insert(output_buf, text)
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

    -- Summarize via LLM if a provider is configured
    local ok, llm = pcall(require, "llm")
    if not (ok and llm) then return end

    local rf = io.open(session_path, "r")
    if not rf then return end
    local log_text = rf:read("*a")
    rf:close()

    if #log_text == 0 then return end

    proxy.inject_output("\r\n[session_log] summarizing session...\r\n")

    local summary, serr = llm.query(
        "Summarize this terminal session log in plain English. " ..
        "Note what machine(s) were used (look for ssh commands and remote prompts), " ..
        "what was accomplished, and highlight any errors or non-zero exit codes. " ..
        "Be concise — a short paragraph is ideal.\n\n" ..
        "The log is JSONL. Each line has a 'type' field:\n" ..
        "  session_start — host and shell at proxy launch\n" ..
        "  input         — full command line entered by the user\n" ..
        "  output        — full terminal output for a completed command, includes exit_code\n" ..
        "  session_end   — proxy is shutting down\n\n" ..
        log_text
    )

    if serr then
        proxy.inject_output("[session_log] summary error: " .. serr .. "\r\n")
        return
    end

    local sf = io.open(base_dir .. "/summaries/" .. stamp .. ".txt", "w")
    if sf then
        sf:write(summary .. "\n")
        sf:close()
        proxy.inject_output(
            "[session_log] summary → summaries/" .. stamp .. ".txt\r\n"
        )
    end
end)
