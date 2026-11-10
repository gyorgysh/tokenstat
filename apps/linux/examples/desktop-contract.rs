// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Deterministic source/behavior comparison with the compiled SwiftUI reference.

#[path = "contracts/chats.rs"]
mod chat_contract;
#[path = "contracts/home.rs"]
mod home_contract;
#[path = "contracts/projects.rs"]
mod project_contract;
#[path = "contracts/sidebar.rs"]
mod sidebar_contract;

use serde_json::{Value, json};
use tokenstat_linux::{
    commands::{AccountMenuState, EntryKind, account_menu},
    design,
    layout::{DisplayFit, ShellLayout},
    localization,
    navigation::{GlobalSection, RailPlace, Route, WorkspaceSection},
};

fn scalars(values: &[(&str, f32)]) -> Value {
    values
        .iter()
        .map(|(name, value)| (name.to_string(), json!(value)))
        .collect()
}

fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let screen_width = args.first().and_then(|s| s.parse().ok()).unwrap_or(1440.0);
    let screen_height = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(900.0);
    let floating = args.get(2).is_none_or(|s| s == "floating");
    let fit = DisplayFit::for_screen(screen_width, screen_height);
    let mut geometry = Vec::new();
    for width in [0.0, 720.0, 999.0, 1000.0, 1260.0, 1468.0, 1600.0] {
        for companion in [None, Some(320.0), Some(520.0)] {
            for chosen in [false, true] {
                for sidebar_width in [220.0, 272.0, 440.0] {
                    for inspector_width in [300.0, 400.0, 640.0] {
                        let layout = ShellLayout {
                            fit,
                            floating_chrome: floating,
                            sidebar_chosen: chosen,
                            sidebar_width,
                            inspector_width,
                            ..Default::default()
                        };
                        geometry.push(json!({"width":width,"companion":companion,"chosen":chosen,"sidebarWidth":sidebar_width,"inspectorWidth":inspector_width,"sidebarFits":layout.sidebar_fits(width,companion),"showsSidebar":layout.shows_sidebar(width,companion),"inspectorFits":layout.inspector_fits(width,companion)}));
                    }
                }
            }
        }
    }
    let mut toggles = Vec::new();
    let mut layout = ShellLayout {
        fit,
        floating_chrome: floating,
        ..Default::default()
    };
    for width in [1500.0, 1500.0, 720.0, 720.0, 720.0, 1500.0] {
        layout.toggle_sidebar(width, None);
        toggles.push(json!({"width":width,"chosen":layout.sidebar_chosen,"pinned":layout.sidebar_pinned,"overlay":layout.sidebar_overlay}));
    }
    let palette: Value = design::palette::ALL
        .iter()
        .map(|(name, colour)| {
            (
                name.to_string(),
                json!({"light":colour.light,"dark":colour.dark}),
            )
        })
        .collect();
    let account_menus = (0..16).map(|bits| {
        let state = AccountMenuState { signed_in: bits & 1 != 0, syncing: bits & 2 != 0, sync_cooldown: bits & 4 != 0, checking_updates: bits & 8 != 0 };
        account_menu(state).iter().map(|entry| json!({
            "kind":match entry.kind { EntryKind::Action=>"action",EntryKind::Separator=>"separator",EntryKind::Heading=>"heading" },
            "title":entry.title,"enabled":entry.enabled,"selected":entry.selected,"symbol":entry.icon.map(|icon|icon.symbol()),"destructive":entry.destructive
        })).collect::<Vec<_>>()
    }).collect::<Vec<_>>();
    let formatting = [
        ("{1} {0} {1}", vec!["a", "b"]),
        ("{0}: {1}", vec!["{1}", "$HOME %1$@ {0}"]),
        ("東京 {1} {0}", vec!["🇭🇺", "árvíz"]),
        ("{{0}} {01}", vec!["x", "y"]),
        ("{-1} {x} {3} {0", vec!["x"]),
        ("%1$@ 100% {0}", vec!["a"]),
        ("{0} unchanged", vec![]),
    ].into_iter().map(|(template, arguments)| {
        let catalog = localization::LanguageCatalog::from_strings([("fixture".to_string(),template.to_string())].into_iter().collect());
        json!({"template":template,"arguments":arguments,"result":catalog.text("fixture",&arguments)})
    }).collect::<Vec<_>>();
    let result = json!({
        "rail":RailPlace::ALL.iter().map(|r|json!({"id":r.id(),"label":localization::text(r.label_key(),&[]),"symbol":r.symbol()})).collect::<Vec<_>>(),
        "global":GlobalSection::ALL.iter().map(|s| {let route=Route::Global{section:*s};json!({"id":s.id(),"label":localization::text(s.label_key(),&[]),"symbol":s.symbol(),"rail":route.rail_place().map(RailPlace::id),"hasInspector":route.has_inspector()})}).collect::<Vec<_>>(),
        "workspace":WorkspaceSection::ALL.iter().map(|s| {let route=Route::Workspace{id:"fixture".into(),section:*s};json!({"id":s.id(),"label":localization::text(s.label_key(),&[]),"symbol":s.symbol(),"rail":route.rail_place().map(RailPlace::id),"hasInspector":route.has_inspector()})}).collect::<Vec<_>>(),
        "design":{"shell":scalars(design::shell::ALL),"space":scalars(design::space::ALL),"control":scalars(design::control::ALL),"modal":scalars(design::modal::ALL),"cards":scalars(design::cards::ALL),"workbench":scalars(design::workbench::ALL),"chromeHeight":design::shell_layout::DETAIL_CHROME_BAR_HEIGHT,"chromeBottomSpacing":design::shell_layout::DETAIL_CHROME_BOTTOM_SPACING,"sidebarRange":design::shell_layout::SIDEBAR_RANGE,"inspectorRange":design::shell_layout::INSPECTOR_RANGE},
        "palette":palette,
        "fonts":{"interface":design::fonts::INTERFACE,"mono":design::fonts::MONO},
        "screen":[screen_width,screen_height],
        "floatingChrome":floating,
        "displayFit":{"factor":fit.factor,"box100":fit.text(100.0),"dp14":fit.text(14.0),"scale100":fit.scale(100.0)},
        "geometry":geometry,
        "toggles":toggles,
        "home":home_contract::snapshot().unwrap(),
        "accountMenus":account_menus,
        "projects":project_contract::snapshot(),
        "sidebar":sidebar_contract::snapshot(),
        "chats":chat_contract::snapshot(),
        "formatting":formatting,
        "actionIcons":design::ActionIcon::ALL.iter().map(|icon|json!({"id":icon.id(),"symbol":icon.symbol()})).collect::<Vec<_>>(),
    });
    println!("{}", serde_json::to_string(&result).unwrap());
}
