use bytes::BytesMut;

/// OSC 133 event types emitted by the state machine.
#[derive(Debug, Clone)]
pub enum OscEvent {
    /// Shell integration: command execution start
    CommandStart,
    /// Shell integration: command finished with exit code
    CommandExit(String),
    /// Shell integration: prompt rendered
    PromptStart,
    /// TUI app entered alternate screen buffer (ESC[?1049h)
    TuiStart,
    /// TUI app left alternate screen buffer (ESC[?1049l)
    TuiEnd,
    /// Shell reported its current working directory via OSC 7
    CwdChanged(String),
}

/// A streaming parser for OSC 133 escape sequences.
///
/// Parser state (self.state, self.pending_osc) persists across calls,
/// so sequences split across read() boundaries are handled correctly.
///
/// Supported sequences:
///   \x1b]133;C\x07          — CommandStart
///   \x1b]133;A\x07          — PromptStart
///   \x1b]133;D[;A][,<code>]\x07 — CommandExit
///
/// Both BEL (\x07) and ST (\x1b\x5c) terminators are recognized.
pub struct OscParser {
    state: ParserState,
    pending_osc: BytesMut,
    pending_csi: BytesMut,
}

enum ParserState {
    Normal,
    FoundEsc,
    InOSC,
    InOscFoundEsc, // saw ESC inside OSC — waiting to confirm ST terminator
    InCSI,         // saw ESC [ — accumulating CSI params until final byte
}

impl OscParser {
    pub fn new() -> Self {
        Self {
            state: ParserState::Normal,
            pending_osc: BytesMut::new(),
            pending_csi: BytesMut::new(),
        }
    }

