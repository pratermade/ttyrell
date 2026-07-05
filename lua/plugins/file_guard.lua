-- file_guard.lua — Backs up files before vim/nvim edits and diffs+summarizes
--                  changes when the session ends.
--
-- Backups live in:   ~/.local/share/ttyrell/file_guard/
-- Change log:        ~/.local/share/ttyrell/file_guard/changes.jsonl
--
-- Each JSONL entry:
--   {"path":"...","backup":"...","diff":"...","summary":"...","t":"..."}
--
-- The diff is a unified diff (10 lines of context before/after each hunk).
-- An optional LLM summary (if LLM provider is set) appends a high-level
-- overview of the changes.

-- ── Settings ─────────────────────────────────────────────────────────────────
-- Set to an LLM provider from the palette (e.g. LLM.local_llama) to get an
-- AI-generated summary appended after the raw diff.  Leave as nil to log only
-- the diff.
--
-- CHANGE_SUMMARY_LLM = LLM.local_llama
local CHANGE_SUMMARY_LLM = nil

-- Prompt sent to the LLM when summarizing a diff.  Edit to taste.
CHANGE_SUMMARY_PROMPT = [[
You are a code reviewer.  Analyze this unified diff and produce a concise
summary of what changed.

Rules:
- 1-2 sentences of overall context
- Bullet list of what was added (grouped by file)
- Bullet list of what was removed (grouped by file)
- Note any surprising or significant changes (new functions, removed files,
  large blocks of deleted/added code, etc.)
- Output only the summary — no preamble, no closing remarks.

Diff:
---
]]

-- Glob patterns to exclude (space-separated).  Files matching any pattern are
-- ignored.  Example: "*.swp *.swo *.lock"
--
-- CHANGE_IGNORED_PATTERNS = "*.swp *.swo *.lock"
local CHANGE_IGNORED_PATTERNS = "*.swp *.swo *.lock"

-- ─────────────────────────────────────────────────────────────────────────────

-- Platform helpers
local is_windows = package.config:sub(1, 1) == '\\'
local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
if home == "" then return end

local data_dir = home .. "/.local/share/ttyrell"
local guard_dir = data_dir .. "/file_guard"

local function mkdir_p(path)
    if is_windows then
        os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
    else
        os.execute("mkdir -p '" .. path .. "'")
    end
end
mkdir_p(guard_dir)

-- ── State ────────────────────────────────────────────────────────────────────

local vim_active  = false   -- true while a vim/nvim TUI session is active
local edited_path = nil     -- absolute path of the file currently being edited
local edited_backup = nil   -- path to its backup

-- ── Helpers ──────────────────────────────────────────────────────────────────

--- Check if |output| contains a vim/nvim command and extract the target file.
-- Returns: file_path (string) | nil
local function detect_vim_file(output)
    local cmd = output:match(".*\r([^\r\n]+)$")
    if not cmd then return nil end

    -- Match: [whitespace or start][nvim|vim][whitespace/dash][<flags> ]<file>
    -- We use string.match with 4 captures: boundary, command, flags+separator, file
    local _, _, _, file = cmd:match("(^|[%s])(nvim|vim)([%s%-]+)([^%s%-]+)")
    return file
end

--- Check if |path| should be ignored based on CHANGE_IGNORED_PATTERNS.
local function is_ignored(path)
    local basename = path:match("([^/\\]+)$") or path
    for pat in (CHANGE_IGNORED_PATTERNS or ""):gmatch("%S+") do
        if basename:find(pat:gsub("%%", "%%%%"):gsub("%.", "%%."):gsub("%*", ".*"):gsub("?", ".") .. "$") then
            return true
        end
    end
    return false
end

--- Get the backup path for a given file.
local function backup_path_for(path)
    local name = path:match("([^/\\]+)$") or path
    local dir  = path:match("(.*/)") or "."
    return guard_dir .. "/" .. dir:gsub("[^a-zA-Z0-9_-]", "_") .. "_" .. name
end

