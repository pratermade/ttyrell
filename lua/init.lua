-- ttyrell init.lua
-- The proxy API is available as the global `proxy`.
-- Configure your LLM provider below, then uncomment the llm.setup() call.

local base = PROXY_LUA_DIR or "."

-- Add lua/ to the module path so plugins can require("llm")
package.path = package.path .. ";" .. base .. "/?.lua"

local function try_load(path)
    local f, err = loadfile(path .. ".lua")
    if f then return pcall(f) end
    return false, err
end

-- ── LLM provider ─────────────────────────────────────────────────────────────
-- Uncomment one block and set your values, or write your own provider table.
--
local llm = require("llm")
--
-- Local llama-server (OpenAI-compatible, no auth needed):
 llm.setup({
     endpoint = "http://mint.pratermade.com:8083/v1/chat/completions",
     model    = "default",
 })
--
-- -- OpenAI:
-- llm.setup({
--     endpoint = "https://api.openai.com/v1/chat/completions",
--     api_key  = os.getenv("OPENAI_API_KEY"),
--     model    = "gpt-4o-mini",
-- })
--
-- -- Anthropic (overrides headers, build_request, and parse_response):
-- llm.setup({
--     endpoint       = "https://api.anthropic.com/v1/messages",
--     api_key        = os.getenv("ANTHROPIC_API_KEY"),
--     model          = "claude-opus-4-8",
--     headers        = function(cfg)
--         return {
--             ["x-api-key"]         = cfg.api_key,
--             ["anthropic-version"] = "2023-06-01",
--         }
--     end,
--     build_request  = function(cfg, prompt)
--         return {
--             model      = cfg.model,
--             max_tokens = 1024,
--             system     = cfg.system_prompt,
--             messages   = {{ role = "user", content = prompt }},
--         }
--     end,
--     parse_response = function(parsed)
--         if not parsed.content or #parsed.content == 0 then
--             return nil, "no content"
--         end
--         return parsed.content[1].text, nil
--     end,
-- })
-- ─────────────────────────────────────────────────────────────────────────────

-- Set the terminal window/tab title to "ttyrell" so it's clear the proxy is active
proxy.on("session_start", function()
    proxy.inject_output("\27]0;ttyrell\7")
end)

-- Built-in plugins (only loaded if the file exists)
local plugins = base .. "/plugins"
-- activity_log is superseded by session_log; add it back here if you want the
-- lightweight per-command JSONL log alongside the full session transcript.
for _, name in ipairs({ "session_log", "ai_query", "error_help", "workflow_journal" }) do
    try_load(plugins .. "/" .. name)
end
