mod install;
mod lua_api;
mod osc;
mod proxy;

fn main() -> anyhow::Result<()> {
    // rustls 0.23 (via ureq) requires a process-wide crypto provider before any
    // TLS handshake, otherwise the first HTTPS request panics. ureq does not
    // install one, so do it here. Idempotent-ish: ignore the "already set" error.
    let _ = rustls::crypto::ring::default_provider().install_default();

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
    let shell = choose_windows_shell();
    #[cfg(not(windows))]
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
    proxy::run(&shell, registry, &lua, send_input_rx)?;

    Ok(())
}

/// Pick the shell to spawn on Windows.
///
/// 1. `TTYRELL_SHELL` env var, if set (useful when a terminal profile launches
///    ttyrell directly and there is no invoking shell to detect).
/// 2. The invoking shell, detected by walking the parent-process chain — so
///    running ttyrell from PowerShell drops you back into PowerShell.
/// 3. `%COMSPEC%` (cmd.exe) as the fallback.
#[cfg(windows)]
fn choose_windows_shell() -> String {
    if let Ok(s) = std::env::var("TTYRELL_SHELL") {
        if !s.is_empty() {
            return s;
        }
    }
    if let Some(s) = detect_parent_shell() {
        return s;
    }
    std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".to_string())
}

/// Walk up the parent-process chain looking for a known interactive shell.
/// Returns the shell's executable name (resolved on PATH when spawned), or None.
#[cfg(windows)]
fn detect_parent_shell() -> Option<String> {
    use std::collections::HashMap;

    const TH32CS_SNAPPROCESS: u32 = 0x0000_0002;

    #[repr(C)]
    struct ProcessEntry32W {
        dw_size: u32,
        cnt_usage: u32,
        th32_process_id: u32,
        th32_default_heap_id: usize,
        th32_module_id: u32,
        cnt_threads: u32,
        th32_parent_process_id: u32,
        pc_pri_class_base: i32,
        dw_flags: u32,
        sz_exe_file: [u16; 260],
    }

    unsafe extern "system" {
        fn CreateToolhelp32Snapshot(flags: u32, pid: u32) -> *mut core::ffi::c_void;
        fn Process32FirstW(snap: *mut core::ffi::c_void, entry: *mut ProcessEntry32W) -> i32;
        fn Process32NextW(snap: *mut core::ffi::c_void, entry: *mut ProcessEntry32W) -> i32;
        fn CloseHandle(h: *mut core::ffi::c_void) -> i32;
        fn GetCurrentProcessId() -> u32;
    }

    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snap.is_null() || snap as isize == -1 {
            return None;
        }

        let mut parent_of: HashMap<u32, u32> = HashMap::new();
        let mut name_of: HashMap<u32, String> = HashMap::new();

        let mut entry: ProcessEntry32W = std::mem::zeroed();
        entry.dw_size = std::mem::size_of::<ProcessEntry32W>() as u32;

        if Process32FirstW(snap, &mut entry) != 0 {
            loop {
                let len = entry
                    .sz_exe_file
                    .iter()
                    .position(|&c| c == 0)
                    .unwrap_or(entry.sz_exe_file.len());
                let name = String::from_utf16_lossy(&entry.sz_exe_file[..len]);
                parent_of.insert(entry.th32_process_id, entry.th32_parent_process_id);
                name_of.insert(entry.th32_process_id, name);
                if Process32NextW(snap, &mut entry) == 0 {
                    break;
                }
            }
        }
        CloseHandle(snap);

        // Bounded walk up the ancestry. Stop at the first recognizable shell.
        let mut pid = GetCurrentProcessId();
        for _ in 0..16 {
            let parent = *parent_of.get(&pid)?;
            if parent == 0 {
                return None;
            }
            let name = name_of.get(&parent)?.to_ascii_lowercase();
            match name.strip_suffix(".exe").unwrap_or(&name) {
                "pwsh" | "powershell" => return Some(name),
                "cmd" => return None, // launched from cmd → let COMSPEC handle it
                _ => {}
            }
            pid = parent;
        }
        None
    }
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
