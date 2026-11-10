// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Source native confirmation content in GPUI. Its system glass backdrop,
//! composited colour, active-window focus and Linux pixels remain unaccepted.

use super::*;
use crate::confirmation::{Choice, Content, Interaction, Role, geometry as g};
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};
pub(super) type Measurements = Arc<Mutex<BTreeMap<String, [f32; 4]>>>;
fn observe(name: &'static str, measurements: Measurements) -> impl IntoElement {
    gpui::canvas(
        move |bounds, _, _| {
            if let Ok(mut rows) = measurements.lock() {
                rows.insert(
                    name.into(),
                    [
                        bounds.origin.x.into(),
                        bounds.origin.y.into(),
                        bounds.size.width.into(),
                        bounds.size.height.into(),
                    ],
                );
            }
        },
        |_, _, _, _| {},
    )
    .absolute()
    .inset_0()
}

pub(super) struct ConfirmationView {
    pub content: Content,
    pub interaction: Interaction,
    pub focus: FocusHandle,
    pub forced_dark: Option<bool>,
    pub panel_only: bool,
    pub measurements: Option<Measurements>,
}
impl ConfirmationView {
    pub fn new(content: Content, cx: &mut Context<Self>) -> Self {
        let interaction = Interaction::for_content(&content);
        Self {
            content,
            interaction,
            focus: cx.focus_handle(),
            forced_dark: None,
            panel_only: false,
            measurements: None,
        }
    }
    fn respond(&mut self, choice: Choice, cx: &mut Context<Self>) {
        if let Some(choice) = self.interaction.complete(choice) {
            cx.emit(choice);
            cx.notify();
        }
    }
}
impl gpui::EventEmitter<Choice> for ConfirmationView {}
impl Render for ConfirmationView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let dark = self.forced_dark.unwrap_or_else(|| {
            matches!(
                window.appearance(),
                WindowAppearance::Dark | WindowAppearance::VibrantDark
            )
        });
        // These flat native semantic fills are provisional. AppKit composites
        // a separate regular glass window; a content-only bitmap omits it.
        let surface = rgb(if dark { 0x1e1e1e } else { 0xffffff });
        let native_text = if dark { gpui::white() } else { gpui::black() }.opacity(216. / 255.);
        let mut buttons = div()
            .w_full()
            .flex()
            .gap(px(g::BUTTON_GAP))
            .px(px(g::BUTTON_INSET));
        for button in &self.content.buttons {
            let choice = button.choice;
            let color = if button.role == Role::Destructive {
                rgb(if dark { 0xff4245 } else { 0xff383c }).into()
            } else {
                native_text
            };
            let selected = self.interaction.show_focus && self.interaction.focused == Some(choice);
            buttons = buttons.child(
                div()
                    .id(SharedString::from(format!("confirmation-{choice:?}")))
                    .flex_1()
                    .h(px(g::BUTTON_HEIGHT))
                    .rounded(px(g::BUTTON_CORNER))
                    .relative()
                    .when_some(self.measurements.clone(), |row, m| {
                        row.child(observe(
                            if choice == Choice::Cancel {
                                "cancel"
                            } else {
                                "remove"
                            },
                            m,
                        ))
                    })
                    .bg(if dark {
                        gpui::white().opacity(0.247)
                    } else {
                        gpui::white()
                    })
                    .when(selected, |row| {
                        row.child(
                            div()
                                .absolute()
                                .inset_0()
                                .rounded(px(g::BUTTON_CORNER))
                                .border_2()
                                .border_color(
                                    gpui::Hsla::from(rgb(if dark { 0x1aa9ff } else { 0x0067f4 }))
                                        .opacity(127. / 255.),
                                ),
                        )
                    })
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_default()
                    .active(|style| style.opacity(0.75))
                    .child(
                        presentation::system_text(button.title.clone(), 13., 400, cx)
                            .text_color(color),
                    )
                    .on_click(cx.listener(move |view, _, _, cx| view.respond(choice, cx))),
            );
        }
        let panel = div()
            .relative()
            .when_some(self.measurements.clone(), |row, m| {
                row.child(observe("panel", m))
            })
            .w(px(g::WIDTH))
            .flex()
            .flex_col()
            .rounded(px(g::CORNER))
            .overflow_hidden()
            .bg(surface)
            .child(
                div()
                    .w_full()
                    .px(px(g::TEXT_INSET))
                    .pt(px(g::TEXT_INSET))
                    .flex()
                    .flex_col()
                    .gap(px(g::TITLE_GAP))
                    .child(
                        presentation::system_text(self.content.title.clone(), 13., 700, cx)
                            .text_color(native_text)
                            .relative()
                            .when_some(self.measurements.clone(), |row, m| {
                                row.child(observe("title", m))
                            }),
                    )
                    .child(
                        presentation::system_text(self.content.message.clone(), 13., 400, cx)
                            .text_color(native_text)
                            .relative()
                            .when_some(self.measurements.clone(), |row, m| {
                                row.child(observe("message", m))
                            }),
                    ),
            )
            .child(div().h(px(g::BUTTONS_TOP)).flex_none())
            .child(buttons)
            .child(div().h(px(g::BUTTON_INSET)).flex_none());
        div()
            .id("source-confirmation")
            .absolute()
            .inset_0()
            .size_full()
            .occlude()
            .cursor_default()
            .track_focus(&self.focus)
            .key_context("TokenstatConfirmation")
            .flex()
            .items_center()
            .justify_center()
            .when(!self.panel_only, |view| {
                view.bg(gpui::black().opacity(0.25))
            })
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|_, _, _, cx| cx.stop_propagation()),
            )
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(|_, _, _, cx| cx.stop_propagation()),
            )
            .on_key_down(cx.listener(|view, event: &KeyDownEvent, _, cx| {
                if !event.keystroke.modifiers.platform
                    && !event.keystroke.modifiers.control
                    && !event.keystroke.modifiers.alt
                {
                    if let Some(choice) = view
                        .interaction
                        .key(&event.keystroke.key, event.keystroke.modifiers.shift)
                    {
                        cx.emit(choice);
                    }
                    cx.notify();
                }
                cx.stop_propagation();
            }))
            .child(panel)
    }
}
