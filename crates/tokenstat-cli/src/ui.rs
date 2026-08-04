//! Terminal rendering.
//!
//! Deliberately hand rolled rather than pulling a table crate. The output has a
//! specific shape (right-aligned magnitudes, inline bars, a heat grid) that a
//! generic table would fight, and it keeps the dependency surface small.
//!
//! Colour goes through `anstream`, which strips styling when the output is piped
//! or the terminal cannot handle it, so `tokenstat daily | less` stays readable.

use std::sync::OnceLock;

use anstyle::{Ansi256Color, AnsiColor, Color, RgbColor, Style};

pub const DIM: Style = Style::new().dimmed();
pub const BOLD: Style = Style::new().bold();

/// What this terminal can actually render.
///
/// The brand ramp is defined in 24-bit colour and the chrome is drawn with box
/// and block characters, neither of which is universal. Emitting a truecolor
/// escape to a terminal that only knows 256 colours does not degrade, it prints
/// garbage or picks an unrelated colour, and a UTF-8 glyph in a Latin-1 locale
/// prints as mojibake. So both are resolved once, up front, and everything
/// draws through the result.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Caps {
    /// 24-bit colour: RGB escapes are safe.
    pub truecolor: bool,
    /// The 256-colour palette: indexed escapes are safe.
    pub palette256: bool,
    /// Box drawing and block characters are safe.
    pub unicode: bool,
}

static CAPS: OnceLock<Caps> = OnceLock::new();

/// Terminal capabilities for this process, detected once.
pub fn caps() -> Caps {
    *CAPS.get_or_init(|| detect_caps(|name| std::env::var(name).ok()))
}

fn detect_caps(env: impl Fn(&str) -> Option<String>) -> Caps {
    let lower = |name: &str| env(name).map(|v| v.to_ascii_lowercase());
    let term = lower("TERM").unwrap_or_default();

    // `TOKENSTAT_ASCII=1` is the escape hatch for anyone whose terminal lies,
    // and for recording tools that render a fixed font.
    let forced_ascii = env("TOKENSTAT_ASCII").is_some_and(|v| v != "0");

    let colorterm = lower("COLORTERM").unwrap_or_default();
    let truecolor =
        colorterm.contains("truecolor") || colorterm.contains("24bit") || term.contains("direct");
    let palette256 = truecolor || term.contains("256color") || term.contains("kitty");

    // A locale that does not say UTF-8 is treated as not UTF-8. Windows is the
    // exception: it has no locale variables here and its modern console is
    // UTF-8 capable, so guessing ASCII there would punish the common case.
    let utf8_locale = ["LC_ALL", "LC_CTYPE", "LANG"]
        .iter()
        .filter_map(|name| lower(name))
        .any(|v| v.contains("utf-8") || v.contains("utf8"));
    let unicode = !forced_ascii && (utf8_locale || cfg!(windows));

    Caps {
        truecolor,
        palette256,
        unicode,
    }
}

/// A brand colour resolved to what this terminal can show.
pub fn rgb(r: u8, g: u8, b: u8) -> Color {
    let caps = caps();
    if caps.truecolor {
        Color::Rgb(RgbColor(r, g, b))
    } else if caps.palette256 {
        Color::Ansi256(Ansi256Color(to_xterm256(r, g, b)))
    } else {
        Color::Ansi(to_basic(r, g, b))
    }
}

fn style_rgb(r: u8, g: u8, b: u8) -> Style {
    Style::new().fg_color(Some(rgb(r, g, b)))
}

