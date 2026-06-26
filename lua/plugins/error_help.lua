-- error_help.lua — Non-zero exit code handler with LLM assistance
--
-- On command_exit with a non-zero code, queries the LLM using recent terminal
-- output as context so the response is specific to what actually failed.
--
-- NOTE: last_cmd is populated by shell integration (shell/integration.*).
-- Without it the ignore list is a no-op but LLM assistance still works.

local ignore_set = {}
for _, cmd in ipairs({ "grep", "diff", "test", "false", "[", ":" }) do
    ignore_set[cmd] = true
end

local last_cmd = ""

local function should_ignore(cmd)
    local first_word = cmd:match("^(%S+)") or cmd
    return ignore_set[first_word] == true
end

-- Rolling buffer of recent terminal output — gives the LLM context about
-- what was running when the failure occurred
local recent_lines = {}
local MAX_LINES = 40

proxy.on("output", function(text)
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if #line > 0 then
            table.insert(recent_lines, line)
            if #recent_lines > MAX_LINES then
                table.remove(recent_lines, 1)
            end
        end
    end
end)

proxy.on("command_exit", function(exit_code)
    local code = tonumber(exit_code) or -1
    if code <= 0 or should_ignore(last_cmd) then return end

    local ok, llm = pcall(require, "llm")
    if not (ok and llm) then
        proxy.inject_output(
            "\r\n[error_help] exit " .. exit_code ..
            " — add llm.setup() to init.lua for AI help\r\n"
        )
        return
    end

    local context = table.concat(recent_lines, "\n")
    local response, err = llm.query(
        string.format(
            "A shell command just exited with code %d.\n" ..
            "Recent terminal output for context:\n\n%s\n\n" ..
            "In 1-2 sentences: what likely caused this and what should I check?",
            code, context
        )
    )

    if err then
        proxy.inject_output("\r\n[error_help] " .. err .. "\r\n")
    elseif response then
        proxy.inject_output("\r\n[error_help] " .. response .. "\r\n")
    end
end)
