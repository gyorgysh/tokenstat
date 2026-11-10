// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Home's pinned day and passive hover card, arranged from the SwiftUI sources.

use super::*;
use crate::{
    display,
    home::{
        ActivityScope, HeatCell,
        day::{
            DayDetail, DayOverview, DayRequest, GroupRow, PopoverGeometry, Segment, bucket_rows,
            harness_rows, model_rows,
        },
    },
};
use gpui::{Animation, AnimationExt, Transformation, percentage};
use std::{
    hash::{BuildHasher, RandomState},
    sync::OnceLock,
    time::Duration,
};

fn label(value: impl IntoElement, points: f32, weight: u16, fit: DisplayFit) -> Div {
    text(
        value,
        FontToken {
            points: fit.text(points),
            weight,
        },
    )
}
fn number(value: impl IntoElement, points: f32, weight: u16, fit: DisplayFit) -> Div {
    presentation::numeric(
        value,
        FontToken {
            points: fit.text(points),
            weight,
        },
    )
}
fn tertiary(dark: bool) -> gpui::Hsla {
    primary(dark).opacity(0.25 / 0.85)
}
pub(super) fn feature(name: &str, side: f32, dark: bool) -> Div {
    div()
        .size(px(side))
        .flex_none()
        .rounded(px(side * 0.28))
        .bg(palette::ACCENT.opacity(0.12).resolve(dark))
        .flex()
        .items_center()
        .justify_center()
        .child(
            svg()
                .path(format!("assets/{name}"))
                .size(px(side * 0.62))
                .text_color(palette::ACCENT.resolve(dark)),
        )
}
fn rule(dark: bool) -> Div {
    div()
        .h(px(1.))
        .w_full()
        .flex_none()
        .bg(palette::BORDER.resolve(dark))
}
fn loading(key: &str, mini: bool, dark: bool, fit: DisplayFit) -> Div {
    div()
        .flex()
        .items_center()
        .gap(px(8.))
        .child(
            svg()
                .path("symbols/progress")
                .size(px(if mini { 10. } else { 14. }))
                .text_color(secondary(dark))
                .with_animation(
                    "day-progress",
                    Animation::new(Duration::from_secs(1)).repeat(),
                    |svg, t| svg.with_transformation(Transformation::rotate(percentage(t))),
                ),
        )
        .child(label(l(key), 10., 400, fit).text_color(if mini {
            tertiary(dark)
        } else {
            secondary(dark)
        }))
}
pub(super) fn harness_mark(id: &str, side: f32, dark: bool) -> Div {
    let mut mark = div()
        .size(px(side))
        .flex_none()
        .rounded(px(side * 0.28))
        .bg(palette::ACCENT.opacity(0.12).resolve(dark))
        .flex()
        .items_center()
        .justify_center();
    if let Some(asset) =
        display::harness_brand_asset(id).filter(|name| crate::symbols::has_asset(name))
    {
        mark = mark.child(
            svg()
                .path(format!("assets/{asset}"))
                .size(px(side * 0.58))
                .text_color(palette::ACCENT.resolve(dark)),
        );
    } else {
        mark = mark.child(
            text(
                display::harness_initial(id),
                FontToken {
                    points: side * 0.46,
                    weight: 600,
                },
            )
            .text_color(palette::ACCENT.resolve(dark)),
        );
    }
    mark
}
fn segment_color(kind: usize, dark: bool) -> gpui::Hsla {
    match kind {
        0 => palette::HEAT[1].resolve(dark),
        1 => palette::HEAT[2].resolve(dark),
        2 => palette::HEAT[4].resolve(dark),
        _ => palette::ACCENT.resolve(dark),
    }
}
fn segment_label(segment: &Segment, popover: bool) -> String {
    let prefix = if popover {
        "apple.daydetailpopover"
    } else {
        "apple.homeinspector"
    };
    let suffix = match segment.kind {
        0 => Some("cache_read.e16dda7a"),
        1 => Some("cache_write.e2bcc9d6"),
        3 => Some("fresh_in.28475ebb"),
        _ => None,
    };
    let title = suffix
        .map(|s| l(&format!("{prefix}.{s}")))
        .unwrap_or_else(|| "output".into());
    format!("{title} {}%", segment.percent())
}
fn split(detail: &DayDetail, width: f32, popover: bool, dark: bool, fit: DisplayFit) -> Div {
    let segments = detail.segments();
    let mut out = div()
        .flex()
        .flex_col()
        .gap(px(if popover { 5. } else { 4. }));
    if segments.is_empty() {
        return out;
    }
    out = out.child(div().flex().gap(px(2.)).children(segments.iter().map(|s| {
        div()
            .w(px(s.width(f64::from(width)) as f32))
            .h(px(4.))
            .flex_none()
            .rounded_full()
            .bg(segment_color(s.kind, dark))
    })));
    if popover {
        out =
            out.child(div().flex().gap(px(8.)).children(
                segments.iter().map(|s| {
                    label(segment_label(s, true), 9., 400, fit).text_color(tertiary(dark))
                }),
            ));
    } else {
        out = out.children(
            segments
                .iter()
                .map(|s| label(segment_label(s, false), 11., 400, fit).text_color(tertiary(dark))),
        );
    }
    out
}

