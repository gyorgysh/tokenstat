// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Home's linked-device card from DesktopHomeMachines. Selection is retained
//! as a key for the Devices destination; that destination remains unported.

use super::*;
use super::{day_view::feature, home_panels::card_header};

impl Desktop {
    pub(super) fn home_devices(&self, dark: bool, cx: &Context<Self>) -> Div {
        let Some(account) = self.account() else {
            return div();
        };
        if account.machines.is_empty() {
            return div();
        }
        let fit = self.layout.fit;
        let label = |value: String, points, weight| {
            text(
                value,
                FontToken {
                    points: fit.text(points),
                    weight,
                },
            )
        };
        let mut rows = div().w_full().flex().flex_col();
        for (index, machine) in account.machines.iter().enumerate() {
            let help = l("apple.desktophomework.open_this_device_in_devices.24ae7e3a");
            let selected = machine.clone();
            rows = rows.child(
                div()
                    .id(SharedString::from(format!(
                        "home-machine-{index}-{}",
                        machine.id()
                    )))
                    .w_full()
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .py(px(8.))
                    .cursor_pointer()
                    .child(
                        div()
                            .w(px(24.))
                            .flex_none()
                            .flex()
                            .justify_center()
                            .child(icon(machine.symbol(), 13., palette::ACCENT.resolve(dark))),
                    )
                    .child(
                        label(machine.home_label(), 12., 500)
                            .min_w_0()
                            .line_clamp(2),
                    )
                    .child(div().flex_1().min_w(px(8.)))
                    .child(label(machine.home_status(), 10., 400).text_color(secondary(dark)))
                    .child(icon(
                        crate::design::ActionIcon::Next.symbol(),
                        13.,
                        palette::ACCENT.resolve(dark),
                    ))
                    .tooltip(move |_, cx| cx.new(|_| Tooltip(help.clone())).into())
                    .on_click(cx.listener(move |view, _, window, cx| {
                        view.close_menu(window);
                        view.machines_selection.select_account(&selected);
                        view.navigate(
                            Route::Global {
                                section: GlobalSection::Machines,
                            },
                            cx,
                        );
                        cx.notify();
                    })),
            );
            if Some(machine.id()) != account.machines.last().map(|m| m.id()) {
                rows = rows.child(
                    div()
                        .w_full()
                        .h(px(1.))
                        .flex_none()
                        .bg(palette::BORDER.resolve(dark)),
                );
            }
        }
        presentation::card_surface(dark)
            .w_full()
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(card_header(
                l("apple.desktophomework.machines.c061da19"),
                Some(l(
                    "apple.desktophomework.devices_linked_to_your_account.dc6eb913",
                )),
                feature("mark_device", 22., dark),
                fit,
                dark,
                cx,
            ))
            .child(rows)
    }
}
