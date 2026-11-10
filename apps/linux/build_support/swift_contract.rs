// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Extract the supported desktop design declarations without maintaining a copy.
//! Unsupported Swift expressions fail the build instead of guessing a value.

use std::path::Path;

pub const SOURCE_FILES: &[&str] = &[
    "Design/Theme.swift",
    "Design/AppFonts.swift",
    "App/ShellChrome.swift",
    "App/Route.swift",
    "App/DesktopWorkbenchState.swift",
    "App/RootView.swift",
    "Design/ActionIcon.swift",
    "App/TokenstatApp.swift",
    "Features/Workspaces/Chat/ChatTranscriptFold.swift",
    "Features/Account/ChatDetailSettings.swift",
    "Features/Home/HeatmapView.swift",
];

type Result<T> = std::result::Result<T, String>;

fn font_metrics(path: &Path) -> Result<[f64; 3]> {
    let data = std::fs::read(path).map_err(|e| e.to_string())?;
    let read16 = |bytes: &[u8], offset: usize| -> Result<u16> {
        let bytes: [u8; 2] = bytes
            .get(offset..offset + 2)
            .ok_or("truncated font word")?
            .try_into()
            .map_err(|_| "invalid font word")?;
        Ok(u16::from_be_bytes(bytes))
    };
    let read32 = |offset: usize| -> Result<u32> {
        let bytes: [u8; 4] = data
            .get(offset..offset + 4)
            .ok_or("truncated font offset")?
            .try_into()
            .map_err(|_| "invalid font offset")?;
        Ok(u32::from_be_bytes(bytes))
    };
    let table = |tag: &[u8]| -> Result<&[u8]> {
        for i in 0..usize::from(read16(&data, 4)?) {
            let record = 12 + i * 16;
            if data.get(record..record + 4) == Some(tag) {
                let offset = read32(record + 8)? as usize;
                let length = read32(record + 12)? as usize;
                return data
                    .get(offset..offset.checked_add(length).ok_or("font table overflow")?)
                    .ok_or_else(|| "truncated font table".into());
            }
        }
        Err("required font metric table is missing".into())
    };
    let units = f64::from(read16(table(b"head")?, 18)?);
    if units == 0. {
        return Err("font has zero units per em".into());
    }
    let hhea = table(b"hhea")?;
    Ok([
        f64::from(read16(hhea, 4)? as i16) / units,
        f64::from(read16(hhea, 6)? as i16) / units,
        f64::from(read16(hhea, 8)? as i16) / units,
    ])
}

fn read(root: &Path, file: &str) -> Result<String> {
    let text = std::fs::read_to_string(root.join(file)).map_err(|e| format!("{file}: {e}"))?;
    Ok(without_comments(&text))
}

fn without_comments(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = bytes.to_vec();
    let mut index = 0;
    let mut quoted = false;
    while index < bytes.len() {
        if quoted {
            if bytes[index] == b'\\' {
                index += 2;
                continue;
            }
            if bytes[index] == b'"' {
                quoted = false;
            }
        } else if bytes[index] == b'"' {
            quoted = true;
        } else if bytes[index..].starts_with(b"//") {
            while index < bytes.len() && bytes[index] != b'\n' {
                out[index] = b' ';
                index += 1;
            }
            continue;
        } else if bytes[index..].starts_with(b"/*") {
            let mut depth = 1;
            out[index..index + 2].fill(b' ');
            index += 2;
            while index < bytes.len() && depth > 0 {
                if bytes[index..].starts_with(b"/*") {
                    depth += 1;
                    out[index..index + 2].fill(b' ');
                    index += 2;
                } else if bytes[index..].starts_with(b"*/") {
                    depth -= 1;
                    out[index..index + 2].fill(b' ');
                    index += 2;
                } else {
                    if bytes[index] != b'\n' {
                        out[index] = b' ';
                    }
                    index += 1;
                }
            }
            continue;
        }
        index += 1;
    }
    // Only ASCII comment bytes have changed, preserving UTF-8 boundaries.
    String::from_utf8(out).unwrap_or_default()
}