/// Nearest xterm-256 index: the 6×6×6 colour cube, or the greyscale ramp when
/// the colour is close to neutral (the cube's greys are coarse and banded).
pub fn to_xterm256(r: u8, g: u8, b: u8) -> u8 {
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    if max - min < 10 {
        // 24 grey steps from 8 to 238, then the two extremes.
        let level = i32::from(max);
        if level < 8 {
            return 16;
        }
        if level > 238 {
            return 231;
        }
        return 232 + ((level - 8) / 10) as u8;
    }
    let axis = |v: u8| -> u8 {
        // Cube levels are 0, 95, 135, 175, 215, 255. Below 48 the nearest is 0.
        match v {
            0..=47 => 0,
            48..=114 => 1,
            115..=154 => 2,
            155..=194 => 3,
            195..=234 => 4,
            _ => 5,
        }
    };
    16 + 36 * axis(r) + 6 * axis(g) + axis(b)
}

/// Nearest of the eight bright ANSI colours, for 16-colour terminals.
fn to_basic(r: u8, g: u8, b: u8) -> AnsiColor {
    const CANDIDATES: [(AnsiColor, (u8, u8, u8)); 8] = [
        (AnsiColor::BrightBlack, (0x55, 0x55, 0x55)),
        (AnsiColor::BrightRed, (0xFF, 0x55, 0x55)),
        (AnsiColor::BrightGreen, (0x55, 0xFF, 0x55)),
        (AnsiColor::BrightYellow, (0xFF, 0xFF, 0x55)),
        (AnsiColor::BrightBlue, (0x55, 0x55, 0xFF)),
        (AnsiColor::BrightMagenta, (0xFF, 0x55, 0xFF)),
        (AnsiColor::BrightCyan, (0x55, 0xFF, 0xFF)),
        (AnsiColor::White, (0xBB, 0xBB, 0xBB)),
    ];
    let mut best = (AnsiColor::White, u32::MAX);
    for (color, (cr, cg, cb)) in CANDIDATES {
        let d = |a: u8, b: u8| {
            let d = i32::from(a) - i32::from(b);
            (d * d) as u32
        };
        let distance = d(r, cr) + d(g, cg) + d(b, cb);
        if distance < best.1 {
            best = (color, distance);
        }
    }
    best.0
}

/// Electric accent for black terminals (`#B264EB`).
///
/// Sampled from the galaxy purple reference (mid `#9F68C7`), then pushed
/// brighter so chrome, bars, and the active tab read cleanly on black. The
/// website should use black/white surfaces with `#9F68C7` as the brand mid and
/// `#B264EB` where something needs to pop.
pub const ACCENT_RGB: (u8, u8, u8) = (0xB2, 0x64, 0xEB);

/// Secondary accent (`#67E8F9`). Cool cyan beside electric purple, the usual
/// nebula pairing on black. Used for the activity heat grid so it does not
/// fight the purple chrome with a leftover green.
pub const SECONDARY_RGB: (u8, u8, u8) = (0x67, 0xE8, 0xF9);

pub fn accent() -> Style {
    let (r, g, b) = ACCENT_RGB;
    style_rgb(r, g, b)
}

/// Secondary accent, for values that should read apart from the purple chrome.
pub fn secondary() -> Style {
    let (r, g, b) = SECONDARY_RGB;
    style_rgb(r, g, b)
}

/// Brand ramp from deep violet through electric purple to cyan.
///
/// `t` is 0..=1. Low values stay quiet on black, high values peak in cyan so
/// charts read as a fade that gets stronger rather than one flat purple.
pub fn intensity_rgb(t: f64) -> (u8, u8, u8) {
    const STOPS: [(f64, (u8, u8, u8)); 4] = [
        (0.0, (0x3D, 0x2A, 0x55)),
        (0.35, (0x9F, 0x68, 0xC7)),
        (0.70, (0xB2, 0x64, 0xEB)),
        (1.0, (0x67, 0xE8, 0xF9)),
    ];
    let t = t.clamp(0.0, 1.0);
    for w in STOPS.windows(2) {
        let (t0, c0) = w[0];
        let (t1, c1) = w[1];
        if t <= t1 {
            let u = if (t1 - t0).abs() < f64::EPSILON {
                0.0
            } else {
                (t - t0) / (t1 - t0)
            };
            return lerp_rgb(c0, c1, u);
        }
    }
    STOPS[STOPS.len() - 1].1
}

