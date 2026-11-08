use crate::store::Event;

#[derive(Clone)]
struct RawEvent {
    uid: String,
    title: String,
    start: Civil,
    end: Option<Civil>,
    all_day: bool,
    start_hm: String,
    end_hm: String,
    rrule: Option<RRule>,
    /// A moved date of a series (RECURRENCE-ID): no RRULE of its own.
    moved: bool,
    exdates: Vec<i32>,
    seal: String,
    rev: String,
}

#[derive(Clone, Copy)]
struct Civil {
    y: i32,
    m: u8,
    d: u8,
}

#[derive(Clone)]
struct RRule {
    freq: Freq,
    interval: i32,
    count: Option<i32>,
    until: Option<i32>,
    byday: Vec<ByDay>,
    bymonth: Vec<u8>,
}

#[derive(Clone, Copy)]
struct ByDay {
    nth: i32,
    weekday: i32,
}

#[derive(Clone, Copy, PartialEq)]
enum Freq {
    Daily,
    Weekly,
    Monthly,
    Yearly,
}

pub fn events_from_ics(
    ics: &str,
    calendar_id: &str,
    color: &str,
    window_start: i32,
    window_end: i32,
) -> Vec<Event> {
    let mut out = Vec::new();
    for raw in parse_vevents(ics) {
        if !raw.seal.is_empty() {
            continue;
        }
        for (ord, civil) in expand(&raw, window_start, window_end) {
            if raw.exdates.contains(&ord) {
                continue;
            }
            out.push(Event {
                id: format!("{}:{}:{}", calendar_id, raw.uid, ymd(civil)),
                calendar_id: calendar_id.into(),
                date_key: ymd(civil),
                title: raw.title.clone(),
                start: if raw.all_day {
                    String::new()
                } else {
                    raw.start_hm.clone()
                },
                end: if raw.all_day {
                    String::new()
                } else {
                    raw.end_hm.clone()
                },
                color: color.into(),
                all_day: raw.all_day,
                rev: raw.rev.clone(),
                repeats: raw.rrule.is_some() || raw.moved,
            });
        }
    }
    out
}

fn parse_vevents(ics: &str) -> Vec<RawEvent> {
    let lines = unfold(ics);
    let mut events = Vec::new();
    let mut cur: Option<RawEvent> = None;
    for line in lines {
        let upper = line.to_ascii_uppercase();
        if upper == "BEGIN:VEVENT" {
            cur = Some(RawEvent {
                uid: String::new(),
                title: "Untitled".into(),
                start: Civil { y: 1970, m: 1, d: 1 },
                end: None,
                all_day: false,
                start_hm: String::new(),
                end_hm: String::new(),
                rrule: None,
                moved: false,
                exdates: Vec::new(),
                seal: String::new(),
                rev: String::new(),
            });
            continue;
        }
        if upper == "END:VEVENT" {
            if let Some(event) = cur.take() {
                if event.uid.is_empty() {
                    continue;
                }
                events.push(event);
            }
            continue;
        }
        let Some(event) = cur.as_mut() else { continue };
        let (name, params, value) = split_prop(&line);
        match name.as_str() {
            "UID" => event.uid = value,
            "X-ALMANAC-SEAL" => event.seal = value,
            // X-ALMANAC-REV: what scripts before the Agent Cloud rename wrote.
            "X-CLOUD-REV" | "X-ALMANAC-REV" => event.rev = value,
            "SUMMARY" => event.title = unescape_ics(&value),
            "STATUS" if value.eq_ignore_ascii_case("CANCELLED") => event.uid.clear(),
            "DTSTART" => apply_dt(event, &params, &value, true),
            "DTEND" => apply_dt(event, &params, &value, false),
            "RRULE" => event.rrule = parse_rrule(&value),
            "RECURRENCE-ID" => event.moved = true,
            "EXDATE" => {
                for part in value.split(',') {
                    if let Some(c) = parse_ics_date(part.trim()) {
                        event.exdates.push(ordinal(c));
                    }
                }
            }
            _ => {}
        }
    }
    events
}

fn apply_dt(event: &mut RawEvent, params: &str, value: &str, start: bool) {
    let all_day = params.to_ascii_uppercase().contains("VALUE=DATE") || value.len() == 8;
    if let Some(civil) = parse_ics_date(value) {
        let hm = parse_ics_time(value);
        if start {
            event.start = civil;
            event.all_day = all_day;
            event.start_hm = hm;
        } else {
            event.end = Some(civil);
            event.end_hm = hm;
        }
    }
}

