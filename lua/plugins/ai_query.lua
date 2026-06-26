-- ai_query.lua — #ai: prefix handler
--
-- Intercepts lines starting with "#ai:", sends the question to the LLM,
-- and prints the response inline. The "#ai:" line is never sent to the shell.

local llm = require("llm")

proxy.on("input", function(line)
    if line:match("^#ai:") then
        local question = line:gsub("^#ai:%s*", ""):gsub("%s+$", "")
        if question == "" then return "suppress" end

        proxy.inject_output("\r\n[ai] thinking...\r\n")
        local response, err = llm.query(question)
        if err then
            proxy.inject_output("[ai] error: " .. err .. "\r\n")
        else
            proxy.inject_output("[ai] " .. response .. "\r\n")
        end
        return "suppress"
    end
end)
