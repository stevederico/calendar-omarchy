use std::fs;
use std::path::PathBuf;

#[derive(Clone)]
pub struct Calendar {
    pub id: String,
    pub name: String,
    pub url: String,
    pub color: String,
    pub enabled: bool,
}

#[derive(Clone)]
pub struct Event {
    pub id: String,
    pub calendar_id: String,
    pub date_key: String,
    pub title: String,
    pub start: String,
    pub end: String,
    pub color: String,
    pub all_day: bool,
    /// Almanac rev of the event this row came from; empty for other feeds.
    pub rev: String,
    /// One date of a repeating event (or a moved date of one).
    pub repeats: bool,
}

#[derive(Clone)]
pub struct Store {
    pub calendars: Vec<Calendar>,
    pub events: Vec<Event>,
}

pub const LOCAL_ID: &str = "local";
pub const LOCAL_COLOR: &str = "#c4a574";

pub const PALETTE: &[&str] = &[
    "#5b9fd4", "#e07a5f", "#81b29a", "#f2cc8f", "#9b8ec4", "#e9c46a",
    "#c4a574", "#d67b7b", "#6bb3b3", "#c47ba0",
];

impl Default for Store {
    fn default() -> Self {
        Self {
            calendars: vec![local_calendar()],
            events: Vec::new(),
        }
    }
}

fn local_calendar() -> Calendar {
    Calendar {
        id: LOCAL_ID.into(),
        name: "Local".into(),
        url: String::new(),
        color: LOCAL_COLOR.into(),
        enabled: true,
    }
}

pub fn next_color(existing: usize) -> String {
    PALETTE[existing % PALETTE.len()].into()
}

pub fn load(path: &PathBuf) -> Result<Store, String> {
    if !path.exists() {
        return Ok(Store::default());
    }
    let text = fs::read_to_string(path).map_err(|e| e.to_string())?;
    if text.trim().is_empty() {
        return Ok(Store::default());
    }
    parse_store(&text)
}

/// Writes the store owner-only (0600): it can hold opened sealed events.
/// Missing parent directories are made 0700.
pub fn save(path: &PathBuf, store: &Store) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
    if let Some(dir) = path.parent() {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)
            .map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("json.tmp");
    let _ = fs::remove_file(&tmp);
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(|e| e.to_string())?;
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|e| e.to_string())?;
    file.write_all(encode(store).as_bytes())
        .map_err(|e| e.to_string())?;
    drop(file);
    fs::rename(&tmp, path).map_err(|e| e.to_string())
}

pub fn encode(store: &Store) -> String {
    let mut out = String::from("{\n  \"version\": 1,\n  \"calendars\": [\n");
    for (i, cal) in store.calendars.iter().enumerate() {
        if i > 0 {
            out.push_str(",\n");
        }
        out.push_str("    {\"id\":\"");
        out.push_str(&escape(&cal.id));
        out.push_str("\",\"name\":\"");
        out.push_str(&escape(&cal.name));
        out.push_str("\",\"url\":\"");
        out.push_str(&escape(&cal.url));
        out.push_str("\",\"color\":\"");
        out.push_str(&escape(&cal.color));
        out.push_str("\",\"enabled\":");
        out.push_str(if cal.enabled { "true" } else { "false" });
        out.push('}');
    }
    out.push_str("\n  ],\n  \"events\": [\n");
    for (i, event) in store.events.iter().enumerate() {
        if i > 0 {
            out.push_str(",\n");
        }
        out.push_str("    {\"id\":\"");
        out.push_str(&escape(&event.id));
        out.push_str("\",\"calendarId\":\"");
        out.push_str(&escape(&event.calendar_id));
        out.push_str("\",\"dateKey\":\"");
        out.push_str(&escape(&event.date_key));
        out.push_str("\",\"title\":\"");
        out.push_str(&escape(clip_title(&event.title)));
        out.push_str("\",\"start\":\"");
        out.push_str(&escape(&event.start));
        out.push_str("\",\"end\":\"");
        out.push_str(&escape(&event.end));
        out.push_str("\",\"color\":\"");
        out.push_str(&escape(&event.color));
        out.push_str("\",\"allDay\":");
        out.push_str(if event.all_day { "true" } else { "false" });
        if !event.rev.is_empty() {
            out.push_str(",\"rev\":\"");
            out.push_str(&escape(&event.rev));
            out.push('"');
        }
        if event.repeats {
            out.push_str(",\"repeats\":true");
        }
        out.push('}');
    }
    if !store.events.is_empty() {
        out.push('\n');
    }
    out.push_str("  ]\n}\n");
    out
}

