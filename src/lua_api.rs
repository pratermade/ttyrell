use mlua::{IntoLua, Function, Lua, LuaSerdeExt, Result as LuaResult, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// Thread-safe registry of Lua event callbacks.
pub struct EventRegistry {
    inner: Arc<Mutex<HashMap<String, Vec<Function>>>>,
}

impl Clone for EventRegistry {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
        }
    }
}

impl EventRegistry {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn register(&self, event: &str, func: Function) {
        let mut map = self.inner.lock().unwrap();
        map.entry(event.to_string())
            .or_insert_with(Vec::new)
            .push(func);
    }

    /// Fire all callbacks for an event with string args.
    /// Returns true if any callback returned "suppress" or "drop".
    pub fn fire(
        &self,
        lua: &Lua,
        event: &str,
        args: Vec<String>,
    ) -> LuaResult<bool> {
        // Clone the callback list while holding the lock, then release before
        // calling into Lua. Without this, any callback that calls proxy.on()
        // would deadlock trying to re-acquire the same mutex.
        let callbacks = {
            let map = self.inner.lock().unwrap();
            match map.get(event) {
                Some(cbs) => cbs.clone(),
                None => return Ok(false),
            }
        };

        let mut suppressed = false;
        for cb in &callbacks {
            let multi = mlua::MultiValue::from_vec(
                args.iter()
                    .map(|s| lua.create_string(s).unwrap().into_lua(lua).unwrap())
                    .collect(),
            );
            match cb.call::<Option<String>>(multi) {
                Ok(Some(ref s)) if s == "suppress" || s == "drop" => suppressed = true,
                Err(e) => eprintln!("Lua error in {} handler: {}", event, e),
                _ => {}
            }
        }
        Ok(suppressed)
    }
}

