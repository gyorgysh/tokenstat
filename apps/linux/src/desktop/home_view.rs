// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Initial Home profile and activity surfaces from HomeView/HeatmapView.swift.

use super::*;
use crate::{
    design::heatmap,
    home::{ActivityScope, Calendar, HeatmapGeometry, format_spend},
};
use gpui::{canvas, fill};
use std::{cell::Cell, rc::Rc, sync::Arc};

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

impl Desktop {
    pub(super) fn refresh_home(
        &mut self,
        scope: ActivityScope,
        force: bool,
        cx: &mut Context<Self>,
    ) {
        let request = self.home.begin(scope, scope == self.home.requested_scope);
        let Some(client) = self.client.clone() else {
            let result = Calendar::fixture(ActivityScope::ThisMachine)
                .map(|mut grid| {
                    if scope == ActivityScope::AllMachines {
                        grid.notice_code = Some("auth".into());
                    }
                    Some(grid)
                })
                .map_err(|e| e.to_string());
            self.home.finish(request, result);
            self.load_home_selection(cx);
            cx.notify();
            return;
        };
        let task = cx.background_executor().spawn(async move {
            client
                .activity_calendar(scope, force)
                .map_err(|e| format!("{e:#}"))
        });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                if view.home.finish(request, result) {
                    view.load_home_selection(cx);
                    cx.notify();
                }
            });
        })
        .detach();
        cx.notify();
    }

    pub(super) fn home_scope_picker(&self, dark: bool, cx: &Context<Self>) -> Div {
        div()
            .w(px(280.))
            .flex_none()
            .flex()
            .gap(px(4.))
            .p(px(2.))
            .rounded(px(10.))
            .bg(palette::PANEL.resolve(dark))
            .border_1()
            .border_color(palette::BORDER.resolve(dark))
            .children(ActivityScope::ALL.map(|scope| {
                let selected = self.home.requested_scope == scope;
                div()
                    .id(SharedString::from(format!(
                        "activity-scope-{}",
                        scope.wire()
                    )))
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .gap(px(4.))
                    .px(px(12.))
                    .py(px(6.))
                    .rounded(px(8.))
                    .cursor_pointer()
                    .when(selected, |d| d.bg(palette::ACCENT_SOFT.resolve(dark)))
                    .hover(|s| s.bg(palette::ROW_HIGHLIGHT.opacity(0.7).resolve(dark)))
                    .text_color(if selected {
                        palette::ACCENT.resolve(dark)
                    } else {
                        palette::CONTROL_GLYPH.resolve(dark)
                    })
                    .child(icon(
                        scope.symbol(),
                        11.,
                        if selected {
                            palette::ACCENT.resolve(dark)
                        } else {
                            palette::CONTROL_GLYPH.resolve(dark)
                        },
                    ))
                    .child(
                        text(
                            l(scope.label_key()),
                            FontToken {
                                points: 12.,
                                weight: 500,
                            },
                        )
                        .truncate(),
                    )
                    .on_click(cx.listener(move |view, _, _, cx| {
                        if view.home.requested_scope != scope {
                            view.refresh_home(scope, false, cx);
                            view.sync_account_insights(cx);
                            view.sync_local_insights(cx);
                        }
                    }))
            }))
    }

    pub(super) fn home_content(&self, width: f32, dark: bool, cx: &Context<Self>) -> Div {
        let fit = self.layout.fit;
        let mut content = div().flex().flex_col().gap(px(8.)).p(px(8.));
        if let Some(error) = self.preview_error(cx) {
            content = content.child(
                label(error.clone(), 12., 400, fit)
                    .p(px(12.))
                    .text_color(secondary(dark)),
            );
        }
        if let Some(error) = &self.home.error {
            content = content.child(
                label(error.clone(), 12., 400, fit)
                    .p(px(12.))
                    .text_color(secondary(dark)),
            );
        }
        if self.home.needs_sign_in() {
            content = content.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .p(px(12.))
                    .rounded(px(14.))
                    .bg(palette::ACCENT_SOFT.resolve(dark))
                    .child(icon("person.crop.circle", 14., secondary(dark)))
                    .child(
                        label(
                            l("apple.homeview.all_devices_needs_your_tokenstat_ai_accoun.019e31cd"),
                            12.,
                            400,
                            fit,
                        )
                        .flex_1()
                        .text_color(secondary(dark)),
                    )
                    .child(
                        div()
                            .id("home-sign-in")
                            .cursor_pointer()
                            .px(px(10.))
                            .py(px(4.))
                            .rounded(px(6.))
                            .bg(palette::ACCENT.resolve(dark))
                            .text_color(rgb(0xffffff))
                            .child(label(l("common.sign_in"), 12., 500, fit))
                            .on_click(cx.listener(|view, _, window, cx| {
                                view.command(Command::SignIn, window, cx)
                            })),
                    ),
            );
        }
        let shared = cx.global::<super::home_shared::HomeShared>();
        if let Some(error) = &shared.preferences_error {
            content = content.child(
                label(error.clone(), 12., 400, fit).text_color(palette::DANGER.resolve(dark)),
            );
        }
        content = content.child(self.home_profile(dark));
        if shared.layout.visible().is_empty() {
            content = content.child(self.clear_home(dark, cx));
        }
        for section in shared.layout.visible() {
            content = content.child(self.home_section(section, width - 16., dark, cx));
        }
        content
    }

    fn home_profile(&self, dark: bool) -> Div {
        let fit = self.layout.fit;
        let account = self.account();
        let title = if account.is_some_and(|a| !a.signed_in) {
            l("apple.homeview.not_signed_in.491fc91c")
        } else if let Some(account) = account {
            crate::home::greeting(
                account.title(),
                self.home
                    .calendar
                    .as_ref()
                    .is_some_and(|c| c.active_days > 0),
            )
        } else {
            l("common.account")
        };
        let identity = div()
            .flex()
            .items_center()
            .gap(px(12.))
            .flex_none()
            .child(self.avatar(52., dark))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(3.))
                    .child(label(title, 20., 600, fit))
                    .when_some(
                        account.and_then(|a| {
                            a.handle.as_ref().filter(|h| Some(h.as_str()) != a.title())
                        }),
                        |d, handle| {
                            d.child(
                                label(format!("@{handle}"), 12., 400, fit)
                                    .text_color(secondary(dark)),
                            )
                        },
                    )
                    .when(account.is_some_and(|a| !a.signed_in), |d| {
                        d.child(
                            label(l("apple.homeview.working_locally.da99af57"), 12., 400, fit)
                                .text_color(secondary(dark)),
                        )
                    }),
            );
        let mut stats = div().flex().gap(px(20.)).flex_none();
        if let Some(grid) = &self.home.calendar {
            for (key, value, note, accent) in [
                (
                    "apple.homeview.streak.41db983f",
                    grid.streak_current,
                    if grid.streak_current == 1 {
                        "day"
                    } else {
                        "days"
                    },
                    grid.streak_current > 0,
                ),
                (
                    "apple.homeview.best.c47d21c6",
                    grid.streak_best,
                    "days",
                    false,
                ),
                ("common.active", grid.active_days, "days", false),
            ] {
                stats = stats.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(2.))
                        .child(
                            label(l(key).to_uppercase(), 12., 600, fit).text_color(tertiary(dark)),
                        )
                        .child(
                            div()
                                .flex()
                                .items_baseline()
                                .gap(px(3.))
                                .child(number(value.to_string(), 24., 500, fit).text_color(
                                    if accent {
                                        palette::ACCENT.resolve(dark)
                                    } else {
                                        primary(dark)
                                    },
                                ))
                                .child(label(note, 10., 400, fit).text_color(tertiary(dark))),
                        ),
                );
            }
        } else if self.home.loading {
            for _ in 0..3 {
                stats = stats.child(
                    div()
                        .w(px(72.))
                        .h(px(40.))
                        .rounded(px(4.))
                        .bg(palette::ROW_HIGHLIGHT.resolve(dark)),
                );
            }
        }
        let card = presentation::card_surface(dark)
            .w_full()
            .flex()
            .flex_wrap()
            .items_center()
            .justify_between()
            .gap(px(12.));
        card.child(identity).child(stats)
    }

    pub(super) fn activity_card(&self, width: f32, dark: bool, cx: &Context<Self>) -> Div {
        let fit = self.layout.fit;
        let header = div()
            .flex()
            .items_center()
            .gap(px(8.))
            .child(
                div()
                    .size(px(22.))
                    .flex_none()
                    .rounded(px(22. * 0.28))
                    .bg(palette::ACCENT.opacity(0.12).resolve(dark))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(
                        svg()
                            .path("features/activity")
                            .size(px(22. * 0.62))
                            .text_color(palette::ACCENT.resolve(dark)),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .child(presentation::system_text(
                        l("apple.homeview.activity.38da1505"),
                        fit.text(13.),
                        600,
                        cx,
                    ))
                    .child(
                        presentation::system_text(self.home.subtitle(), 10., 400, cx)
                            .text_color(secondary(dark)),
                    ),
            );
        let mut card = presentation::card_surface(dark)
            .w_full()
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(header);
        if let Some(calendar) = &self.home.calendar {
            card = card.child(self.heatmap(calendar, (width - 32.).max(0.), dark, cx));
        } else if self.home.error.is_some() {
            card = card.child(
                label(
                    l("apple.homeview.the_activity_could_not_be_read_see_the_mes.595eb6b5"),
                    12.,
                    400,
                    fit,
                )
                .text_color(secondary(dark)),
            );
        } else if self.home.confirmed_empty {
            card = card.child(self.getting_started(dark, cx));
        } else {
            card = card.child(
                div()
                    .h(px(187.))
                    .w_full()
                    .rounded(px(4.))
                    .bg(palette::ROW_HIGHLIGHT.resolve(dark)),
            );
        }
        card
    }

    fn heatmap(&self, calendar: &Calendar, width: f32, dark: bool, cx: &Context<Self>) -> Div {
        let fit = self.layout.fit;
        let geometry = HeatmapGeometry::new(f64::from(width), calendar.weeks, calendar.rows.len());
        let g = geometry;
        let left = ((f64::from(width) - g.gutter - g.gap - g.content_width()) / 2.).max(0.);
        let grid_x = left + g.gutter + g.gap;
        let grid_y = 11. + g.gap;
        let rows = Arc::new(calendar.rows.clone());
        let bounds = Rc::new(Cell::new(None::<Bounds<gpui::Pixels>>));
        let measured = bounds.clone();
        let selected = self.home.selected.as_ref().map(|c| c.date.clone());
        let hovered = self.home.hovered.as_ref().map(|c| c.date.clone());
        let anchor_date = hovered.clone();
        let anchor_rows = rows.clone();
        let weak = cx.weak_entity();
        let draw_rows = rows.clone();
        let cells = canvas(
            move |rect, _, cx| {
                measured.set(Some(rect));
                if let Some(date) = anchor_date {
                    let slot = anchor_rows.iter().enumerate().find_map(|(row, cells)| {
                        cells
                            .iter()
                            .position(|day| day.as_ref().is_some_and(|d| d.date == date))
                            .map(|column| (row, column))
                    });
                    if let Some((row, column)) = slot {
                        let anchor = crate::home::day::HoverAnchor {
                            date: date.clone(),
                            rect: crate::home::day::Rect {
                                x: f64::from(f32::from(rect.origin.x))
                                    + grid_x
                                    + column as f64 * g.stride(),
                                y: f64::from(f32::from(rect.origin.y))
                                    + grid_y
                                    + row as f64 * g.stride(),
                                width: g.cell,
                                height: g.cell,
                            },
                        };
                        cx.defer(move |cx| {
                            let _ = weak.update(cx, |view, cx| {
                                if view.home.hovered.as_ref().is_some_and(|d| d.date == date)
                                    && view.hover_anchor.as_ref() != Some(&anchor)
                                {
                                    view.hover_anchor = Some(anchor);
                                    cx.notify();
                                }
                            });
                        });
                    }
                }
            },
            move |rect, _, window, _| {
                for (row, cells) in draw_rows.iter().enumerate() {
                    for (column, day) in cells.iter().enumerate() {
                        let Some(day) = day else {
                            continue;
                        };
                        let bounds = Bounds::new(
                            rect.origin
                                + point(
                                    px((grid_x + column as f64 * g.stride()) as f32),
                                    px((grid_y + row as f64 * g.stride()) as f32),
                                ),
                            size(px(g.cell as f32), px(g.cell as f32)),
                        );
                        let level = (day.level.max(0) as usize).min(palette::HEAT.len() - 1);
                        let color = palette::HEAT[level]
                            .opacity(if day.locked { 0.28 } else { 1. })
                            .resolve(dark);
                        window.paint_quad(
                            fill(bounds, color).corner_radii(px(heatmap::CELL_CORNER as f32)),
                        );
                        let rings = [
                            (selected.as_deref() == Some(&day.date))
                                .then_some((1.5, palette::ACCENT.resolve(dark))),
                            (hovered.as_deref() == Some(&day.date))
                                .then_some((1., primary(dark).opacity(0.55))),
                        ];
                        for (weight, color) in rings.into_iter().flatten() {
                            window.paint_quad(
                                fill(bounds, gpui::transparent_black())
                                    .corner_radii(px(heatmap::CELL_CORNER as f32))
                                    .border_widths(px(weight))
                                    .border_color(color),
                            );
                        }
                    }
                }
            },
        )
        .w_full()
        .h(px(g.reserved_height() as f32));
        let move_bounds = bounds.clone();
        let move_rows = rows.clone();
        let mut grid = div()
            .id("home-heatmap")
            .relative()
            .w_full()
            .h(px(g.reserved_height() as f32))
            .flex_none()
            .child(cells)
            .on_mouse_move(
                cx.listener(move |view, event: &gpui::MouseMoveEvent, _, cx| {
                    let day = move_bounds
                        .get()
                        .and_then(|rect| {
                            g.slot(
                                f64::from(f32::from(event.position.x - rect.origin.x)) - grid_x,
                                f64::from(f32::from(event.position.y - rect.origin.y)) - grid_y,
                                &move_rows,
                            )
                        })
                        .and_then(|(row, column)| move_rows[row][column].clone());
                    if day != view.home.hovered {
                        view.set_home_hover(day, cx);
                    }
                }),
            )
            .on_hover(cx.listener(|view, inside, _, cx| {
                if !inside {
                    view.set_home_hover(None, cx);
                }
            }))
            .on_mouse_down_out(cx.listener(|view, _, _, cx| {
                view.set_home_hover(None, cx);
            }))
            .on_click(cx.listener(move |view, event: &gpui::ClickEvent, _, cx| {
                if let Some((row, column)) = bounds.get().and_then(|rect| {
                    g.slot(
                        f64::from(f32::from(event.position().x - rect.origin.x)) - grid_x,
                        f64::from(f32::from(event.position().y - rect.origin.y)) - grid_y,
                        &rows,
                    )
                }) && let Some(day) = &rows[row][column]
                {
                    view.select_home_day(day.clone(), cx);
                }
            }));
        for month in &calendar.months {
            grid = grid.child(
                label(month.name.clone(), 9., 400, fit)
                    .absolute()
                    .top_0()
                    .left(px(
                        (g.gutter + g.gap + month.column as f64 * g.stride()) as f32
                    ))
                    .text_color(tertiary(dark)),
            );
        }
        for row in 0..calendar.rows.len() {
            let key = match row {
                0 => Some("apple.heatmapview.mon.f40d7f51"),
                2 => Some("apple.heatmapview.wed.58339f45"),
                4 => Some("apple.heatmapview.fri.66dab40c"),
                _ => None,
            };
            if let Some(key) = key {
                grid = grid.child(
                    label(l(key), 9., 400, fit)
                        .absolute()
                        .left(px(left as f32))
                        .top(px((grid_y + row as f64 * g.stride()) as f32))
                        .h(px(g.cell as f32))
                        .flex()
                        .items_center()
                        .text_color(tertiary(dark)),
                );
            }
        }
        let mut footer = div().flex().items_center().gap(px(8.));
        if let Some(day) = &self.home.hovered {
            footer = footer
                .child(number(day.date.clone(), 11., 400, fit).text_color(secondary(dark)))
                .child(number(format_spend(day.value), 11., 500, fit));
        } else {
            footer = footer.child(
                number(
                    localization::text(
                        "apple.heatmapview.0_to_1.c1e3e989",
                        &[&calendar.first, &calendar.last],
                    ),
                    11.,
                    400,
                    fit,
                )
                .text_color(tertiary(dark)),
            );
        }
        footer = footer
            .child(div().flex_1())
            .child(
                label(l("apple.heatmapview.less.ae5239ec"), 10., 400, fit)
                    .text_color(tertiary(dark)),
            )
            .children(
                palette::HEAT
                    .iter()
                    .map(|c| div().size(px(9.)).rounded(px(2.)).bg(c.resolve(dark))),
            )
            .child(
                label(l("apple.heatmapview.more.d47d7cb0"), 10., 400, fit)
                    .text_color(tertiary(dark)),
            );
        let mut result = div().flex().flex_col().gap(px(8.)).child(grid);
        if calendar.history_locked {
            result = result.child(div().flex().flex_col().gap(px(6.)).px(px(12.)).py(px(10.)).rounded(px(10.)).bg(palette::ACCENT_SOFT.opacity(0.55).resolve(dark))
                .child(label(l("apple.historylockbanner.older_history_is_locked.8ef6b29a"), 12., 600, fit))
                .child(label(localization::text("apple.historylockbanner.free_shows_the_last_0_days_in_full_older_d.2a97306a", &[&calendar.history_days.unwrap_or(30).to_string()]), 12., 400, fit).text_color(secondary(dark)))
                .child(div().id("history-plans").cursor_pointer().child(label(l("apple.historylockbanner.upgrade_to_see_the_year.7918f544"), 12., 600, fit).text_color(palette::ACCENT.resolve(dark)))
                    .on_click(|_, _, cx| cx.open_url("https://tokenstat.ai/pricing"))));
        }
        result.child(footer)
    }
}
