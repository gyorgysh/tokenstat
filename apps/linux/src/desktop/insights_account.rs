// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Initial account-wide Insights route. Charts and native visual/input parity
//! remain open; report data and requests still belong to the shared host.

use super::*;
use crate::{
    home::ActivityScope,
    input_field::Field,
    insights::account::{Cut, State},
    work::Scope,
};
use std::sync::{
    Arc, Weak,
    atomic::{AtomicBool, Ordering},
};

pub(super) struct Screen {
    state: State,
    scope: Option<Scope>,
    pub field: gpui::Entity<Field>,
    automatic: Option<Arc<AtomicBool>>,
    pending: Vec<Weak<AtomicBool>>,
}

#[derive(Clone, Copy, Debug)]
pub(super) enum FixtureState {
    Ready,
    Empty,
    Error,
    Loading,
}
impl Screen {
    fn cancel_automatic(&mut self) {
        if let Some(cancel) = self.automatic.take() {
            cancel.store(true, Ordering::Release);
        }
    }
    fn cancel_all(&mut self) {
        self.cancel_automatic();
        for pending in self.pending.drain(..) {
            if let Some(cancel) = pending.upgrade() {
                cancel.store(true, Ordering::Release);
            }
        }
    }
}

impl Desktop {
    /// Offline fixtures never start a host or read an account.
    pub(super) fn prepare_account_insights_fixture(&mut self, fixture: FixtureState) {
        let Some(screen) = &mut self.account_insights else {
            return;
        };
        let Some(read) = screen.state.load(screen.scope.as_ref(), false) else {
            return;
        };
        let result = match fixture {
            FixtureState::Loading => return,
            FixtureState::Error => Err("Synthetic account report failure".into()),
            FixtureState::Ready | FixtureState::Empty => {
                let rows = if matches!(fixture, FixtureState::Ready) {
                    serde_json::json!([{"key":"fixture-model","counters":{"total":123456,"inputTotal":456,"hasUnknown":false},"events":7,"sessions":2,"valueMicros":1200000,"estimated":true,"unpricedModels":[]}])
                } else {
                    serde_json::json!([])
                };
                Ok(serde_json::from_value(
                    serde_json::json!({"rows":rows,"group":"model","fetchedAtMs":1,"stale":false}),
                )
                .unwrap())
            }
        };
        screen
            .state
            .finish(&read, screen.scope.as_ref(), false, result);
    }

    fn account_insights_scope(&self, app: &App) -> Option<Scope> {
        let shared = app.global::<super::home_shared::HomeShared>();
        if self.client.is_none() {
            shared
                .work
                .as_ref()
                .and_then(|work| work.catalog.scope.clone())
        } else {
            shared.metadata.scope()
        }
    }

    pub(super) fn sync_account_insights(&mut self, cx: &mut Context<Self>) {
        let active = matches!(
            self.navigation.route,
            Route::Global {
                section: GlobalSection::Insights
            }
        ) && self.home.requested_scope == ActivityScope::AllMachines;
        if !active {
            if let Some(mut old) = self.account_insights.take() {
                old.cancel_all();
                self.account_insights_epoch = self.account_insights_epoch.wrapping_add(1);
            }
            return;
        }
        let scope = self.account_insights_scope(cx);
        if self
            .account_insights
            .as_ref()
            .is_some_and(|screen| screen.scope == scope)
        {
            return;
        }
        if let Some(mut old) = self.account_insights.take() {
            old.cancel_all();
        }
        self.account_insights_epoch = self.account_insights_epoch.wrapping_add(1);
        let field =
            cx.new(|cx| Field::new(String::new(), l("apple.insightsview.filter.638e249f"), cx));
        cx.observe(&field, |_, _, cx| cx.notify()).detach();
        self.account_insights = Some(Screen {
            state: State::default(),
            scope,
            field,
            automatic: None,
            pending: Vec::new(),
        });
        self.load_account_insights(false, true, cx);
    }

