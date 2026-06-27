-- workflow_journal.lua — AI-structured work journal
--
-- At session end, reads the current session log and spawns a background process
-- that asks the LLM to group commands into named tasks, then appends the result
-- to a running journal file.
--
-- Journal: ~/.local/share/ttyrell/journal.md

if TTYRELL_MODE then return end  -- skip in background modes

local home = os.getenv("HOME") or ""
if home == "" then return end

local journal_path = home .. "/.local/share/ttyrell/journal.md"

local ok_llm, llm = pcall(require, "llm")
if not (ok_llm and llm) then return end

local session_start = os.time()

proxy.on("session_start", function()
    session_start = os.time()
end)

proxy.on("session_end", function()
    local log_path = CURRENT_SESSION_LOG
    if not log_path then return end

    -- Only journal sessions that contain at least one command
    local lf = io.open(log_path, "r")
    if not lf then return end
    local content = lf:read("*a")
    lf:close()
    if not content:find('"input"', 1, true) then return end

    local duration = math.max(1, os.time() - session_start)
    local bin = (TTYRELL_BIN or "ttyrell"):gsub("'", "")
    proxy.spawn(string.format("'%s' --journal '%s' '%s' %d",
        bin, log_path, journal_path, duration))
    proxy.inject_output("[journal] writing work log in background → journal.md\r\n")
end)
