// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! App-owned design values come from the current SwiftUI implementation at build time.

/// Logical light/dark colours preserve alpha for chrome and selection overlays.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AdaptiveColor {
    pub light: (u32, f32),
    pub dark: (u32, f32),
}

impl AdaptiveColor {
    pub const fn new(light: u32, light_alpha: f32, dark: u32, dark_alpha: f32) -> Self {
        Self {
            light: (light, light_alpha),
            dark: (dark, dark_alpha),
        }
    }

    /// Overlay alpha multiplies the source alpha, matching SwiftUI opacity.
    pub const fn opacity(self, alpha: f32) -> Self {
        Self::new(
            self.light.0,
            self.light.1 * alpha,
            self.dark.0,
            self.dark.1 * alpha,
        )
    }

    #[cfg(all(feature = "gui", any(target_os = "linux", target_os = "macos")))]
    pub fn resolve(self, dark: bool) -> gpui::Hsla {
        let (value, alpha) = if dark { self.dark } else { self.light };
        let mut colour = gpui::rgb(value);
        colour.a = alpha;
        colour.into()
    }
}

/// Desktop logical points and real font weights, rather than framework text presets.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FontToken {
    pub points: f32,
    pub weight: u16,
}

impl FontToken {
    /// SwiftUI's native default line box rounds ascent and descent separately.
    /// GPUI defaults to phi spacing, which makes every multiline/card row taller.
    pub fn line_height(self, mono: bool) -> f32 {
        let [ascent, descent, leading] = if mono {
            fonts::MONO_METRICS
        } else {
            fonts::INTERFACE_METRICS
        };
        let size = f64::from(self.points);
        ((ascent * size).round() + (-descent * size).round() + (leading * size).round()) as f32
    }
}

include!(concat!(env!("OUT_DIR"), "/swiftui_contract.rs"));