    fn load_account_insights(&mut self, refresh: bool, automatic: bool, cx: &mut Context<Self>) {
        let Some(client) = self.client.clone() else {
            return;
        };
        let Some(screen) = self.account_insights.as_mut() else {
            return;
        };
        let cancel = Arc::new(AtomicBool::new(false));
        if automatic {
            screen.cancel_automatic();
            screen.automatic = Some(cancel.clone());
        }
        let read = if refresh {
            screen.state.refresh(screen.scope.as_ref(), false)
        } else {
            screen.state.load(screen.scope.as_ref(), false)
        };
        let Some(read) = read else { return };
        screen.pending.retain(|pending| pending.strong_count() != 0);
        screen.pending.push(Arc::downgrade(&cancel));
        let epoch = self.account_insights_epoch;
        let cut = read.cut;
        let worker_cancel = cancel.clone();
        let worker = cx.background_executor().spawn(async move {
            client
                .account_insights_if_current(cut, || !worker_cancel.load(Ordering::Acquire))
                .map_err(|error| format!("{error:#}"))
        });
        cx.spawn(async move |view, cx| {
            let result = worker.await;
            let _ = view.update(cx, |view, cx| {
                if view.account_insights_epoch != epoch {
                    return;
                }
                let scope = view.account_insights_scope(cx);
                if let Some(screen) = &mut view.account_insights {
                    screen.state.finish(
                        &read,
                        scope.as_ref(),
                        cancel.load(Ordering::Acquire),
                        result,
                    );
                    cx.notify();
                }
            });
        })
        .detach();
        cx.notify();
    }