--- Check whether a backup exists and compare against the current file.
-- Returns: diff_text or nil (if no backup or no changes)
local function get_diff(path, backup)
    if not backup or not (io.open(path, "r") or io.open(backup, "r")) then return nil end

    if is_windows then
        local cmd = string.format(
            'powershell -NoProfile -Command "' ..
            'diff -ReferenceObject (Get-Content %q) -DifferenceObject (Get-Content %q) 2>$null"',
            path:gsub("'", "''"),
            backup:gsub("'", "''")
        )
        local pipe = io.popen(cmd)
        if not pipe then return nil end
        local out = pipe:read("*a"):gsub("\r\n", "\n"):gsub("\n$", "")
        pipe:close()
        return #out > 0 and out or nil
    else
        local cmd = string.format(
            "diff -u '%s' '%s' 2>/dev/null",
            path, backup
        )
        local pipe = io.popen(cmd)
        if not pipe then return nil end
        local out = pipe:read("*a"):gsub("\n$", "")
        pipe:close()
        return #out > 0 and out or nil
    end
end

--- Parse unified diff output into a summary table.
-- Returns: { lines_added, lines_removed, files_changed }
local function parse_diff_output(diff_text)
    local added    = 0
    local removed  = 0
    local files    = {}
    local cur_file = nil

    for line in diff_text:gmatch("([^\n]*)\n?") do
        if line:match("^diff ") then
            cur_file = line:match("diff --.*b/(.+)$")
            if cur_file then files[cur_file] = { a = 0, b = 0 } end
        elseif line:match("^--- ") then
            -- skip
        elseif line:match("^\\+\\+\\+ ") then
            -- skip
        elseif line:match("^@@") then
            -- hunk header, skip
        elseif line:match("^%+") then
            added = added + 1
            if cur_file then files[cur_file].b = files[cur_file].b + 1 end
        elseif line:match("^%-") then
            removed = removed + 1
            if cur_file then files[cur_file].a = files[cur_file].a + 1 end
        end
    end

    return {
        lines_added    = added,
        lines_removed  = removed,
        files_changed  = files,
    }
end

--- Format a diff into a readable summary for the log.
local function summarize_diff(diff_text, path, backup)
    if not diff_text then return "" end

    local stats = parse_diff_output(diff_text)
    local lines = {}
    local basename = path:match("([^/\\]+)$") or path

    table.insert(lines, string.format(
        "## %s  (%s → %s)\n\n",
        basename,
        backup:gsub(guard_dir .. "/", ""),
        path
    ))

    table.insert(lines, string.format(
        "- **%d lines added**, **%d lines removed**\n\n",
        stats.lines_added,
        stats.lines_removed
    ))

    -- Show a short excerpt of the diff (first 15 lines of content)
    local excerpt_lines = {}
    for line in diff_text:gmatch("([^\n]+)") do
        -- skip diff metadata lines
        if not (line:match("^diff ") or line:match("^--- ") or line:match("^\\+\\+\\+ ") or line:match("^@@")) then
            table.insert(excerpt_lines, line)
        end
        if #excerpt_lines >= 15 then break end
    end

    if #excerpt_lines > 0 then
        table.insert(lines, "```\n")
        for _, el in ipairs(excerpt_lines) do table.insert(lines, el .. "\n") end
        table.insert(lines, "```\n")
    end

    return table.concat(lines)
end

--- Get (or create) the backup for |path|.
-- Returns: (backup_path, was_new)
local function ensure_backup(path)
    local bkp = backup_path_for(path)
    local src = io.open(path, "r")
    if not src then return bkp, false end

    local existing = io.open(bkp, "r")
    if existing then
        existing:close()
        -- Backup already exists — don't overwrite.
        src:close()
        return bkp, false
    end

    local content = src:read("*a")
    src:close()

    local dst = io.open(bkp, "w")
    if dst then
        dst:write(content)
        dst:close()
        return bkp, true
    end
    return bkp, false
end

--- Log a change entry to the JSONL change log.
local function log_change(entry)
    entry.t = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local ok, line = pcall(proxy.json_encode, entry)
    if not ok then return end
    local log_file = guard_dir .. "/changes.jsonl"
    local f, err = io.open(log_file, "a")
    if f then
        f:write(line .. "\n")
        f:close()
    else
        proxy.inject_output(string.format(
            "\r\n[file_guard] cannot open change log: %s\r\n",
            tostring(err)
        ))
    end
