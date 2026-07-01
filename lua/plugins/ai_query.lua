-- ai_query.lua — #ai: prefix handler with optional shell command execution
--
-- Type "#ai: <question>" and press Enter. The AI sees recent session
-- history as context. If the AI wants to run a command it appends
-- "EXEC: <cmd>" — ttyrell shows it and asks [y/N] before running anything.
--
-- ── File references ───────────────────────────────────────────────────────────
-- Include file content in context by mentioning @path in the question:
--   #ai: @src/main.rs why is line 42 failing
--   #ai: @Cargo.toml @src/lib.rs explain the dependency setup
-- The @ is stripped from the question text; the file content appears in context.
-- Paths are resolved relative to the directory ttyrell was launched from.
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

local pending_cmd = nil
local buf = {}

local EXEC_INSTRUCTIONS =
    "If running a shell command would help answer the question, " ..
    "append exactly one line at the very end of your response in this format:\n" ..
    "EXEC: <command>\n" ..
    "Do not include explanation after the EXEC line. " ..
    "The user will be shown the command and asked for permission before it runs.\n\n"

proxy.on("input", function(data)
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

    for i = 1, #data do
        local ch = data:sub(i, i)
        local b  = ch:byte()
        if ch == "\r" or ch == "\n" then
            local line = table.concat(buf)
            buf = {}
            if line:match("^#ai:") then
                local raw = line:gsub("^#ai:%s*", ""):gsub("%s+$", "")
                if #raw > 0 then
                    proxy.inject_output("\r\n[ai] thinking...\r\n")

                    local question, file_refs = extract_file_refs(raw)

                    -- 1. File context (listed files, in order)
                    local context_parts = {}
                    for _, path in ipairs(file_refs) do
                        local content, err = read_file(resolve_path(path))
                        if err then
                            proxy.inject_output("[ai] " .. err .. "\r\n")
                        else
                            table.insert(context_parts,
                                "File: " .. path .. "\n```\n" .. content .. "\n```")
                        end
                    end

                    -- 2. Session log context (structured command history)
                    local n_cmds = (type(AI_CONTEXT_COMMANDS) == "number")
                        and AI_CONTEXT_COMMANDS or 10
                    local session_ctx = read_session_context(n_cmds)
                    if session_ctx then
                        table.insert(context_parts, session_ctx)
                    elseif #history > 0 then
                        -- Fallback: raw output buffer
                        table.insert(context_parts,
                            "Recent terminal output:\n```\n" ..
                            table.concat(history, "\n") .. "\n```")
                    end

                    local context = #context_parts > 0
                        and table.concat(context_parts, "\n\n") or nil

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