fn lerp_rgb(a: (u8, u8, u8), b: (u8, u8, u8), t: f64) -> (u8, u8, u8) {
    let t = t.clamp(0.0, 1.0);
    (
        (a.0 as f64 + (b.0 as f64 - a.0 as f64) * t).round() as u8,
        (a.1 as f64 + (b.1 as f64 - a.1 as f64) * t).round() as u8,
        (a.2 as f64 + (b.2 as f64 - a.2 as f64) * t).round() as u8,
    )
}

/// Heat-grid cell colors on the same ramp, spaced so levels read apart.
pub fn heat_rgb(level: u8) -> (u8, u8, u8) {
    match level {
        0 => (0x2A, 0x20, 0x38),
        1 => (0x5A, 0x3D, 0x82),
        2 => (0x9F, 0x68, 0xC7),
        3 => ACCENT_RGB,
        _ => SECONDARY_RGB,
    }
}

/// Style for one heat level, for the one-shot renderer.
pub fn heat_style(level: u8) -> Style {
    let (r, g, b) = heat_rgb(level);
    style_rgb(r, g, b)
}

pub fn good() -> Style {
    Style::new().fg_color(Some(Color::Ansi(AnsiColor::Green)))
}

pub fn warn() -> Style {
    Style::new().fg_color(Some(Color::Ansi(AnsiColor::Yellow)))
}

/// Format a dollar amount for tables. Sub-dollar values keep cents so a real
/// but tiny Gemini bill does not render as `$0`.
pub fn usd(dollars: f64) -> String {
    if dollars == 0.0 {
        "$0".into()
    } else if dollars.abs() < 1.0 {
        format!("${dollars:.2}")
    } else if dollars.abs() < 10.0 {
        format!("${dollars:.1}")
    } else {
        format!("${dollars:.0}")
    }
}

/// Format a token count compactly: `1.2M`, `93.0M`, `4.2k`.
///
/// Reports are scanned, not read, so a reader should get the magnitude at a
/// glance without counting digits.
pub fn tokens(n: u64) -> String {
    const K: f64 = 1_000.0;
    let f = n as f64;
    if f >= K * K * K {
        format!("{:.2}B", f / (K * K * K))
    } else if f >= K * K {
        format!("{:.1}M", f / (K * K))
    } else if f >= K {
        format!("{:.1}k", f / K)
    } else {
        n.to_string()
    }
}

