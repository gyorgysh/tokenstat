// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Initial local Insights surface. Native chart, inspector and styling parity
//! still require comparison with the SwiftUI implementation on Linux.

use super::*;
use crate::insights::{Period, Tab};
use std::time::Duration;

impl Desktop {
    pub(super) fn show_insights_action(&mut self, message: String, cx: &mut Context<Self>) {
        let generation = self.insights.show_action(message);
        cx.spawn(async move |view, cx| {
            cx.background_executor().timer(Duration::from_secs(5)).await;
            let _ = view.update(cx, |view, cx| {
                if view.insights.expire_action(generation) {
                    cx.notify();
                }
            });
        })
        .detach();
    }

    fn fetch_remote_usage(&mut self, cx: &mut Context<Self>) {
        let Some(client) = self.client.clone() else {
            return;
        };
        let Some(ticket) = self.remote_fetch.begin() else {
            return;
        };
        self.insights.clear_action();
        let refresh_client = client.clone();
        let worker = cx
            .background_executor()
            .spawn(async move { client.fetch_remotes().map_err(|error| format!("{error:#}")) });
        let held = cx.entity();
        cx.notify();
        cx.spawn(async move |view, cx| {
            let _held = held;
            let result = worker.await;
            let read = view
                .update(cx, |view, cx| {
                    if !view.remote_fetch.finish_fetch(ticket, result) {
                        if let Some(error) = view.remote_fetch.error.take() {
                            view.insights.error = Some(error);
                        }
                        cx.notify();
                        return None;
                    }
                    if let Some(message) = view.remote_fetch.action.clone() {
                        view.show_insights_action(message, cx);
                    }
                    cx.spawn(async move |view, cx| {
                        cx.background_executor()
                            .timer(Duration::from_secs(
                                crate::insights::fetch::COOLDOWN_SECONDS,
                            ))
                            .await;
                        let _ = view.update(cx, |view, cx| {
                            if view.remote_fetch.expire(ticket) {
                                cx.notify();
                            }
                        });
                    })
                    .detach();
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
                    let notify = view.remote_fetch.awaiting_refresh(ticket);
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
                    if view.remote_fetch.finish_refresh(ticket) {
                        cx.notify();
                    }
                });
            }
        })
        .detach();
    }

    pub(super) fn sync_local_insights(&mut self, cx: &mut Context<Self>) {
        let active = matches!(
            self.navigation.route,
            Route::Global {
                section: GlobalSection::Insights
            }
        );
        if active && !self.local_insights_active && !self.insights.loading {
            self.load_local_insights(cx);
        }
        self.local_insights_active = active;
    }

    pub(super) fn load_local_insights(&mut self, cx: &mut Context<Self>) {
        let Some(client) = self.client.clone() else {
            return;
        };
        self.insights.update_query();
        let read = self.insights.begin(self.insights.query.clone());
        let query = read.query.clone();
        let worker_read = read.clone();
        let worker = cx.background_executor().spawn(async move {
            client
                .insights_snapshot_if_current(&query, || worker_read.is_current())
                .map_err(|error| format!("{error:#}"))
        });
        cx.spawn(async move |view, cx| {
            let result = worker.await;
            let _ = view.update(cx, |view, cx| {
                view.insights.update_query();
                if view.insights.finish(&read, result) {
                    cx.notify();
                }
            });
        })
        .detach();
        cx.notify();
    }

    pub(super) fn local_insights_toolbar(&self, dark: bool, cx: &Context<Self>) -> Div {
        let mut picker = div()
            .flex()
            .p(px(2.))
            .gap(px(3.))
            .rounded(px(10.))
            .bg(palette::PANEL.resolve(dark));
        for period in Period::ALL {
            picker = picker.child(
                div()
                    .id(SharedString::from(format!(
                        "insights-period-{}",
                        period.label()
                    )))
                    .px(px(10.))
                    .py(px(5.))
                    .rounded(px(8.))
                    .cursor_pointer()
                    .when(self.insights.period == period, |d| {
                        d.bg(palette::ACCENT_SOFT.resolve(dark))
                    })
                    .text_color(if self.insights.period == period {
                        palette::ACCENT.resolve(dark)
                    } else {
                        secondary(dark)
                    })
                    .child(text(
                        period.label(),
                        FontToken {
                            points: 12.,
                            weight: 500,
                        },
                    ))
                    .on_click(cx.listener(move |view, _, _, cx| {
                        if view.insights.set_period(period) {
                            view.local_insights_visible = 50;
                            view.load_local_insights(cx);
                        }
                    })),
            );
        }
        div().flex().items_center().gap(px(6.)).child(picker)
            .child(div().id("local-insights-scan").size(px(44.)).flex().items_center().justify_center()
                .when(self.scanner.scanning || self.scanner.cooling_down, |d| d.opacity(0.4))
                .when(!self.scanner.scanning && !self.scanner.cooling_down, |d| d.cursor_pointer())
                .child(icon(if self.scanner.scanning { "progress" } else { "arrow.triangle.2.circlepath" }, 14., secondary(dark)))
                .tooltip(|_, cx| cx.new(|_| Tooltip(l("apple.insightsview.read_new_sessions_from_supported_local_too.baa5d296"))).into())
                .on_click(cx.listener(|view, _, _, cx| view.scan_from_home(cx))))
            .child(div().id("local-insights-fetch").size(px(44.)).flex().items_center().justify_center()
                .when(self.remote_fetch.fetching || self.remote_fetch.cooling_down, |d| d.opacity(0.4))
                .when(!self.remote_fetch.fetching && !self.remote_fetch.cooling_down, |d| d.cursor_pointer())
                .child(icon(if self.remote_fetch.fetching { "progress" } else { "arrow.down.circle" }, 14., secondary(dark)))
                .tooltip(|_, cx| cx.new(|_| Tooltip(l("apple.insightsview.fetch_usage_from_remote_vendors_such_as_cu.406af0cd"))).into())
                .on_click(cx.listener(|view, _, _, cx| view.fetch_remote_usage(cx))))
    }

    pub(super) fn insights_toast(&self, dark: bool, cx: &Context<Self>) -> Option<Div> {
        let message = self.insights.action_message.as_ref()?;
        let accent = palette::ACCENT.resolve(dark);
        Some(
            div()
                .absolute()
                .bottom(px(16.))
                .right(px(16.))
                .flex()
                .items_center()
                .gap(px(8.))
                .px(px(16.))
                .py(px(8.))
                .rounded_full()
                .bg(palette::PANEL.resolve(dark))
                .border_1()
                .border_color(palette::ACCENT.opacity(0.35).resolve(dark))
                .text_color(accent)
                .child(icon("checkmark.circle.fill", 13., accent))
                .child(text(
                    message.clone(),
                    FontToken {
                        points: self.layout.fit.text(13.),
                        weight: 500,
                    },
                ))
                .child(
                    div()
                        .id("dismiss-insights-toast")
                        .cursor_pointer()
                        .child(icon("xmark", 10., accent))
                        .on_click(cx.listener(|view, _, _, cx| {
                            view.insights.clear_action();
                            cx.notify();
                        })),
                ),
        )
    }

    pub(super) fn local_insights_content(
        &self,
        _width: f32,
        dark: bool,
        cx: &Context<Self>,
    ) -> Div {
        let fit = self.layout.fit;
        let mut tabs = div().w_full().flex().gap(px(4.)).px(px(16.)).py(px(8.));
        for tab in Tab::ALL {
            tabs = tabs.child(
                div()
                    .id(SharedString::from(format!("local-insights-tab-{tab:?}")))
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .px(px(10.))
                    .py(px(6.))
                    .rounded(px(8.))
                    .cursor_pointer()
                    .when(self.insights.tab == tab, |d| {
                        d.bg(palette::ACCENT_SOFT.resolve(dark))
                    })
                    .text_color(if self.insights.tab == tab {
                        palette::ACCENT.resolve(dark)
                    } else {
                        secondary(dark)
                    })
                    .child(icon(
                        tab.symbol(),
                        12.,
                        if self.insights.tab == tab {
                            palette::ACCENT.resolve(dark)
                        } else {
                            secondary(dark)
                        },
                    ))
                    .child(text(
                        l(tab.label_key()),
                        FontToken {
                            points: fit.text(12.),
                            weight: 500,
                        },
                    ))
                    .on_click(cx.listener(move |view, _, _, cx| {
                        if view.insights.tab != tab {
                            view.local_insights_visible = 50;
                        }
                        view.insights.set_tab(tab);
                        cx.notify();
                    })),
            );
        }
        let mut body = div().flex().flex_col().gap(px(12.)).p(px(16.));
        if let Some(error) = &self.insights.error {
            body = body.child(presentation::card_surface(dark).child(text(
                error.clone(),
                FontToken {
                    points: fit.text(12.),
                    weight: 400,
                },
            )));
        }
        if let Some(day) = &self.insights.focused_day {
            body = body.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .p(px(12.))
                    .rounded(px(12.))
                    .bg(palette::ACCENT_SOFT.resolve(dark))
                    .child(icon("calendar", 13., palette::ACCENT.resolve(dark)))
                    .child(text(
                        day.clone(),
                        FontToken {
                            points: fit.text(12.),
                            weight: 500,
                        },
                    ))
                    .child(div().flex_1())
                    .child(
                        div()
                            .id("clear-insights-day")
                            .cursor_pointer()
                            .text_color(palette::ACCENT.resolve(dark))
                            .child(text(
                                l("apple.insightsview.clear.83b12c22"),
                                FontToken {
                                    points: fit.text(12.),
                                    weight: 500,
                                },
                            ))
                            .on_click(cx.listener(|view, _, _, cx| {
                                if view.insights.clear_focused_day() {
                                    view.load_local_insights(cx);
                                }
                            })),
                    ),
            );
        }
        if self.insights.loading
            && self.insights.snapshot.is_none()
            && self.insights.error.is_none()
        {
            body = body.child(presentation::card_surface(dark).h(px(260.)).child(text(
                l("common.loading"),
                FontToken {
                    points: fit.text(13.),
                    weight: 400,
                },
            )));
        } else if let Some(snapshot) = &self.insights.snapshot {
            if self.insights.tab == Tab::Overview {
                let metrics = [
                    (
                        "apple.insightsview.total_tokens.e7601ca1",
                        crate::display::tokens(snapshot.totals.counters.total),
                    ),
                    (
                        "apple.insightsview.api_list_price.060458ef",
                        crate::insights::model_value(&snapshot.by_model),
                    ),
                    (
                        "apple.insightsview.sessions.6fa3cbf4",
                        crate::display::integer(snapshot.totals.sessions),
                    ),
                    (
                        "apple.insightsview.active_days.6cbebfa2",
                        crate::display::integer(snapshot.totals.days),
                    ),
                ];
                let mut grid = div().flex().flex_wrap().gap(px(12.));
                for (key, value) in metrics {
                    grid = grid.child(
                        presentation::card_surface(dark)
                            .flex_1()
                            .min_w(px(160.))
                            .child(
                                text(
                                    l(key),
                                    FontToken {
                                        points: fit.text(12.),
                                        weight: 500,
                                    },
                                )
                                .text_color(secondary(dark)),
                            )
                            .child(text(
                                value,
                                FontToken {
                                    points: fit.text(20.),
                                    weight: 600,
                                },
                            )),
                    );
                }
                body = body.child(grid);
                let mut chart = presentation::card_surface(dark)
                    .flex()
                    .flex_col()
                    .gap(px(10.))
                    .child(text(
                        l("apple.insightsview.usage_over_time.56d901b0"),
                        FontToken {
                            points: fit.text(14.),
                            weight: 600,
                        },
                    ));
                // This compact preview uses the real daily values; it is not yet
                // the Swift Charts axis, gradient, or interaction.
                let peak = snapshot
                    .daily
                    .iter()
                    .map(|r| r.counters.total)
                    .max()
                    .unwrap_or(0);
                let mut bars = div()
                    .h(px(200.))
                    .flex()
                    .items_end()
                    .gap(px(2.))
                    .overflow_hidden();
                for row in &snapshot.daily {
                    let height = if peak == 0 {
                        0.
                    } else {
                        190. * row.counters.total as f32 / peak as f32
                    };
                    bars = bars.child(
                        div()
                            .flex_1()
                            .min_w(px(2.))
                            .h(px(height))
                            .bg(palette::ACCENT.resolve(dark)),
                    );
                }
                chart = chart.child(bars);
                body = body.child(chart);
                for (key, tab, rows) in [
                    (
                        "apple.insightsview.top_models.79489561",
                        Tab::Models,
                        &snapshot.by_model,
                    ),
                    (
                        "apple.insightsview.by_coding_tool.d88bafe1",
                        Tab::Harnesses,
                        &snapshot.by_source,
                    ),
                    (
                        "apple.insightsview.project_activity.3601328f",
                        Tab::Projects,
                        &snapshot.by_project,
                    ),
                ] {
                    if tab == Tab::Projects && rows.is_empty() {
                        continue;
                    }
                    body = body.child(self.local_insights_rows(key, tab, rows, 5, dark, cx));
                }
            } else {
                body = body.child(self.local_insights_rows(
                    self.insights.tab.label_key(),
                    self.insights.tab,
                    self.insights.rows(),
                    self.local_insights_visible,
                    dark,
                    cx,
                ));
            }
        }
        div().flex().flex_col().size_full().child(tabs).child(
            div()
                .id("local-insights-scroll")
                .flex_1()
                .min_h_0()
                .overflow_y_scroll()
                .child(body),
        )
    }

    fn local_insights_rows(
        &self,
        title: &'static str,
        tab: Tab,
        rows: &[crate::insights::Bucket],
        limit: usize,
        dark: bool,
        cx: &Context<Self>,
    ) -> Div {
        let fit = self.layout.fit;
        let mut card = presentation::card_surface(dark)
            .flex()
            .flex_col()
            .gap(px(5.))
            .child(text(
                l(title),
                FontToken {
                    points: fit.text(14.),
                    weight: 600,
                },
            ));
        if rows.is_empty() {
            return card.child(
                text(
                    l("apple.insightsview.nothing_recorded.44985e2c"),
                    FontToken {
                        points: fit.text(12.),
                        weight: 400,
                    },
                )
                .text_color(secondary(dark)),
            );
        }
        for (index, row) in rows.iter().take(limit).enumerate() {
            let selected = self.insights.tab == tab
                && self
                    .insights
                    .selected
                    .as_ref()
                    .is_some_and(|selected| crate::work::text::equal(&selected.key, &row.key));
            let row = row.clone();
            let chosen = row.clone();
            card = card.child(
                div()
                    .id(SharedString::from(format!(
                        "local-insights-{tab:?}-{index}"
                    )))
                    .w_full()
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .px(px(8.))
                    .py(px(6.))
                    .rounded(px(6.))
                    .cursor_pointer()
                    .when(selected, |d| d.bg(palette::ACCENT_SOFT.resolve(dark)))
                    .child(
                        text(
                            row.key,
                            FontToken {
                                points: fit.text(12.),
                                weight: 500,
                            },
                        )
                        .flex_1()
                        .truncate(),
                    )
                    .child(
                        text(
                            crate::display::integer(row.sessions),
                            FontToken {
                                points: fit.text(12.),
                                weight: 400,
                            },
                        )
                        .text_color(secondary(dark)),
                    )
                    .child(text(
                        crate::display::tokens(row.counters.total),
                        FontToken {
                            points: fit.text(12.),
                            weight: 500,
                        },
                    ))
                    .on_click(cx.listener(move |view, _, window, cx| {
                        let changed_tab = view.insights.tab != tab;
                        let same = view.insights.tab == tab
                            && view.insights.selected.as_ref().is_some_and(|selected| {
                                crate::work::text::equal(&selected.key, &chosen.key)
                            });
                        view.insights.set_tab(tab);
                        view.insights.selected = if same { None } else { Some(chosen.clone()) };
                        if view.insights.selected.is_some() {
                            view.layout.inspector_chosen = true;
                            if !view
                                .layout
                                .inspector_fits(f32::from(window.viewport_size().width), None)
                            {
                                view.layout.inspector_overlay = true;
                                view.layout.inspector_held_by_press = true;
                            }
                        }
                        if changed_tab {
                            view.local_insights_visible = 50;
                        }
                        cx.notify();
                    })),
            );
        }
        if self.insights.tab != Tab::Overview && rows.len() > limit {
            let hidden = rows.len() - limit;
            card = card.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .child(
                        div()
                            .id("local-insights-more")
                            .cursor_pointer()
                            .text_color(palette::ACCENT.resolve(dark))
                            .child(text(
                                localization::text(
                                    "apple.insightsview.show_0_more.b91c3640",
                                    &[&hidden.min(30).to_string()],
                                ),
                                FontToken {
                                    points: fit.text(12.),
                                    weight: 500,
                                },
                            ))
                            .on_click(cx.listener(|view, _, _, cx| {
                                view.local_insights_visible =
                                    view.local_insights_visible.saturating_add(30);
                                cx.notify();
                            })),
                    )
                    .child(
                        text(
                            localization::text(
                                "apple.insightsview.0_more_hidden.4beb56b2",
                                &[&hidden.to_string()],
                            ),
                            FontToken {
                                points: fit.text(11.),
                                weight: 400,
                            },
                        )
                        .text_color(secondary(dark)),
                    )
                    .child(div().flex_1())
                    .child(
                        div()
                            .id("local-insights-all")
                            .cursor_pointer()
                            .child(text(
                                l("apple.insightsview.show_all.2150d8df"),
                                FontToken {
                                    points: fit.text(11.),
                                    weight: 400,
                                },
                            ))
                            .on_click(cx.listener(|view, _, _, cx| {
                                view.local_insights_visible = usize::MAX;
                                cx.notify();
                            })),
                    ),
            );
        }
        card
    }
}
