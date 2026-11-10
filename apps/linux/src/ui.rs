// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use gpui::{
    App, Application, Bounds, Context, IntoElement, Render, SharedString, Window, WindowBounds,
    WindowOptions, div, prelude::*, px, rgb, size,
};
use tokenstat_linux::client::{Bucket, Client, Snapshot};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Page {
    Home,
    Insights,
    Host,
}

struct Desktop {
    client: Client,
    page: Page,
    snapshot: Option<Snapshot>,
    error: Option<String>,
    busy: bool,
}

impl Desktop {
    fn refresh(&mut self, scan: bool, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        self.busy = true;
        self.error = None;
        cx.notify();
        let client = self.client.clone();
        let task = cx
            .background_executor()
            .spawn(async move { client.snapshot(scan) });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                view.busy = false;
                match result {
                    Ok(snapshot) => {
                        view.snapshot = Some(snapshot);
                        view.error = None;
                    }
                    Err(error) => view.error = Some(format!("{error:#}")),
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn card(label: &'static str, value: String) -> impl IntoElement {
        div()
            .flex_1()
            .min_w(px(100.))
            .p_5()
            .rounded_lg()
            .bg(rgb(0x100E1A))
            .border_1()
            .border_color(rgb(0x211D33))
            .child(div().text_sm().text_color(rgb(0xA8A5B5)).child(label))
            .child(div().mt_3().text_3xl().child(value))
    }

    fn table(title: &'static str, rows: &[Bucket]) -> impl IntoElement {
        div()
            .flex()
            .flex_col()
            .gap_3()
            .p_5()
            .rounded_lg()
            .bg(rgb(0x100E1A))
            .border_1()
            .border_color(rgb(0x211D33))
            .child(div().text_lg().child(title))
            .when(rows.is_empty(), |d| {
                d.child(div().text_color(rgb(0xA8A5B5)).child("No recorded usage"))
            })
            .children(rows.iter().take(30).map(|row| {
                div()
                    .flex()
                    .justify_between()
                    .gap_4()
                    .py_2()
                    .border_b_1()
                    .border_color(rgb(0x211D33))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .overflow_hidden()
                            .child(row.key.clone()),
                    )
                    .child(div().text_color(rgb(0xA8A5B5)).child(format!(
                        "{} tokens  ·  {} sessions",
                        number(row.counters.total),
                        number(row.sessions)
                    )))
            }))
    }
}

impl Render for Desktop {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mut content = div().flex().flex_col().gap_5();
        if let Some(error) = &self.error {
            content = content.child(
                div()
                    .p_4()
                    .rounded_lg()
                    .bg(rgb(0x2B1921))
                    .text_color(rgb(0xF4B6B0))
                    .child(if self.snapshot.is_some() {
                        "Reading is stale"
                    } else {
                        "Host unavailable"
                    })
                    .child(div().mt_2().text_sm().child(error.clone())),
            );
        }
        if let Some(snapshot) = &self.snapshot {
            match self.page {
                Page::Home => {
                    content = content
                        .child(
                            div()
                                .flex()
                                .gap_4()
                                .child(Self::card(
                                    "Recorded tokens",
                                    number(snapshot.totals.counters.total),
                                ))
                                .child(Self::card("Sessions", number(snapshot.totals.sessions)))
                                .child(Self::card("Active days", number(snapshot.totals.days))),
                        )
                        .child(Self::table("Tools", &snapshot.by_source))
                        .child(Self::table("Projects", &snapshot.by_project));
                }
                Page::Insights => {
                    content =
                        content
                            .child(Self::table("Models", &snapshot.by_model))
                            .child(Self::table("Tools", &snapshot.by_source))
                            .child(div().text_sm().text_color(rgb(0xA8A5B5)).child(
                                "All recorded dates. Counters come from the shared Rust host.",
                            ));
                }
                Page::Host => {
                    let info = &snapshot.info;
                    content = content.child(div().p_5().rounded_lg().bg(rgb(0x100E1A))
                        .child(div().text_lg().child("Local host"))
                        .child(div().mt_4().child(format!("Version {}  ·  {}", info.core_version, info.timezone)))
                        .child(div().mt_3().child(format!("Open files: {} / {}", optional(info.open_files), optional(info.open_file_limit))))
                        .child(div().mt_3().text_sm().text_color(rgb(0xA8A5B5)).child(self.client.socket.display().to_string()))
                        .child(div().mt_4().text_sm().child("Login startup and Always-on controls are part of the Linux integration milestone.")));
                }
            }
        } else if self.busy {
            content = content.child(
                div()
                    .p_6()
                    .text_color(rgb(0xA8A5B5))
                    .child("Connecting to your local host…"),
            );
        }
        let page_title = match self.page {
            Page::Home => "Home",
            Page::Insights => "Insights",
            Page::Host => "Host",
        };
        div()
            .size_full()
            .flex()
            .bg(rgb(0x08070D))
            .text_color(rgb(0xE9E7F0))
            .font_family("Manrope")
            .child(
                div()
                    .w(px(208.))
                    .h_full()
                    .flex_none()
                    .flex()
                    .flex_col()
                    .p_5()
                    .gap_2()
                    .bg(rgb(0x12101D))
                    .border_r_1()
                    .border_color(rgb(0x211D33))
                    .child(
                        div()
                            .text_2xl()
                            .mb_6()
                            .text_color(rgb(0xA78BFA))
                            .child("tokenstat"),
                    )
                    .children(
                        [
                            (Page::Home, "Home"),
                            (Page::Insights, "Insights"),
                            (Page::Host, "Host"),
                        ]
                        .map(|(page, name)| {
                            div()
                                .id(name)
                                .px_4()
                                .py_3()
                                .rounded_md()
                                .cursor_pointer()
                                .bg(rgb(if self.page == page {
                                    0x1B1430
                                } else {
                                    0x12101D
                                }))
                                .hover(|s| s.bg(rgb(0x1B1430)))
                                .on_click(cx.listener(move |view, _, _, cx| {
                                    view.page = page;
                                    cx.notify();
                                }))
                                .child(name)
                        }),
                    )
                    .child(
                        div()
                            .mt_6()
                            .text_xs()
                            .text_color(rgb(0xA8A5B5))
                            .child("Linux feasibility build"),
                    ),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .p_6()
                            .flex()
                            .items_center()
                            .justify_between()
                            .border_b_1()
                            .border_color(rgb(0x211D33))
                            .child(div().text_2xl().child(page_title))
                            .child(
                                div()
                                    .flex()
                                    .gap_3()
                                    .child(
                                        div()
                                            .id("refresh")
                                            .px_4()
                                            .py_2()
                                            .rounded_md()
                                            .bg(rgb(0x211D33))
                                            .cursor_pointer()
                                            .on_click(
                                                cx.listener(|view, _, _, cx| {
                                                    view.refresh(false, cx)
                                                }),
                                            )
                                            .child(if self.busy {
                                                "Working…"
                                            } else {
                                                "↻  Refresh"
                                            }),
                                    )
                                    .child(
                                        div()
                                            .id("scan")
                                            .px_4()
                                            .py_2()
                                            .rounded_md()
                                            .bg(rgb(0x6A3DFF))
                                            .cursor_pointer()
                                            .on_click(
                                                cx.listener(|view, _, _, cx| {
                                                    view.refresh(true, cx)
                                                }),
                                            )
                                            .child("＋  Scan logs"),
                                    ),
                            ),
                    )
                    .child(
                        div()
                            .id("content")
                            .flex_1()
                            .min_h_0()
                            .overflow_y_scroll()
                            .p_6()
                            .child(content),
                    ),
            )
    }
}

