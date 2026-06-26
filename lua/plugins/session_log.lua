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

proxy.on("input", function(data)
    append({ type = "input", data = data })
end)

proxy.on("output", function(text)
    append({ type = "output", data = text })
end)

proxy.on("command_exit", function(exit_code)
    append({ type = "command_exit", exit_code = tonumber(exit_code) })
end)

proxy.on("session_end", function()
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
        "  input         — keystrokes/lines sent to the shell\n" ..
        "  output        — text received from the shell/remote\n" ..
        "  command_exit  — exit code of a completed command\n" ..
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
