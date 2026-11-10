// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Fixed-size component states for comparison with the original SwiftUI views.
//! These fixtures never receive a host client or acquire an archive/owner lock.

use super::*;
use crate::home::day::{DayDetail, DayOverview, HoverAnchor, Reading, Rect};

#[derive(Clone, Copy, Debug)]
pub(super) enum Fixture {
    Day(DayFixture),
    Home(super::home_fixtures::HomeFixture),
    Project(super::project_fixtures::ProjectFixture),
}
impl Fixture {
    pub fn size(self) -> gpui::Size<gpui::Pixels> {
        match self {
            Self::Day(f) => f.size(),
            Self::Home(f) => f.size(),
            Self::Project(f) => f.size(),
        }
    }
    pub fn prepare(self, view: &mut Desktop, window: &mut Window, cx: &mut Context<Desktop>) {
        if let Self::Day(f) = self {
            f.prepare(view);
        }
        if let Self::Project(f) = self {
            f.prepare(view, window, cx);
        }
        if let Self::Home(f) = self {
            f.prepare(view, cx);
        }
    }
    pub fn initialize(self, app: &mut App) {
        if let Self::Home(f) = self {
            f.initialize(app);
        }
    }
    pub fn render(
        self,
        view: &Desktop,
        window: &Window,
        cx: &Context<Desktop>,
    ) -> gpui::Stateful<Div> {
        match self {
            Self::Day(f) => f.render(view, window, cx),
            Self::Home(f) => f.render(view, window, cx),
            Self::Project(f) => f.render(view, window, cx),
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub(super) enum DaySurface {
    Inspector,
    Popover,
}
#[derive(Clone, Copy, Debug)]
pub(super) enum DayState {
    Ready,
    Empty,
    Loading,
    Locked,
    NoSelection,
}
#[derive(Clone, Copy, Debug)]
pub(super) struct DayFixture {
    surface: DaySurface,
    state: DayState,
    pub dark: bool,
}
impl DayFixture {
    pub fn parse(name: &str) -> anyhow::Result<Self> {
        let (name, appearance) = name
            .rsplit_once('-')
            .ok_or_else(|| anyhow::anyhow!("A day fixture needs a light/dark suffix"))?;
        let dark = match appearance {
            "dark" => true,
            "light" => false,
            _ => anyhow::bail!("Day fixture appearance must be light or dark"),
        };
        let (surface, state) = if let Some(state) = name.strip_prefix("inspector-") {
            (
                DaySurface::Inspector,
                match state {
                    "ready" => DayState::Ready,
                    "empty" => DayState::Empty,
                    "loading" => DayState::Loading,
                    "locked" => DayState::Locked,
                    "no-selection" => DayState::NoSelection,
                    _ => anyhow::bail!("Unknown inspector fixture state"),
                },
            )
        } else if let Some(state) = name.strip_prefix("popover-") {
            (
                DaySurface::Popover,
                match state {
                    "ready" => DayState::Ready,
                    "loading" => DayState::Loading,
                    _ => anyhow::bail!("Unknown popover fixture state"),
                },
            )
        } else {
            anyhow::bail!("Day fixture must start with inspector- or popover-");
        };
        Ok(Self {
            surface,
            state,
            dark,
        })
    }
    pub fn size(self) -> gpui::Size<gpui::Pixels> {
        match self.surface {
            DaySurface::Inspector => size(px(400.), px(797.)),
            DaySurface::Popover => size(px(360.), px(400.)),
        }
    }
    pub fn prepare(self, view: &mut Desktop) {
        debug_assert!(view.client.is_none());
        let day = view
            .home
            .selected
            .as_ref()
            .expect("The synthetic calendar pins today")
            .clone();
        let detail = DayDetail::fixture(&day).expect("The synthetic pinned day has detail");
        view.home.days.selected = Reading {
            date: Some(day.date.clone()),
            value: matches!(self.state, DayState::Ready).then_some(detail.clone()),
            loading: matches!(self.state, DayState::Loading),
            error: None,
        };
        view.home.days.overview = Reading {
            date: Some(day.date.clone()),
            value: matches!(self.state, DayState::Ready).then(|| DayOverview::fixture(&detail)),
            ..Default::default()
        };
        if matches!(self.state, DayState::NoSelection) {
            view.home.selected = None;
        } else if let Some(selected) = &mut view.home.selected {
            selected.locked = matches!(self.state, DayState::Locked);
        }
        if matches!(self.surface, DaySurface::Popover) {
            view.hover_anchor = Some(HoverAnchor {
                date: day.date.clone(),
                rect: Rect {
                    x: 16.,
                    y: 194.,
                    width: 12.,
                    height: 12.,
                },
            });
            view.home.days.hovered = Reading {
                date: Some(day.date),
                value: matches!(self.state, DayState::Ready).then_some(detail),
                loading: matches!(self.state, DayState::Loading),
                error: None,
            };
        }
    }
    pub fn render(
        self,
        view: &Desktop,
        window: &Window,
        cx: &Context<Desktop>,
    ) -> gpui::Stateful<Div> {
        let root = div()
            .id("day-parity-fixture")
            .key_context("Tokenstat")
            .track_focus(&view.root_focus)
            .on_action(cx.listener(|view, action: &ExecuteCommand, window, cx| {
                view.command(action.command, window, cx)
            }))
            .size_full()
            .font_family(fonts::INTERFACE)
            .font_weight(FontWeight::NORMAL)
            .text_color(primary(self.dark))
            .bg(palette::BACKGROUND.resolve(self.dark));
        match self.surface {
            DaySurface::Inspector => root.child(view.inspector_body(0., self.dark, cx)),
            DaySurface::Popover => root.child(view.day_popover(window.viewport_size(), self.dark)),
        }
    }
}
