-- secret_guard.lua — redact credentials before they land in session logs
--
-- Masks common patterns: AWS keys, GitHub tokens, Authorization headers,
-- URL passwords, PEM blocks, and env-var assignments whose key name
-- contains words like password, secret, token, api_key, etc.
--
-- Usage (automatic when secret_guard is in the lua path):
--   local sg = require("secret_guard")
--   local clean = sg.sanitize(text)

local M = {}

-- Fixed pattern rules: { lua_pattern, replacement }
local rules = {
    -- AWS Access Key IDs  (AKIA + exactly 16 uppercase/digit chars)
    { "AKIA" .. string.rep("[%u%d]", 16), "AKIA[REDACTED]" },

    -- GitHub tokens
    { "ghp_[%w]+",         "ghp_[REDACTED]"         },
    { "gho_[%w]+",         "gho_[REDACTED]"         },
    { "ghs_[%w]+",         "ghs_[REDACTED]"         },
    { "github_pat_[%w_]+", "github_pat_[REDACTED]"  },

    -- HTTP Authorization headers
    { "(Authorization:%s*Bearer%s+)%S+", "%1[REDACTED]" },
    { "(Authorization:%s*Token%s+)%S+",  "%1[REDACTED]" },

    -- URL passwords:  scheme://user:pass@host
    { "(://[^:@%s]+:)[^@%s]+(@)", "%1[REDACTED]%2" },

    -- PEM private key blocks
    { "%-%-%-%-%-BEGIN[%u ]+PRIVATE KEY%-%-%-%-%-", "[REDACTED PRIVATE KEY BLOCK]" },
}

-- Key-name substrings that flag an assignment as sensitive
local sensitive_keywords = {
    "password", "passwd", "secret", "token",
    "api_key", "apikey", "api_secret",
    "access_key", "private_key",
    "auth_key", "auth_token", "client_secret",
}

local function is_sensitive_key(key)
    local low = key:lower():gsub("%-", "_")
    for _, kw in ipairs(sensitive_keywords) do
        if low:find(kw, 1, true) then return true end
    end
    return false
end

--- Redact secrets in text, returning the sanitized string.
function M.sanitize(text)
    if type(text) ~= "string" then return text end

    for _, rule in ipairs(rules) do
        text = text:gsub(rule[1], rule[2])
    end

    -- KEY=value  or  KEY: value  (env vars, YAML, config files)
    text = text:gsub("([%w_%-]+)(%s*[=:]%s*)(%S+)", function(key, eq, val)
        if is_sensitive_key(key) then
            return key .. eq .. "[REDACTED]"
        end
        return key .. eq .. val
    end)

    return text
end

return M
