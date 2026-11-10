// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The original Continue and Pinned work card anatomy. Full chat reveal,
//! draft-aware title projection and the saved reader remain integration gaps.

use super::*;
use super::{day_view::feature, home_panels::card_header};
use crate::home::work::{OpenTarget, Pin, RecentRow};

impl Desktop {
    fn work_label(&self, value: String, points: f32, weight: u16) -> Div {
        text(
            value,
            FontToken {
                points: self.layout.fit.text(points),
                weight,
            },
        )
    }
    pub(super) fn home_continue(&self, dark: bool, cx: &Context<Self>) -> Div {
        let Some(work) = self.work_reading(cx) else {
            return self.work_gap(crate::home::layout::Section::Continue, dark);
        };
        let destinations = work.recent_rows();
        if destinations.is_empty() {
            return div();
        }
        let mut rows = div().w_full().flex().flex_col();
        for (index, destination) in destinations.iter().enumerate() {
            rows = rows.child(self.recent_row(index, destination.clone(), dark, cx));
            if destination.reference != destinations[destinations.len() - 1].reference {
                rows = rows.child(work_rule(dark));
            }
        }
        let leading = div()
            .size(px(24.))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(24. * 0.28))
            .bg(palette::ACCENT.opacity(0.12).resolve(dark))
            .child(icon(
                crate::design::ActionIcon::History.symbol(),
                24. * 0.44,
                palette::ACCENT.resolve(dark),
            ));
        presentation::card_surface(dark)
            .w_full()
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(card_header(
                l("apple.desktophomework.continue.31fbef16"),
                Some(l(
                    "apple.desktophomework.the_conversations_you_last_opened.565f4f1f",
                )),
                leading,
                self.layout.fit,
                dark,
                cx,
            ))
            .child(rows)
    }
    fn recent_row(
        &self,
        index: usize,
        destination: RecentRow,
        dark: bool,
        cx: &Context<Self>,
    ) -> gpui::Stateful<Div> {
        let help = destination.unavailable.clone().unwrap_or_else(|| {
            localization::text(
                "apple.desktophomework.open_0.e71b4013",
                &[&destination.title],
            )
        });
        let enabled = destination.unavailable.is_none();
        let reference = destination.reference;
        div()
            .id(SharedString::from(format!("home-continue-{index}")))
            .w_full()
            .flex()
            .items_center()
            .gap(px(12.))
            .py(px(8.))
            .when(!enabled, |row| row.opacity(0.5))
            .child(icon(
                "bubble.left.and.bubble.right",
                13.,
                palette::ACCENT.resolve(dark),
            ))
            .child(
                div()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap(px(3.))
                    .child(self.work_label(destination.title, 12., 500).line_clamp(2))
                    .child(
                        self.work_label(
                            destination.unavailable.unwrap_or(destination.subtitle),
                            10.,
                            400,
                        )
                        .text_color(secondary(dark))
                        .line_clamp(2),
                    ),
            )
            .child(div().flex_1().min_w_0())
            .child(icon(
                crate::design::ActionIcon::Next.symbol(),
                13.,
                palette::ACCENT.resolve(dark),
            ))
            .tooltip(move |_, cx| cx.new(|_| Tooltip(help.clone())).into())
            .when(enabled, |row| {
                row.cursor_pointer()
                    .on_click(cx.listener(move |view, _, window, cx| {
                        view.close_menu(window);
                        let target = view
                            .work_reading(cx)
                            .and_then(|w| w.catalog.open_recent(&reference));
                        view.open_home_target(target, Some(reference.clone()), cx);
                    }))
            })
    }
    pub(super) fn home_pins(&self, dark: bool, cx: &Context<Self>) -> Div {
        let Some(work) = self.work_reading(cx) else {
            return self.work_gap(crate::home::layout::Section::Pinned, dark);
        };
        let pins = work.pin_rows();
        if pins.is_empty() {
            return div();
        }
        let mut rows = div().w_full().flex().flex_col();
        for (index, row) in pins.iter().enumerate() {
            let pin = row.pin.clone();
            let enabled = row.unavailable.is_none();
            let help = row.unavailable.clone().unwrap_or_else(|| {
                localization::text(
                    "apple.desktoppinnedworksection.open_0.e71b4013",
                    &[&pin.label],
                )
            });
            let selected = pin.clone();
            let open = div()
                .id(SharedString::from(format!("home-pin-open-{index}")))
                .flex_1()
                .min_w_0()
                .flex()
                .items_center()
                .gap(px(12.))
                .py(px(8.))
                .when(!enabled, |open| open.opacity(0.5))
                .child(
                    div()
                        .w(px(24.))
                        .flex_none()
                        .flex()
                        .justify_center()
                        .child(icon(
                            if pin.reference.kind == crate::work::Kind::Workspace {
                                "folder"
                            } else {
                                "bubble.left.and.bubble.right"
                            },
                            13.,
                            palette::ACCENT.resolve(dark),
                        )),
                )
                .child(
                    div()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .gap(px(4.))
                        .child(self.work_label(pin.label.clone(), 12., 500).line_clamp(2))
                        .child(
                            self.work_label(
                                row.unavailable.clone().unwrap_or(row.subtitle.clone()),
                                10.,
                                400,
                            )
                            .text_color(secondary(dark))
                            .line_clamp(2),
                        ),
                )
                .child(div().flex_1().min_w_0())
                .tooltip(move |_, cx| cx.new(|_| Tooltip(help.clone())).into())
                .when(enabled, |open| {
                    open.cursor_pointer()
                        .on_click(cx.listener(move |view, _, window, cx| {
                            view.close_menu(window);
                            let target = view
                                .work_reading(cx)
                                .and_then(|w| w.catalog.open_pin(&selected));
                            view.open_home_target(target, Some(selected.reference.clone()), cx);
                        }))
                });
            rows = rows.child(
                div()
                    .w_full()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .child(open)
                    .child(self.unpin_button(index, pin, dark, cx)),
            );
            if index + 1 < pins.len() {
                rows = rows.child(work_rule(dark));
            }
        }
        presentation::card_surface(dark).w_full().flex().flex_col().gap(px(12.))
            .child(card_header(l("apple.desktoppinnedworksection.pinned_work.23dd8f45"),Some(l("apple.desktoppinnedworksection.folders_and_conversations_you_kept_close.e3603d3c")),feature("mark_pin",22.,dark),self.layout.fit,dark,cx)).child(rows)
    }
    fn unpin_button(
        &self,
        index: usize,
        pin: Pin,
        dark: bool,
        cx: &Context<Self>,
    ) -> gpui::Stateful<Div> {
        let help = localization::text(
            "apple.desktoppinnedworksection.unpin_0.450ccf9f",
            &[&pin.label],
        );
        div()
            .id(SharedString::from(format!("home-unpin-{index}")))
            .size(px(44.))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .cursor_pointer()
            .child(
                div()
                    .size(px(30.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(8.))
                    .bg(palette::ACCENT_SOFT.opacity(0.8).resolve(dark))
                    .hover(|s| s.bg(palette::ROW_HIGHLIGHT.resolve(dark)))
                    .child(icon(
                        crate::design::ActionIcon::Pinned.symbol(),
                        14.,
                        palette::ACCENT.resolve(dark),
                    )),
            )
            .tooltip(move |_, cx| cx.new(|_| Tooltip(help.clone())).into())
            .on_click(cx.listener(move |view, _, window, cx| {
                view.close_menu(window);
                view.unpin_home(pin.reference.clone(), cx);
            }))
    }
    fn open_home_target(
        &mut self,
        target: Option<OpenTarget>,
        reference: Option<crate::work::Reference>,
        cx: &mut Context<Self>,
    ) {
        let Some(target) = target else {
            return;
        };
        match target {
            OpenTarget::SavedCopy { .. } => {
                self.gap = Some(
                    "Desktop preview: the saved conversation reader is still being ported.".into(),
                )
            }
            OpenTarget::Conversation { folder, item } => {
                self.selected_chat = Some((folder.clone(), item));
                self.chat_overview = false;
                self.requested_work = reference;
                self.set_project_expanded(&folder, true, cx);
                self.set_history_expanded(&folder, true, cx);
                self.navigate(
                    Route::Workspace {
                        id: folder,
                        section: WorkspaceSection::Chat,
                    },
                    cx,
                );
            }
            OpenTarget::Workspace { folder } => {
                let section = self.navigation.last_workspace_section(&folder);
                self.set_project_expanded(&folder, true, cx);
                self.navigate(
                    Route::Workspace {
                        id: folder,
                        section,
                    },
                    cx,
                );
            }
            OpenTarget::Terminal { .. } => self.gap = Some(
                "Desktop preview: selecting the retained terminal session is still being ported."
                    .into(),
            ),
        }
        cx.notify();
    }
    fn work_gap(&self, section: crate::home::layout::Section, dark: bool) -> Div {
        presentation::card_surface(dark).child(
            self.work_label(
                format!(
                    "Desktop preview: {} is still being ported.",
                    l(section.label_key())
                ),
                12.,
                400,
            )
            .text_color(secondary(dark)),
        )
    }
}

fn work_rule(dark: bool) -> Div {
    div()
        .w_full()
        .h(px(1.))
        .flex_none()
        .bg(palette::BORDER.resolve(dark))
}
