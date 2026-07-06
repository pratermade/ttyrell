# Fix Terminal Size Detection and Last-Line Scroll Misbehavior

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Fix two terminal misbehaviors: (1) console size not detected correctly — PTY is opened with stale/fallback dimensions instead of actual window size, so TUI apps like vim don't fill the window; (2) when output reaches the last line of the terminal, the terminal rewrites the same line instead of scrolling.

**Architecture:** The root cause is the same for both issues: `get_terminal_size()` is called once at PTY creation time in `proxy.rs:27` and the size is never updated afterward. The PTY is opened with a fixed `PtySize`, and when the real terminal window changes size (or when output reaches the bottom of a window whose dimensions don't match reality), the slave PTY doesn't know the actual viewport. The fix is to (a) read the current terminal size before opening the PTY (using `ioctl` from `/dev/tty` on Unix, not `stderr` which may be redirected/piped) and (b) handle `SIGWINCH` to resize the PTY when the terminal window changes.

**Tech Stack:** Rust, `libc` (already a dependency), `portable-pty` crate.

---

## Root Cause Analysis

### Issue #1 — Console size not detected correctly

The `get_terminal_size()` function at `src/proxy.rs:431` queries `stderr`'s file descriptor:

```rust
let fd = std::io::stderr().as_raw_fd();
```

This works only if stderr is a terminal. If stderr is redirected (e.g., `ttyrell 2>/dev/null`), the `ioctl` call fails and falls through to the default `24×80`. Even when it succeeds, it captures the size at the moment of PTY creation — if the terminal is later resized, the PTY is never told.

Additionally, `/dev/tty` is the correct file descriptor to query for the controlling terminal. Using stderr is fragile.

### Issue #2 — Last line rewrites instead of scrolling

This is a symptom of the same root cause. When the PTY was created with dimensions that don't match the actual terminal, or when the terminal was resized after PTY creation, the kernel's terminal line discipline thinks the screen has different bounds. When the shell outputs a newline at what it believes is the bottom row, the PTY-master writes bytes, but the real terminal's cursor is in a different position because the real scroll region doesn't match. This causes the overwrite-at-bottom behavior.

There's an additional subtlety: even with correct initial sizing, if the user resizes the window (font change, split pane, etc.), the PTY needs to be notified via `master.resize(size)` or the shell inside the PTY will never know the new dimensions.

---

## Plan

### Task 1: Fix `get_terminal_size()` to read from `/dev/tty`

**Objective:** Query the controlling terminal's size from `/dev/tty` instead of stderr, and handle the case where there is no controlling terminal gracefully.

**Files:**
- Modify: `src/proxy.rs` (`get_terminal_size` function, lines 431–474)

**Step 1: Rewrite `get_terminal_size` for Unix**

Replace the stderr-based ioctl with a `/dev/tty`-based approach. If `/dev/tty` can't be opened (no controlling terminal), fall back to stderr, then to the 24×80 default.

The key insight: `libc::STDERR_FILENO` is a raw file descriptor and may not point to a terminal. `/dev/tty` is the controlling terminal of the process group. Opening it gives us the real terminal dimensions.

New implementation for the `#[cfg(unix)]` block:

```rust
fn get_terminal_size() -> PtySize {
    #[cfg(unix)]
    {
        use std::os::unix::io::AsRawFd;
        // Prefer /dev/tty — the controlling terminal. Using stderr fails when
        // stderr is redirected or piped (the fd refers to the pipe, not the tty).
        let fd = std::fs::OpenOptions::new()
            .read(true)
            .write(true)  // TIOCGWINSZ may require a writable fd on some BSDs
            .open("/dev/tty")
            .map(|f| f.as_raw_fd())
            .ok();

        // Fall back to stderr if /dev/tty is unavailable (no controlling terminal)
        let query_fds: &[i32] = if let Some(fd) = fd {
            &[fd, libc::STDERR_FILENO]
        } else {
            &[libc::STDERR_FILENO]
        };

        for &fd in query_fds {
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
    // ... windows block unchanged ...
    PtySize {
        rows: 24,
        cols: 80,
        pixel_width: 0,
        pixel_height: 0,
    }
}
```

**Step 2: Build and verify compilation**

Run: `cargo build --release`
Expected: compiles without errors or warnings.

**Step 3: Commit**

```bash
git add src/proxy.rs
git commit -m "fix: read terminal size from /dev/tty instead of stderr"
```

---

### Task 2: Handle `SIGWINCH` to resize PTY on terminal size changes

**Objective:** When the terminal window is resized, forward the new size to the PTY master so the slave (and shell/TUI inside) learns the new dimensions. This fixes vim not filling the window and the bottom-line scrolling issue.

**Files:**
- Modify: `src/proxy.rs` (the `run` function, around lines 15–216)

**Step 1: Add a SIGWINCH handler thread**

Use `libc::signal` with `SA_RESTART` to install a handler for `SIGWINCH`. The handler sets an `AtomicBool` flag. The main loop polls this flag and calls `master.resize(new_size)` when set.

Alternatively: use a `signalfd`-style approach (Rust doesn't have stable `signalfd`, but we can use the `signal-hook` crate... actually, let's keep it zero-dependency by using a classic signal handler + atomic flag). On Unix, after a signal handler fires, interrupted syscalls restart (SA_RESTART), so the handler is safe as long as it only writes to an `AtomicBool`.

The simplest safe approach:

1. Create a `static NEED_RESIZE: AtomicBool`.
2. Register a `SIGWINCH` handler that sets it to `true`.
3. In the main event loop, before or after each `recv()`, check the flag. If set, call `get_terminal_size()` and `master.resize(new_size)`.

Implementation sketch to add inside `pub fn run(...)`:

```rust
use std::sync::atomic::{AtomicBool, Ordering};

static NEED_RESIZE: AtomicBool = AtomicBool::new(false);

#[cfg(unix)]
unsafe {
    // libc::SIG_IGN in Rust 2024 — use std::ptr::null_mut() for SIG_DFL equivalent,
    // or better: use sigaction for SA_RESTART semantics.
    // Actually, simplest: just spawn a thread that blocks on sigwait.
    // But sigwait requires blocking SIGWINCH in the main thread first...
    // 
    // Simplest practical approach: spawn a dedicated thread that uses
    // sigwaitinfo/sigtimedwait or just polls via a pipe from a signal handler.
    // 
    // PRACTICAL approach for a binary: use signal_hook crate... no, keep zero deps.
    // Use the classic signal() function — it's not thread-safe per POSIX but works
    // fine for SIGWINCH in a single-threaded Rust program.
    extern "C" fn sigwinch_handler(_: i32) {
        NEED_RESIZE.store(true, Ordering::SeqCst);
    }
    libc::signal(libc::SIGWINCH, sigwinch_handler as libc::sighandler_t);
}
```

Then in the main loop (after `match msg_rx.recv()`):

```rust
if NEED_RESIZE.swap(false, Ordering::SeqCst) {
    let new_size = get_terminal_size();
    if let Err(e) = master.resize(new_size) {
        eprintln!("PTY resize failed: {}", e);
    }
}
```

Wait — there's a subtlety. On some systems, `ioctl(TIOCGWINSZ)` on the master pty after a resize actually returns the *new* size, not the old one, because the kernel copies winsize from the terminal to the pty when the terminal is resized. So just calling `get_terminal_size()` (which now reads from `/dev/tty` in task 1) and then `master.resize()` with those values should work.

Actually, no — `get_terminal_size()` reads from `/dev/tty`, which already reflects the new size after a SIGWINCH (the kernel updated it before sending the signal). `master.resize(new_size)` then propagates it to the slave, which sends SIGWINCH to the foreground process group in the PTY. Perfect.

**Step 2: Build and verify compilation**

Run: `cargo build --release`
Expected: compiles without errors.

**Step 3: Commit**

```bash
git add src/proxy.rs
git commit -m "fix: handle SIGWINCH to resize PTY on terminal size changes"
```

---

### Task 3: Update `get_terminal_size()` fallback to also check `stdin`

**Objective:** In the rare case where `/dev/tty` can't be opened AND stderr is not a terminal (piped), try stdin as a last resort. This is defensive — if the user somehow has stdin as a terminal but both `/dev/tty` and stderr are unavailable.

**Files:**
- Modify: `src/proxy.rs` (`get_terminal_size` function)

**Step 1: Add `STDIN_FILENO` to the query list**

Modify the Unix block of `get_terminal_size` to include `libc::STDIN_FILENO` as a final fallback:

```rust
let query_fds: &[i32] = match fd {
    Some(fd) => &[fd, libc::STDERR_FILENO, libc::STDIN_FILENO],
    None => &[libc::STDERR_FILENO, libc::STDIN_FILENO],
};
```

But be careful: `STDERR_FILENO` and `STDIN_FILENO` may be the same fd if stderr is dup'd to stdin. The ioctl will succeed on any valid terminal fd, so trying both is harmless.

**Step 2: Build and verify**

Run: `cargo build --release`
Expected: compiles cleanly.

**Step 3: Commit**

```bash
git add src/proxy.rs
git commit -m "fix: add stdin as terminal size query fallback"
```

---

## Verification

After all tasks:

1. **Test terminal size detection:**
   ```bash
   # Run ttyrell, then resize the terminal window
   # Inside ttyrell, run: tput lines && tput cols
   # Or open vim — it should fill the entire terminal
   ttyrell
   ```

2. **Test last-line scrolling:**
   ```bash
   # Run ttyrell, then generate output that fills the screen:
   ttyrell
   # Inside: for i in $(seq 1 100); do echo "line $i"; done
   # The terminal should scroll normally — old lines scroll off, new lines appear at bottom
   ```

3. **Test that signals are properly re-delivered:**
   ```bash
   # Run a child that cares about SIGWINCH:
   ttyrell
   # Inside: watch -n1 'tput lines; tput cols'
   # Resize terminal — the displayed values should change immediately
   ```

4. **Build and lint:**
   ```bash
   cargo build --release
   cargo test
   ```

## Files Changed Summary

| File | Change |
|------|--------|
| `src/proxy.rs` | Rewrite `get_terminal_size()` to use `/dev/tty`; add `SIGWINCH` handler; add resize logic in main loop |

## Risks

- **Signal handler safety**: Using `libc::signal()` is technically not async-signal-safe in multi-threaded programs. However, ttyrell only sets an `AtomicBool` in the handler, which is safe on all platforms. The alternative (`sigaction` + `SA_RESTART`) would be more correct but adds complexity with minimal practical benefit for SIGWINCH.
- **`/dev/tty` availability**: Some container/headless environments lack a controlling terminal. The fallback chain (`/dev/tty` → stderr → stdin → default 24×80) handles this gracefully.
- **Windows**: The Windows `CONSOLE_SCREEN_BUFFER_INFO` approach in the existing code is correct and unchanged. Windows sends `WINDOW_BUFFER_SIZE_EVENT` through its console input queue, which ConPTY should handle automatically.
