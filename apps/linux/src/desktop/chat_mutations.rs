// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Captured row mutations use the owning project, never current selection.
//! Rename and fork are wired; send/delete owners remain to be ported.

use super::{
    chat_rows::{self, Target},
    home_shared::HomeShared,
    *,
};
use crate::work::continuity::Date;

pub(super) struct OpenAlert {
    pub view: gpui::Entity<super::confirmation_view::ConfirmationView>,
    key: crate::chat::actions::Key,
    ticket: u64,
    restore_focus: Option<FocusHandle>,
}
struct ForkRequest {
    ticket: crate::chat::actions::Ticket,
    owner: crate::chat::directory::Owner,
    target: Target,
    previous_route: Route,
}

impl Desktop {
    pub(super) fn chat_action_key(
        &self,
        folder: &str,
        id: &str,
    ) -> Option<crate::chat::actions::Key> {
        self.chat_directory
            .owner()
            .map(|owner| crate::chat::actions::Key::new(owner, folder, id))
    }
    pub(super) fn sync_fork_alert(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self
            .fork_alert
            .as_ref()
            .is_some_and(|alert| self.chat_actions.error(&alert.key).is_none())
        {
            self.dismiss_fork_alert(window, cx);
        }
        if self.fork_alert.is_some()
            || self.rename_dialog.is_some()
            || self.confirmation.is_some()
            || self.home_editor.is_some()
        {
            return;
        }
        let Some((key, message)) = self.chat_actions.next_error() else {
            return;
        };
        self.close_menu(window);
        let view = cx.new(|cx| {
            super::confirmation_view::ConfirmationView::new(
                crate::confirmation::Content::fork_error(message),
                cx,
            )
        });
        self.fork_alert_ticket = self.fork_alert_ticket.wrapping_add(1);
        let ticket = self.fork_alert_ticket;
        cx.subscribe_in(&view, window, move |view, _, _, window, cx| {
            if view.fork_alert.as_ref().is_some_and(|a| a.ticket == ticket) {
                view.dismiss_fork_alert(window, cx);
                view.sync_fork_alert(window, cx);
            }
        })
        .detach();
        let restore_focus = window.focused(cx);
        view.read(cx).focus.focus(window);
        self.fork_alert = Some(OpenAlert {
            view,
            key,
            ticket,
            restore_focus,
        });
        cx.notify();
    }
    fn dismiss_fork_alert(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(alert) = self.fork_alert.take() {
            self.chat_actions.dismiss_error(&alert.key);
            alert
                .restore_focus
                .unwrap_or_else(|| self.root_focus.clone())
                .focus(window);
        }
        cx.notify();
    }
    pub(super) fn fork_sidebar_chat(
        &mut self,
        target: Target,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if target.conversation.team_share.is_some() || target.conversation.running {
            return;
        }
        let Some(owner) = self.chat_directory.owner().cloned() else {
            return;
        };
        let key =
            crate::chat::actions::Key::new(&owner, &target.folder.id, &target.conversation.id);
        let Some(ticket) = self.chat_actions.begin(key) else {
            return;
        };
        let previous_route = self.navigation.route.clone();
        let Some(client) = self.client.clone() else {
            let mut record = target.conversation.clone();
            // Private synthetic fixtures never send a write or clone transcript.
            record.id = format!(
                "fixture-copy-{}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or_default()
            );
            record.title = format!("{} (fork)", record.title);
            record.running = false;
            record.pending_steer = None;
            self.finish_chat_fork(
                ForkRequest {
                    ticket,
                    owner,
                    target,
                    previous_route,
                },
                Ok(record),
                window,
                cx,
            );
            return;
        };
        let epoch = cx.global::<HomeShared>().transport_epoch.clone();
        let generation = owner.generation;
        let probe_client = client.clone();
        let probe_folder = target.folder.id.clone();
        let probe_epoch = epoch.clone();
        let probe = cx.background_executor().spawn(async move {
            probe_client
                .fork_supported_if_current(&probe_folder, || {
                    probe_epoch.load(std::sync::atomic::Ordering::Acquire) == generation
                })
                .map_err(|e| format!("{e:#}"))
        });
        let handle = window.window_handle();
        cx.spawn(async move |view, cx| {
            let supported = probe.await;
            let ready = cx
                .update(|app| {
                    app.global::<HomeShared>().account.owner.generation() == generation
                        && app.global::<HomeShared>().metadata.scope().as_ref()
                            == Some(&owner.scope)
                })
                .unwrap_or(false);
            if !ready {
                let _ = view.update(cx, |view, cx| {
                    view.chat_actions.finish(&ticket, Ok(()));
                    cx.notify();
                });
                return;
            }
            let result = match supported {
                Ok(true) => {
                    // Source capability failure returns before mutation invalidation.
                    let _ = cx.update(|app| chat_rows::invalidate(&owner, &target.folder.id, app));
                    let folder = target.folder.id.clone();
                    let id = target.conversation.id.clone();
                    let result = cx
                        .background_executor()
                        .spawn(async move {
                            client
                                .fork_conversation_if_current(&folder, &id, || {
                                    epoch.load(std::sync::atomic::Ordering::Acquire) == generation
                                })
                                .map_err(|e| format!("{e:#}"))
                        })
                        .await;
                    let _ = cx.update(|app| chat_rows::invalidate(&owner, &target.folder.id, app));
                    result
                }
                Ok(false) => Err(l(
                    "apple.bridge.update_the_project_s_computer_to_fork_chat.4d57279f",
                )),
                Err(error) => Err(error),
            };
            let current = cx
                .update(|app| {
                    app.global::<HomeShared>().account.owner.generation() == generation
                        && app.global::<HomeShared>().metadata.scope().as_ref()
                            == Some(&owner.scope)
                })
                .unwrap_or(false);
            if !current {
                let _ = view.update(cx, |view, cx| {
                    view.chat_actions.finish(&ticket, Ok(()));
                    cx.notify();
                });
                return;
            }
            let _ = handle.update(cx, |_, window, cx| {
                let _ = view.update(cx, |view, cx| {
                    view.finish_chat_fork(
                        ForkRequest {
                            ticket,
                            owner,
                            target,
                            previous_route,
                        },
                        result,
                        window,
                        cx,
                    )
                });
            });
        })
        .detach();
        cx.notify();
    }
    fn finish_chat_fork(
        &mut self,
        request: ForkRequest,
        result: Result<crate::chat::Conversation, String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // Publication/reveal belongs to the accepted operation even if its
        // initiating row disappeared. Only its local copying/error state retires.
        let ForkRequest {
            ticket,
            owner,
            target,
            previous_route,
        } = request;
        self.chat_actions
            .finish(&ticket, result.as_ref().map(|_| ()).map_err(Clone::clone));
        if let Ok(record) = result
            && self.chat_directory.publish(
                &owner,
                &target.folder.id,
                record.clone(),
                crate::home::plans::now_ms(),
            )
            && self.navigation.route == previous_route
        {
            self.set_project_expanded(&target.folder.id, true, cx);
            self.set_history_expanded(&target.folder.id, true, cx);
            let reference = self.draft_reference(&target.folder.id, &record.id, cx);
            self.select_sidebar_chat(
                Target {
                    folder: target.folder,
                    conversation: record,
                    reference,
                },
                cx,
            );
        }
        self.sync_fork_alert(window, cx);
        cx.notify();
    }
    pub(super) fn submit_chat_rename(
        &mut self,
        target: Target,
        name: String,
        ticket: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(owner) = self.chat_directory.owner().cloned().filter(|owner| {
            target
                .reference
                .as_ref()
                .is_none_or(|r| r.scope == owner.scope)
        }) else {
            // Its source row has retired. Close without dispatching an edit
            // under the replacement account or inventing a transport failure.
            self.finish_chat_rename(ticket, Ok(()), window, cx);
            return;
        };
        let Some(client) = self.client.clone() else {
            let mut record = target.conversation.clone();
            record.title = name.clone();
            self.chat_directory.publish(
                &owner,
                &target.folder.id,
                record,
                crate::home::plans::now_ms(),
            );
            if let Some(reference) = target.reference
                && let Some(work) = cx.global_mut::<HomeShared>().work.as_mut()
                && let Some(folder) = work
                    .pins
                    .iter()
                    .find(|pin| pin.reference.same_pin(&reference))
                    .map(|pin| pin.folder_name.clone())
                && let Err(error) = work.pin_ephemeral(reference, &name, &folder)
            {
                self.error = Some(format!("{error:#}"));
            }
            self.finish_chat_rename(ticket, Ok(()), window, cx);
            return;
        };
        let generation = owner.generation;
        let epoch = cx.global::<HomeShared>().transport_epoch.clone();
        let folder = target.folder.id.clone();
        let id = target.conversation.id.clone();
        // Invalidate before any startup/protocol await, then fence dispatch again.
        chat_rows::invalidate(&owner, &folder, cx);
        let request_folder = folder.clone();
        let worker = cx.background_executor().spawn(async move {
            client
                .rename_conversation_if_current(&request_folder, &id, &name, || {
                    epoch.load(std::sync::atomic::Ordering::Acquire) == generation
                })
                .map_err(|e| format!("{e:#}"))
        });
        let handle = window.window_handle();
        cx.spawn(async move |view, cx| {
            let result = worker.await;
            let current = cx
                .update(|app| {
                    // A failed mutation can also have changed host state. Both
                    // result branches retire predecessor reads and sharing slots.
                    chat_rows::invalidate(&owner, &folder, app);
                    let current = app.global::<HomeShared>().account.owner.generation()
                        == owner.generation
                        && app.global::<HomeShared>().metadata.scope().as_ref()
                            == Some(&owner.scope);
                    if current
                        && let Ok(record) = &result
                        && let Some(mut reference) = target.reference
                    {
                        reference.item_id = Some(record.id.clone());
                        app.global_mut::<HomeShared>()
                            .metadata
                            .relabel_title_if_pinned(
                                reference,
                                record.title.clone(),
                                Date::from_unix_ms(crate::home::plans::now_ms()),
                            );
                        work_metadata::pump(app);
                    }
                    current
                })
                .unwrap_or(false);
            let _ = handle.update(cx, |_, window, cx| {
                let _ = view.update(cx, |view, cx| {
                    if current && let Ok(record) = &result {
                        view.chat_directory.publish(
                            &owner,
                            &folder,
                            record.clone(),
                            crate::home::plans::now_ms(),
                        );
                    }
                    view.finish_chat_rename(
                        ticket,
                        if current { result.map(|_| ()) } else { Ok(()) },
                        window,
                        cx,
                    );
                });
            });
        })
        .detach();
        cx.notify();
    }
    fn finish_chat_rename(
        &mut self,
        ticket: u64,
        result: Result<(), String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(dialog) = self.rename_dialog.as_mut().filter(|d| d.ticket == ticket) {
            if dialog.state.finish(result) {
                self.dismiss_project_rename(window, cx);
            } else {
                dialog.field.update(cx, |field, cx| {
                    field.enabled = true;
                    cx.notify();
                });
            }
        }
        cx.notify();
    }
}
