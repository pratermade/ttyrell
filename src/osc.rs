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
}

enum ParserState {
    Normal,
    FoundEsc,
    InOSC,
    InOscFoundEsc, // saw ESC inside OSC — waiting to confirm ST terminator
}

impl OscParser {
    pub fn new() -> Self {
        Self {
            state: ParserState::Normal,
            pending_osc: BytesMut::new(),
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
                    } else {
                        // Not an OSC — emit ESC and the byte as-is
                        output.extend_from_slice(&[0x1b, byte]);
                        self.state = ParserState::Normal;
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

    fn finish_osc(&mut self, events: &mut Vec<OscEvent>) {
        let payload = std::mem::take(&mut self.pending_osc);
        let text = std::str::from_utf8(&payload).unwrap_or("");
        let text = text.trim_end_matches(|c| c == '\0' || c == '\x1b');

        if text == "133;C" || text == "133;C\0" {
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
