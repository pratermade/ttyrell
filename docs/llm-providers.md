# LLM provider configuration

ttyrell uses an OpenAI-compatible format by default. For other APIs, you override three functions: `headers`, `build_request`, and `parse_response`. The proxy itself doesn't know or care which LLM you use — all of that logic lives in Lua.

---

## Table of contents

- [How the provider system works](#how-the-provider-system-works)
- [Local llama-server](#local-llama-server)
- [Ollama](#ollama)
- [OpenAI](#openai)
- [Anthropic](#anthropic)
- [Azure OpenAI](#azure-openai)
- [Custom provider from scratch](#custom-provider-from-scratch)
- [Switching providers at runtime](#switching-providers-at-runtime)
- [The three override functions](#the-three-override-functions)

---

## How the provider system works

`lua/llm.lua` wraps `proxy.http_post` with a thin abstraction. The active provider is a table stored in a module-local variable. When you call `llm.query(prompt)`:

1. `build_request(cfg, prompt)` produces a Lua table (the request body)
2. `proxy.json_encode` serialises it to JSON
3. `headers(cfg)` produces the auth and content-type headers
4. `proxy.http_post` sends the POST
5. `proxy.json_decode` parses the JSON response
6. `parse_response(parsed)` extracts the text from wherever the API put it

Overriding any of those three functions lets you use any API without changing the Rust code.

All provider setup happens in `lua/init.lua`. Uncomment one block and fill in your values.

---

## Local llama-server

llama-server ships with llama.cpp and implements the OpenAI chat completions API. No API key needed.

```lua
local llm = require("llm")

llm.setup({
    endpoint = "http://localhost:8083/v1/chat/completions",
    model    = "default",
    -- system_prompt is optional; defaults to:
    -- "You are a helpful terminal assistant. Be concise."
})
```

Start the server with:
```bash
llama-server --model your-model.gguf --port 8083
```

The `model` field is sent in the request body. llama-server ignores it (it always uses the loaded model), so any string works.

---

## Ollama

Ollama implements the OpenAI-compatible API at `/api/chat` but uses a slightly different request format. Use the OpenAI-compatible endpoint:

```lua
local llm = require("llm")

llm.setup({
    endpoint = "http://localhost:11434/v1/chat/completions",
    model    = "llama3.2",   -- must match a pulled model
})
```

Or use Ollama's native API:

```lua
local llm = require("llm")

llm.setup({
    endpoint      = "http://localhost:11434/api/generate",
    model         = "llama3.2",
    system_prompt = "You are a helpful terminal assistant. Be concise.",

    build_request = function(cfg, prompt)
        return {
            model  = cfg.model,
            system = cfg.system_prompt,
            prompt = prompt,
            stream = false,
        }
    end,

    parse_response = function(parsed)
        if not parsed or not parsed.response then
            return nil, "no response field"
        end
        return parsed.response, nil
    end,
})
```

---

## OpenAI

```lua
local llm = require("llm")

llm.setup({
    endpoint = "https://api.openai.com/v1/chat/completions",
    api_key  = os.getenv("OPENAI_API_KEY"),
    model    = "gpt-4o-mini",   -- or gpt-4o, o1-mini, etc.
    system_prompt = "You are a helpful terminal assistant. Be concise.",
})
```

The `api_key` field is automatically placed in the `Authorization: Bearer` header by the default `headers` function.

Set the key in your shell environment before launching the proxy:
```bash
export OPENAI_API_KEY="sk-..."
```

Or set it in `~/.zshrc` / `~/.bashrc` so it's always available.

---

## Anthropic

Anthropic's API uses a different auth header scheme, request body format, and response shape. Override all three functions:

```lua
local llm = require("llm")

llm.setup({
    endpoint  = "https://api.anthropic.com/v1/messages",
    api_key   = os.getenv("ANTHROPIC_API_KEY"),
    model     = "claude-haiku-4-5-20251001",   -- fast and cheap; use claude-opus-4-8 for best quality
    system_prompt = "You are a helpful terminal assistant. Be concise.",

    headers = function(cfg)
        return {
            ["x-api-key"]         = cfg.api_key,
            ["anthropic-version"] = "2023-06-01",
        }
    end,

    build_request = function(cfg, prompt)
        return {
            model      = cfg.model,
            max_tokens = 1024,
            system     = cfg.system_prompt,
            messages   = {{ role = "user", content = prompt }},
        }
    end,

    parse_response = function(parsed)
        if not parsed or not parsed.content or #parsed.content == 0 then
            return nil, "no content in response"
        end
        local block = parsed.content[1]
        if block.type ~= "text" then
            return nil, "unexpected content type: " .. tostring(block.type)
        end
        return block.text, nil
    end,
})
```

Available Anthropic models (as of mid-2025):
- `claude-haiku-4-5-20251001` — fastest, cheapest
- `claude-sonnet-4-6` — balanced
- `claude-opus-4-8` — most capable

---

## Azure OpenAI

Azure uses a different base URL and auth scheme. The request and response format is the same as OpenAI.

```lua
local llm = require("llm")

local AZURE_ENDPOINT  = os.getenv("AZURE_OPENAI_ENDPOINT")   -- https://YOUR_RESOURCE.openai.azure.com
local AZURE_KEY       = os.getenv("AZURE_OPENAI_KEY")
local DEPLOYMENT_NAME = "gpt-4o"   -- your Azure deployment name

llm.setup({
    endpoint = AZURE_ENDPOINT .. "/openai/deployments/" .. DEPLOYMENT_NAME
              .. "/chat/completions?api-version=2024-02-01",
    model    = DEPLOYMENT_NAME,

    headers = function(cfg)
        return { ["api-key"] = AZURE_KEY }
    end,

    -- build_request and parse_response use OpenAI defaults — no override needed
})
```

---

## Custom provider from scratch

Implement all three functions for an API that has nothing in common with OpenAI:

```lua
local llm = require("llm")

llm.setup({
    endpoint = "https://my-internal-ai.corp.example/v1/complete",
    api_key  = os.getenv("INTERNAL_AI_KEY"),

    headers = function(cfg)
        return {
            ["X-API-Token"] = cfg.api_key,
            ["X-Client"]    = "ttyrell",
        }
    end,

    build_request = function(cfg, prompt)
        return {
            instruction  = cfg.system_prompt,
            user_message = prompt,
            max_output   = 500,
        }
    end,

    parse_response = function(parsed)
        -- parsed is the decoded JSON response as a Lua table
        if not parsed or parsed.status ~= "ok" then
            return nil, "unexpected status: " .. tostring(parsed and parsed.status)
        end
        return parsed.result.text, nil
    end,
})
```

---

## Switching providers at runtime

`llm.setup()` replaces the active provider. You can call it multiple times — the most recent call wins. This lets you define convenience functions in `init.lua`:

```lua
local llm = require("llm")

local PROVIDERS = {
    local_fast = {
        endpoint = "http://localhost:8083/v1/chat/completions",
        model    = "default",
    },
    openai = {
        endpoint = "https://api.openai.com/v1/chat/completions",
        api_key  = os.getenv("OPENAI_API_KEY"),
        model    = "gpt-4o",
    },
}

-- Start with local by default
llm.setup(PROVIDERS.local_fast)

-- Switch with #llm: command
proxy.on("input", function(data)
    local provider = data:match("^#llm:%s*(%S+)")
    if not provider then return end
    if PROVIDERS[provider] then
        llm.setup(PROVIDERS[provider])
        proxy.inject_output("\r\n[llm] switched to " .. provider .. "\r\n")
    else
        proxy.inject_output("\r\n[llm] unknown provider: " .. provider .. "\r\n")
    end
    return "suppress"
end)
```

---

## The three override functions

### headers(cfg)

Returns a Lua table of header key/value pairs. All values become strings in the HTTP request. The `Content-Type: application/json` header is added automatically by the proxy; you do not need to include it.

```lua
headers = function(cfg)
    return {
        ["Authorization"] = "Bearer " .. cfg.api_key,
        ["X-Custom"]      = "value",
    }
end
```

### build_request(cfg, prompt)

Returns a Lua table that is JSON-encoded and sent as the POST body. The `cfg` argument is the full provider table so you can access `cfg.model`, `cfg.system_prompt`, and any custom fields you added at setup time.

```lua
build_request = function(cfg, prompt)
    return {
        model       = cfg.model,
        temperature = cfg.temperature or 0.7,
        messages    = {
            { role = "system", content = cfg.system_prompt },
            { role = "user",   content = prompt },
        },
        stream = false,
    }
end
```

### parse_response(parsed)

Receives the decoded JSON response as a Lua table. Returns `text, nil` on success or `nil, error_string` on failure. The function must handle the case where the API returns a valid JSON error object (status 200 with an error field).

```lua
parse_response = function(parsed)
    if parsed.error then
        return nil, parsed.error.message or "API error"
    end
    local msg = parsed.choices and parsed.choices[1] and parsed.choices[1].message
    if not msg then return nil, "no message in response" end
    return msg.content, nil
end
```
