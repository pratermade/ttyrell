-- workflow_journal.lua — AI-structured work journal
--
-- At session end, reads the current session log and spawns a background process
-- that asks the LLM to group commands into named tasks, then appends the result
-- to a running journal file.
--
-- ── Settings ─────────────────────────────────────────────────────────────────
-- Uncomment and edit any of these to customize behaviour:
--
JOURNAL_OBSIDIAN_VAULT = "/Volumes/home/pratersm/obsidian/notes"
JOURNAL_OBSIDIAN_DIR   = "Work Journal"   -- subdirectory inside the vault
--
-- Prompt sent to the LLM when writing journal entries.
-- Edit this to change what the AI focuses on or how it formats output.
JOURNAL_PROMPT = [[
You are writing a developer's/system administrator's work journal. Given this terminal session log
(JSONL format), identify distinct tasks and summarize each concisely in markdown.

Output ONLY task sections -- no preamble, no date header, no closing remarks:

### Task Name
- Key outcome or finding
- Host task was performed on
- Additional detail (omit if redundant)

Rules:
- Name tasks with action verbs: Fixed auth bug, Deployed API, Set up database
- Summarize outcomes, not steps -- do not list every command typed
- Group closely related commands into one task
- Skip trivial commands: cd, ls, pwd, echo, clear, history
- If errors were encountered and resolved, note it in one bullet
- If a task was abandoned with no result, omit it]]
--
-- LLM provider for journal entries — pick from the palette defined in init.lua:
JOURNAL_LLM = LLM.local_llama
-- JOURNAL_LLM = LLM.claude
--
-- ─────────────────────────────────────────────────────────────────────────────

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