enum GroupPresentation {
    Priced,
    Tools,
    Plain,
}

impl Desktop {
    pub(super) fn load_home_selection(&mut self, cx: &mut Context<Self>) {
        let Some(day) = self.home.selected.clone() else {
            return;
        };
        let scope = self
            .home
            .calendar
            .as_ref()
            .map(|c| c.delivered_scope())
            .unwrap_or(ActivityScope::ThisMachine);
        if let Some(request) = self.home.days.begin_selected(&day, scope) {
            self.fetch_home_day(request, false, cx);
        }
        if let Some(request) = self.home.days.begin_overview(&day, scope) {
            let client = self.client.clone();
            if let Some(client) = client {
                let request_call = request.clone();
                let task = cx.background_executor().spawn(async move {
                    client
                        .day_overview(&request_call.date)
                        .map_err(|e| format!("{e:#}"))
                });
                cx.spawn(async move |view, cx| {
                    let result = task.await;
                    let _ = view.update(cx, |view, cx| {
                        if view.home.days.finish_overview(&request, result) {
                            cx.notify();
                        }
                    });
                })
                .detach();
            } else {
                let detail = DayDetail::fixture(&day);
                self.home.days.finish_overview(
                    &request,
                    Ok(detail
                        .as_ref()
                        .map(DayOverview::fixture)
                        .unwrap_or_default()),
                );
            }
        }
    }
    pub(super) fn select_home_day(&mut self, day: HeatCell, cx: &mut Context<Self>) {
        self.home.select(day);
        self.load_home_selection(cx);
        cx.notify();
    }
    pub(super) fn set_home_hover(&mut self, day: Option<HeatCell>, cx: &mut Context<Self>) {
        if self.home.hovered == day {
            return;
        }
        self.home.hovered = day;
        self.hover_anchor = None;
        let scope = self
            .home
            .calendar
            .as_ref()
            .map(|c| c.delivered_scope())
            .unwrap_or(ActivityScope::ThisMachine);
        if let Some(request) = self
            .home
            .days
            .begin_hover(self.home.hovered.as_ref(), scope)
        {
            self.fetch_home_day(request, true, cx);
        }
        cx.notify();
    }
    fn fetch_home_day(&mut self, request: DayRequest, settle: bool, cx: &mut Context<Self>) {
        if !settle && self.client.is_none() {
            let detail = self
                .home
                .calendar
                .as_ref()
                .and_then(|c| c.cell(&request.date))
                .and_then(DayDetail::fixture);
            self.home.days.finish_detail(&request, Ok(detail));
            return;
        }
        let client = self.client.clone();
        cx.spawn(async move |view, cx| {
            if settle {
                cx.background_executor()
                    .timer(Duration::from_millis(140))
                    .await;
            }
            if !view
                .update(cx, |view, _| view.home.days.is_current(&request))
                .unwrap_or(false)
            {
                return;
            }
            let result = if let Some(client) = client {
                let call = request.clone();
                cx.background_executor()
                    .spawn(async move {
                        client
                            .day_detail(&call.date, call.scope)
                            .map_err(|e| format!("{e:#}"))
                    })
                    .await
            } else {
                view.update(cx, |view, _| {
                    Ok(view
                        .home
                        .calendar
                        .as_ref()
                        .and_then(|c| c.cell(&request.date))
                        .and_then(DayDetail::fixture))
                })
                .unwrap_or_else(|e| Err(e.to_string()))
            };
            let _ = view.update(cx, |view, cx| {
                if view.home.days.finish_detail(&request, result) {
                    cx.notify();
                }
            });
        })
        .detach();
    }