fn parse_store(text: &str) -> Result<Store, String> {
    let mut p = Parser::new(text);
    p.skip_ws();
    p.expect(b'{')?;
    let mut store = Store::default();
    store.calendars.clear();
    loop {
        p.skip_ws();
        if p.peek() == Some(b'}') {
            p.expect(b'}')?;
            break;
        }
        let key = p.string()?;
        p.skip_ws();
        p.expect(b':')?;
        p.skip_ws();
        match key.as_str() {
            "version" => {
                let _ = p.number()?;
            }
            "calendars" => store.calendars = p.calendar_array()?,
            "events" => store.events = p.event_array()?,
            _ => p.skip_value()?,
        }
        p.skip_ws();
        if p.peek() == Some(b',') {
            p.i += 1;
        }
    }
    if !store.calendars.iter().any(|c| c.id == LOCAL_ID) {
        store.calendars.insert(0, local_calendar());
    }
    for event in &mut store.events {
        if event.calendar_id.is_empty() {
            event.calendar_id = LOCAL_ID.into();
        }
        if event.color.is_empty() {
            event.color = store
                .calendars
                .iter()
                .find(|c| c.id == event.calendar_id)
                .map(|c| c.color.clone())
                .unwrap_or_else(|| LOCAL_COLOR.into());
        }
    }
    Ok(store)
}

struct Parser<'a> {
    bytes: &'a [u8],
    i: usize,
}

enum Value {
    Str(String),
    Bool(bool),
    Num(u64),
    Skip,
}

