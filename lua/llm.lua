-- llm.lua — LLM provider abstraction
--
-- Plugins call llm.query(prompt, cfg, context) where cfg is a provider table
-- from the LLM palette defined in init.lua (e.g. LLM.local_llama).
-- Defaults to the OpenAI-compatible chat completions format.
-- Override headers(), build_request(), or parse_response() in the provider
-- table for other APIs.

local M = {}

local function default_headers(cfg)
    local h = {}
    if cfg.api_key then
        h["Authorization"] = "Bearer " .. cfg.api_key
    end
    return h
end

local function default_build_request(cfg, prompt, context)
    local user_content = context and (prompt .. "\n\n" .. context) or prompt
    return {
        model    = cfg.model or "default",
        messages = {
            { role = "system", content = cfg.system_prompt },
            { role = "user",   content = user_content },
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

local function resolve(opts)
    return {
        endpoint       = opts.endpoint,
        model          = opts.model,
        api_key        = opts.api_key,
        system_prompt  = opts.system_prompt  or "You are a helpful terminal assistant. Be concise.",
        headers        = opts.headers        or default_headers,
        build_request  = opts.build_request  or default_build_request,
        parse_response = opts.parse_response or default_parse_response,
    }
end

--- Send a prompt to an LLM provider.
--
-- prompt   string    The instruction or question.
-- cfg      table     Provider config from the LLM palette (e.g. LLM.local_llama).
-- context  string|nil  Optional data blob (log, terminal output, etc.) appended
--                      after the prompt in the user message.
--
-- Returns: response_text, nil   on success
--          nil, error_string    on failure
function M.query(prompt, cfg, context)
    if not cfg then
        return nil, "no LLM provider given — pass a provider from the LLM palette (e.g. LLM.local_llama)"
    end

    local provider = resolve(cfg)

    local ok_enc, body = pcall(proxy.json_encode, provider.build_request(provider, prompt, context))
    if not ok_enc then
        return nil, "encode error: " .. tostring(body)
    end

    local headers = provider.headers(provider)
    local ok_http, status, resp = pcall(proxy.http_post, provider.endpoint, body, headers)
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

    return provider.parse_response(parsed)
end

return M