/// Thousands-separated integer, for places where the exact value matters.
pub fn exact(n: u64) -> String {
    let s = n.to_string();
    let mut out = String::with_capacity(s.len() + s.len() / 3);
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (s.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// A proportional bar drawn with eighth-block characters, so a value smaller
/// than one cell still renders visibly instead of vanishing.
///
/// Falls back to `#` with a trailing `-` for the partial cell where block
/// characters are not available. The sub-cell rounding matters either way: a
/// row that used a thousandth of the busiest day should not draw as empty.
pub fn bar(fraction: f64, width: usize) -> String {
    const EIGHTHS: [char; 8] = ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'];
    let f = fraction.clamp(0.0, 1.0);
    let total_eighths = (f * width as f64 * 8.0).round() as usize;
    let full = total_eighths / 8;
    let rem = total_eighths % 8;
    if !caps().unicode {
        let mut s = "#".repeat(full.min(width));
        if full < width && rem > 0 {
            s.push('-');
        }
        return s;
    }
    let mut s = "█".repeat(full.min(width));
    if full < width && rem > 0 {
        s.push(EIGHTHS[rem - 1]);
    }
    s
}

/// A one-line sparkline over `values`, scaled to the largest of them.
///
/// Trend tables print a magnitude per row but nothing about the shape of the
/// series, which is the thing a reader is usually after. One line of eighth
/// blocks above the table answers it without spending vertical space.
pub fn sparkline(values: &[u64]) -> String {
    const LEVELS: [char; 8] = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
    const ASCII: [char; 4] = ['.', ':', '|', '#'];
    let max = values.iter().copied().max().unwrap_or(0);
    if max == 0 {
        return String::new();
    }
    let unicode = caps().unicode;
    values
        .iter()
        .map(|v| {
            if *v == 0 {
                return ' ';
            }
            let f = *v as f64 / max as f64;
            // A non-zero value always gets at least the lowest visible step, so
            // a quiet day reads as quiet rather than as missing.
            if unicode {
                LEVELS[((f * LEVELS.len() as f64).ceil() as usize).clamp(1, LEVELS.len()) - 1]
            } else {
                ASCII[((f * ASCII.len() as f64).ceil() as usize).clamp(1, ASCII.len()) - 1]
            }
        })
        .collect()
}

/// Pad to `w` display columns, accounting for wide characters.
pub fn pad_right(s: &str, w: usize) -> String {
    let len = width(s);
    if len > w {
        truncate(s, w)
    } else {
        format!("{s}{}", " ".repeat(w - len))
    }
}

pub fn pad_left(s: &str, w: usize) -> String {
    let len = width(s);
    if len > w {
        truncate(s, w)
    } else {
        format!("{}{s}", " ".repeat(w - len))
    }
}

/// Approximate display width. Full width CJK and emoji count as two columns.
fn width(s: &str) -> usize {
    s.chars().map(char_width).sum()
}

fn char_width(c: char) -> usize {
    let cp = c as u32;
    // Ranges that render double width in a terminal. Not exhaustive, but it
    // covers what actually shows up in project and model names.
    if (0x1100..=0x115F).contains(&cp)
        || (0x2E80..=0xA4CF).contains(&cp)
        || (0xAC00..=0xD7A3).contains(&cp)
        || (0xF900..=0xFAFF).contains(&cp)
        || (0xFF00..=0xFF60).contains(&cp)
        || (0xFFE0..=0xFFE6).contains(&cp)
        || (0x1F300..=0x1FAFF).contains(&cp)
    {
        2
    } else {
        1
    }
}

fn truncate(s: &str, w: usize) -> String {
    if w == 0 {
        return String::new();
    }
    // The marker is one column as `…` and two as `..`, so the budget has to be
    // measured rather than assumed. Getting this wrong shifts every column to
    // the right of a truncated cell.
    let marker = ellipsis();
    let marker_w = width(marker);
    if w <= marker_w {
        return marker.chars().take(w).collect();
    }
    let mut out = String::new();
    let mut used = 0;
    for c in s.chars() {
        let cw = char_width(c);
        if used + cw > w - marker_w {
            out.push_str(marker);
            return out;
        }
        out.push(c);
        used += cw;
    }
    out
}

/// Glyph for one calendar cell. A filled square reads as a calendar rather
/// than as a texture, which the old shaded blocks did not.
pub fn heat_cell() -> &'static str {
    if caps().unicode { "■" } else { "#" }
}

/// Ellipsis used when a cell is truncated.
pub fn ellipsis() -> &'static str {
    if caps().unicode { "…" } else { ".." }
}

/// Separator between inline facts on one line.
pub fn separator() -> &'static str {
    if caps().unicode { "·" } else { "|" }
}

/// Columns reserved for the weekday labels down the left edge.
pub const HEAT_GUTTER: usize = 4;

/// Terminal columns one week occupies: the cell plus its gap.
pub const HEAT_COL: usize = 2;

// The calendar itself lives in `tokenstat_core::activity`, because the desktop
// app draws the same grid and a second implementation would be a second answer
// to "how long is my streak". What stayed here is the part that is genuinely
// about a terminal: the column arithmetic and the two label strings.
pub use tokenstat_core::activity::{HeatCalendar, calendar as heat_calendar};

