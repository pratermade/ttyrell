-- ai_query.lua — #ai: prefix handler
--
-- Intercepts lines starting with "#ai:", sends the question to the LLM
-- with the last N lines of terminal output as context, and prints the
-- response inline. "#ai:" is a zsh comment so the shell ignores it.
--
-- Set AI_CONTEXT_LINES in init.lua to override the default (64).

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
    -- Trim to window
    local excess = #history - CONTEXT_LINES
    if excess > 0 then
        table.move(history, excess + 1, #history, 1)
        for i = #history - excess + 1, #history do history[i] = nil end
    end
end)

local buf = {}

proxy.on("input", function(data)
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
                    local prompt = question
                    if #history > 0 then
                        prompt = "Recent terminal output:\n```\n" ..
                            table.concat(history, "\n") ..
                            "\n```\n\nQuestion: " .. question
                    end
                    local response, err = llm.query(prompt)
                    if err then
                        proxy.inject_output("[ai] error: " .. err .. "\r\n")
                    else
                        local formatted = response:gsub("\n", "\r\n")
                        proxy.inject_output("[ai] " .. formatted .. "\r\n")
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