    /// Feed bytes into the parser.
    /// Returns (events, clean_output, _unused).
    /// Parser state persists across calls — the third return value is always empty.
    pub fn feed(&mut self, data: &[u8]) -> (Vec<OscEvent>, BytesMut, BytesMut) {
        let mut events = Vec::new();
        let mut output = BytesMut::new();

        for &byte in data {
            match self.state {
                ParserState::Normal => {
                    if byte == 0x1b {
                        self.state = ParserState::FoundEsc;
                    } else {
                        output.extend_from_slice(&[byte]);
                    }
                }
                ParserState::FoundEsc => {
                    if byte == 0x5d {
                        // ESC ] — start of OSC sequence
                        self.state = ParserState::InOSC;
                        self.pending_osc.clear();
                    } else if byte == 0x5b {
                        // ESC [ — start of CSI sequence
                        self.state = ParserState::InCSI;
                        self.pending_csi.clear();
                    } else {
                        // Not an OSC or CSI — emit ESC and the byte as-is
                        output.extend_from_slice(&[0x1b, byte]);
                        self.state = ParserState::Normal;
                    }
                }
                ParserState::InCSI => {
                    if byte >= 0x40 {
                        // Final byte (0x40–0x7E) — sequence complete
                        let params = std::str::from_utf8(&self.pending_csi).unwrap_or("");
                        if params == "?1049" {
                            if byte == b'h' {
                                events.push(OscEvent::TuiStart);
                            } else if byte == b'l' {
                                events.push(OscEvent::TuiEnd);
                            }
                        }
                        // Pass the full CSI sequence to clean output; strip_ansi removes it
                        output.extend_from_slice(b"\x1b[");
                        output.extend_from_slice(&self.pending_csi);
                        output.extend_from_slice(&[byte]);
                        self.pending_csi.clear();
                        self.state = ParserState::Normal;
                    } else {
                        self.pending_csi.extend_from_slice(&[byte]);
                    }
                }
                ParserState::InOSC => {
                    if byte == 0x07 {
                        // BEL terminator
                        self.finish_osc(&mut events);
                        self.state = ParserState::Normal;
                    } else if byte == 0x1b {
                        // Possible ST terminator (\x1b\x5c) — wait for next byte
                        self.state = ParserState::InOscFoundEsc;
                    } else {
                        self.pending_osc.extend_from_slice(&[byte]);
                    }
                }
                ParserState::InOscFoundEsc => {
                    if byte == 0x5c {
                        // ESC \ = String Terminator — end of OSC
                        self.finish_osc(&mut events);
                        self.state = ParserState::Normal;
                    } else if byte == 0x07 {
                        // ESC then BEL: treat ESC as content, BEL as terminator
                        self.pending_osc.extend_from_slice(&[0x1b]);
                        self.finish_osc(&mut events);
                        self.state = ParserState::Normal;
                    } else {
                        // Not ST — ESC was literal OSC content, keep accumulating
                        self.pending_osc.extend_from_slice(&[0x1b, byte]);
                        self.state = ParserState::InOSC;
                    }
                }
            }
        }

        // State and pending_osc persist automatically across calls.
        (events, output, BytesMut::new())
    }

}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = (bytes[i + 1] as char).to_digit(16);
            let lo = (bytes[i + 2] as char).to_digit(16);
            if let (Some(h), Some(l)) = (hi, lo) {
                out.push((h * 16 + l) as u8 as char);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

impl OscParser {
    fn finish_osc(&mut self, events: &mut Vec<OscEvent>) {
        let payload = std::mem::take(&mut self.pending_osc);
        let text = std::str::from_utf8(&payload).unwrap_or("");
        let text = text.trim_end_matches(|c| c == '\0' || c == '\x1b');

        if text.starts_with("7;file://") {
            // OSC 7: shell CWD notification. Format: 7;file://hostname/path
            // Skip "7;file://" then skip the hostname (everything before the first /).
            let rest = &text[9..];
            let path = rest.find('/').map(|i| &rest[i..]).unwrap_or(rest);
            // URL-decode percent-encoded characters (e.g. %20 → space)
            let decoded = percent_decode(path);
            if !decoded.is_empty() {
                events.push(OscEvent::CwdChanged(decoded));
            }
        } else if text == "133;C" || text == "133;C\0" {
            events.push(OscEvent::CommandStart);
        } else if text == "133;A" || text == "133;A\0" {
            events.push(OscEvent::PromptStart);
        } else if text.starts_with("133;D") {
            let code_part = &text[5..]; // skip "133;D"
            let code = if code_part.starts_with(";A;") {
                &code_part[3..]
            } else if code_part.starts_with(';') {
                &code_part[1..]
            } else {
                code_part
            };
            events.push(OscEvent::CommandExit(code.trim().to_string()));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_command_start() {
        let mut parser = OscParser::new();
        let data = b"\x1b]133;C\x07hello\x1b]133;A\x07";
        let (events, out, _) = parser.feed(data);
        assert_eq!(events.len(), 2);
        assert!(matches!(events[0], OscEvent::CommandStart));
        assert!(matches!(events[1], OscEvent::PromptStart));
        assert_eq!(&out[..], b"hello");
    }

    #[test]
    fn test_command_exit() {
        let mut parser = OscParser::new();
        let data = b"\x1b]133;D;127\x07";
        let (events, out, _) = parser.feed(data);
        assert_eq!(events.len(), 1);
        if let OscEvent::CommandExit(ref c) = events[0] {
            assert_eq!(c, "127");
        } else {
            panic!("expected CommandExit");
        }
        assert!(out.is_empty());
    }

    #[test]
    fn test_passthrough() {
        let mut parser = OscParser::new();
        let data = b"normal text\nmore text\n";
        let (events, out, _) = parser.feed(data);
        assert!(events.is_empty());
        assert_eq!(&out[..], data);
    }

    #[test]
    fn test_interleaved() {
        let mut parser = OscParser::new();
        let data = b"hello\x1b]133;C\x07world\x1b]133;D;0\x07foo";
        let (events, out, _) = parser.feed(data);
        assert_eq!(events.len(), 2);
        assert!(matches!(events[0], OscEvent::CommandStart));
        if let OscEvent::CommandExit(ref c) = events[1] {
            assert_eq!(c, "0");
        }
        assert_eq!(&out[..], b"helloworldfoo");
    }

    #[test]
    fn test_st_terminator() {
        let mut parser = OscParser::new();
        let data = b"\x1b]133;C\x1b\\hello";
        let (events, out, _) = parser.feed(data);
        assert_eq!(events.len(), 1);
        assert!(matches!(events[0], OscEvent::CommandStart));
        assert_eq!(&out[..], b"hello");
    }

    #[test]
    fn test_split_at_in_osc_boundary() {
        let mut parser = OscParser::new();
        // Chunk 1 ends mid-sequence
        let (events1, out1, _) = parser.feed(b"\x1b]133;");
        assert!(events1.is_empty());
        assert!(out1.is_empty());
        // Chunk 2 completes it
        let (events2, out2, _) = parser.feed(b"C\x07after");
        assert_eq!(events2.len(), 1);
        assert!(matches!(events2[0], OscEvent::CommandStart));
        assert_eq!(&out2[..], b"after");
    }

    #[test]
    fn test_osc7_cwd_basic() {
        let mut parser = OscParser::new();
        let (events, _, _) = parser.feed(b"\x1b]7;file://localhost/home/user/projects\x07");
        assert_eq!(events.len(), 1);
        if let OscEvent::CwdChanged(ref p) = events[0] {
            assert_eq!(p, "/home/user/projects");
        } else {
            panic!("expected CwdChanged");
        }
    }

    #[test]
    fn test_osc7_cwd_percent_encoded() {
        let mut parser = OscParser::new();
        let (events, _, _) = parser.feed(b"\x1b]7;file://localhost/home/user/my%20project\x07");
        assert_eq!(events.len(), 1);
        if let OscEvent::CwdChanged(ref p) = events[0] {
            assert_eq!(p, "/home/user/my project");
        } else {
            panic!("expected CwdChanged");
        }
    }

    #[test]
    fn test_osc7_cwd_no_hostname() {
        // file:///path (empty hostname, triple slash)
        let mut parser = OscParser::new();
        let (events, _, _) = parser.feed(b"\x1b]7;file:///tmp/work\x07");
        assert_eq!(events.len(), 1);
        if let OscEvent::CwdChanged(ref p) = events[0] {
            assert_eq!(p, "/tmp/work");
        } else {
            panic!("expected CwdChanged");
        }
    }

    #[test]
    fn test_osc7_interleaved_with_osc133() {
        let mut parser = OscParser::new();
        let data = b"\x1b]133;D;0\x07\x1b]7;file://localhost/home/user\x07\x1b]133;A\x07";
        let (events, _, _) = parser.feed(data);
        assert_eq!(events.len(), 3);
        assert!(matches!(events[0], OscEvent::CommandExit(_)));
        assert!(matches!(events[1], OscEvent::CwdChanged(_)));
        assert!(matches!(events[2], OscEvent::PromptStart));
    }

    #[test]
    fn test_tui_start_emits_event() {
        let mut parser = OscParser::new();
        let (events, out, _) = parser.feed(b"\x1b[?1049hsome text");
        assert_eq!(events.len(), 1);
        assert!(matches!(events[0], OscEvent::TuiStart));
        // CSI sequence passed through to clean output (strip_ansi will drop it)
        assert!(out.windows(b"\x1b[".len()).any(|w| w == b"\x1b["));
        assert!(out.ends_with(b"some text"));
    }

    #[test]
    fn test_tui_end_emits_event() {
        let mut parser = OscParser::new();
        let (events, _, _) = parser.feed(b"\x1b[?1049l");
        assert_eq!(events.len(), 1);
        assert!(matches!(events[0], OscEvent::TuiEnd));
    }

    #[test]
    fn test_tui_start_and_end_in_same_feed() {
        let mut parser = OscParser::new();
        let (events, _, _) = parser.feed(b"\x1b[?1049htext\x1b[?1049l");
        assert_eq!(events.len(), 2);
        assert!(matches!(events[0], OscEvent::TuiStart));
        assert!(matches!(events[1], OscEvent::TuiEnd));
    }

    #[test]
    fn test_other_csi_not_emitted_as_event() {
        let mut parser = OscParser::new();
        // ESC[2J (clear screen) and ESC[H (cursor home) — no TUI events
        let (events, _, _) = parser.feed(b"\x1b[2J\x1b[H");
        assert!(events.is_empty());
    }

    #[test]
    fn test_csi_split_across_reads() {
        let mut parser = OscParser::new();
        // Split "\x1b[?1049h" across two reads
        let (events1, _, _) = parser.feed(b"\x1b[?10");
        assert!(events1.is_empty());
        let (events2, _, _) = parser.feed(b"49h");
        assert_eq!(events2.len(), 1);
        assert!(matches!(events2[0], OscEvent::TuiStart));
    }

    #[test]
    fn test_osc133_and_tui_interleaved() {
        let mut parser = OscParser::new();
        let data = b"\x1b]133;C\x07\x1b[?1049hstuff\x1b[?1049l\x1b]133;D;0\x07";
        let (events, _, _) = parser.feed(data);
        assert_eq!(events.len(), 4);
        assert!(matches!(events[0], OscEvent::CommandStart));
        assert!(matches!(events[1], OscEvent::TuiStart));
        assert!(matches!(events[2], OscEvent::TuiEnd));
        if let OscEvent::CommandExit(ref c) = events[3] { assert_eq!(c, "0"); }
        else { panic!("expected CommandExit"); }
    }

    #[test]
    fn test_split_at_esc_boundary() {
        let mut parser = OscParser::new();
        // Chunk 1 ends exactly on ESC byte
        let (events1, out1, _) = parser.feed(b"before\x1b");
        assert!(events1.is_empty());
        assert_eq!(&out1[..], b"before");
        // Chunk 2 delivers the ] and rest
        let (events2, out2, _) = parser.feed(b"]133;A\x07after");
        assert_eq!(events2.len(), 1);
        assert!(matches!(events2[0], OscEvent::PromptStart));
        assert_eq!(&out2[..], b"after");
    }
}
