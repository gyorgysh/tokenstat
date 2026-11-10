// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! This-device Insights inspector: period, selected row and local archive.
//! Native typography, text selection and visual acceptance remain open.

use super::*;
use crate::{display, insights::Tab};

fn label(value: impl IntoElement, points: f32, weight: u16, fit: DisplayFit) -> Div {
    text(
        value,
        FontToken {
            points: fit.text(points),
            weight,
        },
    )
}

fn stat(
    title: &str,
    value: String,
    note: Option<String>,
    size: f32,
    fit: DisplayFit,
    dark: bool,
) -> Div {
    let mut row = div().flex().items_end().gap(px(4.)).child(
        presentation::numeric(
            value,
            FontToken {
                points: fit.text(size),
                weight: 500,
            },
        )
        .truncate(),
    );
    if let Some(note) = note {
        row = row.child(
            label(note, 10., 400, fit)
                .text_color(secondary(dark))
                .truncate(),
        );
    }
    div()
        .flex()
        .flex_col()
        .min_w_0()
        .gap(px(4.))
        .child(
            label(title.to_uppercase(), 10., 600, fit)
                .text_color(secondary(dark))
                .truncate(),
        )
        .child(row)
}

fn pair(
    first: (&str, String),
    second: (&str, String),
    wide: bool,
    fit: DisplayFit,
    dark: bool,
) -> Div {
    let first = stat(first.0, first.1, None, 15., fit, dark);
    let second = stat(second.0, second.1, None, 15., fit, dark);
    if wide {
        div()
            .w_full()
            .flex()
            .gap(px(12.))
            .child(first.flex_1())
            .child(second.flex_1())
    } else {
        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(4.))
            .child(first)
            .child(second)
    }
}

fn card(title: &str, mark: &str, dark: bool, fit: DisplayFit, cx: &App) -> Div {
    presentation::card_surface(dark)
        .w_full()
        .flex()
        .flex_col()
        .gap(px(12.))
        .child(super::home_panels::card_header(
            l(title),
            None,
            super::day_view::feature(mark, 22., dark),
            fit,
            dark,
            cx,
        ))
}

fn empty(symbol: &'static str, title: &str, message: &str, dark: bool, fit: DisplayFit) -> Div {
    div()
        .w_full()
        .flex()
        .flex_col()
        .items_center()
        .gap(px(8.))
        .px(px(20.))
        .py(px(32.))
        .child(icon(
            symbol,
            28.,
            palette::ACCENT.opacity(0.7).resolve(dark),
        ))
        .child(label(l(title), 14., 600, fit).text_center())
        .child(
            label(l(message), 12., 400, fit)
                .text_center()
                .text_color(secondary(dark)),
        )
}

fn key_value(key: &str, value: String, fit: DisplayFit, dark: bool) -> Div {
    div()
        .w_full()
        .flex()
        .items_center()
        .gap(px(8.))
        .child(label(key.to_string(), 10., 400, fit).text_color(secondary(dark)))
        .child(div().flex_1())
        .child(
            presentation::monospaced(
                value,
                FontToken {
                    points: fit.text(10.),
                    weight: 400,
                },
            )
            .min_w_0()
            .truncate(),
        )
}

impl Desktop {
    pub(super) fn local_insights_inspector(
        &self,
        top_band: f32,
        dark: bool,
        cx: &Context<Self>,
    ) -> Div {
        let fit = self.layout.fit;
        let wide = self.layout.inspector_width - 2. * (12. + 16.) >= 260.;
        let close = div()
            .id("close-local-insights-inspector")
            .size(px(30.))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .cursor_pointer()
            .tooltip(|_, cx| {
                cx.new(|_| Tooltip(l("apple.theme.close_the_inspector.eddd7e3c")))
                    .into()
            })
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
            .border_b_1()
            .border_color(palette::BORDER.resolve(dark))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .pl(px(12.))
                    .child(
                        div()
                            .size(px(24.))
                            .rounded(px(6.))
                            .bg(palette::ACCENT.opacity(0.12).resolve(dark))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(icon("chart.bar.xaxis", 13., palette::ACCENT.resolve(dark))),
                    )
                    .child(label(l("common.insights"), 13., 600, fit)),
            )
            .child(div().flex_1())
            .child(div().pr(px(8.)).child(close));

