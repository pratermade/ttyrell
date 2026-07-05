-- workflow_journal.lua — AI-structured work journal
--
-- At session end, reads the current session log and spawns a background process
-- that asks the LLM to group commands into named tasks, then appends the result
-- to a running journal file.
--
-- ── Settings ─────────────────────────────────────────────────────────────────
-- Uncomment and edit any of these to customize behaviour:
--
-- JOURNAL_OBSIDIAN_VAULT = "/path/to/your/vault"
-- JOURNAL_OBSIDIAN_DIR   = "Work Journal"   -- subdirectory inside the vault
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

-- Background task: turn a session log into journal entries. Registered above the
-- mode guard so it exists when `ttyrell --task journal` re-invokes this plugin in
-- a detached process. All logic lives here in Lua.
proxy.on_task("journal", function(log_path, journal_path, duration_secs)
    local ok, llm = pcall(require, "llm")
    if not (ok and llm) or not JOURNAL_PROMPT then return end

    local lf = io.open(log_path, "r")
    if not lf then return end
    local log = lf:read("*a")
    lf:close()
    if log:gsub("%s", "") == "" then return end

    local secs     = tonumber(duration_secs) or 0
    local mins     = math.floor(secs / 60)
    local duration = (mins > 0) and (mins .. "m " .. (secs % 60) .. "s") or (secs .. "s")

    local tasks = llm.query(JOURNAL_PROMPT .. "\n- Session duration: " .. duration,
        JOURNAL_LLM, log)
    if not tasks then return end
    local tasks_clean = tasks:gsub("%s*$", "")

    -- Main journal file (full date + time heading)
    local entry = "## " .. os.date("%Y-%m-%d %H:%M") .. " -- " .. duration .. "\n\n"
               .. tasks_clean .. "\n\n---\n\n"
    local f = io.open(journal_path, "a")
    if f then f:write(entry); f:close() end

    -- Obsidian daily note (time-only heading; date is the filename)
    if JOURNAL_OBSIDIAN_VAULT then
        local sub_dir   = JOURNAL_OBSIDIAN_DIR or "Work Journal"
        local vault_dir = JOURNAL_OBSIDIAN_VAULT .. "/" .. sub_dir
        if package.config:sub(1, 1) == "\\" then
            os.execute('mkdir "' .. vault_dir:gsub("/", "\\") .. '" 2>nul')
        else
            os.execute('mkdir -p "' .. vault_dir .. '"')
        end
        local daily_file = vault_dir .. "/" .. os.date("%Y-%m-%d") .. ".md"
        local obs_entry  = "## " .. os.date("%H:%M") .. " -- " .. duration .. "\n\n"
                        .. tasks_clean .. "\n\n---\n\n"
        local of = io.open(daily_file, "a")
        if of then of:write(obs_entry); of:close() end
    end
end)

if TTYRELL_MODE then return end  -- registered our task above; skip interactive wiring

local data_dir
if package.config:sub(1, 1) == '\\' then
    local appdata = (os.getenv("LOCALAPPDATA") or os.getenv("APPDATA") or ""):gsub('\\', '/')
    if appdata == "" then return end
    data_dir = appdata .. "/ttyrell"
else
    local home = os.getenv("HOME") or ""
    if home == "" then return end
    data_dir = home .. "/.local/share/ttyrell"
end

local journal_path = data_dir .. "/journal.md"

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
    local bin = (TTYRELL_BIN or "ttyrell"):gsub('"', '')
    proxy.spawn(string.format('"%s" --task journal "%s" "%s" %d',
        bin, log_path, journal_path, duration))
    proxy.inject_output("[journal] writing work log in background → journal.md\r\n")
end)