fn between(text: &str, open: u8, close: u8) -> Result<&str> {
    let start = text
        .find(char::from(open))
        .ok_or("missing opening delimiter")?;
    let mut depth = 0;
    let mut quoted = false;
    let mut escaped = false;
    for (index, byte) in text.as_bytes().iter().copied().enumerate().skip(start) {
        if quoted {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                quoted = false;
            }
            continue;
        }
        if byte == b'"' {
            quoted = true;
        } else if byte == open {
            depth += 1;
        } else if byte == close {
            depth -= 1;
            if depth == 0 {
                return Ok(&text[start + 1..index]);
            }
        }
    }
    Err("unclosed declaration".into())
}

fn body<'a>(source: &'a str, declaration: &str) -> Result<&'a str> {
    let index = source
        .find(declaration)
        .ok_or_else(|| format!("missing {declaration}"))?;
    between(&source[index..], b'{', b'}').map_err(|e| format!("{declaration}: {e}"))
}

fn initializer<'a>(scope: &'a str, name: &str) -> Result<&'a str> {
    let needle = format!("static let {name}");
    let (_, index) = scope
        .match_indices(&needle)
        .filter(|(i, _)| {
            scope
                .as_bytes()
                .get(i + needle.len())
                .is_some_and(|b| b.is_ascii_whitespace() || *b == b':')
        })
        .map(|(i, s)| (s, i))
        .next()
        .ok_or_else(|| format!("missing constant {name}"))?;
    let rest = &scope[index + needle.len()..];
    let start = rest
        .find('=')
        .ok_or_else(|| format!("{name} has no initializer"))?
        + 1;
    let value = rest[start..].trim_start();
    let end = value.find('\n').unwrap_or(value.len());
    Ok(value[..end].trim())
}

fn scalar(scope: &str, name: &str) -> Result<f32> {
    initializer(scope, name)?
        .parse::<f32>()
        .map_err(|_| format!("{name} is no longer a literal number"))
}

fn quoted(text: &str) -> Result<&str> {
    let start = text.find('"').ok_or("missing string literal")? + 1;
    let end = text[start..].find('"').ok_or("unclosed string literal")? + start;
    let value = &text[start..end];
    if value.contains('\\') {
        return Err("escaped/interpolated metadata needs an explicit port".into());
    }
    Ok(value)
}

fn constant_name(value: &str) -> String {
    let mut result = String::new();
    for ch in value.chars() {
        if ch.is_uppercase() && !result.is_empty() {
            result.push('_');
        }
        result.extend(ch.to_uppercase());
    }
    result
}

fn emit_scalars(output: &mut String, module: &str, scope: &str, names: &[&str]) -> Result<()> {
    output.push_str(&format!("pub mod {module} {{\n"));
    for name in names {
        output.push_str(&format!(
            "pub const {}: f32 = {:?};\n",
            constant_name(name),
            scalar(scope, name)?
        ));
    }
    output.push_str("pub const ALL: &[(&str, f32)] = &[\n");
    for name in names {
        output.push_str(&format!("({name:?}, {}),\n", constant_name(name)));
    }
    output.push_str("];\n");
    output.push_str("}\n");
    Ok(())
}

fn colour(expression: &str) -> Result<(u32, f32)> {
    let expression = expression.trim();
    let (base, alpha) = if let Some((base, opacity)) = expression.split_once(".opacity(") {
        let alpha = opacity
            .strip_suffix(')')
            .ok_or("invalid opacity")?
            .parse::<f32>()
            .map_err(|_| "nonliteral opacity")?;
        if !(0.0..=1.0).contains(&alpha) {
            return Err("opacity outside 0...1".into());
        }
        (base, alpha)
    } else {
        (expression, 1.0)
    };
    let rgb = match base {
        ".white" | "Color.white" => 0xFFFFFF,
        ".black" | "Color.black" => 0x000000,
        _ => {
            let hex = base
                .strip_prefix("hex(0x")
                .and_then(|s| s.strip_suffix(')'))
                .ok_or_else(|| format!("unsupported colour: {expression}"))?;
            if hex.len() != 6 {
                return Err("expected a six-digit colour".into());
            }
            u32::from_str_radix(hex, 16).map_err(|_| "invalid hex colour")?
        }
    };
    Ok((rgb, alpha))
}

