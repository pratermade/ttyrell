-- ttyrell init.lua
-- The proxy API is available as the global `proxy`.

local base = PROXY_LUA_DIR or "."

-- Add lua/ to the module path so plugins can require("llm")
package.path = package.path .. ";" .. base .. "/?.lua"

local function try_load(path)
    local f, err = loadfile(path .. ".lua")
    if f then return pcall(f) end
    return false, err
end

-- ── LLM providers ────────────────────────────────────────────────────────────
-- Define named providers here. Plugins reference them by name, e.g.:
--   JOURNAL_LLM = LLM.local_llama
--
LLM = {
    local_llama = {
        endpoint = "http://mint.pratermade.com:8083/v1/chat/completions",
        model    = "default",
    },
    -- claude = {
    --     endpoint = "https://api.anthropic.com/v1/messages",
    --     api_key  = os.getenv("ANTHROPIC_API_KEY"),
    --     model    = "claude-opus-4-8",
    --     headers  = function(cfg)
    --         return {
    --             ["x-api-key"]         = cfg.api_key,
    --             ["anthropic-version"] = "2023-06-01",
    --         }
    --     end,
    --     build_request = function(cfg, prompt, context)
    --         return {
    --             model      = cfg.model,
    --             max_tokens = 1024,
    --             system     = cfg.system_prompt,
    --             messages   = {{ role = "user", content = prompt .. (context and "\n\n" .. context or "") }},
    --         }
    --     end,
    --     parse_response = function(parsed)
    --         if not parsed.content or #parsed.content == 0 then return nil, "no content" end
    --         return parsed.content[1].text, nil
    --     end,
    -- },
}
-- ─────────────────────────────────────────────────────────────────────────────

-- Set the terminal window/tab title to "ttyrell" so it's clear the proxy is active
proxy.on("session_start", function()
    proxy.inject_output("\27]0;ttyrell\7")
end)

-- Built-in plugins (only loaded if the file exists)
local plugins = base .. "/plugins"
-- activity_log is superseded by session_log; add it back here if you want the
-- lightweight per-command JSONL log alongside the full session transcript.
for _, name in ipairs({ "session_log", "ai_query", "workflow_journal" }) do
    try_load(plugins .. "/" .. name)
end
