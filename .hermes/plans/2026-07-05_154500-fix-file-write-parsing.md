# Fix File Write Parsing in ai_query Plugin

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Fix the file-writing feature in the ai_query plugin. When the user asks the AI to write a file via `@filename`, the LLM returns a properly formatted `<<<FILE>>>...<<<ENDFILE>>>` block, but the file is never written to disk because the Lua pattern used to extract the block can't match multi-line content.

**Architecture:** The fix is a one-line change in `ai_query.lua` — the Lua pattern used to match the FILE block needs to handle multi-line content. Lua's `.` metacharacter does NOT match newlines, so the capture group `(.-)` between `\n` and `\n<<<ENDFILE>>>` can only capture single-line content. The fix replaces the pattern with one that explicitly matches across newlines using `[^\n]` negation or a manual multi-line extraction.

**Tech Stack:** Lua 5.5, no external dependencies.

---

## Root Cause Analysis

The regex at `lua/plugins/ai_query.lua:491`:

```lua
local wpath, wcontent = response:match("<<<FILE%s+(.-)%s*>>>\n(.-)\n<<<ENDFILE>>>")
```

In Lua patterns, `.` matches any single character **except newline**. So `(.-)` (lazy match) between `\n` and `\n<<<ENDFILE>>>` will:
1. Start capturing after the first `\n` (after `>>>`)
2. Lazily match characters until it finds `\n<<<ENDFILE>>>`
3. BUT since `.` doesn't match newlines, it stops at the FIRST embedded `\n` inside the content

For a file like:
```
<<<FILE story.md>>>
Once upon a time
there was a snake
<<<ENDFILE>>>
```

The pattern matches `wpath = "story.md"` correctly, but `wcontent` captures only `"Once upon a time"` (up to the first `\n`). Then `\n<<<ENDFILE>>>` doesn't match because the next character is `t` (from "there was..."), so the overall `match()` returns nil.

**Result:** `wpath` is nil, the code falls through to the EXEC check, no file write is offered, and the user sees no file created.

---

## Plan

### Task 1: Fix the FILE block regex to handle multi-line content

**Objective:** Replace the Lua pattern that extracts `<<<FILE path>>>...<<<ENDFILE>>>` blocks with one that correctly captures multi-line file content.

**Files:**
- Modify: `lua/plugins/ai_query.lua:491`

**Step 1: Replace the pattern**

Current (broken):
```lua
local wpath, wcontent = response:match("<<<FILE%s+(.-)%s*>>>\n(.-)\n<<<ENDFILE>>>")
```

Replace with a multi-line-aware extraction:

```lua
-- Lua patterns: . does not match \n. For multi-line FILE blocks we
-- search for the markers manually with string offsets.
local fstart, fend = response:find("<<<FILE%s+(.-)%s*>>>\n()")
if fstart then
    local wpath = response:match("<<<FILE%s+(.-)%s*>>>")
    local content_start = fend
    local content_end = response:find("\n<<<ENDFILE>>>", content_start, true)
    if content_end then
        local wcontent = response:sub(content_start, content_end - 1)
        -- rest of the existing logic (strip code fences, etc.)
    end
end
```

Wait — let me think about this more carefully. The `wpath` extraction from `response:match("<<<FILE%s+(.-)%s*>>>")` already works fine because the path is single-line. The problem is only with extracting the multi-line content.

Simpler fix: replace the problem pattern with a two-step extraction using `string.find` with plain-text search for the `ENDFILE` marker:

```lua
local wpath = response:match("<<<FILE%s+(.-)%s*>>>\n()")
-- ...but match doesn't return positions...

-- Actually, just use find() to get positions, then sub() to extract:
local pstart, pend, wpath = response:find("<<<FILE%s+(.-)%s*>>>\n()")
if pstart then
    local content_start = pend  -- pend from the () capture is position after \n
    -- ...
end
```

Hmm, Lua `string.find` with captures returns the captures but not the positions of those captures. Let me use the `()` position capture trick:

```lua
local pstart, pend, wpath = response:find("<<<FILE%s+(.-)%s*>>>\n()")
```

This returns: `pstart` (start of match), `pend` (end of match), `wpath` (first capture), and then the position of the `()` capture... actually, in Lua, `find` returns pairs of (start, end) for each capture. So:

