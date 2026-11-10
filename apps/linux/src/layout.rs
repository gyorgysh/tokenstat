// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Logical geometry follows DisplayFit and RootView, independently of pixel scale.

use crate::design::{display_fit, shell, shell_layout, shell_thresholds, workbench};
use crate::navigation::Route;

/// The visible screen size controls design fit. Window resizing is a separate input.
#[derive(Clone, Copy, Debug)]
pub struct DisplayFit {
    pub factor: f32,
}

impl DisplayFit {
    pub fn for_screen(width: f32, height: f32) -> Self {
        let factor = (width / display_fit::REFERENCE_WIDTH)
            .min(height / display_fit::REFERENCE_HEIGHT)
            .clamp(display_fit::FLOOR, 1.0);
        Self { factor }
    }
    pub fn scale(self, points: f32) -> f32 {
        points * self.factor
    }
    pub fn text(self, points: f32) -> f32 {
        points * self.factor.max(display_fit::TEXT_FLOOR)
    }
}

/// Persistent pane choices must survive automatic collapse and later widening.
#[derive(Clone, Debug)]
pub struct ShellLayout {
    pub fit: DisplayFit,
    pub floating_chrome: bool,
    pub sidebar_width: f32,
    pub inspector_width: f32,
    pub sidebar_chosen: bool,
    pub sidebar_pinned: bool,
    pub sidebar_overlay: bool,
    pub inspector_chosen: bool,
    pub inspector_overlay: bool,
    pub inspector_held_by_press: bool,
}

impl Default for ShellLayout {
    fn default() -> Self {
        Self {
            fit: DisplayFit::for_screen(
                display_fit::REFERENCE_WIDTH,
                display_fit::REFERENCE_HEIGHT,
            ),
            floating_chrome: true,
            sidebar_width: shell::SIDEBAR_DEFAULT,
            inspector_width: shell::INSPECTOR_DEFAULT,
            sidebar_chosen: true,
            sidebar_pinned: false,
            sidebar_overlay: false,
            inspector_chosen: true,
            inspector_overlay: false,
            inspector_held_by_press: false,
        }
    }
}

impl ShellLayout {
    pub fn panel_inset(&self) -> f32 {
        if self.floating_chrome {
            shell_layout::PANEL_INSET_FLOATING
        } else {
            shell_layout::PANEL_INSET_FLAT
        }
    }

    pub fn rail_extent(&self) -> f32 {
        shell::RAIL_WIDTH
            + if self.floating_chrome {
                self.panel_inset() * 2.0
            } else {
                6.0
            }
    }

    /// Tools beside chat receive their minimum reading space before the sidebar.
    pub fn sidebar_fits(&self, width: f32, companion_width: Option<f32>) -> bool {
        match companion_width {
            Some(tool) => {
                width
                    >= self.rail_extent()
                        + self.sidebar_width
                        + workbench::DETAIL_MINIMUM
                        + workbench::DIVIDER
                        + tool.max(workbench::TOOL_MINIMUM)
            }
            None => width >= self.fit.text(shell_thresholds::WIDTH_FOR_SIDEBAR),
        }
    }

    pub fn shows_sidebar(&self, width: f32, companion_width: Option<f32>) -> bool {
        self.sidebar_chosen && (width <= 0.0 || self.sidebar_fits(width, companion_width))
    }

    pub fn inspector_fits(&self, width: f32, companion_width: Option<f32>) -> bool {
        let sidebar = if self.shows_sidebar(width, companion_width) {
            self.sidebar_width
        } else {
            0.0
        };
        width
            >= self.rail_extent()
                + sidebar
                + self.fit.text(shell_thresholds::COMFORT_DETAIL)
                + self.inspector_width
    }

    pub fn shows_inspector(&self, route: &Route, width: f32, companion_width: Option<f32>) -> bool {
        route.has_inspector()
            && self.inspector_chosen
            && self.inspector_fits(width, companion_width)
    }

    pub fn toggle_sidebar(&mut self, width: f32, companion_width: Option<f32>) {
        self.sidebar_overlay = false;
        if width > 0.0 && !self.sidebar_fits(width, companion_width) {
            self.sidebar_pinned = !self.sidebar_pinned;
            self.sidebar_overlay = self.sidebar_pinned;
            self.sidebar_chosen = false;
        } else {
            self.sidebar_chosen = !self.sidebar_chosen;
            self.sidebar_pinned = false;
        }
    }

    /// The ordinary inspector toggle from RootView; workspace companions have
    /// their own retained workbench state and must not use this path.
    pub fn toggle_inspector(&mut self, route: &Route, width: f32) {
        if !route.has_inspector() {
            return;
        }
        if self.inspector_chosen {
            self.close_inspector();
        } else {
            self.inspector_chosen = true;
            if !self.inspector_fits(width, None) {
                self.inspector_overlay = true;
                self.inspector_held_by_press = true;
            }
        }
    }

    pub fn close_inspector(&mut self) {
        self.inspector_chosen = false;
        self.inspector_overlay = false;
        self.inspector_held_by_press = false;
    }

    /// A newly possible column adopts an explicitly pinned floating sidebar.
    pub fn apply_width(&mut self, width: f32, companion_width: Option<f32>) {
        if self.sidebar_fits(width, companion_width) {
            if self.sidebar_pinned {
                self.sidebar_chosen = true;
            }
            self.sidebar_pinned = false;
            self.sidebar_overlay = false;
        }
        if self.inspector_fits(width, companion_width) {
            self.inspector_overlay = false;
            self.inspector_held_by_press = false;
        }
    }

    /// Commit only at drag end, preserving stored values during intermediate layout.
    pub fn commit_sidebar_width(&mut self, width: f32) {
        self.sidebar_width = if width.is_finite() {
            width.clamp(shell_layout::SIDEBAR_RANGE.0, shell_layout::SIDEBAR_RANGE.1)
        } else {
            shell::SIDEBAR_DEFAULT
        };
    }

    pub fn commit_inspector_width(&mut self, width: f32) {
        self.inspector_width = if width.is_finite() {
            width.clamp(
                shell_layout::INSPECTOR_RANGE.0,
                shell_layout::INSPECTOR_RANGE.1,
            )
        } else {
            shell::INSPECTOR_DEFAULT
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn automatic_collapse_does_not_spend_a_pane_preference() {
        let mut layout = ShellLayout::default();
        assert!(layout.shows_sidebar(1500.0, None));
        layout.apply_width(720.0, None);
        assert!(!layout.shows_sidebar(720.0, None));
        assert!(layout.sidebar_chosen);
        layout.apply_width(1500.0, None);
        assert!(layout.shows_sidebar(1500.0, None));
        layout.toggle_sidebar(720.0, None);
        assert!(layout.sidebar_pinned && layout.sidebar_overlay);
        assert!(!layout.shows_sidebar(720.0, None));
        layout.apply_width(1500.0, None);
        assert!(layout.shows_sidebar(1500.0, None));
        assert!(!layout.sidebar_pinned && !layout.sidebar_overlay);
    }

    #[test]
    fn hiding_the_sidebar_makes_room_without_changing_inspector_choice() {
        let mut layout = ShellLayout::default();
        let route = Route::default();
        assert!(!layout.shows_inspector(&route, 1300.0, None));
        layout.toggle_sidebar(1300.0, None);
        assert!(layout.shows_inspector(&route, 1300.0, None));
        assert!(layout.inspector_chosen);
    }
}
