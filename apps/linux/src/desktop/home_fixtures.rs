// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Fixed-size offline Home components, using the same view as the real shell.

use super::home_shared::HomeShared;
use super::*;

#[derive(Clone, Copy, Debug)]
pub(super) struct HomeFixture {
    surface: Surface,
    populated: bool,
    dark: bool,
}
#[derive(Clone, Copy, Debug)]
enum Surface {
    Machines,
    Continue,
    Pinned,
    GettingStartedReady,
    GettingStartedScanning,
    GettingStartedCooldown,
    GettingStartedConnected,
    InsightsAccountReady,
    InsightsAccountEmpty,
    InsightsAccountError,
    InsightsAccountLoading,
}
impl HomeFixture {
    pub fn parse(name: &str) -> anyhow::Result<Self> {
        let (state, appearance) = name
            .rsplit_once('-')
            .ok_or_else(|| anyhow::anyhow!("Home fixtures need a light/dark suffix"))?;
        let dark = match appearance {
            "light" => false,
            "dark" => true,
            _ => anyhow::bail!("Home fixture appearance must be light or dark"),
        };
        let (surface, populated) = match state {
            "machines-ready" => (Surface::Machines, true),
            "machines-empty" => (Surface::Machines, false),
            "continue-ready" => (Surface::Continue, true),
            "continue-empty" => (Surface::Continue, false),
            "pinned-ready" => (Surface::Pinned, true),
            "pinned-empty" => (Surface::Pinned, false),
            "getting-started-ready" => (Surface::GettingStartedReady, false),
            "getting-started-scanning" => (Surface::GettingStartedScanning, false),
            "getting-started-cooldown" => (Surface::GettingStartedCooldown, false),
            "getting-started-connected" => (Surface::GettingStartedConnected, true),
            "insights-account-ready" => (Surface::InsightsAccountReady, true),
            "insights-account-empty" => (Surface::InsightsAccountEmpty, false),
            "insights-account-error" => (Surface::InsightsAccountError, false),
            "insights-account-loading" => (Surface::InsightsAccountLoading, false),
            _ => anyhow::bail!("Unknown Home fixture surface or state"),
        };
        Ok(Self {
            surface,
            populated,
            dark,
        })
    }
    pub fn size(self) -> gpui::Size<gpui::Pixels> {
        match self.surface {
            Surface::GettingStartedReady
            | Surface::GettingStartedScanning
            | Surface::GettingStartedCooldown
            | Surface::GettingStartedConnected => size(px(520.), px(600.)),
            Surface::InsightsAccountReady
            | Surface::InsightsAccountEmpty
            | Surface::InsightsAccountError
            | Surface::InsightsAccountLoading => size(px(800.), px(640.)),
            Surface::Machines => size(px(400.), px(220.)),
            _ => size(px(400.), px(360.)),
        }
    }
    pub fn initialize(self, app: &mut App) {
        let shared = app.global_mut::<HomeShared>();
        let mut account = DesktopData::fixture().account.expect("synthetic account");
        account.signed_in = !matches!(
            self.surface,
            Surface::GettingStartedReady
                | Surface::GettingStartedScanning
                | Surface::GettingStartedCooldown
        );
        account.handle = Some("fixture".into());
        account.machines = if self.populated {
            crate::devices::Machine::fixture()
        } else {
            vec![]
        };
        let ticket = shared.account.begin();
        shared.accept_account(ticket, Ok(account));
        let mut work = crate::home::work::HomeWork::fixture();
        if !self.populated {
            work.recent.clear();
            work.pins.clear();
        }
        shared.work = Some(work);
        shared.reads = crate::home::plans::Reads::fixture_for_owner(
            shared.clock_ms,
            shared.account.owner.generation(),
        );
    }
    pub fn prepare(self, view: &mut Desktop, cx: &mut Context<Desktop>) {
        view.scanner.scanning = matches!(self.surface, Surface::GettingStartedScanning);
        view.scanner.cooling_down = matches!(self.surface, Surface::GettingStartedCooldown);
        let fixture = match self.surface {
            Surface::InsightsAccountReady => Some(super::insights_account::FixtureState::Ready),
            Surface::InsightsAccountEmpty => Some(super::insights_account::FixtureState::Empty),
            Surface::InsightsAccountError => Some(super::insights_account::FixtureState::Error),
            Surface::InsightsAccountLoading => Some(super::insights_account::FixtureState::Loading),
            _ => None,
        };
        if let Some(fixture) = fixture {
            view.navigate(
                Route::Global {
                    section: GlobalSection::Insights,
                },
                cx,
            );
            view.prepare_account_insights_fixture(fixture);
        }
    }
    pub fn render(
        self,
        view: &mut Desktop,
        window: &mut Window,
        cx: &mut Context<Desktop>,
    ) -> gpui::Stateful<Div> {
        let content = if view.navigation.route == Route::default() {
            match self.surface {
                Surface::Machines => view.home_devices(self.dark, cx),
                Surface::Continue => view.home_continue(self.dark, cx),
                Surface::Pinned => view.home_pins(self.dark, cx),
                Surface::GettingStartedReady
                | Surface::GettingStartedScanning
                | Surface::GettingStartedCooldown
                | Surface::GettingStartedConnected => view.getting_started(self.dark, cx),
                Surface::InsightsAccountReady
                | Surface::InsightsAccountEmpty
                | Surface::InsightsAccountError
                | Surface::InsightsAccountLoading => view.account_insights_content(self.dark, cx),
            }
        } else {
            view.content(window.viewport_size().width.into(), self.dark, window, cx)
        };
        let mut root = div()
            .id("home-parity-fixture")
            .key_context("Tokenstat")
            .track_focus(&view.root_focus)
            .on_action(cx.listener(|view, action: &ExecuteCommand, window, cx| {
                view.command(action.command, window, cx)
            }))
            .on_key_down(cx.listener(|view, event, window, cx| view.key_down(event, window, cx)))
            .size_full()
            .relative()
            .flex()
            .flex_col()
            .justify_center()
            .font_family(fonts::INTERFACE)
            .font_weight(FontWeight::NORMAL)
            .text_color(primary(self.dark))
            .bg(palette::BACKGROUND.resolve(self.dark))
            .child(content);
        if let Some(gap) = view.preview_gap(window.viewport_size().width.into(), self.dark, cx) {
            root = root.child(gap);
        }
        root
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn home_component_fixtures_accept_only_known_states_and_appearances() {
        for name in [
            "machines-ready-light",
            "machines-empty-dark",
            "getting-started-ready-light",
            "getting-started-scanning-dark",
            "getting-started-cooldown-light",
            "getting-started-connected-dark",
            "insights-account-ready-light",
            "insights-account-empty-dark",
            "insights-account-error-light",
            "insights-account-loading-dark",
        ] {
            assert!(HomeFixture::parse(name).is_ok());
        }
        for name in ["machines-ready", "machines-ready-blue", "other-ready-dark"] {
            assert!(HomeFixture::parse(name).is_err());
        }
    }
}
