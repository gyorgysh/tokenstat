// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Offline SidebarRenameSheet states, mounted before host/owner initialization.

use super::*;
#[derive(Clone, Copy, Debug)]
pub(super) struct ProjectFixture {
    state: State,
    pub dark: bool,
    chat_rename: bool,
}
#[derive(Clone, Copy, Debug)]
enum State {
    Ready,
    Empty,
    Error,
    Saving,
    Retry,
    RemoveReady,
    RemoveLong,
    RemoveUnicode,
    RemoveMultiline,
    RemoveCancelFocus,
    RemoveActionFocus,
    Children(crate::chat::fixtures::Case),
    ForkError(crate::chat::fixtures::ErrorCase),
}
impl ProjectFixture {
    pub fn parse(name: &str) -> anyhow::Result<Self> {
        let (state, theme) = name
            .rsplit_once('-')
            .ok_or_else(|| anyhow::anyhow!("A project fixture needs a light/dark suffix"))?;
        let dark = match theme {
            "light" => false,
            "dark" => true,
            _ => anyhow::bail!("Project fixture appearance must be light or dark"),
        };
        let normalized = state
            .strip_prefix("rename-chat-")
            .map(|suffix| format!("rename-{suffix}"));
        let chat_rename = normalized.is_some();
        let state = match normalized.as_deref().unwrap_or(state) {
            "rename-ready" => State::Ready,
            "rename-empty" => State::Empty,
            "rename-error" => State::Error,
            "rename-saving" => State::Saving,
            "rename-retry" => State::Retry,
            "remove-ready" => State::RemoveReady,
            "remove-long" => State::RemoveLong,
            "remove-unicode" => State::RemoveUnicode,
            "remove-multiline" => State::RemoveMultiline,
            "remove-focus-cancel" => State::RemoveCancelFocus,
            "remove-focus-action" => State::RemoveActionFocus,
            other if other.starts_with("children-") => State::Children(
                crate::chat::fixtures::Case::parse(&other[9..])
                    .ok_or_else(|| anyhow::anyhow!("Unknown project children fixture"))?,
            ),
            other if other.starts_with("fork-error-") => State::ForkError(
                crate::chat::fixtures::ErrorCase::parse(&other[11..])
                    .ok_or_else(|| anyhow::anyhow!("Unknown fork error fixture"))?,
            ),
            _ => anyhow::bail!("Project fixture must be a rename, remove or children state"),
        };
        Ok(Self {
            state,
            dark,
            chat_rename,
        })
    }
    pub fn size(self) -> gpui::Size<gpui::Pixels> {
        if let State::ForkError(case) = self.state {
            return size(px(260.), px(case.height()));
        }
        if matches!(self.state, State::Children(_)) {
            return size(px(272.), px(340.));
        }
        if self.is_confirmation() {
            return size(
                px(260.),
                px(match self.state {
                    State::RemoveLong => 186.,
                    State::RemoveUnicode | State::RemoveMultiline => 154.,
                    _ => 138.,
                }),
            );
        }
        size(
            px(460.),
            px(if matches!(self.state, State::Error | State::Retry) {
                300.
            } else {
                250.
            }),
        )
    }
    fn is_confirmation(self) -> bool {
        matches!(
            self.state,
            State::RemoveReady
                | State::RemoveLong
                | State::RemoveUnicode
                | State::RemoveMultiline
                | State::RemoveCancelFocus
                | State::RemoveActionFocus
        )
    }
    pub fn is_fork_error(self) -> bool {
        matches!(self.state, State::ForkError(_))
    }
    pub fn prepare(self, view: &mut Desktop, window: &mut Window, cx: &mut Context<Desktop>) {
        if let State::ForkError(case) = self.state {
            let owner = crate::chat::directory::Owner {
                scope: crate::work::Scope::local("fixture-installation"),
                generation: cx
                    .global::<home_shared::HomeShared>()
                    .account
                    .owner
                    .generation(),
                local_host_identity: "fixture-host".into(),
            };
            let key = crate::chat::actions::Key::new(&owner, "/fixture/alpha", "fork-error");
            if let Some(ticket) = view.chat_actions.begin(key) {
                view.chat_actions.finish(&ticket, Err(case.message()));
            }
            view.sync_fork_alert(window, cx);
            if let Some(alert) = &view.fork_alert {
                alert.view.update(cx, |alert, _| {
                    alert.forced_dark = Some(self.dark);
                    alert.panel_only = true;
                });
            }
            return;
        }
        if let State::Children(case) = self.state {
            let fixture = case.data();
            let folder = "/fixture/alpha";
            view.chat_directory = Default::default();
            view.chat_directory
                .set_owner(Some(crate::chat::directory::Owner {
                    local_host_identity: "fixture-host".into(),
                    scope: crate::work::Scope::local("fixture-installation"),
                    generation: cx
                        .global::<home_shared::HomeShared>()
                        .account
                        .owner
                        .generation(),
                }));
            if fixture.presentation != "loading" {
                view.chat_directory.seed(
                    folder,
                    if fixture.presentation == "failed" {
                        Err("Synthetic directory failure".into())
                    } else {
                        Ok(fixture.rows.clone())
                    },
                    fixture.running_since,
                );
            }
            view.chat_history.set_expanded(folder, fixture.expanded);
            if let Some(held) = fixture.held {
                view.chat_history.hold(folder, &held);
            }
            view.selected_chat = fixture.selected.map(|id| (folder.into(), id));
            if view.selected_chat.is_some() {
                view.navigation.navigate(Route::Workspace {
                    id: folder.into(),
                    section: WorkspaceSection::Chat,
                });
            }
            view.hovered_chat = fixture.hovered.map(|id| (folder.into(), id));
            view.shift_held = fixture.shift;
            for id in fixture.copying {
                if let Some(key) = view.chat_action_key(folder, &id) {
                    view.chat_actions.begin(key);
                }
            }
            for (id, present) in fixture.drafts {
                if present && let Some(reference) = view.draft_reference(folder, &id, cx) {
                    let result = super::draft_marks::update(cx, |service| {
                        service.save(
                            reference,
                            "Synthetic unsent words".into(),
                            vec![],
                            crate::work::continuity::Date::from_unix_ms(fixture.now),
                            false,
                        )
                    });
                    if let Err(error) = result {
                        view.error = Some(format!("{error:#}"));
                    }
                }
            }
            cx.global_mut::<home_shared::HomeShared>().clock_ms = fixture.now;
            return;
        }
        let Some(mut folder) = DesktopData::fixture()
            .repositories
            .unwrap_or_default()
            .into_iter()
            .next()
        else {
            view.error = Some("The synthetic project fixture has no folder.".into());
            return;
        };
        folder.name = if matches!(self.state, State::Empty) {
            String::new()
        } else {
            "alpha".into()
        };
        let target = view.project_target(&folder, cx);
        if self.is_confirmation() {
            let mut target = target;
            target.folder.name=match self.state {
                State::RemoveLong=>"A project with a deliberately long workspace name that wraps over multiple lines",
                State::RemoveUnicode=>"東京・árvíztűrő・🐧",
                State::RemoveMultiline=>"alpha\nnew line",
                _=>"alpha",
            }.into();
            view.request_project_remove(target, window, cx);
            if let Some(open) = &view.confirmation {
                open.view.update(cx, |modal, _| {
                    modal.forced_dark = Some(self.dark);
                    modal.panel_only = true;
                    match self.state {
                        State::RemoveCancelFocus => {
                            modal.interaction.focus(crate::confirmation::Choice::Cancel)
                        }
                        State::RemoveActionFocus => {
                            modal.interaction.focus(crate::confirmation::Choice::Remove)
                        }
                        _ => {}
                    }
                });
            }
            return;
        }
        if self.chat_rename {
            let work = cx.global::<home_shared::HomeShared>().work.as_ref();
            let owner = work.and_then(|work| {
                Some(crate::chat::directory::Owner {
                    scope: work.catalog.scope.clone()?,
                    generation: cx
                        .global::<home_shared::HomeShared>()
                        .account
                        .owner
                        .generation(),
                    local_host_identity: work.catalog.local_host_identity.clone()?,
                })
            });
            view.chat_directory.set_owner(owner);
            let conversation = crate::chat::Conversation {
                id: "fixture-chat".into(),
                workspace_id: folder.id.clone(),
                title: if matches!(self.state, State::Empty) {
                    String::new()
                } else {
                    "alpha".into()
                },
                backend: "codex".into(),
                team_share: None,
                updated_at_ms: 0,
                last_message_at_ms: None,
                running: false,
                pending_steer: None,
                pull: None,
                ..crate::chat::Conversation::default()
            };
            view.chat_directory.seed(
                &folder.id,
                Ok(vec![conversation.clone()]),
                cx.global::<home_shared::HomeShared>().clock_ms,
            );
            let reference = view.draft_reference(&folder.id, &conversation.id, cx);
            view.open_chat_rename(
                super::chat_rows::Target {
                    folder: folder.clone(),
                    conversation,
                    reference,
                },
                window,
                cx,
            );
        } else {
            view.open_project_rename(target, window, cx);
        }
        if let Some(dialog) = view.rename_dialog.as_mut() {
            dialog.state.error = matches!(self.state, State::Error | State::Retry).then(|| {
                if self.chat_rename {
                    "The host could not rename this chat.".into()
                } else {
                    "The host could not rename this project.".into()
                }
            });
            dialog.state.saving = matches!(self.state, State::Saving | State::Retry);
            dialog.field.update(cx, |field, _| {
                field.dark = self.dark;
                field.enabled = !matches!(self.state, State::Saving | State::Retry);
            });
        }
    }
    pub fn render(self, view: &Desktop, _: &Window, cx: &Context<Desktop>) -> gpui::Stateful<Div> {
        let root = div()
            .id("project-parity-fixture")
            .key_context("Tokenstat")
            .track_focus(&view.root_focus)
            .on_key_down(cx.listener(|view, event, window, cx| view.key_down(event, window, cx)))
            .on_action(cx.listener(|view, action: &ExecuteCommand, window, cx| {
                view.command(action.command, window, cx)
            }))
            .size_full()
            .text_color(primary(self.dark))
            .bg(palette::BACKGROUND.resolve(self.dark));
        if self.is_fork_error() {
            return root.when_some(view.fork_alert.as_ref(), |root, alert| {
                root.child(alert.view.clone())
            });
        }
        if matches!(self.state, State::Children(_)) {
            return root.flex().flex_col().items_start().when_some(
                view.data
                    .as_ref()
                    .and_then(|data| data.repositories.as_ref().ok())
                    .and_then(|folders| folders.first()),
                |root, folder| root.child(view.project_children(folder, self.dark, cx)),
            );
        }
        if self.is_confirmation() {
            root.when_some(view.confirmation.as_ref(), |root, open| {
                root.child(open.view.clone())
            })
        } else {
            root.child(view.rename_sheet(self.dark, cx))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn child_modes_are_explicit_and_keep_the_component_viewport() {
        for name in [
            "failed",
            "long",
            "unicode",
            "account-changed",
            "unsupported",
        ] {
            for theme in ["light", "dark"] {
                let fixture = ProjectFixture::parse(&format!("fork-error-{name}-{theme}")).unwrap();
                assert!(fixture.is_fork_error());
                assert_eq!(fixture.size().width, px(260.));
            }
        }
        for state in ["ready", "empty", "error", "saving", "retry"] {
            for theme in ["light", "dark"] {
                let fixture =
                    ProjectFixture::parse(&format!("rename-chat-{state}-{theme}")).unwrap();
                assert!(fixture.chat_rename);
                assert_eq!(
                    fixture.size(),
                    size(
                        px(460.),
                        px(if state == "error" || state == "retry" {
                            300.
                        } else {
                            250.
                        })
                    )
                );
            }
        }
        for case in crate::chat::fixtures::Case::ALL {
            for theme in ["light", "dark"] {
                let fixture =
                    ProjectFixture::parse(&format!("children-{}-{theme}", case.name())).unwrap();
                assert!(matches!(fixture.state,State::Children(found) if found==case));
                assert_eq!(fixture.size(), size(px(272.), px(340.)));
            }
        }
        for invalid in [
            "children-ready",
            "children-unknown-dark",
            "children-ready-auto",
            "children--dark",
            "fork-error-failed",
            "fork-error-unknown-dark",
            "fork-error-failed-auto",
        ] {
            assert!(ProjectFixture::parse(invalid).is_err());
        }
    }
}