        let snapshot = self.insights.snapshot.as_ref();
        let mut period = card(
            "apple.inspectorview.this_period.8ed3e11f",
            "mark_insights",
            dark,
            fit,
            cx,
        );
        if self.insights.inspector_empty_archive() {
            period = period.child(empty(
                "tray",
                "apple.inspectorview.nothing_scanned_yet.b0a2718e",
                "apple.inspectorview.tokenstat_reads_the_session_logs_the_tools.bdd2445b",
                dark,
                fit,
            ));
        } else {
            let total = snapshot.map_or(0, |s| s.totals.counters.total);
            let sessions = snapshot.map_or(0, |s| s.totals.sessions);
            let events = snapshot.map_or(0, |s| s.totals.events);
            let days = snapshot.map_or(0, |s| s.totals.days);
            let value = snapshot.map_or_else(
                || display::money(0, false, true),
                |s| crate::insights::model_value(&s.by_model),
            );
            period = period
                .child(
                    stat(
                        &l("apple.inspectorview.api_list_price.060458ef"),
                        value,
                        Some(l("apple.inspectorview.not_an_extra_bill.79d2c7ad")),
                        if fit.factor < 1. { 22. } else { 26. },
                        fit,
                        dark,
                    )
                    .text_color(palette::ACCENT.resolve(dark)),
                )
                .child(pair(
                    (
                        &l("apple.inspectorview.tokens.a039dfb9"),
                        display::tokens(total),
                    ),
                    (
                        &l("apple.inspectorview.sessions.6fa3cbf4"),
                        sessions.to_string(),
                    ),
                    wide,
                    fit,
                    dark,
                ))
                .child(pair(
                    (
                        &l("apple.inspectorview.events.8d14f6e7"),
                        display::tokens(events),
                    ),
                    (
                        &l("apple.inspectorview.active_days.6cbebfa2"),
                        days.to_string(),
                    ),
                    wide,
                    fit,
                    dark,
                ));
            if let Some(block) = snapshot.and_then(|s| s.active_block.as_ref()) {
                let when = display::local_short_time(block.start_ms).unwrap_or_default();
                period = period
                    .child(div().h(px(1.)).w_full().bg(palette::BORDER.resolve(dark)))
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(4.))
                            .child(label(
                                l("apple.inspectorview.block_open.1bc5df29"),
                                10.,
                                500,
                                fit,
                            ))
                            .child(
                                label(
                                    localization::text(
                                        "apple.inspectorview.0_since_1.8570f4f3",
                                        &[&display::tokens(block.counters.total), &when],
                                    ),
                                    10.,
                                    400,
                                    fit,
                                )
                                .text_color(secondary(dark)),
                            ),
                    );
            }
        }

        let mut selected = card(
            "apple.inspectorview.selected.57fd7a0c",
            "mark_activity",
            dark,
            fit,
            cx,
        );
        if let Some(row) = &self.insights.selected {
            let title = if row.key.is_empty() {
                l("apple.inspectorview.unknown.b23a6a84")
            } else {
                row.key.clone()
            };
            selected = selected
                .child(presentation::monospaced(
                    title,
                    FontToken {
                        points: fit.text(12.),
                        weight: 400,
                    },
                ))
                .child(stat(
                    &l("apple.inspectorview.value.8e37953d"),
                    display::money(
                        row.value_micros,
                        row.estimated,
                        row.unpriced_models.is_empty(),
                    ),
                    None,
                    18.,
                    fit,
                    dark,
                ));
            let mut counters = div().flex().flex_col().gap(px(4.));
            for (key, value) in [
                (
                    "apple.inspectorview.fresh_input.a5156480",
                    row.counters.input_fresh,
                ),
                (
                    "apple.inspectorview.cache_read.0008ce30",
                    row.counters.cache_read,
                ),
                (
                    "apple.inspectorview.cache_write_5m.bf7e82f8",
                    row.counters.cache_write_5m,
                ),
                (
                    "apple.inspectorview.cache_write_1h.80055f01",
                    row.counters.cache_write_1h,
                ),
                ("apple.inspectorview.output.b2439bcb", row.counters.output),
            ] {
                counters = counters.child(
                    div()
                        .w_full()
                        .flex()
                        .gap(px(8.))
                        .child(label(l(key), 10., 400, fit).text_color(secondary(dark)))
                        .child(div().flex_1())
                        .child(
                            presentation::numeric(
                                value.map_or_else(
                                    || l("apple.inspectorview.n_a.a683c5c5"),
                                    display::tokens,
                                ),
                                FontToken {
                                    points: fit.text(11.),
                                    weight: 400,
                                },
                            )
                            .when(value.is_none(), |d| d.text_color(secondary(dark))),
                        ),
                );
            }
            selected = selected.child(counters);
            if row.counters.has_unknown {
                selected = selected.child(label(l("apple.inspectorview.a_dash_means_the_tool_does_not_report_that.ebcc68a5"), 10., 400, fit).text_color(secondary(dark)));
            }
            selected = selected.child(pair(
                (
                    &l("apple.inspectorview.sessions.6fa3cbf4"),
                    row.sessions.to_string(),
                ),
                (
                    &l("apple.inspectorview.events.8d14f6e7"),
                    display::tokens(row.events),
                ),
                wide,
                fit,
                dark,
            ));
            if self.insights.tab == Tab::Projects {
                let harnesses = self.insights.selected_project_harnesses();
                if !harnesses.is_empty() {
                    let mut group = div().flex().flex_col().gap(px(4.)).child(label(
                        l("apple.inspectorview.coding_tools_here.599781a1"),
                        10.,
                        500,
                        fit,
                    ));
                    for item in harnesses {
                        group = group.child(
                            div()
                                .flex()
                                .items_center()
                                .gap(px(8.))
                                .child(super::day_view::harness_mark(&item.split, 14., dark))
                                .child(label(display::harness_name(&item.split), 10., 400, fit))
                                .child(div().flex_1())
                                .child(
                                    presentation::numeric(
                                        display::tokens(item.counters.total),
                                        FontToken {
                                            points: fit.text(10.),
                                            weight: 400,
                                        },
                                    )
                                    .text_color(secondary(dark)),
                                ),
                        );
                    }
                    selected = selected.child(group);
                }
            }
            if !row.unpriced_models.is_empty() {
                let mut group = div().flex().flex_col().gap(px(4.)).child(label(
                    l("apple.inspectorview.unpriced_models.09fe601e"),
                    10.,
                    500,
                    fit,
                ));
                for name in &row.unpriced_models {
                    group = group.child(
                        presentation::monospaced(
                            name.clone(),
                            FontToken {
                                points: fit.text(10.),
                                weight: 400,
                            },
                        )
                        .text_color(secondary(dark)),
                    );
                }
                selected = selected.child(group);
            }
        } else {
            selected = selected.child(empty(
                "hand.tap",
                "apple.inspectorview.nothing_selected.f8c10424",
                "apple.inspectorview.pick_a_row_on_the_left_to_see_what_it_is_m.4837e049",
                dark,
                fit,
            ));
        }
        let mut archive = card("common.archive", "mark_archive", dark, fit, cx);
        if let Some(info) = snapshot.map(|s| &s.info) {
            archive = archive
                .child(key_value("Timezone", info.timezone.clone(), fit, dark))
                .child(key_value("Core", info.core_version.clone(), fit, dark))
                .child(key_value("Host", "daemon".into(), fit, dark));
            if info.has_prices {
                archive = archive.child(key_value(
                    "Rates from",
                    info.price_book_effective_from.clone(),
                    fit,
                    dark,
                ));
            } else {
                archive = archive.child(
                    label(
                        l("apple.inspectorview.no_price_book_yet_so_values_are_estimated.3e76ee99"),
                        10.,
                        400,
                        fit,
                    )
                    .text_color(rgb(0xe0a93b)),
                );
            }
        }
        archive = archive.child(
            label(
                l("apple.inspectorview.read_from_this_device_nothing_left_it.0c693058"),
                10.,
                400,
                fit,
            )
            .pt(px(4.))
            .text_color(secondary(dark)),
        );
        div()
            .h_full()
            .pt(px(top_band))
            .flex()
            .flex_col()
            .child(header)
            .child(
                div()
                    .id("local-insights-inspector-scroll")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .child(
                        div()
                            .p(px(12.))
                            .flex()
                            .flex_col()
                            .gap(px(12.))
                            .child(period)
                            .child(selected)
                            .child(archive),
                    ),
            )
    }
}