    pub(super) fn account_insights_content(&self, dark: bool, cx: &Context<Self>) -> Div {
        let Some(screen) = &self.account_insights else {
            return div();
        };
        let fit = self.layout.fit;
        let text = |value: String, points: f32, weight| {
            super::text(
                value,
                FontToken {
                    points: fit.text(points),
                    weight,
                },
            )
        };
        let current = self.account_insights_scope(cx);
        let cut = screen.state.cut;
        let search = screen.field.read(cx).input.text().to_lowercase();
        let mut picker = div()
            .flex()
            .gap(px(4.))
            .p(px(2.))
            .rounded(px(10.))
            .bg(palette::PANEL.resolve(dark));
        for option in Cut::ALL {
            picker = picker.child(
                div()
                    .id(SharedString::from(format!(
                        "account-insights-{}",
                        option.wire()
                    )))
                    .px(px(12.))
                    .py(px(6.))
                    .rounded(px(8.))
                    .cursor_pointer()
                    .when(cut == option, |d| d.bg(palette::ACCENT_SOFT.resolve(dark)))
                    .text_color(if cut == option {
                        palette::ACCENT.resolve(dark)
                    } else {
                        secondary(dark)
                    })
                    .child(text(l(option.label_key()), 12., 500))
                    .on_click(cx.listener(move |view, _, _, cx| {
                        if let Some(screen) = &mut view.account_insights {
                            if screen.state.cut == option {
                                return;
                            }
                            screen.cancel_automatic();
                            screen.state.cut = option;
                        }
                        view.load_account_insights(false, true, cx);
                        cx.notify();
                    })),
            );
        }
        let header = div()
            .w_full()
            .flex()
            .items_center()
            .gap(px(8.))
            .child(picker)
            .child(div().flex_1().min_w_0().child(screen.field.clone()))
            .child(
                div()
                    .id("account-insights-refresh")
                    .size(px(44.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(icon(
                        if screen.state.loading() {
                            "progress"
                        } else {
                            "arrow.clockwise"
                        },
                        14.,
                        secondary(dark),
                    ))
                    .tooltip(|_, cx| {
                        cx.new(|_| Tooltip(l("apple.insightsview.refresh_account_usage.70ac7105")))
                            .into()
                    })
                    .when(!screen.state.loading(), |d| {
                        d.cursor_pointer().on_click(
                            cx.listener(|view, _, _, cx| {
                                view.load_account_insights(true, false, cx)
                            }),
                        )
                    }),
            );
        let mut body = div().w_full().flex().flex_col().gap(px(8.));
        if screen.state.loading() {
            body = body.child(div().flex().justify_center().child(icon(
                "progress",
                14.,
                secondary(dark),
            )));
        }
        if let Some(rows) = screen.state.rows(cut, current.as_ref()) {
            let mut filtered = rows
                .iter()
                .filter_map(|row| {
                    let title = match cut {
                        Cut::Model => row.key.clone(),
                        Cut::Source => crate::display::harness_name(&row.key),
                        Cut::Day => crate::display::friendly_date(&row.key, false),
                    };
                    (search.is_empty() || title.to_lowercase().contains(&search))
                        .then_some((row, title))
                })
                .collect::<Vec<_>>();
            if cut == Cut::Day {
                filtered.sort_by(|a, b| b.0.key.cmp(&a.0.key));
            } else {
                filtered.sort_by_key(|a| std::cmp::Reverse(a.0.value_micros));
            }
            if !filtered.is_empty() {
                body = body.child(self.account_insights_chart(cut, &filtered, dark));
            }
            if rows.is_empty() {
                body = body.child(
                    text(
                        l("apple.insightsview.no_synced_usage_in_this_period.3484c8af"),
                        12.,
                        400,
                    )
                    .text_color(secondary(dark)),
                );
            } else if filtered.is_empty() {
                body = body.child(
                    text(l("apple.insightsview.no_matching_usage.8b2c6893"), 12., 400)
                        .text_color(secondary(dark)),
                );
            }
            for (row, title) in filtered {
                let count = crate::display::integer(row.counters.total);
                let count = localization::text("apple.insightsview.0_tokens.624f11b9", &[&count]);
                body = body.child(
                    div()
                        .w_full()
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .p(px(12.))
                        .rounded(px(14.))
                        .bg(palette::PANEL.resolve(dark))
                        .when(cut == Cut::Source, |d| {
                            d.child(super::day_view::harness_mark(&row.key, 26., dark))
                        })
                        .child(text(title, 13., 400).flex_1().min_w_0().truncate())
                        .child(
                            div()
                                .flex()
                                .flex_col()
                                .items_end()
                                .child(
                                    text(
                                        crate::display::money(
                                            row.value_micros,
                                            row.estimated,
                                            row.unpriced_models.is_empty(),
                                        ),
                                        13.,
                                        400,
                                    )
                                    .text_color(palette::ACCENT.resolve(dark)),
                                )
                                .child(text(count, 10., 400).text_color(secondary(dark))),
                        ),
                );
            }
        }
        let mut content = div()
            .p(px(12.))
            .flex()
            .flex_col()
            .items_center()
            .gap(px(12.))
            .child(header)
            .child(
                text(
                    l("apple.insightsview.synced_usage_across_all_devices_last_53_we.20b8c5e2"),
                    10.,
                    400,
                )
                .text_color(secondary(dark)),
            );
        if let Some(error) = screen.state.error() {
            content = content.child(
                text(error.to_owned(), 12., 400)
                    .w_full()
                    .p(px(12.))
                    .rounded(px(8.))
                    .text_color(palette::DANGER.resolve(dark)),
            );
        }
        if let Some(report) = screen
            .state
            .report(cut, current.as_ref())
            .filter(|r| r.stale)
        {
            let age = crate::display::relative_english(
                report.fetched_at_ms,
                crate::home::plans::now_ms(),
                false,
            );
            content = content.child(text(localization::text("apple.clientinsightsview.the_refresh_did_not_go_through_showing_wha.790fad9d", &[&age]),10.,400).text_color(secondary(dark)));
        }
        content.child(body)
    }

    fn account_insights_chart(
        &self,
        cut: Cut,
        rows: &[(&crate::insights::Bucket, String)],
        dark: bool,
    ) -> Div {
        let fit = self.layout.fit;
        let label = |value: String, points, weight| {
            super::text(
                value,
                FontToken {
                    points: fit.text(points),
                    weight,
                },
            )
        };
        let daily = cut == Cut::Day;
        let title = if daily {
            l("apple.insightsview.daily_activity.561d7c9e")
        } else {
            localization::text(
                "apple.insightsview.most_used_0.ad293687",
                &[&l(cut.label_key()).to_lowercase()],
            )
        };
        let mut chart = div()
            .w_full()
            .p(px(12.))
            .rounded(px(14.))
            .bg(palette::PANEL.resolve(dark))
            .flex()
            .flex_col()
            .gap(px(8.))
            .child(label(title, 13., 600))
            .child(
                label(
                    l("apple.insightsview.tokens_including_reported_cache_usage.a3e0a451"),
                    10.,
                    400,
                )
                .text_color(secondary(dark)),
            );
        if daily {
            let mut sorted = rows
                .iter()
                .map(|(row, _)| (*row).clone())
                .collect::<Vec<_>>();
            sorted.sort_by(|a, b| a.key.cmp(&b.key));
            let marks = sorted
                .iter()
                .filter_map(|row| {
                    crate::insights::account::day_position(&row.key)
                        .map(|day| (day, row.counters.total))
                })
                .collect::<Vec<_>>();
            let first = marks.iter().map(|(day, _)| *day).min();
            let last = marks.iter().map(|(day, _)| *day).max();
            let peak = marks.iter().map(|(_, n)| *n).max().unwrap_or(0);
            let color = palette::ACCENT.resolve(dark);
            let graph = gpui::canvas(
                |_, _, _| (),
                move |bounds, _, window, _| {
                    let (Some(first), Some(last)) = (first, last) else {
                        return;
                    };
                    let width: f32 = bounds.size.width.into();
                    let height: f32 = bounds.size.height.into();
                    let days = (last - first + 1) as f64;
                    let bar_width = (f64::from(width) / days * 0.8).max(0.25) as f32;
                    for (day, count) in &marks {
                        let x = (((*day - first) as f64 + 0.1) / days * f64::from(width)) as f32;
                        let bar_height = if peak == 0 {
                            0.
                        } else {
                            (*count as f64 / peak as f64 * f64::from(height)) as f32
                        };
                        window.paint_quad(gpui::fill(
                            gpui::Bounds::new(
                                gpui::point(
                                    bounds.origin.x + px(x),
                                    bounds.origin.y + px(height - bar_height),
                                ),
                                gpui::size(px(bar_width), px(bar_height)),
                            ),
                            color,
                        ));
                    }
                },
            )
            .w_full()
            .h(px(170.));
            chart = chart.child(graph).child(
                div()
                    .w_full()
                    .flex()
                    .justify_between()
                    .child(
                        label(
                            sorted.first().map_or(String::new(), |row| row.key.clone()),
                            10.,
                            400,
                        )
                        .text_color(secondary(dark)),
                    )
                    .child(
                        label(
                            sorted.last().map_or(String::new(), |row| row.key.clone()),
                            10.,
                            400,
                        )
                        .text_color(secondary(dark)),
                    ),
            );
        } else {
            let mut sorted = rows
                .iter()
                .map(|(row, title)| ((*row).clone(), title.clone()))
                .collect::<Vec<_>>();
            sorted.sort_by_key(|a| std::cmp::Reverse(a.0.counters.total));
            sorted.truncate(8);
            let peak = sorted.first().map_or(0, |(row, _)| row.counters.total);
            for (row, title) in sorted {
                let fraction = if peak == 0 {
                    0.
                } else {
                    (row.counters.total as f64 / peak as f64) as f32
                };
                chart = chart.child(
                    div()
                        .h(px(28.))
                        .w_full()
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .child(
                            label(title, 10., 400)
                                .w(px(105.))
                                .truncate()
                                .text_color(secondary(dark)),
                        )
                        .child(
                            div().flex_1().h(px(18.)).child(
                                div()
                                    .w(gpui::relative(fraction))
                                    .h_full()
                                    .rounded(px(3.))
                                    .bg(palette::ACCENT.resolve(dark)),
                            ),
                        ),
                );
            }
        }
        chart
    }
}
