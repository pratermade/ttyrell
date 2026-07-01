mod install;
mod lua_api;
mod osc;
mod proxy;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();

    // --install forces the setup wizard regardless of existing installation.
    // Otherwise, run the wizard automatically on first launch (no config + tty).
    let force_install = args.iter().any(|a| a == "--install");
    if force_install || (!install::is_installed() && install::stdin_is_tty()) {
        return install::run(force_install);
    }

    // --summarize <log_path> <out_path>
    let summarize_args = args.iter().position(|a| a == "--summarize").map(|pos| {
        (
            args.get(pos + 1).cloned().unwrap_or_default(),
            args.get(pos + 2).cloned().unwrap_or_default(),
        )
    });

    // --journal <log_path> <journal_path> <duration_secs>
    let journal_args = args.iter().position(|a| a == "--journal").map(|pos| {
        (
            args.get(pos + 1).cloned().unwrap_or_default(),
            args.get(pos + 2).cloned().unwrap_or_default(),
            args.get(pos + 3).and_then(|s| s.parse::<u64>().ok()).unwrap_or(0),
        )
    });

    let (lua, registry, send_input_rx) = lua_api::init_lua()
        .map_err(|e| anyhow::anyhow!("Lua init failed: {}", e))?;

    // Expose the binary path so Lua can re-invoke it for background tasks
    let exe_path = std::env::current_exe()
        .unwrap_or_else(|_| std::path::PathBuf::from(std::env::consts::EXE_SUFFIX)
            .with_file_name(format!("ttyrell{}", std::env::consts::EXE_SUFFIX)))
        .to_string_lossy()
        .to_string();
    lua.globals().set("TTYRELL_BIN", exe_path)
        .map_err(|e| anyhow::anyhow!("Failed to set TTYRELL_BIN: {}", e))?;

    if summarize_args.is_some() {
        lua.globals().set("TTYRELL_MODE", "summarize")
            .map_err(|e| anyhow::anyhow!("Failed to set TTYRELL_MODE: {}", e))?;
    } else if journal_args.is_some() {
        lua.globals().set("TTYRELL_MODE", "journal")
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

    if let Some((log_path, journal_path, duration_secs)) = journal_args {
        drop(send_input_rx);
        return run_journal(&lua, &log_path, &journal_path, duration_secs);
    }

    // Run the PTY proxy
    #[cfg(windows)]
    let shell = std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".to_string());
    #[cfg(not(windows))]
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
    proxy::run(&shell, registry, &lua, send_input_rx)?;

    Ok(())
}

fn run_journal(lua: &mlua::Lua, log_path: &str, journal_path: &str, duration_secs: u64) -> anyhow::Result<()> {
    let log = std::fs::read_to_string(log_path)
        .map_err(|e| anyhow::anyhow!("cannot read {}: {}", log_path, e))?;

    if log.trim().is_empty() {
        return Ok(());
    }

    let mins = duration_secs / 60;
    let secs = duration_secs % 60;
    let duration_str = if mins > 0 {
        format!("{}m {}s", mins, secs)
    } else {
        format!("{}s", secs)
    };

    lua.globals().set("__journal_log__", log)
        .map_err(|e| anyhow::anyhow!("lua globals: {}", e))?;
    lua.globals().set("__journal_path__", journal_path)
        .map_err(|e| anyhow::anyhow!("lua globals: {}", e))?;
    lua.globals().set("__journal_duration__", duration_str)
        .map_err(|e| anyhow::anyhow!("lua globals: {}", e))?;

    lua.load(r#"
        local ok, llm = pcall(require, 'llm')
        if not (ok and llm) then return end

        if not JOURNAL_PROMPT then
            io.stderr:write('[journal] JOURNAL_PROMPT not set - is workflow_journal.lua loaded?\n')
            return
        end
        local prompt = JOURNAL_PROMPT .. '\n- Session duration: ' .. __journal_duration__
        local tasks, err = llm.query(prompt, JOURNAL_LLM, __journal_log__)
        if not tasks then return end

        local tasks_clean = tasks:gsub('%s*$', '')
        local date_str    = os.date('%Y-%m-%d %H:%M')

        -- Main journal file (full date + time heading)
        local entry = '## ' .. date_str .. ' -- ' .. __journal_duration__ .. '\n\n'
                   .. tasks_clean .. '\n\n---\n\n'
        local f = io.open(__journal_path__, 'a')
        if f then f:write(entry); f:close() end

        -- Obsidian daily note (time-only heading; date is the filename)
        if JOURNAL_OBSIDIAN_VAULT then
            local sub_dir = JOURNAL_OBSIDIAN_DIR or 'Work Journal'
            local vault_dir = JOURNAL_OBSIDIAN_VAULT .. '/' .. sub_dir
            if package.config:sub(1, 1) == '\\' then
                os.execute('mkdir "' .. vault_dir:gsub('/', '\\') .. '" 2>nul')
            else
                os.execute('mkdir -p "' .. vault_dir .. '"')
            end

            local daily_file = vault_dir .. '/' .. os.date('%Y-%m-%d') .. '.md'
            local obs_entry  = '## ' .. os.date('%H:%M') .. ' -- ' .. __journal_duration__ .. '\n\n'
                            .. tasks_clean .. '\n\n---\n\n'
            local of = io.open(daily_file, 'a')
            if of then of:write(obs_entry); of:close() end
        end
    "#).exec().map_err(|e| anyhow::anyhow!("journal lua: {}", e))?;

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