fn parse_ics_date(value: &str) -> Option<Civil> {
    let digits: String = value.chars().filter(|c| c.is_ascii_digit()).take(8).collect();
    if digits.len() < 8 {
        return None;
    }
    let y = digits[0..4].parse().ok()?;
    let m = digits[4..6].parse().ok()?;
    let d = digits[6..8].parse().ok()?;
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    Some(Civil { y, m, d })
}

fn parse_ics_time(value: &str) -> String {
    let digits: String = value.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.len() >= 12 {
        format!("{}:{}", &digits[8..10], &digits[10..12])
    } else {
        String::new()
    }
}

fn parse_rrule(value: &str) -> Option<RRule> {
    let mut freq = None;
    let mut interval = 1;
    let mut count = None;
    let mut until = None;
    let mut byday = Vec::new();
    let mut bymonth = Vec::new();
    for part in value.split(';') {
        let Some((k, v)) = part.split_once('=') else {
            continue;
        };
        match k.to_ascii_uppercase().as_str() {
            "FREQ" => {
                freq = match v.to_ascii_uppercase().as_str() {
                    "DAILY" => Some(Freq::Daily),
                    "WEEKLY" => Some(Freq::Weekly),
                    "MONTHLY" => Some(Freq::Monthly),
                    "YEARLY" => Some(Freq::Yearly),
                    _ => None,
                }
            }
            "INTERVAL" => interval = v.parse().unwrap_or(1),
            "COUNT" => count = v.parse().ok(),
            "UNTIL" => until = parse_ics_date(v).map(ordinal),
            "BYDAY" => {
                for day in v.split(',') {
                    if let Some(n) = parse_byday(day) {
                        byday.push(n);
                    }
                }
            }
            "BYMONTH" => {
                for month in v.split(',') {
                    if let Ok(n) = month.trim().parse::<u8>() {
                        if (1..=12).contains(&n) {
                            bymonth.push(n);
                        }
                    }
                }
            }
            _ => {}
        }
    }
    Some(RRule {
        freq: freq?,
        interval: interval.max(1),
        count,
        until,
        byday,
        bymonth,
    })
}

fn parse_byday(token: &str) -> Option<ByDay> {
    let t = token.trim().to_ascii_uppercase();
    if t.len() < 2 {
        return None;
    }
    let day = &t[t.len() - 2..];
    let weekday = match day {
        "SU" => 0,
        "MO" => 1,
        "TU" => 2,
        "WE" => 3,
        "TH" => 4,
        "FR" => 5,
        "SA" => 6,
        _ => return None,
    };
    let prefix = &t[..t.len() - 2];
    let nth = if prefix.is_empty() {
        0
    } else {
        prefix.parse().ok()?
    };
    Some(ByDay { nth, weekday })
}

fn expand(raw: &RawEvent, window_start: i32, window_end: i32) -> Vec<(i32, Civil)> {
    let start_ord = ordinal(raw.start);
    let Some(rrule) = &raw.rrule else {
        if start_ord >= window_start && start_ord <= window_end {
            return vec![(start_ord, raw.start)];
        }
        return Vec::new();
    };
    if rrule.freq == Freq::Yearly {
        return expand_yearly(raw, rrule, window_start, window_end);
    }
    let mut out = Vec::new();
    let mut cursor = raw.start;
    let mut seen = 0;
    let hard_until = rrule.until.unwrap_or(window_end);
    for _ in 0..4000 {
        let ord = ordinal(cursor);
        if ord > window_end || ord > hard_until {
            break;
        }
        if rrule.count.is_some_and(|c| seen >= c) {
            break;
        }
        let weekday_ok = rrule.byday.is_empty()
            || rrule.byday.iter().any(|d| d.weekday == weekday(cursor));
        if ord >= window_start && ord >= start_ord && weekday_ok {
            out.push((ord, cursor));
            seen += 1;
        } else if ord >= start_ord && weekday_ok {
            seen += 1;
        }
        cursor = match rrule.freq {
            Freq::Daily => add_days(cursor, rrule.interval),
            Freq::Weekly => {
                if rrule.byday.is_empty() {
                    add_days(cursor, 7 * rrule.interval)
                } else {
                    next_byday(cursor, &rrule.byday, rrule.interval)
                }
            }
            Freq::Monthly => add_months(cursor, rrule.interval),
            Freq::Yearly => add_years(cursor, rrule.interval),
        };
    }
    out
}

