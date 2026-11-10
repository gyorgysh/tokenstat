// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! DesktopHomeEditor working copy, preview, visibility and ordering controls.
//! Platform sheet chrome, AX announcements and motion still need native QA.

use super::home_shared::HomeShared;
use super::*;
use crate::{
    design::{control, modal},
    home::layout::{Preset, Section},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Target {
    Preset(Preset),
    Toggle(Section),
    Up(Section),
    Down(Section),
    Reset,
    Undo,
    Cancel,
    Done,
    Close,
}

fn label(value: impl IntoElement, points: f32, weight: u16, fit: DisplayFit) -> Div {
    text(
        value,
        FontToken {
            points: fit.text(points),
            weight,
        },
    )
}

impl Desktop {
    pub(super) fn cancel_home_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if cx.global::<HomeShared>().preferences_saving {
            return;
        }
        self.home_editor = None;
        self.home_editor_drag_target = None;
        self.root_focus.focus(window);
        cx.notify();
    }
    fn save_home_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if cx.global::<HomeShared>().preferences_saving {
            return;
        }
        let Some(editor) = &mut self.home_editor else {
            return;
        };
        editor.error = None;
        let arrangement = editor.draft.clone();
        let storage = cx.global::<HomeShared>().storage.clone();
        cx.global_mut::<HomeShared>().preferences_saving = true;
        let task = cx.background_executor().spawn(async move {
            storage
                .save(&arrangement)
                .map(|_| arrangement)
                .map_err(|e| format!("{e:#}"))
        });
        let handle = window.window_handle();
        cx.spawn(async move |view, cx| {
            let result = task.await;
            // Done authorizes the apply even if the initiating window closes.
            let _ = cx.update(|cx| {
                let shared = cx.global_mut::<HomeShared>();
                shared.preferences_saving = false;
                match &result {
                    Ok(arrangement) => {
                        let hiding = !shared.layout.hidden.contains(&Section::Limits)
                            && arrangement.hidden.contains(&Section::Limits);
                        shared.layout = arrangement.clone();
                        shared.preferences_error = None;
                        if hiding {
                            shared.reads.hide_all();
                        }
                    }
                    Err(error) => shared.preferences_error = Some(error.clone()),
                }
            });
            let _ = handle.update(cx, |_, window, cx| {
                let _ = view.update(cx, |view, cx| {
                    match result {
                        Ok(_) => {
                            view.home_editor = None;
                            view.home_editor_drag_target = None;
                            view.root_focus.focus(window);
                            view.load_home_plans(false, cx);
                        }
                        Err(error) => {
                            if let Some(editor) = &mut view.home_editor {
                                editor.error = Some(error);
                            }
                        }
                    }
                    cx.notify();
                });
            });
        })
        .detach();
        cx.notify();
    }
    fn editor_targets(&self) -> Vec<Target> {
        let Some(editor) = &self.home_editor else {
            return vec![];
        };
        let mut out = vec![Target::Close];
        out.extend(Preset::ALL.into_iter().map(Target::Preset));
        let visible = editor.draft.visible();
        for (index, section) in visible.iter().copied().enumerate() {
            out.push(Target::Toggle(section));
            if index > 0 {
                out.push(Target::Up(section));
            }
            if index + 1 < visible.len() {
                out.push(Target::Down(section));
            }
        }
        out.extend(
            editor
                .draft
                .order
                .iter()
                .filter(|s| editor.draft.hidden.contains(s))
                .copied()
                .map(Target::Toggle),
        );
        out.push(Target::Reset);
        if editor.before_reset.is_some() {
            out.push(Target::Undo);
        }
        out.extend([Target::Cancel, Target::Done]);
        out
    }
    fn editor_activate(&mut self, target: Target, window: &mut Window, cx: &mut Context<Self>) {
        if cx.global::<HomeShared>().preferences_saving {
            return;
        }
        self.home_editor_target = target;
        if let Some(editor) = &mut self.home_editor {
            editor.focused = match target {
                Target::Toggle(s) | Target::Up(s) | Target::Down(s) => Some(s),
                _ => None,
            };
        }
        match target {
            Target::Cancel | Target::Close => self.cancel_home_editor(window, cx),
            Target::Done => self.save_home_editor(window, cx),
            _ => {
                if let Some(editor) = &mut self.home_editor {
                    match target {
                        Target::Preset(p) => editor.preset(p),
                        Target::Toggle(s) => {
                            editor.toggle(s);
                            editor.focused = Some(s);
                        }
                        Target::Up(s) | Target::Down(s) => {
                            editor.shift(
                                s,
                                if matches!(target, Target::Up(_)) {
                                    -1
                                } else {
                                    1
                                },
                            );
                            self.home_editor_target = Target::Toggle(s);
                        }
                        Target::Reset => editor.reset(),
                        Target::Undo => {
                            editor.undo_reset();
                            self.home_editor_target = Target::Reset;
                        }
                        _ => {}
                    }
                }
            }
        }
        cx.notify();
    }
    pub(super) fn home_editor_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if cx.global::<HomeShared>().preferences_saving {
            return;
        }
        let key = event.keystroke.key.as_str();
        let modifiers = event.keystroke.modifiers;
        match key {
            "escape" => self.cancel_home_editor(window, cx),
            "tab" => {
                let targets = self.editor_targets();
                if !targets.is_empty() {
                    let index = targets
                        .iter()
                        .position(|t| *t == self.home_editor_target)
                        .unwrap_or(0);
                    let next = if modifiers.shift {
                        (index + targets.len() - 1) % targets.len()
                    } else {
                        (index + 1) % targets.len()
                    };
                    self.home_editor_target = targets[next];
                    if let Some(editor) = &mut self.home_editor {
                        editor.focused = match targets[next] {
                            Target::Toggle(s) | Target::Up(s) | Target::Down(s) => Some(s),
                            _ => None,
                        };
                    }
                    cx.notify();
                }
            }
            "up" | "down" if modifiers.platform || modifiers.control => {
                let section = match self.home_editor_target {
                    Target::Toggle(s) | Target::Up(s) | Target::Down(s) => Some(s),
                    _ => None,
                };
                if let (Some(section), Some(editor)) = (section, &mut self.home_editor) {
                    editor.shift(section, if key == "up" { -1 } else { 1 });
                    cx.notify();
                }
            }
            "space" => self.editor_activate(self.home_editor_target, window, cx),
            "enter" => self.editor_activate(Target::Done, window, cx),
            _ => {}
        }
    }
    fn editor_action(&self, target: Target, dark: bool, cx: &Context<Self>) -> gpui::Stateful<Div> {
        let (key, symbol) = match target {
            Target::Reset => (
                "apple.desktophomeeditor.reset_home.99f3f8ce",
                "arrow.clockwise",
            ),
            Target::Undo => (
                "apple.desktophomeeditor.undo_reset.c4961cf5",
                "arrow.uturn.backward",
            ),
            Target::Cancel => ("common.cancel", "xmark"),
            Target::Done => ("common.done", "checkmark"),
            _ => unreachable!("Only sheet actions use the shared button style"),
        };
        let small = matches!(target, Target::Reset | Target::Undo);
        let accent = target == Target::Done;
        let busy = cx.global::<HomeShared>().preferences_saving;
        let color = if accent {
            palette::ACCENT.resolve(dark)
        } else {
            primary(dark)
        };
        div()
            .id(SharedString::from(format!("home-editor-{target:?}")))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .gap(px(if small { 5. } else { 6. }))
            .h(px(if small {
                control::HEIGHT_SMALL
            } else {
                control::HEIGHT
            }))
            .px(px(if small { 9. } else { 13. }))
            .rounded(px(8.))
            .border_1()
            .border_color(if accent {
                palette::ACCENT.opacity(0.35).resolve(dark)
            } else {
                palette::BORDER.resolve(dark)
            })
            .bg(if accent {
                palette::ACCENT_SOFT.resolve(dark)
            } else {
                palette::PANEL.resolve(dark)
            })
            .when(self.home_editor_target == target, |d| {
                d.border_color(palette::ACCENT.resolve(dark))
            })
            .text_color(color)
            .cursor_pointer()
            .when(busy, |d| d.opacity(0.42))
            .hover(|s| s.bg(palette::ROW_HIGHLIGHT.resolve(dark)))
            .active(|s| s.opacity(0.85))
            .child(icon(symbol, if small { 11. } else { 12. }, color))
            .child(presentation::system_text(
                l(key),
                if small { 12. } else { 13. },
                500,
                cx,
            ))
            .on_click(
                cx.listener(move |view, _, window, cx| view.editor_activate(target, window, cx)),
            )
    }
    fn editor_preview(&self, dark: bool) -> Div {
        let sections = self.home_editor.as_ref().unwrap().draft.visible();
        let mut preview = div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(4.))
            .p(px(7.))
            .rounded(px(10.))
            .border_1()
            .border_color(palette::BORDER.resolve(dark))
            .bg(palette::BACKGROUND.resolve(dark))
            .child(
                div()
                    .mb(px(3.))
                    .w(px(84.))
                    .h(px(8.))
                    .rounded_full()
                    .bg(palette::ACCENT.opacity(0.35).resolve(dark)),
            );
        if sections.is_empty() {
            return preview.child(
                div()
                    .min_h(px(44.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(
                        label(
                            l("apple.homelayoutpreview.your_home_is_clear.9ae93db2"),
                            10.,
                            400,
                            self.layout.fit,
                        )
                        .text_color(secondary(dark)),
                    ),
            );
        }
        for section in sections {
            preview = preview.child(
                div()
                    .h(px(if section == Section::Activity {
                        30.
                    } else {
                        20.
                    }))
                    .flex_none()
                    .w_full()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .px(px(6.))
                    .rounded(px(5.))
                    .bg(palette::ACCENT_SOFT.resolve(dark))
                    .child(
                        div()
                            .w(px(12.))
                            .flex_none()
                            .flex()
                            .justify_center()
                            .child(icon(section.symbol(), 8., palette::ACCENT.resolve(dark))),
                    )
                    .child(
                        text(
                            l(section.label_key()),
                            FontToken {
                                points: 9.,
                                weight: 500,
                            },
                        )
                        .text_color(secondary(dark))
                        .truncate(),
                    ),
            );
        }
        preview
    }
    fn editor_detail(&self, section: Section, cx: &App) -> String {
        let key = match section {
            Section::Continue
                if self
                    .work_reading(cx)
                    .is_some_and(|w| w.recent_rows().is_empty()) =>
            {
                "apple.homeview.appears_after_you_open_a_conversation.c00808b0"
            }
            Section::Pinned
                if self
                    .work_reading(cx)
                    .is_some_and(|w| w.pin_rows().is_empty()) =>
            {
                "apple.homeview.pin_a_folder_from_the_sidebar_or_a_convers.33c68474"
            }
            Section::Machines if self.account().is_some_and(|a| a.machines.is_empty()) => {
                "apple.homeview.appears_when_your_account_has_linked_devic.8a84c464"
            }
            Section::Limits
                if {
                    let reads = &cx.global::<HomeShared>().reads;
                    let plans = reads.home(self.plan_reader);
                    plans.has_loaded
                        && reads.visible().is_empty()
                        && plans.by_source.is_empty()
                        && !plans.loading()
                        && plans.error().is_none()
                } =>
            {
                "apple.homeview.appears_when_a_connected_plan_has_usage_to.fd5f5a3e"
            }
            _ => section.detail_key(),
        };
        l(key)
    }
    fn editor_row(
        &self,
        section: Section,
        on: bool,
        dark: bool,
        cx: &Context<Self>,
    ) -> gpui::Stateful<Div> {
        let editor = self.home_editor.as_ref().unwrap();
        let visible = editor.draft.visible();
        let busy = cx.global::<HomeShared>().preferences_saving;
        let mut row = div()
            .id(SharedString::from(format!("home.editor.{}", section.id())))
            .w_full()
            .flex_none()
            .flex()
            .items_center()
            .gap(px(8.))
            .p(px(7.))
            .rounded(px(14.))
            .bg(palette::PANEL.resolve(dark))
            .border_1()
            .border_color(
                if editor.focused == Some(section) || self.home_editor_drag_target == Some(section)
                {
                    palette::ACCENT.resolve(dark)
                } else {
                    palette::BORDER.resolve(dark)
                },
            );
        if on {
            row = row.child(
                div()
                    .id(SharedString::from(format!("home-grip-{}", section.id())))
                    .w(px(24.))
                    .h(px(36.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor(gpui::CursorStyle::OpenHand)
                    .child(icon("line.3.horizontal", 13., secondary(dark)))
                    .on_drag(section, move |s, _, _, cx| {
                        cx.new(|_| Tooltip(l(s.label_key())))
                    }),
            );
        }
        row = row.child(
            div()
                .id(SharedString::from(format!("home-toggle-{}", section.id())))
                .flex_1()
                .min_w_0()
                .flex()
                .items_center()
                .gap(px(12.))
                .cursor_pointer()
                .child(
                    div()
                        .w(px(24.))
                        .flex_none()
                        .flex()
                        .justify_center()
                        .child(icon(section.symbol(), 14., palette::ACCENT.resolve(dark))),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .gap(px(3.))
                        .child(label(l(section.label_key()), 12., 500, self.layout.fit))
                        .child(
                            label(self.editor_detail(section, cx), 10., 400, self.layout.fit)
                                .text_color(secondary(dark)),
                        ),
                )
                .child(
                    div()
                        .size(px(26.))
                        .flex_none()
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded_full()
                        .border(px(1.5))
                        .border_color(if on {
                            palette::ACCENT.resolve(dark)
                        } else {
                            secondary(dark).opacity(0.4)
                        })
                        .when(on, |d| {
                            d.bg(palette::ACCENT.resolve(dark)).child(icon(
                                "checkmark",
                                12.,
                                rgb(0xffffff).into(),
                            ))
                        }),
                )
                .on_click(cx.listener(move |view, _, window, cx| {
                    view.editor_activate(Target::Toggle(section), window, cx)
                })),
        );
        if on {
            let mut arrows = div().flex_none().flex().flex_col().gap(px(2.));
            for (target, symbol, enabled) in [
                (
                    Target::Up(section),
                    "chevron.up",
                    visible.first() != Some(&section),
                ),
                (
                    Target::Down(section),
                    "chevron.down",
                    visible.last() != Some(&section),
                ),
            ] {
                arrows = arrows.child(
                    div()
                        .id(SharedString::from(format!("home-arrow-{target:?}")))
                        .w(px(28.))
                        .h(px(22.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded(px(4.))
                        .when(self.home_editor_target == target, |d| {
                            d.bg(palette::ACCENT_SOFT.resolve(dark))
                        })
                        .when(!enabled || busy, |d| d.opacity(0.42))
                        .when(enabled && !busy, |d| {
                            d.cursor_pointer()
                                .on_click(cx.listener(move |view, _, window, cx| {
                                    view.editor_activate(target, window, cx)
                                }))
                        })
                        .child(icon(symbol, 12., palette::ACCENT.resolve(dark))),
                );
            }
            row = row.child(arrows);
        }
        row.on_drag_move(
            cx.listener(move |view, event: &gpui::DragMoveEvent<Section>, _, cx| {
                if cx.global::<HomeShared>().preferences_saving {
                    return;
                }
                if event.bounds.contains(&event.event.position) {
                    if view.home_editor_drag_target != Some(section) {
                        let source = *event.drag(cx);
                        if let Some(editor) = &mut view.home_editor {
                            editor.drag(source, section);
                        }
                        view.home_editor_drag_target = Some(section);
                        cx.notify();
                    }
                } else if view.home_editor_drag_target == Some(section) {
                    view.home_editor_drag_target = None;
                    cx.notify();
                }
            }),
        )
        .on_drop(cx.listener(|view, _: &Section, _, cx| {
            view.home_editor_drag_target = None;
            cx.notify();
        }))
    }
    pub(super) fn render_home_editor(
        &self,
        viewport: gpui::Size<gpui::Pixels>,
        dark: bool,
        cx: &Context<Self>,
    ) -> gpui::Stateful<Div> {
        let editor = self.home_editor.as_ref().unwrap();
        let fit = self.layout.fit;
        let mut presets = div()
            .w_full()
            .flex()
            .gap(px(4.))
            .p(px(2.))
            .rounded(px(10.))
            .border_1()
            .border_color(palette::BORDER.resolve(dark))
            .bg(palette::PANEL.resolve(dark));
        for preset in Preset::ALL {
            let target = Target::Preset(preset);
            let selected = editor.draft.preset == Some(preset);
            let color = if selected {
                palette::ACCENT.resolve(dark)
            } else {
                palette::CONTROL_GLYPH.resolve(dark)
            };
            presets = presets.child(
                div()
                    .id(SharedString::from(format!("home-preset-{}", preset.id())))
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .gap(px(4.))
                    .px(px(12.))
                    .py(px(6.))
                    .rounded(px(8.))
                    .border_1()
                    .border_color(if self.home_editor_target == target {
                        palette::ACCENT.resolve(dark)
                    } else {
                        gpui::transparent_black()
                    })
                    .when(selected, |d| d.bg(palette::ACCENT_SOFT.resolve(dark)))
                    .hover(|s| s.bg(palette::ROW_HIGHLIGHT.opacity(0.7).resolve(dark)))
                    .cursor_pointer()
                    .text_color(color)
                    .child(icon("square.grid.2x2", 11., color))
                    .child(presentation::system_text(
                        l(preset.label_key()),
                        12.,
                        500,
                        cx,
                    ))
                    .on_click(cx.listener(move |view, _, window, cx| {
                        view.editor_activate(target, window, cx)
                    })),
            );
        }
        let mut body = div().w_full().flex().flex_col().gap(px(12.)).p(px(modal::BODY_PADDING))
            .child(presets).child(self.editor_preview(dark))
            .child(label(l("apple.desktophomeeditor.visible_drag_the_grip_or_use_the_arrows_to.a21c0f32"), 10., 500, fit).text_color(secondary(dark)));
        if editor.draft.visible().is_empty() {
            body = body.child(
                label(
                    l("apple.desktophomeeditor.your_home_is_clear_turn_a_section_back_on.3f39aedb"),
                    12.,
                    400,
                    fit,
                )
                .text_color(secondary(dark)),
            );
        }
        for section in editor.draft.visible() {
            body = body.child(self.editor_row(section, true, dark, cx));
        }
        if !editor.draft.hidden.is_empty() {
            body = body.child(
                label(l("apple.desktophomeeditor.hidden.7e6fefff"), 10., 500, fit)
                    .text_color(secondary(dark)),
            );
            for section in &editor.draft.order {
                if editor.draft.hidden.contains(section) {
                    body = body.child(self.editor_row(*section, false, dark, cx));
                }
            }
        }
        if !editor.announcement.is_empty() {
            body = body.child(
                label(editor.announcement.clone(), 10., 400, fit)
                    .text_color(palette::ACCENT.resolve(dark)),
            );
        }
        if let Some(error) = &editor.error {
            body = body.child(
                label(error.clone(), 12., 400, fit).text_color(palette::DANGER.resolve(dark)),
            );
        }
        let mut reset = div()
            .flex()
            .gap(px(8.))
            .child(self.editor_action(Target::Reset, dark, cx));
        if editor.before_reset.is_some() {
            reset = reset.child(self.editor_action(Target::Undo, dark, cx));
        }
        body = body.child(reset);
        let sheet = div().id("home-editor-sheet").occlude().track_focus(&self.home_editor_focus)
            .w(px(600f32.min(f32::from(viewport.width)))).h(px(730f32.min(f32::from(viewport.height))))
            .flex().flex_col().rounded(px(12.)).overflow_hidden().shadow_lg().bg(palette::BACKGROUND.resolve(dark))
            .child(div().flex_none().min_h(px(modal::HEADER_MIN_HEIGHT)).w_full().flex().items_center().gap(px(12.)).px(px(20.)).py(px(12.)).bg(palette::SIDEBAR.resolve(dark))
                .child(div().size(px(modal::ICON_SEAT)).flex_none().flex().items_center().justify_center().rounded(px(9.)).bg(palette::ACCENT_SOFT.resolve(dark)).child(icon("square.grid.2x2", 18., palette::ACCENT.resolve(dark))))
                .child(div().flex_1().min_w_0().flex().flex_col().gap(px(4.))
                    .child(label(l("apple.desktophomeeditor.customize_home.642cec6e"), 15., 600, fit))
                    .child(label(l("apple.desktophomeeditor.keep_what_matters_close_this_arrangement_s.bc3b0457"), 10., 400, fit).text_color(palette::CONTROL_GLYPH.resolve(dark))))
                .child(div().id("home-editor-close").size(px(30.)).flex_none().flex().items_center().justify_center().rounded(px(8.)).cursor_pointer()
                    .when(self.home_editor_target == Target::Close, |d| d.bg(palette::CONTROL_SEAT.resolve(dark)))
                    .child(icon("xmark", 12., palette::CONTROL_GLYPH.resolve(dark)))
                    .on_click(cx.listener(|view, _, window, cx| view.cancel_home_editor(window, cx)))))
            .child(div().h(px(1.)).w_full().flex_none().bg(palette::BORDER.resolve(dark)))
            .child(div().id("home-editor-body").flex_1().min_h_0().w_full().overflow_y_scroll().child(body))
            .child(div().h(px(1.)).w_full().flex_none().bg(palette::BORDER.resolve(dark)))
            .child(div().h(px(modal::FOOTER_HEIGHT)).w_full().flex_none().flex().items_center().gap(px(8.)).px(px(20.)).bg(palette::SIDEBAR.resolve(dark))
                .child(self.editor_action(Target::Cancel, dark, cx)).child(div().flex_1())
                .child(self.editor_action(Target::Done, dark, cx)));
        div()
            .id("home-editor-backdrop")
            .absolute()
            .inset_0()
            .occlude()
            .flex()
            .items_center()
            .justify_center()
            .bg(gpui::black().opacity(0.25))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|view, _, window, cx| view.cancel_home_editor(window, cx)),
            )
            .child(sheet.on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation()))
    }
}