```lua
local p1, p2, wpath, content_start = response:find("<<<FILE%s+(.-)%s*>>>\n()")
```

This gives us `wpath` and `content_start` (the position right after `\n`). Then:

```lua
if p1 then
    local content_end = response:find("\n<<<ENDFILE>>>", content_start, true)
    if content_end then
        local wcontent = response:sub(content_start, content_end - 1)
    end
end
```

This is clean and correct. Let me write the plan properly.

---

### Task 1: Fix the FILE block extraction in ai_query.lua

**Objective:** Replace the single-pattern `string.match` call with a two-step `string.find` + `string.sub` approach that correctly captures multi-line file content between `<<<FILE path>>>` and `<<<ENDFILE>>>`.

**Files:**
- Modify: `lua/plugins/ai_query.lua` (line 491)

**Step 1: Replace the single match() with find() + sub()**

Current code (lines 491–502):
```lua
    local wpath, wcontent = response:match("<<<FILE%s+(.-)%s*>>>\n(.-)\n<<<ENDFILE>>>")
    if wpath and wpath ~= "" then
        -- Defensive: strip a wrapping code fence if the model added one anyway.
        wcontent = wcontent:gsub("^```[%w]*\n", ""):gsub("\n```%s*$", "")
        local body = response:gsub("<<<FILE.-<<<ENDFILE>>>", ""):gsub("%s*$", "")
```

Replace with:
```lua
    -- Lua's . metacharacter does not match newlines, so a single match() cannot
    -- capture multi-line content. Use find() with a position-capture trick to
    -- locate the boundaries, then sub() to extract the content.
    local wpath, wcontent = nil, nil
    local p1, _, cap_path, content_start = response:find("<<<FILE%s+(.-)%s*>>>\n()")
    if p1 and cap_path ~= "" then
        local content_end = response:find("\n<<<ENDFILE>>>", content_start, true)
        if content_end then
            wpath = cap_path
            wcontent = response:sub(content_start, content_end - 1)
        end
    end
    if wpath and wpath ~= "" then
        -- Defensive: strip a wrapping code fence if the model added one anyway.
        wcontent = wcontent:gsub("^```[%w]*\n", ""):gsub("\n```%s*$", "")
        local body = response:gsub("<<<FILE.-<<<ENDFILE>>>", ""):gsub("%s*$", "")
```

**Step 2: Build and verify with tests**

Run: `cargo test`
Expected: all existing tests pass.

**Step 3: Commit**

```bash
git add lua/plugins/ai_query.lua
git commit -m "fix: handle multi-line content in FILE block extraction

Lua's . metacharacter does not match newlines, so the single match()
call for <<<FILE ... >>> ... <<<ENDFILE>>> could only capture
single-line content. Replace with a two-step find() + sub() approach
that correctly extracts multi-line file contents.

Closes #3"
```

## Verification

After the fix:

1. Start ttyrell
2. Press Ctrl-G to open the AI query
3. Type: "Write me a story about snakes and save it to @story.md"
4. The AI should respond with a `<<<FILE story.md>>>...<<<ENDFILE>>>` block
5. ttyrell should show a diff and offer to apply the change
6. Press `y` — the file should be created
7. Verify: `cat story.md` shows the story

## Files Changed Summary

| File | Change |
|------|--------|
| `lua/plugins/ai_query.lua` | Replace `response:match(...)` with two-step `find`+`sub` for multi-line FILE blocks |

## Risks

- **Low risk:** The change is localized to the FILE block extraction. The path extraction (`cap_path`) still uses the same Lua pattern as before (`<<<FILE%s+(.-)%s*>>>`), which already worked correctly for single-line paths.
- **Edge case:** If the LLM somehow outputs `<<<ENDFILE>>>` without a preceding `\n`, the plain-text `find` won't match. This is acceptable because the prompt instructions explicitly say `\n<<<ENDFILE>>>` — the newline is required by the format spec.
- **Windows CRLF:** The `\n` literals in the pattern won't match `\r\n`. However, the LLM response is received as a string from `json_decode` and does not contain `\r\n` line endings. If this becomes an issue later, the fix is to use `"\r?\n<<<ENDFILE>>>"` in the plain-text find — but plain `find` with `true` (plain mode) doesn't support patterns, so it would need a pattern-mode find without `true`.