fn expand_yearly(
    raw: &RawEvent,
    rrule: &RRule,
    window_start: i32,
    window_end: i32,
) -> Vec<(i32, Civil)> {
    let start_ord = ordinal(raw.start);
    let hard_until = rrule.until.unwrap_or(window_end);
    let months = if rrule.bymonth.is_empty() {
        vec![raw.start.m]
    } else {
        rrule.bymonth.clone()
    };
    let start_year = raw.start.y;
    let end_civil = from_ordinal(window_end.min(hard_until));
    let mut out = Vec::new();
    let mut seen = 0;
    for y in start_year..=end_civil.y {
        if (y - start_year) % rrule.interval != 0 {
            continue;
        }
        let mut year_hits = Vec::new();
        if rrule.byday.is_empty() {
            for m in &months {
                let d = raw.start.d.min(days_in_month(y, *m));
                year_hits.push(Civil { y, m: *m, d });
            }
        } else {
            for m in &months {
                for day in &rrule.byday {
                    if day.nth == 0 {
                        let mut d = 1u8;
                        let dim = days_in_month(y, *m);
                        while d <= dim {
                            let c = Civil { y, m: *m, d };
                            if weekday(c) == day.weekday {
                                year_hits.push(c);
                            }
                            d += 1;
                        }
                    } else if let Some(c) = nth_weekday(y, *m, day.nth, day.weekday) {
                        year_hits.push(c);
                    }
                }
            }
        }
        year_hits.sort_by_key(|c| ordinal(*c));
        year_hits.dedup_by_key(|c| ordinal(*c));
        for civil in year_hits {
            let ord = ordinal(civil);
            if ord < start_ord {
                continue;
            }
            if rrule.count.is_some_and(|c| seen >= c) {
                return out;
            }
            seen += 1;
            if ord >= window_start && ord <= window_end && ord <= hard_until {
                out.push((ord, civil));
            }
        }
    }
    out
}

fn nth_weekday(y: i32, m: u8, nth: i32, wd: i32) -> Option<Civil> {
    if nth > 0 {
        let first = Civil { y, m, d: 1 };
        let delta = (wd - weekday(first) + 7) % 7;
        let d = 1 + delta + (nth - 1) * 7;
        if d > days_in_month(y, m) as i32 {
            return None;
        }
        Some(Civil { y, m, d: d as u8 })
    } else if nth < 0 {
        let last_d = days_in_month(y, m);
        let last = Civil { y, m, d: last_d };
        let delta = (weekday(last) - wd + 7) % 7;
        let d = last_d as i32 - delta + (nth + 1) * 7;
        if d < 1 {
            return None;
        }
        Some(Civil { y, m, d: d as u8 })
    } else {
        None
    }
}

fn next_byday(from: Civil, days: &[ByDay], interval: i32) -> Civil {
    let mut cur = add_days(from, 1);
    for _ in 0..21 {
        if days.iter().any(|d| d.weekday == weekday(cur)) {
            return cur;
        }
        cur = add_days(cur, 1);
    }
    add_days(from, 7 * interval)
}

fn unfold(ics: &str) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    for raw in ics.replace("\r\n", "\n").split('\n') {
        if raw.starts_with(' ') || raw.starts_with('\t') {
            if let Some(last) = lines.last_mut() {
                last.push_str(raw.trim_start());
                continue;
            }
        }
        if !raw.is_empty() {
            lines.push(raw.to_string());
        }
    }
    lines
}

fn split_prop(line: &str) -> (String, String, String) {
    let (head, value) = match line.split_once(':') {
        Some(pair) => pair,
        None => return (String::new(), String::new(), String::new()),
    };
    let (name, params) = match head.split_once(';') {
        Some((n, p)) => (n, p),
        None => (head, ""),
    };
    (name.to_ascii_uppercase(), params.to_string(), value.to_string())
}

fn unescape_ics(s: &str) -> String {
    s.replace("\\n", "\n")
        .replace("\\N", "\n")
        .replace("\\,", ",")
        .replace("\\;", ";")
        .replace("\\\\", "\\")
}

fn ymd(c: Civil) -> String {
    format!("{:04}-{:02}-{:02}", c.y, c.m, c.d)
}

fn days_in_month(y: i32, m: u8) -> u8 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap(y) => 29,
        2 => 28,
        _ => 30,
    }
}

fn is_leap(y: i32) -> bool {
    y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
}

fn ordinal(c: Civil) -> i32 {
    let mut n = 0;
    for y in 1970..c.y {
        n += if is_leap(y) { 366 } else { 365 };
    }
    for m in 1..c.m {
        n += days_in_month(c.y, m) as i32;
    }
    n + c.d as i32 - 1
}

fn from_ordinal(mut n: i32) -> Civil {
    let mut y = 1970;
    loop {
        let days = if is_leap(y) { 366 } else { 365 };
        if n < days {
            break;
        }
        n -= days;
        y += 1;
    }
    let mut m = 1u8;
    loop {
        let dim = days_in_month(y, m) as i32;
        if n < dim {
            return Civil {
                y,
                m,
                d: (n + 1) as u8,
            };
        }
        n -= dim;
        m += 1;
    }
}

