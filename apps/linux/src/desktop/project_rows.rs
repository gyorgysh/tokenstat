// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Initial WorkspaceRow and captured project-menu dispatch. Sharing, git,
//! remote directory/stale owners, terminal/job children and hover cards remain open.

use super::home_shared::HomeShared;
use super::*;
use crate::{
    desktop_data::Repository,
    project_menu::{self, ProjectAction},
    work::{Reference, continuity::Date},
};

#[derive(Clone)]
pub(super) struct Target {
    pub folder: Repository,
    pub reference: Option<Reference>,
}

impl Desktop {
    pub(super) fn project_target(&self, folder: &Repository, cx: &App) -> Target {
        let reference = if self.client.is_some() {
            let metadata = &cx.global::<HomeShared>().metadata;
            project_menu::reference(
                metadata.scope().as_ref(),
                metadata.local_host_identity.as_deref(),
                &folder.id,
            )
        } else {
            self.work_reading(cx).as_ref().and_then(|work| {
                project_menu::reference(
                    work.catalog.scope.as_ref(),
                    work.catalog.local_host_identity.as_deref(),
                    &folder.id,
                )
            })
        };
        Target {
            folder: folder.clone(),
            reference,
        }
    }

    fn open_project_menu(
        &mut self,
        folder: Repository,
        position: gpui::Point<gpui::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let target = self.project_target(&folder, cx);
        let work = self.work_reading(cx);
        let scoped_pins = work
            .as_ref()
            .map(|work| {
                work.pins
                    .iter()
                    .filter(|pin| work.catalog.scope.as_ref() == Some(&pin.reference.scope))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let pinned = target.reference.as_ref().is_some_and(|reference| {
            scoped_pins
                .iter()
                .any(|pin| pin.reference.same_pin(reference))
        });
        let entries = project_menu::items(&project_menu::State {
            reference: target.reference.is_some(),
            pinned,
            pin_count: scoped_pins.len(),
            machine_id: folder.machine_id.clone(),
            machine_label: folder.machine_label.clone(),
            // These owners have not been ported. Do not infer staleness or
            // shared/git state from a folder name or account machine status.
            ..Default::default()
        });
        self.open_menu(
            entries,
            position.x.into(),
            Some(position.y.into()),
            false,
            window,
            cx,
        );
        if let Some(menu) = self.menu.as_mut() {
            menu.project = Some(target);
        }
    }

    pub(super) fn project_command(
        &mut self,
        action: ProjectAction,
        target: Option<Target>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // Never substitute the currently selected project for a missing target.
        let Some(target) = target else {
            return;
        };
        if cx.global::<HomeShared>().quit_requested {
            return;
        }
        match action {
            ProjectAction::Rename => self.open_project_rename(target, window, cx),
            ProjectAction::Remove => self.request_project_remove(target, window, cx),
            ProjectAction::Pin => {
                let Some(reference) = target.reference else {
                    return;
                };
                if self.client.is_none() {
                    if let Some(work) = cx.global_mut::<HomeShared>().work.as_mut()
                        && let Err(error) =
                            work.pin_ephemeral(reference, &target.folder.name, &target.folder.name)
                    {
                        self.error = Some(format!("{error:#}"));
                    }
                } else {
                    cx.global_mut::<HomeShared>().metadata.pin(
                        reference,
                        target.folder.name.clone(),
                        target.folder.name,
                        Date::from_unix_ms(crate::home::plans::now_ms()),
                    );
                    work_metadata::pump(cx);
                }
            }
            ProjectAction::Unpin => {
                if let Some(reference) = target.reference {
                    self.unpin_home(reference, cx);
                }
            }
            ProjectAction::Reveal => {
                if self.client.is_some() && target.folder.machine_id.is_none() {
                    cx.reveal_path(std::path::Path::new(&target.folder.path));
                } else {
                    self.gap =
                        Some("The shell fixture does not open folders on this computer.".into());
                }
            }
            ProjectAction::NewTerminal => {
                // The source opens its launcher; it does not spawn a shell.
                self.set_project_expanded(&target.folder.id, true, cx);
                self.navigate(
                    Route::Workspace {
                        id: target.folder.id,
                        section: WorkspaceSection::Sessions,
                    },
                    cx,
                );
            }
            other => {
                self.gap = Some(format!(
                    "Desktop preview: {other:?} for {} has not been ported yet.",
                    target.folder.name
                ))
            }
        }
        cx.notify();
    }

    pub(super) fn project_row(
        &self,
        folder: &Repository,
        dark: bool,
        cx: &Context<Self>,
    ) -> impl IntoElement {
        let current =
            matches!(&self.navigation.route, Route::Workspace { id, .. } if id == &folder.id);
        let expanded = self.project_directory.expanded(&folder.id);
        let hovered = self.hovered_project.as_deref() == Some(&folder.id);
        let remote = folder.machine_id.is_some();
        let label = if remote {
            format!(
                "{} / {}",
                folder
                    .machine_label
                    .clone()
                    .unwrap_or_else(|| l("apple.rootview.remote.ffa98e02")),
                folder.name
            )
        } else {
            folder.name.clone()
        };
        let row_folder = folder.clone();
        let menu_folder = folder.clone();
        let action_folder = folder.clone();
        let compose_folder = folder.clone();
        let share_folder = folder.clone();
        let disclosure_id = folder.id.clone();
        let hover_id = folder.id.clone();
        let mut controls = div()
            .absolute()
            .right(px(8.))
            .h_full()
            .flex()
            .items_center()
            .gap(px(4.));
        if !remote {
            controls = controls.child(
                div()
                    .id(SharedString::from(format!("project-share-{}", folder.id)))
                    .size(px(24.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .tooltip(|_, cx| cx.new(|_| Tooltip(l("common.teams.share_project"))).into())
                    .on_click(cx.listener(move |view, _, window, cx| {
                        cx.stop_propagation();
                        let target = view.project_target(&share_folder, cx);
                        view.project_command(ProjectAction::OpenShared, Some(target), window, cx);
                    }))
                    .child(icon(
                        crate::design::ActionIcon::Connect.symbol(),
                        12.,
                        palette::CONTROL_GLYPH.resolve(dark),
                    )),
            );
        }
        let delete_title = l("apple.rootview.remove_project.704e7388");
        let shows_delete = self.shift_held;
        let help = if shows_delete {
            delete_title.clone()
        } else {
            localization::text(
                "apple.sidebarrowactions.actions_for_0_hold_shift_for_1.34c1216b",
                &[&folder.name, &delete_title.to_lowercase()],
            )
        };
        controls = controls
            .child(
                div()
                    .id(SharedString::from(format!("project-actions-{}", folder.id)))
                    .size(px(24.))
                    .rounded(px(5.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .hover(|d| {
                        d.bg(palette::ACCENT_SOFT.resolve(dark))
                            .text_color(palette::ACCENT.resolve(dark))
                    })
                    .text_color(secondary(dark))
                    .tooltip(move |_, cx| cx.new(|_| Tooltip(help.clone())).into())
                    .on_click(
                        cx.listener(move |view, event: &gpui::ClickEvent, window, cx| {
                            cx.stop_propagation();
                            if window.modifiers().shift {
                                let target = view.project_target(&action_folder, cx);
                                view.project_command(
                                    ProjectAction::Remove,
                                    Some(target),
                                    window,
                                    cx,
                                );
                            } else {
                                view.open_project_menu(
                                    action_folder.clone(),
                                    event.position(),
                                    window,
                                    cx,
                                );
                            }
                        }),
                    )
                    .child(
                        svg()
                            .path(if shows_delete {
                                "symbols/trash"
                            } else {
                                "symbols/ellipsis"
                            })
                            .size(px(11.)),
                    ),
            )
            .child(
                div()
                    .id(SharedString::from(format!("project-compose-{}", folder.id)))
                    .size(px(24.))
                    .rounded(px(5.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .hover(|d| {
                        d.bg(palette::ACCENT_SOFT.resolve(dark))
                            .text_color(palette::ACCENT.resolve(dark))
                    })
                    .text_color(secondary(dark))
                    .tooltip({
                        let name = folder.name.clone();
                        move |_, cx| {
                            cx.new(|_| {
                                Tooltip(localization::text(
                                    "apple.rootview.new_chat_in_0.2436f7d3",
                                    &[&name],
                                ))
                            })
                            .into()
                        }
                    })
                    .on_click(cx.listener(move |view, _, window, cx| {
                        cx.stop_propagation();
                        let target = view.project_target(&compose_folder, cx);
                        view.project_command(ProjectAction::NewChat, Some(target), window, cx);
                    }))
                    .child(svg().path("symbols/square.and.pencil").size(px(12.))),
            );
        let row = div()
            .id(SharedString::from(format!("project-{}", folder.id)))
            .relative()
            .flex_1()
            .min_w_0()
            .h(px(self.layout.fit.text(30.)))
            .on_hover(cx.listener(move |view, on: &bool, window, cx| {
                if *on {
                    view.hovered_project = Some(hover_id.clone());
                } else if view.hovered_project.as_ref() == Some(&hover_id) {
                    view.hovered_project = None;
                }
                view.shift_held = window.modifiers().shift;
                cx.notify();
            }))
            .on_modifiers_changed(cx.listener(
                |view, event: &gpui::ModifiersChangedEvent, _, cx| {
                    view.shift_held = event.modifiers.shift;
                    cx.notify();
                },
            ))
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(move |view, event: &gpui::MouseDownEvent, window, cx| {
                    cx.stop_propagation();
                    view.open_project_menu(menu_folder.clone(), event.position, window, cx);
                }),
            )
            .child(
                div()
                    .absolute()
                    .left(px(4.))
                    .right(px(4.))
                    .top(px(1.))
                    .bottom(px(1.))
                    .rounded(px(8.))
                    .when(current, |d| d.bg(palette::ROW_SELECTED.resolve(dark)))
                    .when(!current && hovered, |d| {
                        d.bg(palette::ROW_HIGHLIGHT.opacity(0.6).resolve(dark))
                    })
                    .when(current, |d| {
                        d.child(
                            div()
                                .absolute()
                                .left_0()
                                .top(px(5.))
                                .bottom(px(5.))
                                .w(px(3.))
                                .rounded(px(1.5))
                                .bg(palette::ACCENT.resolve(dark)),
                        )
                    }),
            )
            .child(
                div()
                    .id(SharedString::from(format!("project-open-{}", folder.id)))
                    .relative()
                    .size_full()
                    .px(px(8.))
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .cursor_pointer()
                    .on_click(cx.listener(move |view, _, _, cx| {
                        view.set_project_expanded(&row_folder.id, true, cx);
                        view.navigate(
                            Route::Workspace {
                                id: row_folder.id.clone(),
                                section: WorkspaceSection::Sessions,
                            },
                            cx,
                        );
                        cx.notify();
                    }))
                    .child(
                        div()
                            .w(px(18.))
                            .flex_none()
                            .flex()
                            .justify_center()
                            .child(icon(
                                if remote {
                                    "network"
                                } else if folder.exists {
                                    "folder"
                                } else {
                                    "questionmark.folder"
                                },
                                13.,
                                if current {
                                    palette::ACCENT.resolve(dark)
                                } else {
                                    palette::CONTROL_GLYPH.resolve(dark)
                                },
                            )),
                    )
                    .child(
                        text(
                            label,
                            FontToken {
                                points: self.layout.fit.text(13.),
                                weight: if current { 600 } else { 500 },
                            },
                        )
                        .flex_1()
                        .min_w_0()
                        .overflow_hidden()
                        .whitespace_nowrap(),
                    )
                    .child(div().min_w(px(if remote { 52. } else { 80. })).flex_none()),
            )
            .when(hovered, |d| d.child(controls));
        div()
            .flex()
            .items_center()
            .child(
                div()
                    .id(SharedString::from(format!(
                        "project-disclosure-{}",
                        folder.id
                    )))
                    .w(px(18.))
                    .h(px(24.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .tooltip(move |_, cx| {
                        cx.new(|_| {
                            Tooltip(l(if expanded {
                                "apple.rootview.collapse_project.96385e6d"
                            } else {
                                "apple.rootview.expand_project.1e7feb92"
                            }))
                        })
                        .into()
                    })
                    .on_click(cx.listener(move |view, _, _, cx| {
                        view.set_project_expanded(
                            &disclosure_id,
                            !view.project_directory.expanded(&disclosure_id),
                            cx,
                        );
                    }))
                    .child(icon(
                        if expanded {
                            "chevron.down"
                        } else {
                            "chevron.right"
                        },
                        8.,
                        if current {
                            palette::ACCENT.resolve(dark)
                        } else {
                            secondary(dark)
                        },
                    )),
            )
            .child(row)
    }
}
