// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Home's first-scan card, following GettingStartedCard and its three-step rail.

use super::*;
use crate::home::scan::{self, Action, StepState};
use std::time::Duration;

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
    pub(super) fn scan_from_home(&mut self, cx: &mut Context<Self>) {
        let Some(client) = self.client.clone() else {
            return;
        };
        let Some(ticket) = self.scanner.begin() else {
            return;
        };
        self.insights.clear_action();
        let refresh_client = client.clone();
        let work = cx
            .background_executor()
            .spawn(async move { client.scan().map_err(|error| format!("{error:#}")) });
        let held = cx.entity();
        cx.notify();
        cx.spawn(async move |view, cx| {
            // InsightsModel.scan retains its model while scan and refresh are
            // suspended, even if the initiating pane stops being visible.
            let _held = held;
            let result = work.await;
            let read = view
                .update(cx, |view, cx| {
                    if !view.scanner.finish_scan(ticket, result) {
                        if let Some(error) = view.scanner.error.take() {
                            view.insights.error = Some(error);
                        }
                        cx.notify();
                        return None;
                    }
                    if let Some(message) = view.scanner.action.clone() {
                        view.show_insights_action(message, cx);
                    }
                    // Source timers start at scan success, not after refresh.
                    for (seconds, action) in [(5, true), (10, false)] {
                        cx.spawn(async move |view, cx| {
                            cx.background_executor()
                                .timer(Duration::from_secs(seconds))
                                .await;
                            let _ = view.update(cx, |view, cx| {
                                let changed = if action {
                                    view.scanner.expire_action(ticket)
                                } else {
                                    view.scanner.expire(ticket)
                                };
                                if changed {
                                    cx.notify();
                                }
                            });
                        })
                        .detach();
                    }
                    view.insights.update_query();
                    let read = view.insights.begin(view.insights.query.clone());
                    cx.notify();
                    Some(read)
                })
                .ok()
                .flatten();
            let Some(read) = read else { return };
            let query = read.query.clone();
            let worker_read = read.clone();
            let refresh = cx.background_executor().spawn(async move {
                refresh_client
                    .insights_snapshot_if_current(&query, || worker_read.is_current())
                    .map_err(|error| format!("{error:#}"))
            });
            let result = refresh.await;
            let notify = view
                .update(cx, |view, cx| {
                    view.insights.update_query();
                    view.insights.finish(&read, result);
                    let notify = view.scanner.awaiting_refresh(ticket);
                    cx.notify();
                    notify
                })
                .unwrap_or(false);
            if notify {
                let _ = cx.update(|app| {
                    let shared = app.global_mut::<super::home_shared::HomeShared>();
                    shared.archive_revision = shared.archive_revision.wrapping_add(1);
                });
                let _ = view.update(cx, |view, cx| {
                    if view.scanner.finish_refresh(ticket) {
                        cx.notify();
                    }
                });
            }
        })
        .detach();
    }

    pub(super) fn getting_started(&self, dark: bool, cx: &Context<Self>) -> Div {
        let fit = self.layout.fit;
        let signed_in = self.account().is_some_and(|account| account.signed_in);
        let header = div().flex().flex_col().gap(px(4.))
            .child(div().flex().items_center().gap(px(8.))
                .child(super::day_view::feature("mark_activity", 26., dark))
                .child(label(l("apple.gettingstartedcard.get_tokenstat_counting.331454ea"), 15., 600, fit)))
            .child(label(l("apple.gettingstartedcard.it_reads_the_logs_the_tools_you_already_us.5d21d349"), 12., 400, fit).text_color(secondary(dark)));
        let rail = div().flex().flex_col().children(
            scan::steps(signed_in, self.scanner.scanning, self.scanner.cooling_down)
                .into_iter()
                .map(|step| {
                    let action = step.action.map(|action| match action {
                        Action::Scan => self.getting_started_button(
                            "getting-started-scan",
                            "apple.gettingstartedcard.scan_now.c01d65df",
                            "arrow.clockwise",
                            dark,
                            cx,
                        ),
                        Action::SignIn => self.getting_started_button(
                            "getting-started-sign-in",
                            "common.sign_in",
                            "person.crop.circle",
                            dark,
                            cx,
                        ),
                    });
                    self.getting_started_step(
                        step.number,
                        step.state,
                        step.title_key,
                        step.body_key,
                        action,
                        step.number == 3,
                        dark,
                    )
                }),
        );
        let ghost = div()
            .flex()
            .flex_col()
            .gap(px(3.))
            .children((0..7).map(|_| {
                div().flex().gap(px(3.)).children((0..30).map(|_| {
                    div()
                        .size(px(9.))
                        .rounded(px(2.))
                        .bg(palette::ACCENT.opacity(0.08).resolve(dark))
                }))
            }));
        div()
            .w_full()
            .p(px(19.))
            .rounded(px(14.))
            .bg(palette::PANEL.resolve(dark))
            .border_1()
            .border_color(palette::ACCENT.opacity(0.28).resolve(dark))
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(header)
            .child(rail)
            .child(
                div()
                    .pt(px(4.))
                    .flex()
                    .flex_col()
                    .gap(px(8.))
                    .child(div().h(px(1.)).w_full().bg(palette::BORDER.resolve(dark)))
                    .child(label(
                        l("apple.gettingstartedcard.then_the_year_fills_in.8ee449de"),
                        13.,
                        600,
                        fit,
                    ))
                    .child(ghost),
            )
    }

    #[allow(clippy::too_many_arguments)]
    fn getting_started_step(
        &self,
        number: usize,
        state: StepState,
        title: &str,
        body: &str,
        action: Option<Div>,
        last: bool,
        dark: bool,
    ) -> Div {
        let fit = self.layout.fit;
        let disc = div()
            .size(px(30.))
            .rounded_full()
            .flex()
            .items_center()
            .justify_center()
            .when(state == StepState::Now, |d| {
                d.bg(palette::ACCENT.opacity(0.16).resolve(dark))
            })
            .child(
                div()
                    .size(px(26.))
                    .rounded_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .bg(if state == StepState::Next {
                        palette::ACCENT_SOFT.resolve(dark)
                    } else {
                        palette::ACCENT.resolve(dark)
                    })
                    .when(state == StepState::Next, |d| {
                        d.border_1().border_color(palette::BORDER.resolve(dark))
                    })
                    .when(state == StepState::Done, |d| {
                        d.child(icon("checkmark", 12., rgb(0xffffff).into()))
                    })
                    .when(state != StepState::Done, |d| {
                        d.child(
                            presentation::monospaced(
                                number.to_string(),
                                FontToken {
                                    points: fit.text(11.),
                                    weight: 700,
                                },
                            )
                            .text_color(if state == StepState::Next {
                                secondary(dark)
                            } else {
                                rgb(0xffffff).into()
                            }),
                        )
                    }),
            );
        let left = div()
            .relative()
            .w(px(30.))
            .flex_none()
            .child(disc)
            .when(!last, |d| {
                d.child(
                    div()
                        .absolute()
                        .left(px(14.))
                        .top(px(34.))
                        .bottom(px(4.))
                        .w(px(2.))
                        .rounded_full()
                        .bg(if state == StepState::Done {
                            palette::ACCENT.opacity(0.5).resolve(dark)
                        } else {
                            palette::BORDER.resolve(dark)
                        }),
                )
            });
        let content = div()
            .flex_1()
            .min_w_0()
            .flex()
            .flex_col()
            .gap(px(4.))
            .when(!last, |d| d.pb(px(20.)))
            .child(
                label(l(title), 13., 600, fit).text_color(if state == StepState::Done {
                    secondary(dark)
                } else {
                    primary(dark)
                }),
            )
            .child(
                label(l(body), 12., 400, fit)
                    .max_w(px(420.))
                    .text_color(secondary(dark)),
            )
            .when_some(action, |d, action| d.child(div().pt(px(4.)).child(action)));
        div().flex().gap(px(12.)).child(left).child(content)
    }

    fn getting_started_button(
        &self,
        id: &'static str,
        key: &str,
        symbol: &'static str,
        dark: bool,
        cx: &Context<Self>,
    ) -> Div {
        let fit = self.layout.fit;
        let mut button = div()
            .id(id)
            .h(px(30.))
            .px(px(12.))
            .rounded(px(7.))
            .bg(palette::ACCENT.resolve(dark))
            .text_color(rgb(0xffffff))
            .flex()
            .items_center()
            .gap(px(6.))
            .cursor_pointer()
            .child(icon(symbol, 12., rgb(0xffffff).into()))
            .child(label(l(key), 13., 600, fit));
        button = if id == "getting-started-scan" {
            button.on_click(cx.listener(|view, _, _, cx| view.scan_from_home(cx)))
        } else {
            button.on_click(
                cx.listener(|view, _, window, cx| view.command(Command::SignIn, window, cx)),
            )
        };
        div().flex().child(button)
    }
}
