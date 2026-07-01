-- ai_query.lua — #ai: prefix handler with optional shell command execution
--
-- Type "#ai: <question>" and press Enter. The AI sees recent session
-- history as context. If the AI wants to run a command it appends
-- "EXEC: <cmd>" — ttyrell shows it and asks [y/N] before running anything.
--
-- ── Context settings ─────────────────────────────────────────────────────────
-- AI_CONTEXT_COMMANDS: number of recent command/output pairs from the session
--   log to send as context. Set lower for small local models, higher for cloud.
--   0 = disabled (falls back to the raw output buffer below).
-- AI_CONTEXT_LINES: size of the raw output buffer used when AI_CONTEXT_COMMANDS
--   is 0 or the session log is unavailable. Default: 64.
--
-- AI_CONTEXT_COMMANDS = 10
-- AI_CONTEXT_LINES    = 64
--
-- ── LLM provider ─────────────────────────────────────────────────────────────
-- LLM provider for AI queries — pick from the palette defined in init.lua:
AI_QUERY_LLM = LLM.local_llama
-- AI_QUERY_LLM = LLM.claude
-- ─────────────────────────────────────────────────────────────────────────────

local llm = require("llm")

local CONTEXT_LINES = (type(AI_CONTEXT_LINES) == "number" and AI_CONTEXT_LINES > 0)
    and AI_CONTEXT_LINES or 64

-- Rolling buffer of recent output lines — used when AI_CONTEXT_COMMANDS is 0
-- or the session log is unavailable.
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

--- Read the last n command/output pairs from the current session log.
-- Parses CURRENT_SESSION_LOG (JSONL written by session_log.lua) and returns
-- a formatted string suitable for LLM context, or nil if unavailable.
local function read_session_context(n)
    if n <= 0 then return nil end
    local log_path = CURRENT_SESSION_LOG
    if not log_path then return nil end

    local f = io.open(log_path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()

    -- Walk the JSONL: group output entries under their preceding input entry.
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

    -- Take the last n pairs and format them.
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

-- Set while waiting for the user to answer a permission prompt
local pending_cmd = nil
local buf = {}

local EXEC_INSTRUCTIONS =
    "If running a shell command would help answer the question, " ..
    "append exactly one line at the very end of your response in this format:\n" ..
    "EXEC: <command>\n" ..
    "Do not include explanation after the EXEC line. " ..
    "The user will be shown the command and asked for permission before it runs.\n\n"

proxy.on("input", function(data)
    -- Intercept keypresses while waiting for permission
    if pending_cmd then
        for i = 1, #data do
            local ch = data:sub(i, i)
            local b  = ch:byte()
            if ch == "y" or ch == "Y" then
                proxy.inject_output("y\r\n")
                proxy.send_input(pending_cmd .. "\n")
                pending_cmd = nil
            elseif b == 27 or ch == "n" or ch == "N" or ch == "\r" or ch == "\n" then
                proxy.inject_output("N\r\n[ai] cancelled\r\n")
                pending_cmd = nil
            end
        end
        return "suppress"
    end

    -- Normal #ai: line buffering
    for i = 1, #data do
        local ch = data:sub(i, i)
        local b  = ch:byte()
        if ch == "\r" or ch == "\n" then
            local line = table.concat(buf)
            buf = {}
            if line:match("^#ai:") then
                local question = line:gsub("^#ai:%s*", ""):gsub("%s+$", "")
                if #question > 0 then
                    proxy.inject_output("\r\n[ai] thinking...\r\n")

                    -- Prefer structured session-log context; fall back to text buffer.
                    local n_cmds = (type(AI_CONTEXT_COMMANDS) == "number")
                        and AI_CONTEXT_COMMANDS or 10
                    local context = read_session_context(n_cmds)
                    if not context and #history > 0 then
                        context = "Recent terminal output:\n```\n" ..
                            table.concat(history, "\n") .. "\n```"
                    end

                    local prompt = EXEC_INSTRUCTIONS
                    if context then
                        prompt = prompt .. context .. "\n\nQuestion: " .. question
                    else
                        prompt = prompt .. "Question: " .. question
                    end

                    local response, err = llm.query(prompt, AI_QUERY_LLM)
                    if err then
                        proxy.inject_output("[ai] error: " .. err .. "\r\n")
                    else
                        local exec_cmd = response:match("\nEXEC:%s*([^\n]+)%s*$")
                                      or response:match("^EXEC:%s*([^\n]+)%s*$")
                        if exec_cmd then
                            exec_cmd = exec_cmd:match("^%s*(.-)%s*$")
                            local body = response:gsub("\n?EXEC:%s*[^\n]+%s*$", ""):gsub("%s*$", "")
                            if #body > 0 then
                                proxy.inject_output("[ai] " .. body:gsub("\n", "\r\n") .. "\r\n")
                            end
                            proxy.inject_output("[ai] run: " .. exec_cmd .. " ? [y/N] ")
                            pending_cmd = exec_cmd
                        else
                            proxy.inject_output("[ai] " .. response:gsub("\n", "\r\n") .. "\r\n")
                        end
                    end
                end
            end
        elseif b == 127 or b == 8 then
            if #buf > 0 then table.remove(buf) end
        elseif b >= 32 then
            buf[#buf + 1] = ch
        end
    end
end)
