mod lua_api;
mod osc;
mod proxy;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();

    // --summarize <log_path> <out_path>
    // Re-uses the Lua/LLM stack to summarize a session log in a background process.
    let summarize_args = args.iter().position(|a| a == "--summarize").map(|pos| {
        (
            args.get(pos + 1).cloned().unwrap_or_default(),
            args.get(pos + 2).cloned().unwrap_or_default(),
        )
    });

    let (lua, registry, send_input_rx) = lua_api::init_lua()
        .map_err(|e| anyhow::anyhow!("Lua init failed: {}", e))?;

    // Expose the binary path so Lua can re-invoke it for background tasks
    let exe_path = std::env::current_exe()
        .unwrap_or_else(|_| std::path::PathBuf::from("ttyrell"))
        .to_string_lossy()
        .to_string();
    lua.globals().set("TTYRELL_BIN", exe_path)
        .map_err(|e| anyhow::anyhow!("Failed to set TTYRELL_BIN: {}", e))?;

    if summarize_args.is_some() {
        lua.globals().set("TTYRELL_MODE", "summarize")
            .map_err(|e| anyhow::anyhow!("Failed to set TTYRELL_MODE: {}", e))?;
    }

    // Load user's init.lua from config dir or local path
    let home = dirs::home_dir();
    let candidates: &[std::path::PathBuf] = &[
        dirs::config_dir()
            .map(|d| d.join("ttyrell").join("lua").join("init.lua"))
            .unwrap_or_default(),
        #[cfg(target_os = "macos")]
        home.as_ref()
            .map(|h| h.join(".config").join("ttyrell").join("lua").join("init.lua"))
            .unwrap_or_default(),
        home.as_ref()
            .map(|h| h.join(".ttyrell").join("lua").join("init.lua"))
            .unwrap_or_default(),
        std::path::PathBuf::from("./lua/init.lua"),
    ];
    let init_path = candidates
        .iter()
        .find(|p| !p.as_os_str().is_empty() && p.exists())
        .cloned()
        .unwrap_or_else(|| std::path::PathBuf::from("./lua/init.lua"));

    if init_path.exists() {
        let lua_dir = init_path.parent()
            .unwrap_or_else(|| std::path::Path::new("."))
            .to_string_lossy()
            .to_string();
        lua.globals().set("PROXY_LUA_DIR", lua_dir)
            .map_err(|e| anyhow::anyhow!("Failed to set PROXY_LUA_DIR: {}", e))?;

        if let Err(e) = lua.load(init_path.as_path()).exec() {
            eprintln!("Failed to load init.lua: {}", e);
        }
    }

    if let Some((log_path, out_path)) = summarize_args {
        drop(send_input_rx);
        return run_summarize(&lua, &log_path, &out_path);
    }

    // Run the PTY proxy
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
    proxy::run(&shell, registry, &lua, send_input_rx)?;

    Ok(())
}

fn run_summarize(lua: &mlua::Lua, log_path: &str, out_path: &str) -> anyhow::Result<()> {
    let log = std::fs::read_to_string(log_path)
        .map_err(|e| anyhow::anyhow!("cannot read {}: {}", log_path, e))?;

    if log.trim().is_empty() {
        return Ok(());
    }

    lua.globals().set("__summarize_log__", log)
        .map_err(|e| anyhow::anyhow!("lua globals: {}", e))?;
    lua.globals().set("__summarize_out__", out_path)
        .map_err(|e| anyhow::anyhow!("lua globals: {}", e))?;

    lua.load(r#"
        local ok, llm = pcall(require, "llm")
        if not (ok and llm) then return end

        local summary, err = llm.query(
            "Summarize this terminal session log in plain English. " ..
            "Note what machine(s) were used (look for ssh commands and remote prompts), " ..
            "what was accomplished, and highlight any errors or non-zero exit codes. " ..
            "Be concise — a short paragraph is ideal.\n\n" ..
            "The log is JSONL. Each line has a 'type' field:\n" ..
            "  session_start — host and shell at proxy launch\n" ..
            "  input         — full command line entered by the user\n" ..
            "  output        — full terminal output for a completed command, includes exit_code\n" ..
            "  session_end   — proxy is shutting down\n\n" ..
            __summarize_log__
        )

        if not summary then return end

        local f = io.open(__summarize_out__, "w")
        if f then
            f:write(summary .. "\n")
            f:close()
        end
    "#).exec().map_err(|e| anyhow::anyhow!("summarize lua: {}", e))?;

    Ok(())
}