impl<'a> Parser<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            bytes: text.as_bytes(),
            i: 0,
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.i).copied()
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\n' | b'\r' | b'\t')) {
            self.i += 1;
        }
    }

    fn expect(&mut self, byte: u8) -> Result<(), String> {
        if self.peek() == Some(byte) {
            self.i += 1;
            Ok(())
        } else {
            Err(format!("expected '{}'", byte as char))
        }
    }

    fn string(&mut self) -> Result<String, String> {
        self.expect(b'"')?;
        let mut raw = Vec::new();
        while let Some(b) = self.peek() {
            self.i += 1;
            match b {
                b'"' => {
                    return String::from_utf8(raw).map_err(|_| "string is not utf-8".into());
                }
                b'\\' => match self.peek() {
                    Some(n) => {
                        self.i += 1;
                        raw.push(match n {
                            b'"' => b'"',
                            b'\\' => b'\\',
                            b'n' => b'\n',
                            b'r' => b'\r',
                            b't' => b'\t',
                            other => other,
                        });
                    }
                    None => return Err("unterminated escape".into()),
                },
                _ => raw.push(b),
            }
            if raw.len() > 32 * 1024 {
                return Err("string too long".into());
            }
        }
        Err("unterminated string".into())
    }

    fn number(&mut self) -> Result<u64, String> {
        let start = self.i;
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.i += 1;
        }
        if start == self.i {
            return Err("expected number".into());
        }
        std::str::from_utf8(&self.bytes[start..self.i])
            .unwrap_or("0")
            .parse()
            .map_err(|_| "bad number".to_string())
    }

    fn atom(&mut self) -> Result<Value, String> {
        self.skip_ws();
        match self.peek() {
            Some(b'"') => Ok(Value::Str(self.string()?)),
            Some(b't') => {
                self.eat_word(b"true")?;
                Ok(Value::Bool(true))
            }
            Some(b'f') => {
                self.eat_word(b"false")?;
                Ok(Value::Bool(false))
            }
            Some(b'0'..=b'9') => Ok(Value::Num(self.number()?)),
            _ => {
                self.skip_value()?;
                Ok(Value::Skip)
            }
        }
    }

    fn eat_word(&mut self, word: &[u8]) -> Result<(), String> {
        for b in word {
            if self.peek() != Some(*b) {
                return Err("bad token".into());
            }
            self.i += 1;
        }
        Ok(())
    }

    fn object_fields(&mut self) -> Result<Vec<(String, Value)>, String> {
        self.expect(b'{')?;
        let mut fields = Vec::new();
        loop {
            self.skip_ws();
            if self.peek() == Some(b'}') {
                self.i += 1;
                return Ok(fields);
            }
            let key = self.string()?;
            self.skip_ws();
            self.expect(b':')?;
            fields.push((key, self.atom()?));
            self.skip_ws();
            if self.peek() == Some(b',') {
                self.i += 1;
            }
        }
    }

    fn calendar_array(&mut self) -> Result<Vec<Calendar>, String> {
        self.expect(b'[')?;
        let mut out = Vec::new();
        loop {
            self.skip_ws();
            if self.peek() == Some(b']') {
                self.i += 1;
                return Ok(out);
            }
            let fields = self.object_fields()?;
            let mut cal = Calendar {
                id: String::new(),
                name: String::new(),
                url: String::new(),
                color: LOCAL_COLOR.into(),
                enabled: true,
            };
            for (k, v) in fields {
                match (k.as_str(), v) {
                    ("id", Value::Str(s)) => cal.id = s,
                    ("name", Value::Str(s)) => cal.name = s,
                    ("url", Value::Str(s)) => cal.url = s,
                    ("color", Value::Str(s)) => cal.color = s,
                    ("enabled", Value::Bool(b)) => cal.enabled = b,
                    _ => {}
                }
            }
            if !cal.id.is_empty() {
                out.push(cal);
            }
            self.skip_ws();
            if self.peek() == Some(b',') {
                self.i += 1;
            }
        }
    }

    fn event_array(&mut self) -> Result<Vec<Event>, String> {
        self.expect(b'[')?;
        let mut out = Vec::new();
        loop {
            self.skip_ws();
            if self.peek() == Some(b']') {
                self.i += 1;
                return Ok(out);
            }
            let fields = self.object_fields()?;
            let mut event = Event {
                id: String::new(),
                calendar_id: LOCAL_ID.into(),
                date_key: String::new(),
                title: String::new(),
                start: String::new(),
                end: String::new(),
                color: String::new(),
                all_day: false,
                rev: String::new(),
                repeats: false,
            };
            for (k, v) in fields {
                match (k.as_str(), v) {
                    ("id", Value::Str(s)) => event.id = s,
                    ("calendarId", Value::Str(s)) => event.calendar_id = s,
                    ("dateKey", Value::Str(s)) => event.date_key = s,
                    ("title", Value::Str(s)) => event.title = s,
                    ("start", Value::Str(s)) => event.start = s,
                    ("end", Value::Str(s)) => event.end = s,
                    ("color", Value::Str(s)) => event.color = s,
                    ("allDay", Value::Bool(b)) => event.all_day = b,
                    ("rev", Value::Str(s)) => event.rev = s,
                    ("repeats", Value::Bool(b)) => event.repeats = b,
                    _ => {}
                }
            }
            if !event.id.is_empty() && !event.date_key.is_empty() {
                out.push(event);
            }
            self.skip_ws();
            if self.peek() == Some(b',') {
                self.i += 1;
            }
        }
    }

    fn skip_value(&mut self) -> Result<(), String> {
        self.skip_ws();
        match self.peek() {
            Some(b'"') => {
                let _ = self.string()?;
                Ok(())
            }
            Some(b'{') => self.skip_container(b'{', b'}'),
            Some(b'[') => self.skip_container(b'[', b']'),
            Some(b'0'..=b'9') => {
                let _ = self.number()?;
                Ok(())
            }
            Some(b't') | Some(b'f') | Some(b'n') => {
                while matches!(self.peek(), Some(b'a'..=b'z')) {
                    self.i += 1;
                }
                Ok(())
            }
            _ => Err("bad value".into()),
        }
    }

    fn skip_container(&mut self, open: u8, close: u8) -> Result<(), String> {
        self.expect(open)?;
        let mut depth = 1;
        while let Some(b) = self.peek() {
            self.i += 1;
            match b {
                b'"' => {
                    self.i -= 1;
                    let _ = self.string()?;
                }
                b if b == open => depth += 1,
                b if b == close => {
                    depth -= 1;
                    if depth == 0 {
                        return Ok(());
                    }
                }
                _ => {}
            }
        }
        Err("unterminated container".into())
    }
}

fn clip_title(s: &str) -> &str {
    if s.chars().count() <= 512 {
        s
    } else {
        let end = s.char_indices().map(|(i, _)| i).nth(512).unwrap_or(s.len());
        &s[..end]
    }
}

fn escape(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeats_survives_a_save() {
        let mut store = Store::default();
        for (uid, repeats) in [("standup", true), ("dentist", false)] {
            store.events.push(Event {
                id: format!("a:{uid}:2026-10-06"),
                calendar_id: "a".into(),
                date_key: "2026-10-06".into(),
                title: uid.into(),
                start: "09:00".into(),
                end: "09:15".into(),
                color: LOCAL_COLOR.into(),
                all_day: false,
                rev: "7".into(),
                repeats,
            });
        }
        let text = encode(&store);
        assert_eq!(text.matches("\"repeats\":true").count(), 1);
        let back = parse_store(&text).unwrap();
        let flags: Vec<bool> = back.events.iter().map(|e| e.repeats).collect();
        assert_eq!(flags, vec![true, false]);
    }
}
