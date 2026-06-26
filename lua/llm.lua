-- llm.lua — LLM provider abstraction
--
-- Call llm.setup({...}) in init.lua to configure a provider.
-- Defaults to the OpenAI-compatible chat completions format.
-- Override headers(), build_request(), or parse_response() for other APIs.

local M = {}

local active = nil

local function default_headers(cfg)
    local h = {}
    if cfg.api_key then
        h["Authorization"] = "Bearer " .. cfg.api_key
    end
    return h
end

local function default_build_request(cfg, prompt)
    return {
        model    = cfg.model or "default",
        messages = {
            { role = "system", content = cfg.system_prompt },
            { role = "user",   content = prompt },
        },
        stream = false,
    }
end

local function default_parse_response(parsed)
    local choices = parsed and parsed.choices
    if not choices or #choices == 0 then
        return nil, "no choices in response"
    end
    local msg = choices[1].message
    return (msg and msg.content) or "", nil
end

--- Configure the active provider.
--
-- Required fields:
--   endpoint  string  Full URL, e.g. "http://localhost:8083/v1/chat/completions"
--   model     string  Model name passed in the request body
--
-- Optional fields:
--   api_key       string    Added as "Authorization: Bearer <key>" header
--   system_prompt string    Default: "You are a helpful terminal assistant. Be concise."
--
-- Override functions (all receive cfg as first arg):
--   headers(cfg)              -> table of header key/value pairs
--   build_request(cfg, prompt) -> table serialised as JSON request body
--   parse_response(parsed)    -> response_text, err_or_nil
function M.setup(opts)
    active = opts
    active.system_prompt  = active.system_prompt  or "You are a helpful terminal assistant. Be concise."
    active.headers        = active.headers        or default_headers
    active.build_request  = active.build_request  or default_build_request
    active.parse_response = active.parse_response or default_parse_response
end

--- Send a prompt to the configured provider.
-- Returns: response_text, nil   on success
--          nil, error_string    on failure
function M.query(prompt)
    if not active then
        return nil, "no LLM provider configured — call llm.setup() in init.lua"
    end

    local ok_enc, body = pcall(proxy.json_encode, active.build_request(active, prompt))
    if not ok_enc then
        return nil, "encode error: " .. tostring(body)
    end

    local headers = active.headers(active)
    local ok_http, status, resp = pcall(proxy.http_post, active.endpoint, body, headers)
    if not ok_http then
        return nil, "connection error: " .. tostring(status)
    end
    if status ~= 200 then
        return nil, string.format("HTTP %d: %s", status, resp or "")
    end

    local ok_dec, parsed = pcall(proxy.json_decode, resp)
    if not ok_dec then
        return nil, "decode error: " .. tostring(parsed)
    end

    return active.parse_response(parsed)
end

return M
