// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Shared GPUI primitives use SwiftUI logical sizes, not the framework defaults.

use crate::design::{FontToken, cards, fonts, palette, shell_layout, space};
use gpui::{App, Div, FontWeight, IntoElement, div, prelude::*, px};
use std::borrow::Cow;

/// Both families are process-local assets, never installed into the user's font set.
pub fn register_fonts(app: &mut App) -> anyhow::Result<()> {
    app.text_system()
        .add_fonts(include!(concat!(env!("OUT_DIR"), "/embedded_fonts.rs")))
}

/// GPUI presets use a different scale, so pass the source token explicitly.
pub fn text(value: impl IntoElement, font: FontToken) -> Div {
    div()
        .font_family(fonts::INTERFACE)
        .font_weight(FontWeight(f32::from(font.weight)))
        .text_size(px(font.points))
        .line_height(px(font.line_height(false)))
        .child(value)
}

/// For the places where SwiftUI explicitly uses .system or native .caption.
/// Keep these roles separate from the app's bundled interface family. The
/// platform UI font still needs Linux shape/metrics acceptance.
pub fn system_text(value: impl IntoElement, points: f32, weight: u16, app: &App) -> Div {
    let font = system_font(weight);
    let line = system_seat(points, weight, app).line_height;
    div()
        .font(font)
        .text_size(px(points))
        .line_height(px(line))
        .child(value)
}

/// GPUI 0.2.2's font-kit mapping places AppKit Medium's 0.23 trait at CSS
/// 530, above the CSS 400/500 matching range. Requesting 500 selects Regular.
/// Keep the logical role at 500 and correct only the macOS preview backend's
/// face selection. Linux's font weights retain their actual CSS/OS2 values.
pub fn system_font(weight: u16) -> gpui::Font {
    let mut font = gpui::font(".SystemUIFont");
    font.weight = FontWeight(if cfg!(target_os = "macos") && weight == 500 {
        530.
    } else {
        f32::from(weight)
    });
    font
}

/// A native caption beside a Manrope number shares its actual glyph baseline.
/// Taffy uses these Divs' bottom edge as the baseline, so reserve the difference
/// in their descender seats rather than aligning their unequal line-box ends.
pub fn numeric_system_note(
    value: impl IntoElement,
    base: FontToken,
    points: f32,
    app: &App,
) -> Div {
    let pad = interface_seat(base, app).baseline_from_bottom
        - system_seat(points, 400, app).baseline_from_bottom;
    system_text(value, points, 400, app).pb(px(pad.max(0.)))
}

/// Measured seats shared by baseline layout and the native font comparison.
#[derive(Clone, Copy, Debug, serde::Serialize)]
pub struct TextSeat {
    pub line_height: f32,
    pub baseline_from_bottom: f32,
}
fn seat(
    family: &'static str,
    points: f32,
    weight: u16,
    height: Option<f32>,
    app: &App,
) -> TextSeat {
    let font = if family == ".SystemUIFont" {
        system_font(weight)
    } else {
        let mut font = gpui::font(family);
        font.weight = FontWeight(f32::from(weight));
        font
    };
    let system = app.text_system();
    let id = system.resolve_font(&font);
    let ascent = f32::from(system.ascent(id, px(points)));
    let descent = f32::from(system.descent(id, px(points))).abs();
    let line_height = height.unwrap_or_else(|| ascent.ceil() + descent.ceil());
    TextSeat {
        line_height,
        baseline_from_bottom: (line_height - ascent - descent) / 2. + descent,
    }
}
pub fn system_seat(points: f32, weight: u16, app: &App) -> TextSeat {
    seat(".SystemUIFont", points, weight, None, app)
}
pub fn interface_seat(token: FontToken, app: &App) -> TextSeat {
    seat(
        fonts::INTERFACE,
        token.points,
        token.weight,
        Some(token.line_height(false)),
        app,
    )
}

/// Identifiers and source code keep the same separate family as the SwiftUI app.
pub fn monospaced(value: impl IntoElement, font: FontToken) -> Div {
    text(value, font)
        .font_family(fonts::MONO)
        .line_height(px(font.line_height(true)))
}

/// SwiftUI numeric() uses the interface family with tabular figures, not mono().
pub fn numeric(value: impl IntoElement, token: FontToken) -> Div {
    let mut font = gpui::font(fonts::INTERFACE);
    font.weight = FontWeight(f32::from(token.weight));
    font.features = gpui::FontFeatures(std::sync::Arc::new(vec![("tnum".into(), 1)]));
    text(value, token).font(font)
}

/// The common panel surface leaves title/content composition to the feature view.
pub fn card_surface(dark: bool) -> Div {
    div()
        // SwiftUI's strokeBorder is an overlay. GPUI includes a one-point
        // border in layout, so reserve it inside the original padding.
        .p(px(cards::CARD_PADDING - 1.))
        .rounded(px(cards::CARD_RADIUS))
        .bg(palette::PANEL.resolve(dark))
        .border_1()
        .border_color(palette::BORDER.resolve(dark))
}

/// Adjacent bars share the measured SwiftUI baseline correction and fixed height.
pub fn chrome_bar(dark: bool) -> Div {
    div()
        .flex()
        .items_center()
        .gap(px(space::S))
        .px(px(space::M))
        .pb(px(shell_layout::DETAIL_CHROME_BOTTOM_SPACING - 1.))
        .h(px(shell_layout::DETAIL_CHROME_BAR_HEIGHT))
        .w_full()
        .flex_none()
        .bg(palette::TAB_STRIP.resolve(dark))
        .border_b_1()
        .border_color(palette::BORDER.resolve(dark))
}
