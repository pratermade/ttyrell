-- ai_query.lua — #ai: prefix handler with optional shell command execution
--
-- Type "#ai: <question>" and press Enter. The AI sees the last N lines of
-- terminal output as context. If the AI wants to run a command it appends
-- "EXEC: <cmd>" — ttyrell shows it and asks [y/N] before running anything.
--
-- Set AI_CONTEXT_LINES in init.lua to override the context window (default 64).
--
-- LLM provider for AI queries — pick from the palette defined in init.lua:
AI_QUERY_LLM = LLM.local_llama
-- AI_QUERY_LLM = LLM.claude

local llm = require("llm")

local CONTEXT_LINES = (type(AI_CONTEXT_LINES) == "number" and AI_CONTEXT_LINES > 0)
    and AI_CONTEXT_LINES or 64

-- Rolling buffer of recent output lines (ANSI-stripped by proxy.rs)
local history = {}

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

                    local prompt = EXEC_INSTRUCTIONS
                    if #history > 0 then
                        prompt = prompt ..
                            "Recent terminal output:\n```\n" ..
                            table.concat(history, "\n") ..
                            "\n```\n\nQuestion: " .. question
                    else
                        prompt = prompt .. "Question: " .. question
                    end

                    local response, err = llm.query(prompt, AI_QUERY_LLM)
                    if err then
                        proxy.inject_output("[ai] error: " .. err .. "\r\n")
                    else
                        -- Check for EXEC: line at end of response
                        local exec_cmd = response:match("\nEXEC:%s*([^\n]+)%s*$")
                                      or response:match("^EXEC:%s*([^\n]+)%s*$")
                        if exec_cmd then
                            exec_cmd = exec_cmd:match("^%s*(.-)%s*$")
                            -- Show the non-EXEC part of the response (if any)
                            local body = response:gsub("\n?EXEC:%s*[^\n]+%s*$", ""):gsub("%s*$", "")
                            if #body > 0 then
                                proxy.inject_output("[ai] " .. body:gsub("\n", "\r\n") .. "\r\n")
                            end
                            -- Permission prompt — stays on one line, awaits y/N
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