    pub(super) fn inspector_body(&self, top_band: f32, dark: bool, cx: &Context<Self>) -> Div {
        if matches!(
            self.navigation.route,
            Route::Global {
                section: GlobalSection::Insights
            }
        ) && self.home.requested_scope == crate::home::ActivityScope::AllMachines
        {
            let fit = self.layout.fit;
            return div()
                .h_full()
                .pt(px(top_band))
                .p(px(12.))
                .flex()
                .flex_col()
                .gap(px(12.))
                .child(
                    div()
                        .flex()
                        .items_center()
                        .child(label(
                            l("apple.insightsview.all_devices.0594fe82"),
                            13.,
                            600,
                            fit,
                        ))
                        .child(div().flex_1())
                        .child(
                            div()
                                .id("close-account-insights-inspector")
                                .cursor_pointer()
                                .child(label(l("common.close"), 12., 400, fit))
                                .on_click(cx.listener(|view, _, _, cx| {
                                    view.layout.close_inspector();
                                    cx.notify();
                                })),
                        ),
                )
                .child(
                    label(
                        l("apple.insightsview.aggregated_model_coding_tool_and_daily_usa.c5f79ddb"),
                        12.,
                        400,
                        fit,
                    )
                    .text_color(secondary(dark)),
                )
                .child(div().flex_1());
        }
        if matches!(
            self.navigation.route,
            Route::Global {
                section: GlobalSection::Insights
            }
        ) {
            return self.local_insights_inspector(top_band, dark, cx);
        }
        if self.navigation.route != Route::default() {
            return label(
                "Desktop preview: inspector content is still being ported.",
                12.,
                400,
                self.layout.fit,
            )
            .p(px(16.));
        }
        let fit = self.layout.fit;
        let close = div()
            .id("close-home-inspector")
            .size(px(30.))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .cursor_pointer()
            .on_click(cx.listener(|view, _, _, cx| {
                view.layout.close_inspector();
                cx.notify();
            }))
            .child(
                div()
                    .size(px(22.))
                    .rounded_full()
                    .border_1()
                    .border_color(palette::BORDER.opacity(0.55).resolve(dark))
                    .bg(palette::CONTROL_SEAT.resolve(dark))
                    .flex()
                    .items_center()
                    .justify_center()
                    .hover(|s| s.bg(palette::ROW_HIGHLIGHT.resolve(dark)))
                    .child(icon("xmark", 10., palette::CONTROL_GLYPH.resolve(dark))),
            );
        let header = presentation::chrome_bar(dark)
            .px(px(0.))
            .bg(palette::SIDEBAR.resolve(dark))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .pl(px(12.))
                    .child(
                        div()
                            .size(px(24.))
                            .flex_none()
                            .rounded(px(6.))
                            .bg(palette::ACCENT.opacity(0.12).resolve(dark))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(icon("calendar", 13., palette::ACCENT.resolve(dark))),
                    )
                    .child(label(l("apple.homeinspector.day.8f2364e1"), 13., 600, fit)),
            )
            .child(div().flex_1())
            .child(div().pr(px(8.)).child(close));
        let mut scroll = div()
            .id("home-day-inspector-scroll")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll();
        if let Some(day) = &self.home.selected {
            let mut content = div().p(px(12.)).flex().flex_col().gap(px(12.));
            if day.locked {
                content = content.child(
                    label(
                        l("apple.homeinspector.this_day_is_outside_the_unlocked_window.0d92dfdb"),
                        12.,
                        400,
                        fit,
                    )
                    .text_color(secondary(dark)),
                );
            } else if self.home.days.selected.loading && self.home.days.selected.value.is_none() {
                content = content.child(loading(
                    "apple.homeinspector.loading_day.758e26f6",
                    false,
                    dark,
                    fit,
                ));
            } else if let Some(detail) = &self.home.days.selected.value {
                content = content.child(self.day_overview(detail, dark, cx));
            } else {
                content = content.child(
                    label(
                        l("apple.homeinspector.nothing_recorded_on_this_day.5ad77ba8"),
                        12.,
                        400,
                        fit,
                    )
                    .text_color(secondary(dark)),
                );
            }
            scroll = scroll.child(content);
        } else {
            scroll = scroll.flex().items_center().justify_center().child(
                div()
                    .w_full()
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap(px(10.))
                    .child(feature("mark_activity", 28., dark))
                    .child(label(
                        l("apple.homeinspector.today_opens_here.a6818424"),
                        13.,
                        600,
                        fit,
                    ).text_color(primary(dark).opacity(0.75)))
                    .child(
                        label(
                            l("apple.homeinspector.the_heatmap_is_still_loading_hover_a_day_f.566fb595"),
                            11.,
                            400,
                            fit,
                        )
                        .max_w(px(360.))
                        .text_center()
                        .text_color(secondary(dark)),
                    ),
            );
        }
        let mut out = div()
            .h_full()
            .w_full()
            .flex()
            .flex_col()
            .pt(px(top_band))
            .bg(palette::BACKGROUND.resolve(dark))
            .child(header)
            .child(scroll);
        if self.home.selected.is_some() {
            out = out.child(
                div()
                    .flex_none()
                    .bg(palette::SIDEBAR.resolve(dark))
                    .child(rule(dark))
                    .child(
                        div().px(px(12.)).py(px(8.)).child(
                            div()
                                .id("open-day-insights")
                                .h(px(30.))
                                .w_full()
                                .rounded(px(8.))
                                .border_1()
                                .border_color(palette::ACCENT.opacity(0.35).resolve(dark))
                                .bg(palette::ACCENT_SOFT.resolve(dark))
                                .text_color(palette::ACCENT.resolve(dark))
                                .flex()
                                .items_center()
                                .justify_center()
                                .gap(px(4.))
                                .cursor_pointer()
                                .child(presentation::system_text(
                                    l("apple.homeinspector.open_in_insights.5529d386"),
                                    13.,
                                    500,
                                    cx,
                                ))
                                .child(icon("arrow.right", 11., palette::ACCENT.resolve(dark)))
                                .on_click(cx.listener(|view, _, window, cx| {
                                    view.command(Command::OpenSelectedDayInInsights, window, cx)
                                })),
                        ),
                    ),
            );
        }
        out
    }

    fn day_overview(&self, detail: &DayDetail, dark: bool, cx: &App) -> Div {
        let fit = self.layout.fit;
        let extra = self.home.days.overview.value.as_ref();
        let mut headline = vec![
            localization::text(
                "apple.homeinspector.0_tokens.624f11b9",
                &[&display::tokens(detail.tokens)],
            ),
            localization::text(
                "apple.homeinspector.0_requests.26f9894c",
                &[&display::integer(detail.events)],
            ),
        ];
        if let Some(totals) = extra.and_then(|e| e.totals.as_ref()) {
            headline.push(localization::text(
                "apple.homeinspector.0_sessions.42cfea31",
                &[&display::integer(totals.sessions)],
            ));
        }
        let mut out = div()
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(label(
                display::friendly_date(&detail.date, false),
                15.,
                600,
                fit,
            ))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.))
                    .child(
                        label(
                            l("apple.homeinspector.api_list_price.060458ef").to_uppercase(),
                            12.,
                            600,
                            fit,
                        )
                        .text_color(tertiary(dark)),
                    )
                    .child(
                        div()
                            .flex()
                            .items_baseline()
                            .gap(px(4.))
                            .child(
                                number(detail.value(), 22., 500, fit)
                                    .text_color(palette::ACCENT.resolve(dark)),
                            )
                            .child(
                                presentation::numeric_system_note(
                                    if detail.estimated {
                                        "estimated".into()
                                    } else {
                                        l("apple.homeinspector.not_an_extra_bill.79d2c7ad")
                                    },
                                    FontToken {
                                        points: fit.text(22.),
                                        weight: 500,
                                    },
                                    10.,
                                    cx,
                                )
                                .text_color(secondary(dark)),
                            ),
                    ),
            )
            .child(label(headline.join(" · "), 10., 400, fit).text_color(secondary(dark)));
        let mut counters = div().flex().flex_col().gap(px(4.));
        for (key, value) in [
            "fresh_input.a5156480",
            "cache_read.0008ce30",
            "cache_write_5m.bf7e82f8",
            "cache_write_1h.80055f01",
            "output.b2439bcb",
        ]
        .into_iter()
        .zip(detail.counters())
        {
            counters = counters.child(
                div()
                    .flex()
                    .items_center()
                    .child(
                        label(l(&format!("apple.homeinspector.{key}")), 10., 400, fit)
                            .text_color(secondary(dark)),
                    )
                    .child(div().flex_1())
                    .child(
                        number(
                            value
                                .map(display::tokens)
                                .unwrap_or_else(|| l("apple.homeinspector.n_a.a683c5c5")),
                            11.,
                            400,
                            fit,
                        )
                        .text_color(if value.is_some() {
                            primary(dark)
                        } else {
                            tertiary(dark)
                        }),
                    ),
            );
        }
        out = out
            .child(counters)
            .child(split(
                detail,
                (self.layout.inspector_width - 24.).max(2.),
                false,
                dark,
                fit,
            ))
            .child(self.day_group(
                "apple.homeinspector.models.d17d2d78",
                "apple.homeinspector.api_list_price.060458ef",
                model_rows(detail, extra, false),
                GroupPresentation::Priced,
                dark,
                cx,
            ))
            .child(self.day_group(
                "apple.homeinspector.coding_tools.6032f740",
                "apple.homeinspector.which_agent_produced_the_tokens.d4a409e3",
                harness_rows(detail, extra),
                GroupPresentation::Tools,
                dark,
                cx,
            ));
        if let Some(extra) = extra {
            if !extra.by_project.is_empty() {
                out = out.child(self.day_group(
                    "common.projects",
                    "apple.homeinspector.where_the_work_happened.250180a6",
                    bucket_rows(&extra.by_project),
                    GroupPresentation::Plain,
                    dark,
                    cx,
                ));
            }
            if !extra.by_session.is_empty() {
                out = out.child(self.day_group(
                    "apple.homeinspector.sessions.6fa3cbf4",
                    "apple.homeinspector.this_device.d052579c",
                    bucket_rows(&extra.by_session),
                    GroupPresentation::Plain,
                    dark,
                    cx,
                ));
            }
        }
        if !detail.unpriced_models.is_empty() {
            out = out.child(self.day_group(
                "apple.homeinspector.unpriced_local_models.620f0ccf",
                "apple.homeinspector.no_api_price_tokens_still_counted.9fd4e18e",
                model_rows(detail, extra, true),
                GroupPresentation::Plain,
                dark,
                cx,
            ));
        }
        if self.home.days.overview.loading {
            out = out.child(loading(
                "apple.homeinspector.loading_breakdown.98c86f22",
                true,
                dark,
                fit,
            ));
        }
        out
    }
    fn day_group(
        &self,
        title: &str,
        subtitle: &str,
        rows: Vec<GroupRow>,
        presentation: GroupPresentation,
        dark: bool,
        cx: &App,
    ) -> Div {
        let value = matches!(presentation, GroupPresentation::Priced);
        let harness = matches!(presentation, GroupPresentation::Tools);
        let fit = self.layout.fit;
        let mut card = presentation::card_surface(dark)
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .child(feature(
                        if harness {
                            "mark_automation"
                        } else {
                            "mark_insights"
                        },
                        22.,
                        dark,
                    ))
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(2.))
                            .child(presentation::system_text(l(title), fit.text(13.), 600, cx))
                            .child(
                                presentation::system_text(l(subtitle), 10., 400, cx)
                                    .text_color(secondary(dark)),
                            ),
                    ),
            );
        if rows.is_empty() {
            return card.child(
                label(
                    l("apple.homeinspector.nothing_recorded_yet.17f000e0"),
                    10.,
                    400,
                    fit,
                )
                .text_color(tertiary(dark)),
            );
        }
        let mut list = div().flex().flex_col().gap(px(8.));
        for row in rows.iter().take(8) {
            let title = if row.monospaced {
                presentation::monospaced(
                    row.label.clone(),
                    FontToken {
                        points: fit.text(12.),
                        weight: 400,
                    },
                )
            } else {
                label(row.label.clone(), 12., 400, fit)
            };
            list = list.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .when(harness, |d| d.child(harness_mark(&row.key, 15., dark)))
                    .child(title.flex_1().min_w_0().truncate())
                    .child(
                        number(display::tokens(row.tokens), 11., 400, fit)
                            .text_color(secondary(dark)),
                    )
                    .when(value, |d| {
                        d.when_some(row.value.clone(), |d, v| {
                            d.child(number(v, 11., 400, fit).text_color(secondary(dark)))
                        })
                    }),
            );
        }
        if rows.len() > 8 {
            list = list.child(
                label(
                    localization::text(
                        "apple.homeinspector.and_0_more.938c3a14",
                        &[&(rows.len() - 8).to_string()],
                    ),
                    10.,
                    400,
                    fit,
                )
                .text_color(tertiary(dark)),
            );
        }
        card = card.child(list);
        card
    }

    pub(super) fn day_popover(&self, window: gpui::Size<gpui::Pixels>, dark: bool) -> Div {
        let Some(anchor) = &self.hover_anchor else {
            return div();
        };
        let reading = &self.home.days.hovered;
        if reading.date.as_deref() != Some(&anchor.date)
            || (reading.value.is_none() && !reading.loading)
        {
            return div();
        }
        let fit = self.layout.fit;
        let geometry = PopoverGeometry::new(
            Some(anchor.rect),
            f64::from(f32::from(window.width)),
            f64::from(f32::from(window.height)),
        );
        let mut card = presentation::card_surface(dark)
            .p(px(11.))
            .w(px(geometry.width as f32))
            .shadow_lg()
            .flex()
            .flex_col()
            .gap(px(6.));
        if let Some(detail) = &reading.value {
            card = card
                .h(px(geometry.height as f32))
                .child(
                    label(
                        l("apple.daydetailpopover.selected_day.43c93a22"),
                        9.,
                        600,
                        fit,
                    )
                    .text_color(tertiary(dark)),
                )
                .child(label(
                    display::friendly_date(&detail.date, true),
                    15.,
                    600,
                    fit,
                ))
                .child(
                    div()
                        .flex()
                        .items_baseline()
                        .gap(px(6.))
                        .child(number(detail.value(), 14., 500, fit))
                        .when(!detail.estimated, |d| {
                            d.child(
                                label(
                                    l("apple.daydetailpopover.at_api_list_price.128de85c"),
                                    10.,
                                    400,
                                    fit,
                                )
                                .text_color(tertiary(dark)),
                            )
                        }),
                )
                .child(
                    label(
                        localization::text(
                            "apple.daydetailpopover.0_tokens_1_requests.02bc82f3",
                            &[
                                &display::tokens(detail.tokens),
                                &display::integer(detail.events),
                            ],
                        ),
                        10.,
                        400,
                        fit,
                    )
                    .text_color(secondary(dark)),
                );
            if !detail.rows.is_empty() {
                static HASHER: OnceLock<RandomState> = OnceLock::new();
                let mut rows = div()
                    .flex_1()
                    .min_h_0()
                    .max_h(px(150.))
                    .overflow_hidden()
                    .flex()
                    .flex_col()
                    .gap(px(5.));
                for part in detail.rows.iter().take(8) {
                    // Swift's hashValue is also process-seeded. This preserves
                    // stable per-pair colours within the same source palette.
                    let index = HASHER
                        .get_or_init(RandomState::new)
                        .hash_one(format!("{}\u{1}{}", part.src, part.model))
                        % 5;
                    let color = match index {
                        0 => palette::ACCENT.resolve(dark),
                        1 => palette::HEAT[4].resolve(dark),
                        2 => palette::HEAT[3].resolve(dark),
                        3 => palette::HEAT[2].resolve(dark),
                        _ => palette::HEAT[1].resolve(dark),
                    };
                    rows = rows.child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(7.))
                            .child(div().size(px(6.)).flex_none().rounded_full().bg(color))
                            .child(
                                label(
                                    format!(
                                        "{} · {}",
                                        display::short_model(&part.model),
                                        display::harness_name(display::harness_key(&part.src))
                                    ),
                                    11.,
                                    400,
                                    fit,
                                )
                                .flex_1()
                                .min_w_0()
                                .truncate(),
                            )
                            .child(
                                number(display::tokens(part.tokens), 11., 500, fit)
                                    .text_color(secondary(dark)),
                            ),
                    );
                }
                card = card.child(rule(dark)).child(rows);
                if detail.rows.len() > 8 {
                    card = card.child(
                        label(
                            localization::text(
                                "apple.daydetailpopover.0_more.3f1d2fb4",
                                &[&(detail.rows.len() - 8).to_string()],
                            ),
                            10.,
                            500,
                            fit,
                        )
                        .text_color(tertiary(dark)),
                    );
                }
                card = card.child(split(
                    detail,
                    (geometry.width - 24.) as f32,
                    true,
                    dark,
                    fit,
                ));
            }
        } else {
            card = card.child(loading(
                "apple.daydetailpopover.loading_day.758e26f6",
                false,
                dark,
                fit,
            ));
        }
        // The source centres even its shorter loading card in the same clamped
        // position. A populated card has the source's fixed 330-point seat.
        let height = if reading.value.is_some() {
            geometry.height
        } else {
            38.
        };
        div()
            .absolute()
            .left(px((geometry.center_x - geometry.width / 2.) as f32))
            .top(px((geometry.center_y - height / 2.) as f32))
            .child(card)
    }
}
