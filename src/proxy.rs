use crate::lua_api::EventRegistry;
use crate::osc::{OscEvent, OscParser};
use mlua::Lua;
use portable_pty::{CommandBuilder, NativePtySystem, PtySize, PtySystem};
use std::io::{Read, Write};

enum Message {
    PtyEvents(Vec<OscEvent>),
    PtyOutput(String),
    StdinData(Vec<u8>),
    Eof,
}

pub fn run(shell: &str, registry: EventRegistry, lua: &Lua) -> anyhow::Result<()> {
    let pty_system = NativePtySystem::default();
    let size = get_terminal_size();

    let pair = pty_system.openpty(size)?;
    let (master, slave) = (pair.master, pair.slave);

    let mut cmd = CommandBuilder::new(shell);
    cmd.env(
        "TERM",
        std::env::var("TERM").unwrap_or_else(|_| "xterm-256color".to_string()),
    );

    let _child = slave.spawn_command(cmd)?;
    drop(slave);

    let mut reader = master.try_clone_reader()?;
    let mut writer = master.take_writer()?;

    // Expose static session metadata to Lua before any events fire.
    // mlua::Error isn't Send+Sync so can't use ? directly into anyhow::Result.
    let hostname = get_hostname();
    (|| -> mlua::Result<()> {
        let proxy_table: mlua::Table = lua.globals().get("proxy")?;
        let info = lua.create_table()?;
        info.set("host", hostname.clone())?;
        info.set("shell", shell)?;
        info.set("version", env!("CARGO_PKG_VERSION"))?;
        info.set("pid", std::process::id())?;
        proxy_table.set("session_info", info)
    })()
    .map_err(|e| anyhow::anyhow!("Lua session_info setup failed: {}", e))?;

    let _ = registry.fire(lua, "session_start", vec![hostname, shell.to_string()]);

    let (msg_tx, msg_rx) = std::sync::mpsc::channel::<Message>();

    // --- PTY output thread: reads PTY, parses OSC, forwards to stdout and main loop ---
    let pty_tx = msg_tx.clone();
    let stdout_thread = std::thread::spawn(move || {
        use std::io::Write as IoWrite;
        let mut osc = OscParser::new();
        let mut stdout = std::io::stdout();
        let mut buf = [0u8; 8192];

        loop {
            match reader.read(&mut buf) {
                Ok(0) => {
                    let _ = pty_tx.send(Message::Eof);
                    break;
                }
                Err(e) => {
                    eprintln!("PTY read error: {}", e);
                    let _ = pty_tx.send(Message::Eof);
                    break;
                }
                Ok(n) => {
                    let (events, clean, _) = osc.feed(&buf[..n]);

                    if !events.is_empty() {
                        let _ = pty_tx.send(Message::PtyEvents(events));
                    }

                    if !clean.is_empty() {
                        if stdout.write_all(&clean).is_err() {
                            break;
                        }
                        let _ = stdout.flush();

                        let stripped = strip_ansi(&clean);
                        if !stripped.is_empty() {
                            if let Ok(text) = String::from_utf8(stripped) {
                                let _ = pty_tx.send(Message::PtyOutput(text));
                            }
                        }
                    }
                }
            }
        }
    });

    // --- Stdin thread: reads stdin and forwards to main loop ---
    let stdin_tx = msg_tx;
    std::thread::spawn(move || {
        let mut stdin = std::io::stdin();
        let mut buf = [0u8; 4096];
        loop {
            match stdin.read(&mut buf) {
                Ok(0) => {
                    let _ = stdin_tx.send(Message::Eof);
                    break;
                }
                Err(_) => {
                    let _ = stdin_tx.send(Message::Eof);
                    break;
                }
                Ok(n) => {
                    if stdin_tx
                        .send(Message::StdinData(buf[..n].to_vec()))
                        .is_err()
                    {
                        break;
                    }
                }
            }
        }
    });

    // --- Main loop: dispatch all events reactively ---
    loop {
        match msg_rx.recv() {
            Ok(Message::PtyEvents(events)) => {
                for event in &events {
                    match event {
                        OscEvent::CommandStart => {
                            let _ = registry.fire(lua, "command_start", vec![]);
                        }
                        OscEvent::CommandExit(code) => {
                            let _ = registry.fire(lua, "command_exit", vec![code.clone()]);
                        }
                        OscEvent::PromptStart => {
                            let _ = registry.fire(lua, "prompt_start", vec![]);
                        }
                    }
                }
            }
            Ok(Message::PtyOutput(text)) => {
                let _ = registry.fire(lua, "output", vec![text]);
            }
            Ok(Message::StdinData(input)) => {
                let suppressed = registry
                    .fire(
                        lua,
                        "input",
                        vec![String::from_utf8_lossy(&input).to_string()],
                    )
                    .unwrap_or(false);

                if !suppressed {
                    if writer.write_all(&input).is_err() {
                        break;
                    }
                    let _ = writer.flush();
                }
            }
            Ok(Message::Eof) | Err(_) => break,
        }
    }

    drop(writer);
    drop(master);
    let _ = registry.fire(lua, "session_end", vec![]);
    let _ = stdout_thread.join();
    Ok(())
}

/// Strip ANSI/VT escape sequences, keeping only printable text.
fn strip_ansi(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 0x1b && i + 1 < bytes.len() {
            i += 1;
            match bytes[i] {
                // CSI: ESC [ <params> <final byte 0x40–0x7E>
                0x5b => {
                    i += 1;
                    while i < bytes.len() && bytes[i] < 0x40 {
                        i += 1;
                    }
                    if i < bytes.len() {
                        i += 1;
                    }
                }
                // OSC: ESC ] ... BEL or ST (ESC \)
                0x5d => {
                    i += 1;
                    while i < bytes.len() {
                        if bytes[i] == 0x07 {
                            i += 1;
                            break;
                        }
                        if bytes[i] == 0x1b
                            && i + 1 < bytes.len()
                            && bytes[i + 1] == 0x5c
                        {
                            i += 2;
                            break;
                        }
                        i += 1;
                    }
                }
                // Any other ESC + single char
                _ => {
                    i += 1;
                }
            }
        } else {
            let b = bytes[i];
            if b >= 0x20 || b == b'\n' || b == b'\r' || b == b'\t' {
                out.push(b);
            }
            i += 1;
        }
    }
    out
}

fn get_hostname() -> String {
    if let Ok(h) = std::env::var("HOSTNAME") {
        return h;
    }
    if let Ok(h) = std::env::var("COMPUTERNAME") {
        return h;
    }
    #[cfg(unix)]
    {
        let mut buf = [0u8; 256];
        unsafe {
            if libc::gethostname(buf.as_mut_ptr() as *mut libc::c_char, buf.len()) == 0 {
                let len = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
                if let Ok(s) = std::str::from_utf8(&buf[..len]) {
                    return s.to_string();
                }
            }
        }
    }
    "unknown".to_string()
}

fn get_terminal_size() -> PtySize {
    #[cfg(unix)]
    {
        use std::os::unix::io::AsRawFd;
        let fd = std::io::stderr().as_raw_fd();
        let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
        if unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut ws) } == 0 && ws.ws_col > 0 {
            return PtySize {
                rows: ws.ws_row,
                cols: ws.ws_col,
                pixel_width: ws.ws_xpixel,
                pixel_height: ws.ws_ypixel,
            };
        }
    }
    PtySize {
        rows: 24,
        cols: 80,
        pixel_width: 0,
        pixel_height: 0,
    }
}
