// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! App-owned Linux vector drawings, keyed by the source's logical symbol names.
//! These initial outlines need same-state visual review; name mapping alone is
//! not a claim that SF Symbol geometry, selected variants or weights match.

use gpui::{AssetSource, SharedString};
use std::borrow::Cow;

pub struct Symbols;

include!(concat!(env!("OUT_DIR"), "/embedded_assets.rs"));

pub fn has_asset(name: &str) -> bool {
    embedded_asset(&format!("assets/{name}")).is_some()
}

impl AssetSource for Symbols {
    fn load(&self, path: &str) -> anyhow::Result<Option<Cow<'static, [u8]>>> {
        if let Some(bytes) = embedded_asset(path) {
            return Ok(Some(Cow::Borrowed(bytes)));
        }
        if path == "features/activity" {
            return Ok(Some(Cow::Borrowed(include_bytes!(
                "../../mac/Resources/FeatureMarks.xcassets/mark_activity.imageset/activity.svg"
            ))));
        }
        let Some(name) = path.strip_prefix("symbols/") else {
            return Ok(None);
        };
        let shape = match name {
            "house" => r#"<path d="M3 11 12 3l9 8M5.5 9.5V21h5v-7h3v7h5V9.5"/>"#,
            "folder" => {
                r#"<path d="M3 6a2 2 0 0 1 2-2h5l2 3h7a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2ZM3 10h18"/>"#
            }
            "checklist" => {
                r#"<path d="m3 5 1.5 1.5L7 3M10 5h11M3 12l1.5 1.5L7 10M10 12h11M3 19l1.5 1.5L7 17M10 19h11"/>"#
            }
            "note.text" => {
                r#"<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 8h8M8 12h8M8 16h5"/>"#
            }
            "bolt" => r#"<path d="m14 2-10 12h7l-1 8L20 9h-7Z"/>"#,
            "chart.bar.xaxis" => r#"<path d="M2 21h20M5 18v-7h3v7ZM11 18V3h3v15ZM17 18V7h3v11Z"/>"#,
            "cpu" => {
                r#"<rect x="5" y="5" width="14" height="14" rx="2"/><rect x="9" y="9" width="6" height="6" rx="1"/><path d="M8 2v3m4-3v3m4-3v3M8 19v3m4-3v3m4-3v3M2 8h3m-3 4h3m-3 4h3m14-8h3m-3 4h3m-3 4h3"/>"#
            }
            "chevron.left" => r#"<path d="m15 5-7 7 7 7"/>"#,
            "arrow.down.circle" => {
                r#"<circle cx="12" cy="12" r="10"/><path d="M12 6v11m-4-4 4 4 4-4"/>"#
            }
            "arrow.triangle.2.circlepath" => {
                r#"<path d="M20 9a8 8 0 0 0-14-3L4 8m0-5v5h5M4 15a8 8 0 0 0 14 3l2-2m0 5v-5h-5"/>"#
            }
            "checkmark.circle.fill" => {
                r#"<circle cx="12" cy="12" r="10"/><path d="m7.5 12 3 3 6-6"/>"#
            }
            "tray" => {
                r#"<path d="M4 4h16l2 10v5a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-5L4 4ZM2 14h6l1.5 2h5l1.5-2h6"/>"#
            }
            "hand.tap" => {
                r#"<path d="M9 13V6a2 2 0 0 1 4 0v5l1-1a2 2 0 0 1 3 1h1a2 2 0 0 1 2 2v3c0 4-2 6-5 6h-3c-2 0-3-1-4-2l-3-4a2 2 0 0 1 3-2l1 1ZM7 3 6 1m9 2 1-2M4 7H2m17 0h3"/>"#
            }
            "laptopcomputer" => {
                r#"<rect x="4" y="4" width="16" height="13" rx="1.5"/><path d="m4 17-2 3h20l-2-3M10 20h4"/>"#
            }
            "network" => {
                r#"<circle cx="12" cy="12" r="10"/><ellipse cx="12" cy="12" rx="4" ry="10"/><path d="M2 12h20M4 6h16M4 18h16"/>"#
            }
            "terminal" => {
                r#"<rect x="2" y="4" width="20" height="16" rx="2"/><path d="m6 9 3 3-3 3M12 15h5"/>"#
            }
            "person.2" => {
                r#"<circle cx="9" cy="7" r="3"/><circle cx="18" cy="9" r="2.5"/><path d="M2 21v-3a7 7 0 0 1 14 0v3ZM17 15a5 5 0 0 1 5 5v1h-4"/>"#
            }
            "person.crop.circle" => {
                r#"<circle cx="12" cy="12" r="10"/><circle cx="12" cy="9" r="3"/><path d="M5 19a7 7 0 0 1 14 0"/>"#
            }
            "square.and.pencil" => {
                r#"<path d="M11 4H5a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2h13a2 2 0 0 0 2-2v-7M10 14l1-4L20 1l3 3-9 9ZM18 3l3 3"/>"#
            }
            "magnifyingglass" => r#"<circle cx="10" cy="10" r="7"/><path d="m15 15 7 7"/>"#,
            "sidebar.left" => {
                r#"<rect x="2" y="4" width="20" height="16" rx="2"/><path d="M8 4v16M4.5 8h1M4.5 11h1"/>"#
            }
            "sidebar.right" => {
                r#"<rect x="2" y="4" width="20" height="16" rx="2"/><path d="M16 4v16M18.5 8h1M18.5 11h1"/>"#
            }
            "gearshape" => {
                r#"<path d="m10 2 4 0 .5 3 2 .9 2.5-1.5 2 3.4-2.3 2v2.4l2.3 2-2 3.4-2.5-1.5-2 .9L14 21h-4l-.5-3-2-.9L5 18.6l-2-3.4 2.3-2v-2.4L3 8.8l2-3.4L7.5 7l2-.9Z"/><circle cx="12" cy="11.5" r="3.2"/>"#
            }
            "plus.circle" => r#"<circle cx="12" cy="12" r="10"/><path d="M7 12h10M12 7v10"/>"#,
            "plus" => r#"<path d="M4 12h16M12 4v16"/>"#,
            "calendar" => {
                r#"<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M7 2v6M17 2v6M7 14h1M11 14h1M15 14h1M7 18h1M11 18h1"/>"#
            }
            "arrow.right" => r#"<path d="M3 12h18m-7-7 7 7-7 7"/>"#,
            "progress" => {
                r#"<g><path d="M12 2v4" opacity="1"/><path d="m17 3-2 3.5" opacity=".92"/><path d="m20.7 7-3.5 2" opacity=".84"/><path d="M22 12h-4" opacity=".76"/><path d="m20.7 17-3.5-2" opacity=".68"/><path d="m17 20.7-2-3.5" opacity=".6"/><path d="M12 22v-4" opacity=".52"/><path d="m7 20.7 2-3.5" opacity=".44"/><path d="m3.3 17 3.5-2" opacity=".36"/><path d="M2 12h4" opacity=".28"/><path d="m3.3 7 3.5 2" opacity=".2"/><path d="m7 3.3 2 3.5" opacity=".12"/></g>"#
            }
            "square.grid.2x2" => {
                r#"<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>"#
            }
            "chevron.down" => r#"<path d="m5 9 7 7 7-7"/>"#,
            "chevron.up" => r#"<path d="m5 15 7-7 7 7"/>"#,
            "checkmark" => r#"<path d="m4 12 5 5L20 6"/>"#,
            "line.3.horizontal" => r#"<path d="M4 6h16M4 12h16M4 18h16"/>"#,
            "arrow.uturn.backward" => r#"<path d="m8 3-5 5 5 5M3 8h11a7 7 0 0 1 0 14h-2"/>"#,
            "arrow.uturn.backward.circle.fill" => {
                r#"<circle cx="12" cy="12" r="10"/><path d="m9 7-3 3 3 3M6 10h8a4 4 0 0 1 0 8h-2"/>"#
            }
            "pin.fill" => r#"<path d="M8 3h8l-1 6 4 5H5l4-5ZM12 14v8"/>"#,
            "pin" => r#"<path d="M8 3h8l-1 6 4 5H5l4-5ZM12 14v8"/>"#,
            "ellipsis" => {
                r#"<circle cx="4" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="20" cy="12" r="1"/>"#
            }
            "trash" => r#"<path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7"/>"#,
            "archivebox" => r#"<path d="M4 8v13h16V8M2 3h20v5H2ZM9 12h6"/>"#,
            "plus.circle.fill" => r#"<circle cx="12" cy="12" r="10"/><path d="M7 12h10M12 7v10"/>"#,
            "link" => {
                r#"<path d="m10 7 3-3a5 5 0 0 1 7 7l-3 3M14 17l-3 3a5 5 0 0 1-7-7l3-3M8 16l8-8"/>"#
            }
            "minus.circle" => r#"<circle cx="12" cy="12" r="10"/><path d="M7 12h10"/>"#,
            "xmark.circle" => r#"<circle cx="12" cy="12" r="10"/><path d="m8 8 8 8M16 8l-8 8"/>"#,
            "chevron.left.forwardslash.chevron.right" => {
                r#"<path d="m7 6-5 6 5 6M17 6l5 6-5 6M14 3l-4 18"/>"#
            }
            "pencil" => r#"<path d="m3 21 1-6L17 2l5 5L9 20ZM14 5l5 5"/>"#,
            "pencil.line" => r#"<path d="m4 16 1-5L15 1l5 5L10 16ZM12 4l5 5M3 22h18"/>"#,
            "info.circle" => r#"<circle cx="12" cy="12" r="10"/><path d="M12 11v7M12 6v1"/>"#,
            "arrow.triangle.pull" => {
                r#"<circle cx="6" cy="5" r="3"/><circle cx="6" cy="19" r="3"/><circle cx="18" cy="19" r="3"/><path d="M6 8v8M18 16V9a4 4 0 0 0-4-4h-2m3-3-3 3 3 3"/>"#
            }
            "arrow.triangle.merge" => {
                r#"<circle cx="6" cy="5" r="3"/><circle cx="18" cy="5" r="3"/><circle cx="6" cy="19" r="3"/><path d="M6 8v8M18 8v2a4 4 0 0 1-4 4H6m3-3-3 3 3 3"/>"#
            }
            "questionmark.folder" => {
                r#"<path d="M3 6a2 2 0 0 1 2-2h5l2 3h7a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2ZM10 12a2 2 0 0 1 4 0c0 2-2 1-2 3M12 18h.01"/>"#
            }
            "bubble.left.and.bubble.right" => {
                r#"<path d="M3 3h12a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H8l-5 4v-4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2ZM18 8h3a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2v3l-4-3h-6a2 2 0 0 1-2-2v-2"/>"#
            }
            "desktopcomputer" => {
                r#"<rect x="2" y="3" width="20" height="14" rx="2"/><path d="M12 17v4M7 21h10"/>"#
            }
            "sum" => r#"<path d="M19 4H5l9 8-9 8h14"/>"#,
            "square.grid.3x3.fill" => {
                r#"<path d="M3 3h4v4H3ZM10 3h4v4h-4ZM17 3h4v4h-4ZM3 10h4v4H3ZM10 10h4v4h-4ZM17 10h4v4h-4ZM3 17h4v4H3ZM10 17h4v4h-4ZM17 17h4v4h-4Z" fill="white" stroke="none"/>"#
            }
            "gauge.with.needle" => {
                r#"<path d="M4 19a10 10 0 1 1 16 0M6 16l-2-1M7 8 5 6M12 6V3M18 8l2-2M12 16l5-6"/><circle cx="12" cy="16" r="2"/>"#
            }
            "clock.arrow.circlepath" => r#"<path d="M21 7a10 10 0 1 0 1 7M21 2v5h-5M12 6v6l4 2"/>"#,
            "server.rack" => {
                r#"<rect x="3" y="3" width="18" height="7" rx="2"/><rect x="3" y="14" width="18" height="7" rx="2"/><path d="M7 6.5h.01M7 17.5h.01M12 6.5h5M12 17.5h5"/>"#
            }
            "iphone" => {
                r#"<rect x="6" y="1" width="12" height="22" rx="3"/><path d="M10 4h4M10 20h4"/>"#
            }
            "ipad" => {
                r#"<rect x="3" y="1" width="18" height="22" rx="2.5"/><path d="M11 3h2M11 20h2"/>"#
            }
            "chevron.right" => r#"<path d="m9 5 7 7-7 7"/>"#,
            "arrow.clockwise" => r#"<path d="M20 8a9 9 0 1 0 1 7M20 2v6h-6"/>"#,
            "xmark" => r#"<path d="m5 5 14 14M19 5 5 19"/>"#,
            _ => return Ok(None),
        };
        Ok(Some(Cow::Owned(format!(r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">{shape}</svg>"#).into_bytes())))
    }

    fn list(&self, _path: &str) -> anyhow::Result<Vec<SharedString>> {
        Ok(Vec::new())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_insights_controls_and_empty_states_have_drawable_symbols() {
        for symbol in [
            "chart.bar.xaxis",
            "square.grid.2x2",
            "cpu",
            "folder",
            "terminal",
            "bubble.left.and.bubble.right",
            "chevron.left",
            "calendar",
            "arrow.down.circle",
            "arrow.triangle.2.circlepath",
            "checkmark.circle.fill",
            "progress",
            "tray",
            "hand.tap",
            "xmark",
        ] {
            assert!(
                Symbols
                    .load(&format!("symbols/{symbol}"))
                    .unwrap()
                    .is_some(),
                "{symbol}"
            );
        }
        for name in ["mark_insights", "mark_activity", "mark_archive"] {
            assert!(has_asset(name), "{name}");
        }
    }

    #[test]
    fn every_project_menu_glyph_has_an_explicit_preview_asset() {
        let menus = crate::project_menu::items(&crate::project_menu::State {
            reference: true,
            shared: true,
            stop_sharing: true,
            git_is_repo: Some(true),
            ..Default::default()
        });
        for symbol in menus
            .iter()
            .filter_map(|item| item.icon.map(|icon| icon.symbol()))
            .chain([
                "pin.fill",
                "ellipsis",
                "trash",
                "questionmark.folder",
                "xmark.circle",
                "info.circle",
                "pencil",
                "pencil.line",
                "arrow.triangle.pull",
                "arrow.triangle.merge",
            ])
        {
            assert!(
                Symbols
                    .load(&format!("symbols/{symbol}"))
                    .unwrap()
                    .is_some(),
                "{symbol}"
            );
        }
    }

    #[test]
    fn day_cards_load_the_original_feature_and_vendor_svg_assets() {
        for id in [
            "claude_code",
            "codex",
            "grok",
            "opencode",
            "cline",
            "openclaw",
            "muse",
            "devin",
            "pi",
            "dsh",
            "zed",
            "copilot",
            "antigravity",
            "cursor",
            "gemini",
            "hermes",
            "kilo",
            "kimi",
            "qwen",
        ] {
            let name = crate::display::harness_brand_asset(id).unwrap();
            assert!(has_asset(&name), "missing {name}");
        }
        for name in [
            "mark_activity",
            "mark_insights",
            "mark_automation",
            "mark_plan",
            "mark_device",
            "mark_pin",
        ] {
            assert!(has_asset(name), "missing {name}");
        }
    }

    #[test]
    fn source_rail_and_home_section_symbols_have_drawable_assets() {
        for symbol in crate::design::RailPlace::ALL
            .iter()
            .map(|p| p.symbol())
            .chain(
                crate::home::layout::Section::ALL
                    .into_iter()
                    .map(|s| s.symbol()),
            )
            .chain([
                "desktopcomputer",
                "laptopcomputer",
                "server.rack",
                "ipad",
                "iphone",
                crate::design::ActionIcon::Next.symbol(),
                "bubble.left.and.bubble.right",
                crate::design::ActionIcon::History.symbol(),
                crate::design::ActionIcon::Pinned.symbol(),
            ])
        {
            assert!(
                Symbols
                    .load(&format!("symbols/{symbol}"))
                    .unwrap()
                    .is_some(),
                "missing {}",
                symbol
            );
        }
    }
}