fn adaptive(scope: &str, name: &str) -> Result<((u32, f32), (u32, f32))> {
    let needle = format!("static let {name} = Color.adaptive(");
    let index = scope
        .find(&needle)
        .ok_or_else(|| format!("missing adaptive colour {name}"))?;
    let values = between(&scope[index + needle.len() - 1..], b'(', b')')?;
    let (light, dark) = values
        .strip_prefix("light:")
        .or_else(|| values.trim_start().strip_prefix("light:"))
        .ok_or("expected light colour first")?
        .split_once(", dark:")
        .or_else(|| {
            values
                .trim()
                .strip_prefix("light:")?
                .split_once(",\n        dark:")
        })
        .ok_or_else(|| format!("{name}: unsupported adaptive declaration"))?;
    Ok((colour(light)?, colour(dark)?))
}

fn enum_cases(scope: &str) -> Result<Vec<&str>> {
    let mut result = Vec::new();
    let mut depth = 0;
    let mut quoted = false;
    let mut escaped = false;
    for line in scope.lines() {
        if depth == 0
            && let Some(name) = line.trim().strip_prefix("case ")
        {
            if !name.chars().all(|ch| ch.is_ascii_alphanumeric()) {
                return Err("associated enum case needs an explicit port".into());
            }
            result.push(name);
        }
        for ch in line.chars() {
            if quoted {
                if escaped {
                    escaped = false;
                } else if ch == '\\' {
                    escaped = true;
                } else if ch == '"' {
                    quoted = false;
                }
            } else if ch == '"' {
                quoted = true;
            } else if ch == '{' {
                depth += 1;
            } else if ch == '}' {
                depth -= 1;
            }
        }
    }
    if result.is_empty() {
        return Err("enum has no raw cases".into());
    }
    Ok(result)
}

fn switch_string<'a>(scope: &'a str, property: &str, case: &str) -> Result<&'a str> {
    let property = body(scope, &format!("var {property}: String"))?;
    for line in property.lines().map(str::trim) {
        if let Some(cases) = line.strip_prefix("case ")
            && let Some((names, value)) = cases.split_once(':')
            && names
                .split(',')
                .any(|name| name.trim().strip_prefix('.') == Some(case))
        {
            return quoted(value);
        }
    }
    Err(format!("missing {case} in {property}"))
}

fn emit_enum(output: &mut String, source: &str, name: &str, labelled: bool) -> Result<()> {
    let scope = body(source, &format!("enum {name}"))?;
    let cases = enum_cases(scope)?;
    output.push_str("#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]\n");
    output.push_str(&format!("pub enum {name} {{\n"));
    for case in &cases {
        let variant = format!("{}{}", case[..1].to_uppercase(), &case[1..]);
        output.push_str(&format!("#[serde(rename={case:?})] {variant},\n"));
    }
    output.push_str(&format!(
        "}}\nimpl {name} {{\npub const ALL: &'static [Self] = &["
    ));
    for case in &cases {
        output.push_str(&format!(
            "Self::{}{},",
            case[..1].to_uppercase(),
            &case[1..]
        ));
    }
    output.push_str("];\n");
    for property in ["id", "label_key", "symbol"] {
        if property == "label_key" && !labelled {
            continue;
        }
        output.push_str(&format!(
            "pub const fn {property}(self) -> &'static str {{ match self {{\n"
        ));
        for case in &cases {
            let value = match property {
                "id" => case,
                "label_key" => switch_string(scope, "label", case)?,
                _ => switch_string(scope, "symbol", case)?,
            };
            output.push_str(&format!(
                "Self::{}{} => {value:?},\n",
                case[..1].to_uppercase(),
                &case[1..]
            ));
        }
        output.push_str("}}\n");
    }
    output.push_str("}\n");
    Ok(())
}

