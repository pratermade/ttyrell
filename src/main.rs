mod lua_api;
mod osc;
mod proxy;

fn main() -> anyhow::Result<()> {
    // Initialize Lua VM and register the proxy API
    let (lua, registry) = lua_api::init_lua().map_err(|e| anyhow::anyhow!("Lua init failed: {}", e))?;

    // Load user's init.lua from config dir or local path
    let init_path = dirs::config_dir()
        .map(|d| d.join("ttyrell").join("lua").join("init.lua"))
        .or_else(|| {
            let home = dirs::home_dir()?;
            Some(home.join(".ttyrell").join("lua").join("init.lua"))
        })
        .unwrap_or_else(|| std::path::PathBuf::from("./lua/init.lua"));

    if init_path.exists() {
        // Expose the lua/ directory so init.lua can require("llm") etc.
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

    // Run the PTY proxy
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
    proxy::run(&shell, registry, &lua)?;

    Ok(())
}
