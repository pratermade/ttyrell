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

    // --task <name> [args...] — run a plugin-registered background task, then exit.
    // Plugins (session_log, workflow_journal, …) re-invoke ttyrell this way at
    // session end so slow LLM work runs detached. All task logic lives in Lua;
    // adding a new background task needs no changes here.
    let task_args = args.iter().position(|a| a == "--task").map(|pos| {
        let name = args.get(pos + 1).cloned().unwrap_or_default();
        let rest: Vec<String> = args
            .get(pos + 2..)
            .map(<[String]>::to_vec)
            .unwrap_or_default();
        (name, rest)
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

    if task_args.is_some() {
        // Signals plugins to register their task handlers but skip interactive
        // wiring (session logging, prompts, etc.).
        lua.globals().set("TTYRELL_MODE", "task")
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

    if let Some((name, task_argv)) = task_args {
        drop(send_input_rx);
        return run_task(&lua, &name, &task_argv);
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

/// Run a plugin-registered background task: `proxy.tasks[name](args...)`.
/// The task's logic lives entirely in the Lua plugin that registered it (via
/// proxy.on_task); an unregistered name is a no-op (its plugin isn't loaded).
fn run_task(lua: &mlua::Lua, name: &str, args: &[String]) -> anyhow::Result<()> {
    let handler = (|| -> mlua::Result<Option<mlua::Function>> {
        let proxy: mlua::Table = lua.globals().get("proxy")?;
        let tasks: mlua::Table = proxy.get("tasks")?;
        tasks.get(name)
    })()
    .map_err(|e| anyhow::anyhow!("look up task '{}': {}", name, e))?;

    let Some(handler) = handler else {
        return Ok(());
    };

    let lua_args = args
        .iter()
        .map(|s| lua.create_string(s).map(mlua::Value::String))
        .collect::<mlua::Result<Vec<_>>>()
        .map_err(|e| anyhow::anyhow!("task args: {}", e))?;
    handler
        .call::<()>(mlua::MultiValue::from_vec(lua_args))
        .map_err(|e| anyhow::anyhow!("task '{}': {}", name, e))?;
    Ok(())
}