fn emit_application_bindings(output: &mut String, source: &str) -> Result<()> {
    let commands = body(source, ".commands")?;
    output.push_str("pub mod application_contract { pub const BINDINGS: &[(&str, &str)] = &[\n");
    let marker = "Button(L10n.text(";
    if commands.matches("Button(").count() != commands.matches(marker).count()
        || commands.matches(".keyboardShortcut(").count() != commands.matches(marker).count()
    {
        return Err("application command shape changed; review the menu port".into());
    }
    for command in commands.split(marker).skip(1) {
        let key = quoted(command)?;
        let (_, shortcut) = command
            .split_once(".keyboardShortcut(")
            .ok_or_else(|| format!("{key}: command needs an explicit shortcut port"))?;
        // Use the balanced scanner on the original call, including its '(' .
        let call = format!("({shortcut}");
        let args = between(&call, b'(', b')')?;
        let (key_arg, modifiers) = args
            .split_once(", modifiers:")
            .ok_or("shortcut modifiers changed")?;
        let shortcut_key = match key_arg.trim() {
            ".upArrow" => "up",
            ".downArrow" => "down",
            literal => quoted(literal)?,
        };
        let modifiers = modifiers
            .trim()
            .trim_start_matches('[')
            .trim_end_matches(']');
        let values: Vec<_> = modifiers.split(',').map(str::trim).collect();
        if !values.contains(&".command")
            || values
                .iter()
                .any(|v| ![".command", ".option", ".shift"].contains(v))
        {
            return Err(format!("{key}: unsupported command modifiers"));
        }
        let mut binding = String::new();
        if values.contains(&".option") {
            binding.push_str("alt-");
        }
        if values.contains(&".shift") {
            binding.push_str("shift-");
        }
        binding.push_str(shortcut_key);
        output.push_str(&format!("({key:?}, {binding:?}),\n"));
    }
    output.push_str("]; }\n");
    Ok(())
}

