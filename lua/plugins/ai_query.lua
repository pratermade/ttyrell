-- ai_query.lua — #ai: prefix handler
--
-- Intercepts lines starting with "#ai:", sends the question to the LLM,
-- and prints the response inline. The "#ai:" prefix is a zsh comment so
-- the shell ignores it silently; the AI response is injected after.

local llm = require("llm")
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
                    local response, err = llm.query(question)
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
            table.insert(buf, ch)
        end
    end
end)