end

-- ── Events ───────────────────────────────────────────────────────────────────

proxy.on("command_start", function()
    -- Detect vim/nvim command and back up the target file(s).
    -- (command_start fires just before the shell executes the command.)
    local cmd_output = io.popen("ps -o args= -p $$ 2>/dev/null"):read("*a")
    if not cmd_output then return end

    local file = detect_vim_file(cmd_output)
    if not file then return end
    if is_ignored(file) then return end

    -- Resolve to absolute path
    local abs = file:match("^/") and file or (os.getenv("PWD") or ".") .. "/" .. file
    if not io.open(abs, "r") then return end  -- file doesn't exist yet

    local bkp, was_new = ensure_backup(abs)
    if was_new then
        vim_active = true
        edited_path    = abs
        edited_backup  = bkp
    end
end)

proxy.on("tui_start", function()
    if vim_active then
        vim_active = true  -- confirm active
        proxy.inject_output("\r\n[file_guard] file backed up before session\r\n")
    end
end)

proxy.on("tui_end", function()
    if not vim_active then return end

    local path    = edited_path
    local backup  = edited_backup
    local was_new = false

    if backup then
        local f = io.open(backup, "r")
        if f then f:close(); was_new = true end
    end

    local diff_text = get_diff(path, backup)
    local summary   = ""

    -- Optional LLM summary
    if CHANGE_SUMMARY_LLM and diff_text then
        local ok, llm_mod = pcall(require, "llm")
        if ok and llm_mod then
            local resp, err = llm_mod.query(
                CHANGE_SUMMARY_PROMPT .. "\n" .. diff_text,
                CHANGE_SUMMARY_LLM
            )
            if resp and not err then
                summary = "\n---\n\n### Summary\n\n" .. resp
            end
        end
    end

    local log_entry = {
        type   = "file_guard",
        path   = path,
        diff   = diff_text or "",
        summary = summary,
        stats  = diff_text and parse_diff_output(diff_text),
    }
    log_change(log_entry)

    -- Show a brief notification
    local basename = path:match("([^/\\]+)$") or path
    local stats = diff_text and parse_diff_output(diff_text) or { lines_added = 0, lines_removed = 0 }
    proxy.inject_output(
        string.format(
            "\r\n[file_guard] %s: +%d /-%d (logged)\r\n",
            basename,
            stats.lines_added,
            stats.lines_removed
        )
    )

    -- Clean up the backup
    if backup then
        local ok, _ = os.remove(backup)
        if not ok then
            -- non-fatal: backup cleanup failed, leave it for next time
        end
    end

    vim_active = false
    edited_path    = nil
    edited_backup  = nil
end)

-- Fallback: if session ends while vim is still active (terminal crash, etc.)
proxy.on("session_end", function()
    if not vim_active then return end

    local path    = edited_path
    local backup  = edited_backup

    if backup then
        local f = io.open(backup, "r")
        if f then f:close() else return end  -- no backup to compare

        local diff_text = get_diff(path, backup)
        local summary   = ""

        if CHANGE_SUMMARY_LLM and diff_text then
            local ok, llm_mod = pcall(require, "llm")
            if ok and llm_mod then
                local resp, err = llm_mod.query(
                    CHANGE_SUMMARY_PROMPT .. "\n" .. diff_text,
                    CHANGE_SUMMARY_LLM
                )
                if resp and not err then
                    summary = "\n---\n\n### Summary\n\n" .. resp
                end
            end
        end

        local log_entry = {
            type   = "file_guard",
            path   = path,
            diff   = diff_text or "",
            summary = summary,
            stats  = diff_text and parse_diff_output(diff_text),
        }
        log_change(log_entry)

        local basename = path:match("([^/\\]+)$") or path
        proxy.inject_output(
            string.format(
                "\r\n[file_guard] (session end) %s: diff logged\r\n",
                basename
            )
        )

        -- Clean up backup
        os.remove(backup)
    end

    vim_active = false
    edited_path    = nil
    edited_backup  = nil
end)