/// Only generated build output contains the extracted values. Swift stays authoritative.
pub fn generate(root: &Path) -> Result<String> {
    let theme = read(root, SOURCE_FILES[0])?;
    let fonts = read(root, SOURCE_FILES[1])?;
    let chrome = read(root, SOURCE_FILES[2])?;
    let routes = read(root, SOURCE_FILES[3])?;
    let workbench = read(root, SOURCE_FILES[4])?;
    let root_view = read(root, SOURCE_FILES[5])?;
    let icons = read(root, SOURCE_FILES[6])?;
    let shell = body(&chrome, "enum ShellMetrics")?;
    let mut output = String::from("// Generated from the current SwiftUI sources. Do not edit.\n");
    emit_scalars(
        &mut output,
        "shell",
        shell,
        &[
            "railWidth",
            "panelRadius",
            "titleBand",
            "sidebarDefault",
            "inspectorDefault",
        ],
    )?;
    output.push_str("pub mod shell_layout {\n");
    for name in ["sidebarRange", "inspectorRange"] {
        let value = initializer(shell, name)?;
        let (minimum, maximum) = value.split_once("...").ok_or("expected a closed range")?;
        let minimum: f32 = minimum.parse().map_err(|_| "nonliteral range minimum")?;
        let maximum: f32 = maximum.parse().map_err(|_| "nonliteral range maximum")?;
        output.push_str(&format!(
            "pub const {}: (f32, f32) = ({minimum:?}, {maximum:?});\n",
            constant_name(name)
        ));
    }
    let insets = body(shell, "static var panelInset: CGFloat")?;
    let (floating, flat) = insets
        .strip_prefix(" usesGlass ? ")
        .or_else(|| insets.trim().strip_prefix("usesGlass ? "))
        .ok_or("panelInset changed expression")?
        .split_once(':')
        .ok_or("panelInset has no flat value")?;
    for (name, value) in [
        ("PANEL_INSET_FLOATING", floating),
        ("PANEL_INSET_FLAT", flat),
    ] {
        let value: f32 = value
            .trim()
            .parse()
            .map_err(|_| "panelInset is no longer literal")?;
        output.push_str(&format!("pub const {name}: f32 = {value:?};\n"));
    }
    for name in ["DetailChromeBarHeight", "DetailChromeBottomSpacing"] {
        let value = theme
            .split_once(&format!("let {name}: CGFloat = "))
            .ok_or_else(|| format!("missing {name}"))?
            .1
            .lines()
            .next()
            .ok_or("empty chrome metric")?;
        let value: f32 = value
            .trim()
            .parse()
            .map_err(|_| "chrome metric is no longer literal")?;
        output.push_str(&format!(
            "pub const {}: f32 = {value:?};\n",
            constant_name(name)
        ));
    }
    output.push_str("}\n");
    emit_scalars(
        &mut output,
        "display_fit",
        body(&theme, "enum DisplayFit")?,
        &["referenceWidth", "referenceHeight", "floor", "textFloor"],
    )?;
    emit_scalars(
        &mut output,
        "workbench",
        body(&workbench, "enum DesktopWorkbenchLayout")?,
        &["detailMinimum", "toolMinimum", "divider"],
    )?;
    output.push_str("pub mod shell_thresholds {\n");
    for name in [
        "detailMinimumWidth",
        "minimumContentHeight",
        "widthForSidebar",
    ] {
        let expression = body(&root_view, &format!("static var {name}: CGFloat"))?.trim();
        let value: f32 = expression
            .strip_prefix("DisplayFit.box(")
            .and_then(|s| s.strip_suffix(')'))
            .ok_or("shell threshold changed expression")?
            .parse()
            .map_err(|_| "shell threshold is no longer literal")?;
        output.push_str(&format!(
            "pub const {}: f32 = {value:?};\n",
            constant_name(name)
        ));
    }
    for name in ["comfortDetail", "edgeDwell", "edgeGrace", "edgeStrip"] {
        output.push_str(&format!(
            "pub const {}: f32 = {:?};\n",
            constant_name(name),
            scalar(&root_view, name)?
        ));
    }
    output.push_str("}\n");
    for (module, names) in [
        ("Space", vec!["xs", "s", "m", "l", "xl"]),
        (
            "Control",
            vec![
                "height",
                "heightSmall",
                "heightComfortable",
                "pairedWidth",
                "rowHeight",
            ],
        ),
        (
            "Modal",
            vec!["headerMinHeight", "iconSeat", "footerHeight", "bodyPadding"],
        ),
    ] {
        emit_scalars(
            &mut output,
            &module.to_lowercase(),
            body(&theme, &format!("enum {module}"))?,
            &names,
        )?;
    }
    emit_scalars(&mut output, "cards", &theme, &["cardRadius", "cardPadding"])?;
    output.push_str("pub mod palette {\n");
    let colours = [
        "accent",
        "secondary",
        "background",
        "sidebar",
        "panel",
        "tabStrip",
        "border",
        "rowHighlight",
        "controlSeat",
        "controlGlyph",
        "controlGlyphHover",
        "rowSelectedNested",
        "accentSoft",
        "stateIdle",
        "diffAdded",
        "diffRemoved",
    ];
    for name in colours {
        let ((light, light_alpha), (dark, dark_alpha)) = adaptive(&theme, name)?;
        output.push_str(&format!("pub const {}: super::AdaptiveColor = super::AdaptiveColor::new(0x{light:06X}, {light_alpha:?}, 0x{dark:06X}, {dark_alpha:?});\n", constant_name(name)));
    }
    for name in ["warning", "danger"] {
        let value = initializer(&theme, name)?;
        let values = value
            .strip_prefix("Color(red: ")
            .and_then(|v| v.strip_suffix(')'))
            .ok_or_else(|| format!("{name}: unsupported RGB declaration"))?;
        let mut rgb = 0u32;
        let channels: Vec<_> = values.split(", ").collect();
        if channels.len() != 3 {
            return Err(format!("{name}: expected three RGB channels"));
        }
        for (index, channel) in channels.into_iter().enumerate() {
            let channel = channel
                .strip_prefix(if index == 1 {
                    "green: "
                } else if index == 2 {
                    "blue: "
                } else {
                    ""
                })
                .and_then(|v| v.strip_suffix(" / 255"))
                .and_then(|v| v.strip_prefix("0x"))
                .ok_or_else(|| format!("{name}: nonliteral RGB channel"))?;
            let channel = u8::from_str_radix(channel, 16).map_err(|_| "invalid RGB channel")?;
            rgb = (rgb << 8) | u32::from(channel);
        }
        output.push_str(&format!("pub const {}: super::AdaptiveColor = super::AdaptiveColor::new(0x{rgb:06X}, 1., 0x{rgb:06X}, 1.);\n", constant_name(name)));
    }
    let selection = initializer(&theme, "rowSelected")?
        .strip_prefix("accent.opacity(")
        .and_then(|s| s.strip_suffix(')'))
        .ok_or("rowSelected changed expression")?;
    let selection: f32 = selection
        .parse()
        .map_err(|_| "rowSelected opacity is no longer literal")?;
    output.push_str(&format!(
        "pub const ROW_SELECTED: super::AdaptiveColor = ACCENT.opacity({selection:?});\n"
    ));
    output.push_str("pub const ALL: &[(&str, super::AdaptiveColor)] = &[\n");
    for name in colours
        .into_iter()
        .chain(["rowSelected", "warning", "danger"])
    {
        output.push_str(&format!("({name:?}, {}),\n", constant_name(name)));
    }
    output.push_str("];\n");
    let heat_start = theme
        .find("static let heat:")
        .ok_or("missing heat palette")?;
    let (_, heat) = theme[heat_start..]
        .split_once('=')
        .ok_or("missing heat initializer")?;
    output.push_str("pub const HEAT: &[super::AdaptiveColor] = &[\n");
    for expression in between(heat, b'[', b']')?
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        let declaration = format!("static let value = {}", expression.trim_end_matches(','));
        let ((light, la), (dark, da)) = adaptive(&declaration, "value")?;
        output.push_str(&format!(
            "super::AdaptiveColor::new(0x{light:06X}, {la:?}, 0x{dark:06X}, {da:?}),\n"
        ));
    }
    output.push_str("];\n}\n");
    let heatmap = read(root, SOURCE_FILES[10])?;
    output.push_str("pub mod heatmap {\n");
    for name in ["gutter", "gapRatio", "cellCorner", "maxCell", "maxGapRatio"] {
        let prefix = format!("private let {name}: CGFloat = ");
        let value: f64 = heatmap
            .lines()
            .map(str::trim)
            .find_map(|line| line.strip_prefix(&prefix))
            .ok_or_else(|| format!("missing heatmap {name}"))?
            .parse()
            .map_err(|_| format!("nonliteral heatmap {name}"))?;
        output.push_str(&format!(
            "pub const {}: f64 = {value:?};\n",
            constant_name(name)
        ));
    }
    output.push_str("}\n");
    output.push_str("pub mod fonts {\n");
    for name in ["interface", "mono"] {
        output.push_str(&format!(
            "pub const {}: &str = {:?};\n",
            constant_name(name),
            quoted(initializer(&fonts, name)?)?
        ));
    }
    for (name, file) in [("INTERFACE", "Manrope"), ("MONO", "JetBrainsMono")] {
        let metrics = font_metrics(&root.join(format!("../Resources/Fonts/{file}-Variable.ttf")))?;
        output.push_str(&format!(
            "pub const {name}_METRICS: [f64; 3] = {metrics:?};\n"
        ));
    }
    output.push_str("}\npub mod typography {\n");
    for name in [
        "largeTitle",
        "title",
        "title2",
        "title3",
        "headline",
        "body",
        "callout",
        "subheadline",
        "footnote",
        "caption",
        "caption2",
    ] {
        let value = body(&theme, &format!("static var {name}: Font"))?
            .trim()
            .strip_prefix("font(")
            .ok_or_else(|| format!("{name} is no longer a font declaration"))?;
        let (points, rest) = value.split_once(',').ok_or("font has no weight")?;
        let points: f32 = points.parse().map_err(|_| "font points are not literal")?;
        let weight = match rest
            .trim_start()
            .strip_prefix("weight: .")
            .and_then(|s| s.split(',').next())
        {
            Some("regular") => 400,
            Some("medium") => 500,
            Some("semibold") => 600,
            Some("bold") => 700,
            _ => return Err(format!("unsupported weight for {name}")),
        };
        output.push_str(&format!("pub const {}: super::FontToken = super::FontToken {{ points: {points:?}, weight: {weight} }};\n", constant_name(name)));
    }
    output.push_str("}\n");
    emit_enum(&mut output, &chrome, "RailPlace", true)?;
    emit_enum(&mut output, &routes, "GlobalSection", true)?;
    emit_enum(&mut output, &routes, "WorkspaceSection", true)?;
    emit_enum(&mut output, &icons, "ActionIcon", false)?;
    emit_application_bindings(&mut output, &read(root, SOURCE_FILES[7])?)?;
    let detail = read(root, SOURCE_FILES[8])?;
    let settings = read(root, SOURCE_FILES[9])?;
    let labels = body(&settings, "static func label")?;
    let default = initializer(&settings, "defaultLevel")?.trim_start_matches('.');
    let cases = enum_cases(body(&detail, "enum ChatDetail")?)?;
    if !cases.contains(&default) {
        return Err("unsupported chat detail default".into());
    }
    output.push_str(&format!("pub const DEFAULT_CHAT_DETAIL: &str = {default:?};\npub const CHAT_DETAIL_LEVELS: &[(&str, &str)] = &[\n"));
    for case in cases {
        let prefix = format!("case .{case}:");
        let line = labels
            .lines()
            .map(str::trim)
            .find_map(|line| line.strip_prefix(&prefix))
            .ok_or_else(|| format!("missing chat detail label: {case}"))?;
        let key = quoted(line)?;
        output.push_str(&format!("({case:?}, {key:?}),\n"));
    }
    output.push_str("];\n");
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn comment_delimiters_in_strings_do_not_remove_declarations() {
        let source = "// { hidden }\nenum X { let value = \"//literal\" /* } /* nested */ */ }";
        let cleaned = without_comments(source);
        assert_eq!(
            body(&cleaned, "enum X").unwrap().trim(),
            "let value = \"//literal\""
        );
    }

    #[test]
    fn nonliteral_values_require_an_explicit_port() {
        assert!(scalar("static let x = scaled(64)", "x").is_err());
        assert!(colour("Color.primary").is_err());
        assert!(colour("hex(0x123456).opacity(2)").is_err());
        assert!(quoted(r#""dynamic\(value)""#).is_err());
        assert!(enum_cases("case one(value: String)").is_err());
    }

    #[test]
    fn the_current_swift_desktop_contract_is_extractable() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../mac/Sources");
        let generated = generate(&root).unwrap();
        assert!(generated.contains("pub enum RailPlace"));
        assert!(generated.contains("pub enum WorkspaceSection"));
    }

    #[test]
    fn cases_after_methods_are_not_silently_omitted() {
        let source = "case first\nvar label: String { switch self { case .first: return \"{\" } }\ncase second";
        assert_eq!(enum_cases(source).unwrap(), ["first", "second"]);
    }
}
