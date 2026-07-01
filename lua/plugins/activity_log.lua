-- activity_log.lua — JSONL command logger
--
-- Logs every command_start/command_exit pair as a JSONL entry.
-- Writes to ~/.local/share/ttyrell/activity.jsonl

local log_dir
if package.config:sub(1, 1) == '\\' then
    local appdata = (os.getenv("LOCALAPPDATA") or os.getenv("APPDATA") or ""):gsub('\\', '/')
    if appdata == "" then
        print("[activity_log] LOCALAPPDATA not set; logging disabled")
        return
    end
    log_dir = appdata .. "/ttyrell"
else
    local home = os.getenv("HOME") or ""
    if home == "" then
        print("[activity_log] HOME not set; logging disabled")
        return
    end
    log_dir = home .. "/.local/share/ttyrell"
end
local log_file = log_dir .. "/activity.jsonl"

-- Ensure directory exists (cross-platform)
if package.config:sub(1, 1) == '\\' then
    os.execute('mkdir "' .. log_dir:gsub('/', '\\') .. '" 2>nul')
else
    os.execute('mkdir -p "' .. log_dir .. '"')
end

local f, err = io.open(log_file, "a")
if not f then
    print("[activity_log] Failed to open " .. log_file .. ": " .. tostring(err))
    return
end

local pending = {}

proxy.on("command_start", function()
    pending.start = os.time()
    pending.cmd = "" -- shell integration would fill this in with PS0 data
end)

proxy.on("command_exit", function(exit_code)
    local entry = string.format(
        '{"time":%d,"exit_code":%s,"duration":%d}\n',
        pending.start or os.time(),
        exit_code,
        pending.start and (os.time() - pending.start) or 0
    )
    f:write(entry)
    f:flush()
    pending = {}
end)