/// Initialize the Lua environment and expose the `proxy` API table.
///
/// Returns the Lua state, the event registry, and a receiver for PTY input
/// injected by Lua via `proxy.send_input()`.
pub fn init_lua() -> LuaResult<(Lua, EventRegistry, std::sync::mpsc::Receiver<Vec<u8>>)> {
    let lua = Lua::new();
    let registry = EventRegistry::new();
    let registry_clone = registry.clone();
    let (send_input_tx, send_input_rx) = std::sync::mpsc::channel::<Vec<u8>>();

    // Expose `proxy` global table
    let proxy_table = lua.create_table()?;

    // proxy.on(event, callback)
    let on_fn = lua.create_function(move |_lua, (event, callback): (String, Function)| {
        registry_clone.register(&event, callback);
        Ok(())
    })?;
    proxy_table.set("on", on_fn)?;

    // proxy.inject_output(text) — write to terminal stdout
    let inject_output = lua.create_function(|_lua, text: String| {
        use std::io::Write;
        let _ = std::io::stdout().write_all(text.as_bytes());
        let _ = std::io::stdout().flush();
        Ok(())
    })?;
    proxy_table.set("inject_output", inject_output)?;

    // proxy.http_post(url, body [, headers]) -> (status_code, response_body)
    // Returns HTTP status + body even for 4xx/5xx; raises Lua error only on transport failure.
    let http_post = lua.create_function(
        |_lua, (url, body, headers): (String, String, Option<mlua::Table>)| {
            let agent = ureq::AgentBuilder::new()
                .timeout(std::time::Duration::from_secs(90))
                .build();
            let mut req = agent.post(&url).set("Content-Type", "application/json");
            if let Some(h) = headers {
                for pair in h.pairs::<String, String>() {
                    let (k, v) = pair.map_err(mlua::Error::external)?;
                    req = req.set(&k, &v);
                }
            }
            // Guard the network call so a TLS/transport panic surfaces as a
            // catchable Lua error instead of unwinding out of the event handler.
            let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                match req.send_string(&body) {
                    Ok(resp) => {
                        let status = resp.status();
                        Ok((status, resp.into_string().unwrap_or_default()))
                    }
                    Err(ureq::Error::Status(code, resp)) => {
                        Ok((code, resp.into_string().unwrap_or_default()))
                    }
                    Err(e) => Err(e.to_string()),
                }
            }));
            match outcome {
                Ok(Ok((status, text))) => Ok((status, text)),
                Ok(Err(msg)) => Err(mlua::Error::external(msg)),
                Err(_) => Err(mlua::Error::external(
                    "http_post panicked (TLS or transport failure)",
                )),
            }
        },
    )?;
    proxy_table.set("http_post", http_post)?;

    // proxy.json_encode(value) -> string
    let json_encode = lua.create_function(|lua_ctx, val: Value| {
        let json_val: serde_json::Value = lua_ctx.from_value(val)?;
        serde_json::to_string(&json_val).map_err(mlua::Error::external)
    })?;
    proxy_table.set("json_encode", json_encode)?;

    // proxy.json_decode(string) -> value
    let json_decode = lua.create_function(|lua_ctx, s: String| {
        let json_val: serde_json::Value =
            serde_json::from_str(&s).map_err(mlua::Error::external)?;
        lua_ctx.to_value(&json_val)
    })?;
    proxy_table.set("json_decode", json_decode)?;

    // proxy.send_input(text) — write text to the PTY as if the user typed it
    let send_input_fn = lua.create_function(move |_lua, text: String| {
        send_input_tx
            .send(text.into_bytes())
            .map_err(mlua::Error::external)?;
        Ok(())
    })?;
    proxy_table.set("send_input", send_input_fn)?;

    // proxy.spawn(cmd) — run a shell command in the background (non-blocking)
    let spawn_fn = lua.create_function(|_lua, cmd: String| {
        #[cfg(windows)]
        let (interpreter, flag) = ("cmd", "/C");
        #[cfg(not(windows))]
        let (interpreter, flag) = ("sh", "-c");

        std::process::Command::new(interpreter)
            .args([flag, &cmd])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(mlua::Error::external)?;
        Ok(())
    })?;
    proxy_table.set("spawn", spawn_fn)?;

    // proxy.spinner_start() / proxy.spinner_stop() — animated "thinking" indicator.
    // LLM HTTP calls block the Lua thread, so the animation runs on a Rust thread
    // writing frames directly to stdout at the current cursor position. stop()
    // joins the thread before returning, so no frame can be written after the
    // caller's cleanup output.
    let spinner_handle: Arc<Mutex<Option<std::thread::JoinHandle<()>>>> =
        Arc::new(Mutex::new(None));
    let spinner_flag = Arc::new(std::sync::atomic::AtomicBool::new(false));

    let sh = spinner_handle.clone();
    let sf = spinner_flag.clone();
    let spinner_start = lua.create_function(move |_lua, ()| {
        use std::sync::atomic::Ordering;
        let mut guard = sh.lock().unwrap();
        if guard.is_some() {
            return Ok(()); // already spinning
        }
        sf.store(true, Ordering::SeqCst);
        let flag = sf.clone();
        *guard = Some(std::thread::spawn(move || {
            use std::io::Write;
            const FRAMES: [u8; 4] = [b'\\', b'-', b'/', b'|'];
            let mut out = std::io::stdout();
            let mut i = 0usize;
            let _ = out.write_all(&[FRAMES[0]]);
            let _ = out.flush();
            while flag.load(Ordering::SeqCst) {
                std::thread::sleep(std::time::Duration::from_millis(120));
                if !flag.load(Ordering::SeqCst) {
                    break;
                }
                i = (i + 1) % FRAMES.len();
                let _ = out.write_all(&[0x08, FRAMES[i]]);
                let _ = out.flush();
            }
            // Erase the frame character before exiting.
            let _ = out.write_all(b"\x08 \x08");
            let _ = out.flush();
        }));
        Ok(())
    })?;
    proxy_table.set("spinner_start", spinner_start)?;

    let sh2 = spinner_handle.clone();
    let sf2 = spinner_flag.clone();
    let spinner_stop = lua.create_function(move |_lua, ()| {
        use std::sync::atomic::Ordering;
        sf2.store(false, Ordering::SeqCst);
        if let Some(h) = sh2.lock().unwrap().take() {
            let _ = h.join();
        }
        Ok(())
    })?;
    proxy_table.set("spinner_stop", spinner_stop)?;

    // proxy.config.get(key) — placeholder for v0.3
    let config_table = lua.create_table()?;
    let get_fn = lua.create_function(
        |_lua, _key: String| -> LuaResult<Option<String>> { Ok(None) },
    )?;
    config_table.set("get", get_fn)?;
    proxy_table.set("config", config_table)?;

    lua.globals().set("proxy", proxy_table)?;

    Ok((lua, registry, send_input_rx))
}
