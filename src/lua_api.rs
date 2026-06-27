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
/// Returns the Lua state and the event registry.
pub fn init_lua() -> LuaResult<(Lua, EventRegistry)> {
    let lua = Lua::new();
    let registry = EventRegistry::new();
    let registry_clone = registry.clone();

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
            match req.send_string(&body) {
                Ok(resp) => {
                    let status = resp.status();
                    let text = resp.into_string().map_err(mlua::Error::external)?;
                    Ok((status, text))
                }
                Err(ureq::Error::Status(code, resp)) => {
                    let text = resp.into_string().unwrap_or_default();
                    Ok((code, text))
                }
                Err(e) => Err(mlua::Error::external(e)),
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

    // proxy.config.get(key) — placeholder for v0.3
    let config_table = lua.create_table()?;
    let get_fn = lua.create_function(
        |_lua, _key: String| -> LuaResult<Option<String>> { Ok(None) },
    )?;
    config_table.set("get", get_fn)?;
    proxy_table.set("config", config_table)?;

    lua.globals().set("proxy", proxy_table)?;

    Ok((lua, registry))
}
