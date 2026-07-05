use crate::lua_api::EventRegistry;
use crate::osc::{OscEvent, OscParser};
use mlua::Lua;
use portable_pty::{CommandBuilder, NativePtySystem, PtySize, PtySystem};
use std::io::{Read, Write};

/// Atomic flag set by the SIGWINCH signal handler on Unix. The main event loop
/// polls this and resizes the PTY master when the terminal window changes.
#[cfg(unix)]
static NEED_RESIZE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

enum Message {
    PtyEvents(Vec<OscEvent>),
    PtyOutput(String),
    StdinData(Vec<u8>),
    SendInput(Vec<u8>),
    Eof,
}

pub fn run(
    shell: &str,
    registry: EventRegistry,
    lua: &Lua,
    send_input_rx: std::sync::mpsc::Receiver<Vec<u8>>,
) -> anyhow::Result<()> {
    #[cfg(unix)]
    let _raw = RawModeGuard::enable();
    #[cfg(windows)]
    let _raw = WindowsConsoleGuard::enable();

    // Install a SIGWINCH handler so the PTY learns about terminal resize events.
    // The handler sets an atomic flag; the main event loop polls it and calls
    // master.resize(). This is safe: the signal handler only writes to an
    // AtomicBool (async-signal-safe on all platforms) and libc::signal with
    // SA_RESTART semantics means interrupted syscalls are transparently retried.
    #[cfg(unix)]
    unsafe {
        extern "C" fn sigwinch_handler(_: libc::c_int) {
            NEED_RESIZE.store(true, std::sync::atomic::Ordering::SeqCst);
        }
        libc::signal(libc::SIGWINCH, sigwinch_handler as *const () as libc::sighandler_t);
    }

    let pty_system = NativePtySystem::default();
    let size = get_terminal_size();

    let pair = pty_system.openpty(size)?;
    let (master, slave) = (pair.master, pair.slave);

    let mut cmd = CommandBuilder::new(shell);
    cmd.env(
        "TERM",
        std::env::var("TERM").unwrap_or_else(|_| "xterm-256color".to_string()),
    );
    // Start the shell in the directory ttyrell was launched from.
    if let Ok(cwd) = std::env::current_dir() {
        cmd.cwd(cwd);
    }

    let child = slave.spawn_command(cmd)?;
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

    // Forward proxy.send_input() calls into the main message loop
    let send_input_fwd_tx = msg_tx.clone();
    std::thread::spawn(move || {
        while let Ok(bytes) = send_input_rx.recv() {
            if send_input_fwd_tx.send(Message::SendInput(bytes)).is_err() {
                break;
            }
        }
    });

    // --- Child waiter: signal shutdown when the shell exits. On Windows ConPTY
    // the PTY reader does not observe EOF when the child terminates, so `exit`
    // would otherwise hang; watch the child process directly. ---
    let child_tx = msg_tx.clone();
    std::thread::spawn(move || {
        let mut child = child;
        let _ = child.wait();
        let _ = child_tx.send(Message::Eof);
    });

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
        // Poll the SIGWINCH flag on Unix. When the terminal window changes size
        // the signal handler sets this flag, and we propagate the new dimensions
        // into the PTY so the slave (and shell/TUI inside) sees the up-to-date size.
        #[cfg(unix)]
        if NEED_RESIZE.swap(false, std::sync::atomic::Ordering::SeqCst) {
            let new_size = get_terminal_size();
            if let Err(e) = master.resize(new_size) {
                eprintln!("PTY resize failed: {}", e);
            }
        }

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
                        OscEvent::TuiStart => {
                            let _ = registry.fire(lua, "tui_start", vec![]);
                        }
                        OscEvent::TuiEnd => {
                            let _ = registry.fire(lua, "tui_end", vec![]);
                        }
                        OscEvent::CwdChanged(dir) => {
                            let _ = registry.fire(lua, "cwd_changed", vec![dir.clone()]);
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
            Ok(Message::SendInput(bytes)) => {
                let _ = writer.write_all(&bytes);
                let _ = writer.flush();
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

#[cfg(unix)]
struct RawModeGuard(libc::termios);

#[cfg(unix)]
impl RawModeGuard {
    fn enable() -> Option<Self> {
        unsafe {
            let mut orig = std::mem::zeroed::<libc::termios>();
            if libc::tcgetattr(libc::STDIN_FILENO, &mut orig) != 0 {
                return None;
            }
            let mut raw = orig;
            libc::cfmakeraw(&mut raw);
            libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &raw);
            Some(RawModeGuard(orig))
        }
    }
}

#[cfg(unix)]
impl Drop for RawModeGuard {
    fn drop(&mut self) {
        unsafe {
            libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &self.0);
        }
    }
}

// ── Windows console raw mode ───────────────────────────────────────────────────
// Without this the console stays in cooked/line mode: stdin is line-buffered and
// echoed, so per-keystroke `input` events never fire (input only arrives on Enter)
// and control keys like Ctrl-G are swallowed. Put stdin into raw + VT-input mode
// (bytes delivered as typed, no echo) and enable VT output, restoring on drop.
#[cfg(windows)]
mod winconsole {
    pub const STD_INPUT_HANDLE: u32 = 0xFFFF_FFF6; // (DWORD)-10
    pub const STD_OUTPUT_HANDLE: u32 = 0xFFFF_FFF5; // (DWORD)-11
    pub const ENABLE_PROCESSED_INPUT: u32 = 0x0001;
    pub const ENABLE_LINE_INPUT: u32 = 0x0002;
    pub const ENABLE_ECHO_INPUT: u32 = 0x0004;
    pub const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;
    pub const ENABLE_PROCESSED_OUTPUT: u32 = 0x0001;
    pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;

    #[repr(C)]
    pub struct COORD {
        pub x: i16,
        pub y: i16,
    }

    #[repr(C)]
    pub struct SMALL_RECT {
        pub left: i16,
        pub top: i16,
        pub right: i16,
        pub bottom: i16,
    }

    #[repr(C)]
    pub struct CONSOLE_SCREEN_BUFFER_INFO {
        pub dw_size: COORD,
        pub dw_cursor_position: COORD,
        pub w_attributes: u16,
        pub sr_window: SMALL_RECT,
        pub dw_maximum_window_size: COORD,
    }

    unsafe extern "system" {
        pub fn GetStdHandle(n_std_handle: u32) -> *mut core::ffi::c_void;
        pub fn GetConsoleMode(h: *mut core::ffi::c_void, mode: *mut u32) -> i32;
        pub fn SetConsoleMode(h: *mut core::ffi::c_void, mode: u32) -> i32;
        pub fn GetConsoleScreenBufferInfo(
            h: *mut core::ffi::c_void,
            info: *mut CONSOLE_SCREEN_BUFFER_INFO,
        ) -> i32;
    }
}

#[cfg(windows)]
struct WindowsConsoleGuard {
    stdin: *mut core::ffi::c_void,
    stdout: *mut core::ffi::c_void,
    in_mode: u32,
    out_mode: u32,
    restore_out: bool,
}

#[cfg(windows)]
impl WindowsConsoleGuard {
    fn enable() -> Option<Self> {
        use winconsole::*;
        unsafe {
            let stdin = GetStdHandle(STD_INPUT_HANDLE);
            let stdout = GetStdHandle(STD_OUTPUT_HANDLE);

            let mut in_mode = 0u32;
            if GetConsoleMode(stdin, &mut in_mode) == 0 {
                // stdin is not a console (piped/redirected) — leave everything alone.
                return None;
            }

            let raw_in = (in_mode
                & !(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT))
                | ENABLE_VIRTUAL_TERMINAL_INPUT;
            SetConsoleMode(stdin, raw_in);

            let mut out_mode = 0u32;
            let restore_out = GetConsoleMode(stdout, &mut out_mode) != 0;
            if restore_out {
                SetConsoleMode(
                    stdout,
                    out_mode | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING,
                );
            }

            Some(WindowsConsoleGuard {
                stdin,
                stdout,
                in_mode,
                out_mode,
                restore_out,
            })
        }
    }
}

#[cfg(windows)]
impl Drop for WindowsConsoleGuard {
    fn drop(&mut self) {
        use winconsole::*;
        unsafe {
            SetConsoleMode(self.stdin, self.in_mode);
            if self.restore_out {
                SetConsoleMode(self.stdout, self.out_mode);
            }
        }
    }
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

        // Prefer /dev/tty — the controlling terminal of the process. Using
        // stderr alone is fragile: when stderr is redirected or piped its fd
        // points to the pipe, not the terminal, and TIOCGWINSZ fails.
        let tty_fd = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open("/dev/tty")
            .ok()
            .map(|f| f.as_raw_fd());

        // Query chain: /dev/tty → stderr → stdin → give up and use default.
        // All three may be the same underlying fd; trying all is harmless.
        let fds: Vec<i32> = match tty_fd {
            Some(fd) => vec![fd, libc::STDERR_FILENO, libc::STDIN_FILENO],
            None => vec![libc::STDERR_FILENO, libc::STDIN_FILENO],
        };

        for fd in fds {
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
    }
    #[cfg(windows)]
    {
        use winconsole::*;
        unsafe {
            let h = GetStdHandle(STD_OUTPUT_HANDLE);
            let mut info: CONSOLE_SCREEN_BUFFER_INFO = std::mem::zeroed();
            if GetConsoleScreenBufferInfo(h, &mut info) != 0 {
                // Visible window (sr_window), not the buffer (dw_size, which
                // includes scrollback height).
                let cols = info.sr_window.right - info.sr_window.left + 1;
                let rows = info.sr_window.bottom - info.sr_window.top + 1;
                if cols > 0 && rows > 0 {
                    return PtySize {
                        rows: rows as u16,
                        cols: cols as u16,
                        pixel_width: 0,
                        pixel_height: 0,
                    };
                }
            }
        }
    }
    PtySize {
        rows: 24,
        cols: 80,
        pixel_width: 0,
        pixel_height: 0,
    }
}
