// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Home's source-shaped archive figures and vendor/subscription panels.

use super::*;
use super::{
    day_view::{feature, harness_mark},
    home_shared::HomeShared,
};
use crate::{
    display,
    home::{
        layout::Section,
        plans::{self, Provider, Severity},
    },
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
fn numeric(value: impl IntoElement, points: f32, weight: u16, fit: DisplayFit) -> Div {
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
fn quota_color(severity: Severity, dark: bool) -> gpui::Hsla {
    severity.tint().resolve(dark)
}
pub(super) fn card_header(
    title: String,
    subtitle: Option<String>,
    leading: Div,
    fit: DisplayFit,
    dark: bool,
    cx: &App,
) -> Div {
    let mut title_box = div()
        .flex_1()
        .min_w_0()
        .flex()
        .flex_col()
        .gap(px(2.))
        .child(presentation::system_text(title, fit.text(13.), 600, cx));
    if let Some(subtitle) = subtitle {
        title_box = title_box
            .child(presentation::system_text(subtitle, 10., 400, cx).text_color(secondary(dark)))
    }
    div()
        .flex()
        .items_center()
        .gap(px(8.))
        .child(leading)
        .child(title_box)
}
impl Desktop {
    pub(super) fn clear_home(&self, dark: bool, cx: &Context<Self>) -> Div {
        presentation::card_surface(dark)
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(card_header(
                l("apple.homeview.your_home_is_clear.9ae93db2"),
                Some(l(
                    "apple.homeview.your_work_is_still_in_the_sidebar.88f122e8",
                )),
                div()
                    .size(px(24.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(6.))
                    .bg(palette::ACCENT_SOFT.resolve(dark))
                    .child(icon("house", 12., palette::ACCENT.resolve(dark))),
                self.layout.fit,
                dark,
                cx,
            ))
            .child(
                div().flex().child(
                    div()
                        .id("clear-home-customize")
                        .h(px(30.))
                        .px(px(13.))
                        .rounded(px(8.))
                        .border_1()
                        .border_color(palette::BORDER.resolve(dark))
                        .bg(palette::PANEL.resolve(dark))
                        .flex()
                        .items_center()
                        .gap(px(6.))
                        .cursor_pointer()
                        .child(icon("square.grid.2x2", 12., primary(dark)))
                        .child(presentation::system_text(
                            l("apple.homeview.customize_home.642cec6e"),
                            13.,
                            500,
                            cx,
                        ))
                        .on_click(cx.listener(|view, _, window, cx| {
                            view.command(Command::CustomizeHome, window, cx)
                        })),
                ),
            )
    }
    pub(super) fn home_section(
        &self,
        section: Section,
        width: f32,
        dark: bool,
        cx: &Context<Self>,
    ) -> Div {
        match section {
            Section::Usage => self.usage_summary(dark, cx),
            Section::Activity => self.activity_card(width, dark, cx),
            Section::Limits => self.plan_panels(width, dark, cx),
            Section::Machines => self.home_devices(dark, cx),
            Section::Continue => self.home_continue(dark, cx),
            Section::Pinned => self.home_pins(dark, cx),
        }
    }
    fn figure_panel(&self, title: &str, value: String, note: Option<String>, dark: bool) -> Div {
        let fit = self.layout.fit;
        presentation::card_surface(dark)
            .flex_1()
            .min_w_0()
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .child(feature("mark_insights", 22., dark))
                    .child(label(l(title), 13., 600, fit))
                    .child(div().flex_1()),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .child(numeric(value, 20., 500, fit).truncate())
                    .when_some(note, |d, n| {
                        d.child(
                            label(n, 10., 400, fit)
                                .text_color(secondary(dark))
                                .truncate(),
                        )
                    }),
            )
    }
    fn usage_summary(&self, dark: bool, cx: &App) -> Div {
        if let Some(grid) = &self.home.calendar {
            let mut row = div()
                .w_full()
                .flex()
                .gap(px(8.))
                .child(self.figure_panel("common.today", grid.today_value(), None, dark))
                .child(self.figure_panel(
                    "apple.homeview.last_7_days.0603deca",
                    grid.week_value(),
                    None,
                    dark,
                ));
            if let Some(day) = &grid.busiest {
                row = row.child(self.figure_panel(
                    "apple.homeview.busiest.5192c2fb",
                    crate::home::format_spend(day.value),
                    Some(day.date.clone()),
                    dark,
                ))
            }
            return row;
        }
        let mut card = presentation::card_surface(dark)
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(card_header(
                l("apple.homeview.today_and_this_week.2cb0c4ae"),
                None,
                feature("mark_insights", 22., dark),
                self.layout.fit,
                dark,
                cx,
            ));
        if self.home.error.is_some() {
            card = card.child(
                label(
                    l("apple.homeview.usage_could_not_be_read_see_the_message_ab.e05837aa"),
                    12.,
                    400,
                    self.layout.fit,
                )
                .text_color(secondary(dark)),
            )
        } else {
            card = card.child(
                div()
                    .h(px(40.))
                    .w_full()
                    .rounded(px(4.))
                    .bg(palette::ROW_HIGHLIGHT.resolve(dark)),
            )
        }
        card
    }
    fn plan_panels(&self, width: f32, dark: bool, cx: &Context<Self>) -> Div {
        let shared = cx.global::<HomeShared>();
        let reads = &shared.reads;
        let plans = reads.home(self.plan_reader);
        let providers = reads.visible();
        let count = providers.len() + usize::from(!plans.by_source.is_empty());
        let mut out = div().flex().flex_col().gap(px(8.));
        if let Some(error) = plans.error() {
            out = out.child(
                label(error.to_string(), 12., 400, self.layout.fit)
                    .text_color(palette::DANGER.resolve(dark)),
            )
        }
        if count > 0 {
            shared.clock_read.set(true);
            let columns = plans::columns(
                f64::from(width),
                count,
                f64::from(self.layout.fit.text(330.)),
            );
            let mut panels: Vec<Option<&Provider>> = providers.into_iter().map(Some).collect();
            if !plans.by_source.is_empty() {
                panels.push(None)
            }
            while !panels.is_empty() {
                let n = columns.min(panels.len());
                let panel_width = ((width - (n.saturating_sub(1) as f32) * 8.) / n as f32).max(0.);
                out = out.child(
                    div()
                        .w_full()
                        .flex()
                        .gap(px(8.))
                        .children(panels.drain(..n).map(|p| match p {
                            Some(p) => {
                                self.provider_panel(p, panel_width, shared.clock_ms, dark, cx)
                            }
                            None => self.plan_usage_card(dark, cx),
                        })),
                );
            }
        }
        if plans.loading() && reads.state().is_none_or(|s| s.providers.is_empty()) {
            out = out.child(
                presentation::card_surface(dark)
                    .w(px(self.layout.fit.text(330.)))
                    .flex()
                    .flex_col()
                    .gap(px(12.))
                    .children([11., 10., 10.].into_iter().enumerate().map(|(i, h)| {
                        div()
                            .h(px(h))
                            .when(i == 0, |d| d.w(px(96.)))
                            .when(i != 0, |d| d.w_full())
                            .rounded(px(4.))
                            .bg(palette::ROW_HIGHLIGHT.resolve(dark))
                    })),
            );
        }
        out
    }
    fn provider_panel(
        &self,
        provider: &Provider,
        width: f32,
        now: i64,
        dark: bool,
        cx: &Context<Self>,
    ) -> Div {
        let fit = self.layout.fit;
        let mut subtitle = Vec::new();
        if let Some(plan) = provider.plan.as_deref().filter(|p| !p.is_empty()) {
            subtitle.push(display::capitalized(plan))
        }
        if provider.observed_at_ms > 0 {
            subtitle.push(localization::text(
                if provider.is_stale() {
                    "apple.planlimitscard.last_read_0.ee7c4998"
                } else {
                    "apple.planlimitscard.read_0.5e63e83a"
                },
                &[&display::relative_english(
                    provider.observed_at_ms,
                    now,
                    true,
                )],
            ))
        }
        if !provider.windows.is_empty()
            && let Some(next) = provider.next_reset_ms().filter(|n| *n > now)
        {
            subtitle.push(localization::text(
                "apple.planlimitscard.next_window_0.fcd7ac2d",
                &[&display::relative_english(next, now, true)],
            ))
        }
        let busy = cx
            .global::<HomeShared>()
            .reads
            .home(self.plan_reader)
            .loading();
        let header = card_header(
            display::harness_name(&provider.source),
            (!subtitle.is_empty()).then(|| subtitle.join(" · ")),
            harness_mark(&provider.source, 22., dark),
            fit,
            dark,
            cx,
        )
        .when(provider.is_stale(), |d| {
            d.child(icon(
                "clock.arrow.circlepath",
                11.,
                palette::WARNING.resolve(dark),
            ))
        })
        .child(
            div()
                .id(SharedString::from(format!(
                    "quota-refresh-{}",
                    provider.source
                )))
                .flex_none()
                .size(px(16.))
                .flex()
                .items_center()
                .justify_center()
                .cursor_pointer()
                .when(busy, |d| d.opacity(0.4))
                .child(icon(
                    if busy { "progress" } else { "arrow.clockwise" },
                    11.,
                    secondary(dark),
                ))
                .on_click(cx.listener(|view, _, _, cx| view.load_home_plans(true, cx))),
        );
        let mut body = div().flex().flex_col().gap(px(8.));
        if !provider.windows.is_empty() {
            for window in &provider.windows {
                let color = quota_color(window.severity, dark);
                let mut title = div()
                    .w_full()
                    .flex()
                    .items_center()
                    .gap(px(4.))
                    .child(label(window.display_label(), 12., 400, fit).text_color(secondary(dark)))
                    .child(div().flex_1())
                    .child(numeric(window.percent_text(), 12., 500, fit).text_color(color));
                if let Some(reset) = window.resets_at_ms {
                    title = title.child(
                        label(
                            localization::text(
                                "apple.planlimitscard.resets_0.7a4480e9",
                                &[&display::relative_english(reset, now, false)],
                            ),
                            11.,
                            400,
                            fit,
                        )
                        .text_color(tertiary(dark)),
                    )
                }
                body = body.child(
                    div().flex().flex_col().gap(px(3.)).child(title).child(
                        div()
                            .h(px(6.))
                            .w_full()
                            .rounded_full()
                            .bg(palette::ROW_HIGHLIGHT.resolve(dark))
                            .child(
                                div()
                                    .h(px(6.))
                                    .w(px(
                                        ((width - 32.).max(0.) * window.fraction() as f32).max(2.)
                                    ))
                                    .rounded_full()
                                    .bg(color),
                            ),
                    ),
                );
            }
            if provider.is_stale()
                && let Some(note) = &provider.note
            {
                body = body.child(label(note.clone(), 11., 400, fit).text_color(tertiary(dark)))
            }
        } else if let Some(note) = &provider.note {
            body = body.child(label(note.clone(), 12., 400, fit).text_color(secondary(dark)))
        }
        presentation::card_surface(dark)
            .flex_1()
            .min_w_0()
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(header)
            .child(body)
    }
    fn plan_usage_card(&self, dark: bool, cx: &App) -> Div {
        let fit = self.layout.fit;
        let mut rows = div().flex().flex_col();
        for row in &cx
            .global::<HomeShared>()
            .reads
            .home(self.plan_reader)
            .by_source
        {
            rows = rows.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .py(px(4.))
                    .child(harness_mark(&row.key, 20., dark))
                    .child(label(display::harness_name(&row.key), 13., 500, fit))
                    .child(div().flex_1().min_w(px(8.)))
                    .child(numeric(display::tokens(row.counters.total), 13., 500, fit))
                    .child(
                        label(l("apple.planusagecard.tokens.c51e455b"), 11., 400, fit)
                            .text_color(tertiary(dark)),
                    ),
            );
        }
        presentation::card_surface(dark)
            .flex_1()
            .min_w_0()
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(card_header(
                l("apple.planusagecard.plan_usage.eb55e923"),
                Some(l(
                    "apple.planusagecard.subscription_covered_usage_recorded_in_the.e96aa3c3",
                )),
                feature("mark_plan", 22., dark),
                fit,
                dark,
                cx,
            ))
            .child(rows)
    }
}