/// Drawing a calendar into a fixed-width grid.
///
/// A trait rather than methods on the type, because the type is in another
/// crate now and these are of no use to anything that is not a terminal.
pub trait HeatRender {
    /// Width of the rendered block in terminal columns.
    fn width(&self) -> usize;
    /// The month header strip, already padded to line up with the columns.
    fn header(&self) -> String;
}

impl HeatRender for HeatCalendar {
    fn width(&self) -> usize {
        HEAT_GUTTER + self.weeks * HEAT_COL
    }

    fn header(&self) -> String {
        let mut s = " ".repeat(HEAT_GUTTER);
        for (col, name) in &self.months {
            let want = HEAT_GUTTER + col * HEAT_COL;
            let have = s.chars().count();
            if have > want {
                continue;
            }
            s.push_str(&" ".repeat(want - have));
            s.push_str(name);
        }
        s
    }
}

/// Label for a grid row. Only alternate days are labelled so the gutter stays
/// quiet.
pub fn heat_row_label(row: usize) -> &'static str {
    match row {
        0 => "Mon",
        2 => "Wed",
        4 => "Fri",
        _ => "",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Detection against a fixed environment, so tests do not depend on the
    /// terminal that happens to be running them.
    fn caps_for(vars: &[(&str, &str)]) -> Caps {
        detect_caps(|name| {
            vars.iter()
                .find(|(k, _)| *k == name)
                .map(|(_, v)| (*v).to_string())
        })
    }

    #[test]
    fn truecolor_is_believed_only_when_the_terminal_claims_it() {
        assert!(caps_for(&[("COLORTERM", "truecolor")]).truecolor);
        assert!(caps_for(&[("COLORTERM", "24bit")]).truecolor);
        assert!(!caps_for(&[("TERM", "xterm-256color")]).truecolor);
        // Apple Terminal reports 256 colours and no COLORTERM. Sending it RGB
        // would pick unrelated colours rather than degrade.
        assert!(caps_for(&[("TERM", "xterm-256color")]).palette256);
        assert!(!caps_for(&[("TERM", "vt100")]).palette256);
    }

    #[test]
    fn a_non_utf8_locale_turns_off_box_drawing() {
        assert!(caps_for(&[("LANG", "en_US.UTF-8")]).unicode);
        assert!(caps_for(&[("LC_ALL", "C.utf8")]).unicode);
        assert_eq!(
            caps_for(&[("LANG", "en_US.ISO-8859-1")]).unicode,
            cfg!(windows)
        );
        // The override wins over a UTF-8 locale, for terminals that lie.
        assert!(!caps_for(&[("LANG", "en_US.UTF-8"), ("TOKENSTAT_ASCII", "1")]).unicode);
        assert!(caps_for(&[("LANG", "en_US.UTF-8"), ("TOKENSTAT_ASCII", "0")]).unicode);
    }

    #[test]
    fn brand_colors_map_onto_the_256_palette() {
        let (r, g, b) = ACCENT_RGB;
        let index = to_xterm256(r, g, b);
        // Inside the 6x6x6 cube, not the greyscale ramp, and not a system color.
        assert!((16..232).contains(&index), "accent mapped to {index}");
        // A near-neutral colour uses the greyscale ramp, which has finer steps
        // than the cube's washed-out greys.
        assert!(to_xterm256(0x40, 0x42, 0x41) >= 232);
        assert_eq!(to_xterm256(0, 0, 0), 16);
    }

    #[test]
    fn a_sparkline_scales_to_its_own_maximum() {
        let line = sparkline(&[1, 50, 100]);
        assert_eq!(line.chars().count(), 3);
        // The largest value tops out, the smallest still draws.
        let chars: Vec<char> = line.chars().collect();
        assert!(chars[0] != ' ');
        assert!(chars[2] == '█' || chars[2] == '#');
        // A zero leaves a gap rather than a floor value, so an idle day reads
        // as idle instead of as a small amount of usage.
        assert_eq!(sparkline(&[0, 10]).chars().next(), Some(' '));
        assert_eq!(sparkline(&[0, 0]), "");
        assert_eq!(sparkline(&[]), "");
    }

    #[test]
    fn token_magnitudes_read_at_a_glance() {
        assert_eq!(tokens(999), "999");
        assert_eq!(tokens(4_200), "4.2k");
        assert_eq!(tokens(93_000_000), "93.0M");
        assert_eq!(tokens(2_500_000_000), "2.50B");
    }

    #[test]
    fn exact_inserts_thousands_separators() {
        assert_eq!(exact(0), "0");
        assert_eq!(exact(999), "999");
        assert_eq!(exact(1_000), "1,000");
        assert_eq!(exact(161_861), "161,861");
    }

    #[test]
    fn bar_is_visible_for_tiny_but_nonzero_values() {
        assert_eq!(bar(0.0, 10), "");
        assert!(!bar(0.01, 10).is_empty());
        assert_eq!(bar(1.0, 10).chars().count(), 10);
        // Never exceeds the requested width.
        assert!(bar(2.0, 5).chars().count() <= 5);
    }

    #[test]
    fn padding_accounts_for_wide_characters() {
        assert_eq!(pad_right("ab", 4), "ab  ");
        assert_eq!(pad_left("ab", 4), "  ab");
        // A CJK character occupies two columns, so only one fits plus padding.
        assert_eq!(width(&pad_right("日本", 6)), 6);
    }

    #[test]
    fn truncation_marks_elision() {
        // The marker differs by terminal, but the column count must not: a
        // truncated cell that is one column short shifts the whole table.
        assert!(pad_right("averylongprojectname", 8).ends_with(ellipsis()));
        assert_eq!(width(&pad_right("averylongprojectname", 8)), 8);
        assert_eq!(width(&pad_right("averylongprojectname", 3)), 3);
        assert_eq!(width(&pad_right("averylongprojectname", 1)), 1);
        // Exact fit must not elide. YYYY-MM-DD is ten columns.
        assert_eq!(pad_right("2026-07-29", 10), "2026-07-29");
        assert_eq!(pad_left("2026-07-29", 10), "2026-07-29");
    }

    #[test]
    fn intensity_ramps_from_violet_to_cyan() {
        assert_eq!(intensity_rgb(0.0), (0x3D, 0x2A, 0x55));
        assert_eq!(intensity_rgb(1.0), SECONDARY_RGB);
        let mid = intensity_rgb(0.5);
        // Mid should sit between brand purple and electric, not at either end.
        assert_ne!(mid, intensity_rgb(0.0));
        assert_ne!(mid, intensity_rgb(1.0));
    }

    /// Wednesday 2026-07-29, the anchor most of these cases hang off.
    fn anchor() -> jiff::civil::Date {
        jiff::civil::date(2026, 7, 29)
    }

    #[test]
    fn calendar_has_seven_rows_and_whole_weeks() {
        let days: Vec<_> = (1..=28)
            .map(|d| (format!("2026-07-{d:02}"), d as u64 * 100))
            .collect();
        let cal = heat_calendar(&days, 5, anchor()).expect("calendar");
        assert_eq!(cal.rows.len(), 7);
        assert_eq!(cal.weeks, 5);
        assert!(cal.rows.iter().all(|r| r.len() == cal.weeks));
    }

    #[test]
    fn calendar_puts_each_day_in_its_real_weekday_row() {
        let days = vec![("2026-07-29".to_string(), 10)];
        let cal = heat_calendar(&days, 4, anchor()).expect("calendar");
        // 2026-07-29 is a Wednesday: row 2, Monday first.
        let found = cal.rows[2]
            .iter()
            .flatten()
            .find(|c| c.value == 10)
            .expect("cell");
        assert_eq!(found.date.to_string(), "2026-07-29");
    }

    #[test]
    fn calendar_holds_the_window_open_when_the_archive_is_young() {
        // A week-old archive still renders a full rolling year of idle cells,
        // rather than collapsing to the days that happen to have data.
        let days = vec![("2026-07-27".to_string(), 5)];
        let cal = heat_calendar(&days, 53, anchor()).expect("calendar");
        assert_eq!(cal.weeks, 53);
        assert_eq!(cal.active_days, 1);
        // A year back from the anchor week: starts in the previous August.
        assert_eq!(cal.first.to_string(), "2025-07-28");
        assert_eq!(cal.months.first().map(|m| m.1), Some("Jul"));
    }

    #[test]
    fn calendar_leaves_days_after_the_anchor_blank() {
        // The rest of this week has not happened. Blank, not idle.
        let days = vec![("2026-07-29".to_string(), 5)];
        let cal = heat_calendar(&days, 2, anchor()).expect("calendar");
        let last_col = cal.weeks - 1;
        assert!(cal.rows[2][last_col].is_some(), "Wednesday is the anchor");
        assert!(cal.rows[3][last_col].is_none(), "Thursday is the future");
        assert!(cal.rows[6][last_col].is_none(), "Sunday is the future");
    }

    #[test]
    fn calendar_fills_gaps_between_active_days() {
        // The archive stores only active days. The grid must still show the
        // idle days between them, or every later column drifts.
        let days = vec![("2026-07-06".to_string(), 5), ("2026-07-10".to_string(), 7)];
        let cal = heat_calendar(&days, 4, jiff::civil::date(2026, 7, 12)).expect("calendar");
        assert_eq!(cal.active_days, 2);
        assert_eq!(cal.total, 12);
        assert_eq!(cal.busiest.map(|b| b.value), Some(7));
        // Mon and Fri active, Tue to Thu idle: no run longer than one day.
        assert_eq!(cal.streak_best, 1);
    }

    #[test]
    fn calendar_counts_the_trailing_streak() {
        let days: Vec<_> = (20..=24)
            .map(|d| (format!("2026-07-{d:02}"), 100u64))
            .collect();
        let cal = heat_calendar(&days, 4, jiff::civil::date(2026, 7, 24)).expect("calendar");
        assert_eq!(cal.streak_current, 5);
        assert_eq!(cal.streak_best, 5);
    }

    #[test]
    fn a_quiet_anchor_day_does_not_break_the_streak() {
        // Worked through yesterday, nothing logged yet today. The day is not
        // over, so the streak stands.
        let days: Vec<_> = (26..=28)
            .map(|d| (format!("2026-07-{d:02}"), 100u64))
            .collect();
        let cal = heat_calendar(&days, 4, anchor()).expect("calendar");
        assert_eq!(cal.streak_current, 3);
        // Two idle days before the anchor do break it.
        let cal = heat_calendar(&days, 4, jiff::civil::date(2026, 7, 30)).expect("calendar");
        assert_eq!(cal.streak_current, 0);
    }

    #[test]
    fn calendar_header_lines_months_up_with_columns() {
        let days: Vec<_> = (0..60)
            .map(|i| {
                let d = jiff::civil::date(2026, 6, 1)
                    .checked_add(jiff::Span::new().days(i))
                    .expect("date");
                (d.to_string(), 100u64)
            })
            .collect();
        let cal = heat_calendar(&days, 20, anchor()).expect("calendar");
        let header = cal.header();
        assert!(header.contains("Jun"));
        assert!(header.contains("Jul"));
        for (col, name) in &cal.months {
            let at = HEAT_GUTTER + col * HEAT_COL;
            assert!(header[at..].starts_with(name), "{name} misplaced: {header}");
        }
    }

    #[test]
    fn calendar_handles_empty_input() {
        assert!(heat_calendar(&[], 5, anchor()).is_none());
    }
}