fn add_days(c: Civil, days: i32) -> Civil {
    from_ordinal(ordinal(c) + days)
}

fn add_months(c: Civil, months: i32) -> Civil {
    let ym = c.y * 12 + (c.m as i32 - 1) + months;
    let y = ym.div_euclid(12);
    let m = (ym.rem_euclid(12) + 1) as u8;
    let d = c.d.min(days_in_month(y, m));
    Civil { y, m, d }
}

fn add_years(c: Civil, years: i32) -> Civil {
    let y = c.y + years;
    let d = c.d.min(days_in_month(y, c.m));
    Civil { y, m: c.m, d }
}

fn weekday(c: Civil) -> i32 {
    // 1970-01-01 was Thursday = 4
    (4 + ordinal(c)).rem_euclid(7)
}

pub fn today_ordinal() -> i32 {
    // Local civil date via /bin/date so we stay crate-free and timezone-honest.
    if let Ok(out) = std::process::Command::new("date")
        .args(["+%Y-%m-%d"])
        .output()
    {
        if out.status.success() {
            if let Ok(text) = String::from_utf8(out.stdout) {
                let t = text.trim();
                if t.len() == 10 {
                    if let (Ok(y), Ok(m), Ok(d)) = (
                        t[0..4].parse::<i32>(),
                        t[5..7].parse::<u8>(),
                        t[8..10].parse::<u8>(),
                    ) {
                        return ordinal(Civil { y, m, d });
                    }
                }
            }
        }
    }
    0
}

pub fn window() -> (i32, i32) {
    let today = today_ordinal();
    (today - 40, today + 200)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labor_day_2026() {
        let ics = "BEGIN:VEVENT\n\
UID:labor\n\
DTSTART;VALUE=DATE:20250901\n\
RRULE:FREQ=YEARLY;BYMONTH=9;BYDAY=1MO\n\
SUMMARY:Labor Day\n\
END:VEVENT\n";
        let start = ordinal(Civil {
            y: 2026,
            m: 8,
            d: 1,
        });
        let end = ordinal(Civil {
            y: 2026,
            m: 10,
            d: 1,
        });
        let events = events_from_ics(ics, "us", "#5b9fd4", start, end);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].date_key, "2026-09-07");
        assert_eq!(events[0].title, "Labor Day");
        assert!(events[0].all_day);
    }

    #[test]
    fn new_years_fixed() {
        let ics = "BEGIN:VEVENT\n\
UID:ny\n\
DTSTART;VALUE=DATE:20260101\n\
RRULE:FREQ=YEARLY\n\
SUMMARY:New Year's Day\n\
END:VEVENT\n";
        let start = ordinal(Civil {
            y: 2026,
            m: 1,
            d: 1,
        });
        let end = ordinal(Civil {
            y: 2026,
            m: 1,
            d: 2,
        });
        let events = events_from_ics(ics, "us", "#5b9fd4", start, end);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].date_key, "2026-01-01");
        assert!(events[0].repeats);
    }

    #[test]
    fn series_dates_and_moved_dates_repeat_others_do_not() {
        let ics = "BEGIN:VEVENT\n\
UID:standup\n\
DTSTART:20261006T090000\n\
RRULE:FREQ=WEEKLY\n\
EXDATE;VALUE=DATE:20261013,20261020\n\
SUMMARY:Standup\n\
END:VEVENT\n\
BEGIN:VEVENT\n\
UID:standup\n\
RECURRENCE-ID;VALUE=DATE:20261020\n\
DTSTART:20261021T100000\n\
SUMMARY:Standup\n\
END:VEVENT\n\
BEGIN:VEVENT\n\
UID:dentist\n\
DTSTART:20261008T090000\n\
SUMMARY:Dentist\n\
END:VEVENT\n";
        let start = ordinal(Civil { y: 2026, m: 10, d: 1 });
        let end = ordinal(Civil { y: 2026, m: 10, d: 31 });
        let events = events_from_ics(ics, "a", "#5b9fd4", start, end);
        let keys = |uid: &str| -> Vec<(String, bool)> {
            events
                .iter()
                .filter(|e| e.id.contains(&format!(":{uid}:")))
                .map(|e| (e.date_key.clone(), e.repeats))
                .collect()
        };
        assert_eq!(
            keys("standup"),
            vec![
                ("2026-10-06".to_string(), true),
                ("2026-10-27".to_string(), true),
                ("2026-10-21".to_string(), true),
            ]
        );
        assert_eq!(keys("dentist"), vec![("2026-10-08".to_string(), false)]);
    }
}