fn number(value: u64) -> String {
    let text = value.to_string();
    let mut result = String::new();
    for (index, digit) in text.chars().enumerate() {
        if index > 0 && (text.len() - index).is_multiple_of(3) {
            result.push(',');
        }
        result.push(digit);
    }
    result
}

fn optional(value: Option<u64>) -> String {
    value.map(number).unwrap_or_else(|| "Unavailable".into())
}

pub fn run(client: Client) {
    Application::new().run(move |cx: &mut App| {
        if let Err(error) = tokenstat_linux::presentation::register_fonts(cx) {
            eprintln!("tokenstat desktop: could not load font: {error}");
        }
        cx.on_window_closed(|cx| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        let bounds = Bounds::centered(None, size(px(1100.), px(760.)), cx);
        let opened = cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                window_min_size: Some(size(px(780.), px(520.))),
                app_id: Some("ai.tokenstat.tokenstat".into()),
                titlebar: Some(gpui::TitlebarOptions {
                    title: Some(SharedString::from("tokenstat")),
                    ..Default::default()
                }),
                ..Default::default()
            },
            |_, cx| {
                cx.new(|cx| {
                    let mut view = Desktop {
                        client,
                        page: Page::Home,
                        snapshot: None,
                        error: None,
                        busy: false,
                    };
                    view.refresh(false, cx);
                    view
                })
            },
        );
        if let Err(error) = opened {
            eprintln!("tokenstat desktop: {error}");
            cx.quit();
        }
        cx.activate(true);
    });
}
