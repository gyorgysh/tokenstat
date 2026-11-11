// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Conversation-scoped draft editor. Sending and attachment editing are still
//! separate owners; editing text never discards restored attachment metadata.

use super::{composer_input::ComposerInput, draft_marks, *};
use crate::work::{Reference, continuity::Date};

pub(super) struct Composer {
    reference: Reference,
    folder: String,
    key: String,
    pub field: gpui::Entity<ComposerInput>,
    saved: Option<String>,
    error: Option<String>,
}

impl Desktop {
    pub(super) fn composer_visible(&self) -> bool {
        let (Some(composer), Some((selected_folder, selected_id))) =
            (&self.composer, &self.selected_chat)
        else {
            return false;
        };
        matches!(&self.navigation.route, Route::Workspace { id, section: WorkspaceSection::Chat } if crate::work::text::equal(id, selected_folder))
            && !self.chat_overview
            && crate::work::text::equal(&composer.folder, selected_folder)
            && composer
                .reference
                .item_id
                .as_ref()
                .is_some_and(|id| crate::work::text::equal(id, selected_id))
    }

    pub(super) fn save_composer(&mut self, cx: &mut Context<Self>) {
        let Some(composer) = &self.composer else {
            return;
        };
        let value = composer.field.read(cx).input.text().to_owned();
        if composer.saved.as_ref() == Some(&value) {
            return;
        }
        let reference = composer.reference.clone();
        let attachments = cx
            .global::<draft_marks::Shared>()
            .service
            .model
            .draft(&reference)
            .map(|draft| draft.attachments.clone())
            .unwrap_or_default();
        let result = draft_marks::update(cx, |service| {
            service.save(
                reference,
                value.clone(),
                attachments,
                Date::from_unix_ms(crate::home::plans::now_ms()),
                false,
            )
        });
        if let Some(composer) = &mut self.composer {
            match result {
                Ok(()) => {
                    composer.saved = Some(value);
                    composer.error = None;
                }
                Err(error) => composer.error = Some(format!("{error:#}")),
            }
        }
    }

    pub(super) fn retire_composer(&mut self, cx: &mut Context<Self>) {
        self.save_composer(cx);
        if let Some(composer) = self.composer.take() {
            let current = composer.field.read(cx).input.text();
            let stored = cx
                .global::<draft_marks::Shared>()
                .service
                .model
                .draft(&composer.reference);
            // Registration may still be in flight or may have failed. Retain
            // those words in this window until the store has actually adopted
            // them, even when the user changes conversation or account.
            let adopted = stored
                .map(|draft| draft.text.as_str() == current)
                .unwrap_or_else(|| crate::work::text::trim(current).is_empty());
            if !adopted {
                self.held_composers.insert(composer.key.clone(), composer);
            }
        }
    }

    fn retry_composer_save(&mut self, cx: &mut Context<Self>) {
        draft_marks::update(cx, |service| service.retry_failed_save());
        if let Some(composer) = &mut self.composer {
            composer.saved = None;
        }
        self.save_composer(cx);
        cx.notify();
    }

    pub(super) fn composer_content(
        &mut self,
        folder: &str,
        id: &str,
        running: bool,
        dark: bool,
        cx: &mut Context<Self>,
    ) -> Div {
        if !cx.global::<draft_marks::Shared>().service.initialized {
            return div().p(px(16.)).child(
                text(
                    "Loading draft…",
                    FontToken {
                        points: 12.,
                        weight: 400,
                    },
                )
                .text_color(secondary(dark)),
            );
        }
        let Some(reference) = self.draft_reference(folder, id, cx) else {
            return div().p(px(16.)).child(
                text(
                    "Draft is unavailable for this conversation.",
                    FontToken {
                        points: 12.,
                        weight: 400,
                    },
                )
                .text_color(secondary(dark)),
            );
        };
        let Some(key) = reference.conversation_key() else {
            return div();
        };
        let placeholder = if running {
            l("apple.chatview.send_after_this_turn.012fc8c3")
        } else {
            let name = self
                .data
                .as_ref()
                .and_then(|data| data.repositories.as_ref().ok())
                .and_then(|folders| {
                    folders
                        .iter()
                        .find(|candidate| crate::work::text::equal(&candidate.id, folder))
                })
                .map(|folder| folder.name.clone())
                .unwrap_or_else(|| l("apple.chatview.this_folder.9d6325c8"));
            localization::text("apple.chatview.ask_about_0.35c322e7", &[&name])
        };
        if !self
            .composer
            .as_ref()
            .is_some_and(|composer| composer.key == key)
        {
            self.retire_composer(cx);
            if let Some(mut held) = self.held_composers.remove(&key) {
                held.folder = folder.to_owned();
                self.composer = Some(held);
            } else {
                let value = cx
                    .global::<draft_marks::Shared>()
                    .service
                    .model
                    .draft(&reference)
                    .map(|draft| draft.text.clone())
                    .unwrap_or_default();
                let field =
                    cx.new(|cx| ComposerInput::new(value.clone(), dark, placeholder.clone(), cx));
                cx.subscribe(
                    &field,
                    |view, field, _: &super::composer_input::Edited, cx| {
                        if view
                            .composer
                            .as_ref()
                            .is_some_and(|composer| composer.field.entity_id() == field.entity_id())
                        {
                            view.save_composer(cx);
                            cx.notify();
                        }
                    },
                )
                .detach();
                self.composer = Some(Composer {
                    reference: reference.clone(),
                    folder: folder.to_owned(),
                    key,
                    field,
                    saved: Some(value),
                    error: None,
                });
            }
        }
        let composer = self.composer.as_ref().unwrap();
        let field = composer.field.clone();
        if field.read(cx).dark != dark || field.read(cx).placeholder != placeholder {
            field.update(cx, |field, cx| {
                field.dark = dark;
                field.placeholder = placeholder;
                cx.notify();
            });
        }
        let attachments = cx
            .global::<draft_marks::Shared>()
            .service
            .model
            .draft(&reference)
            .map(|draft| draft.attachments.clone())
            .unwrap_or_default();
        let error = composer
            .error
            .clone()
            .or_else(|| cx.global::<draft_marks::Shared>().service.error.clone());
        let mut body = div()
            .w_full()
            .max_w(px(720.))
            .flex()
            .flex_col()
            .gap(px(8.))
            .p(px(12.))
            .rounded(px(12.))
            .border_1()
            .border_color(palette::BORDER.resolve(dark))
            .bg(palette::PANEL.resolve(dark))
            .child(field);
        if !attachments.is_empty() {
            body = body.child(
                text(
                    format!("{} saved attachment(s)", attachments.len()),
                    FontToken {
                        points: 12.,
                        weight: 400,
                    },
                )
                .text_color(secondary(dark)),
            );
        }
        if let Some(error) = error {
            body = body.child(
                div()
                    .flex()
                    .gap(px(8.))
                    .child(
                        text(
                            format!("Draft could not be saved: {error}"),
                            FontToken {
                                points: 12.,
                                weight: 400,
                            },
                        )
                        .text_color(secondary(dark)),
                    )
                    .child(
                        div()
                            .id("retry-chat-draft")
                            .cursor_pointer()
                            .on_click(cx.listener(|view, _, _, cx| view.retry_composer_save(cx)))
                            .child(
                                text(
                                    "Retry",
                                    FontToken {
                                        points: 12.,
                                        weight: 600,
                                    },
                                )
                                .text_color(palette::ACCENT.resolve(dark)),
                            ),
                    ),
            );
        }
        body = body.child(
            text(
                "Sending is not available in this preview yet.",
                FontToken {
                    points: 12.,
                    weight: 400,
                },
            )
            .text_color(secondary(dark)),
        );
        div()
            .w_full()
            .flex()
            .justify_center()
            .px(px(24.))
            .pb(px(20.))
            .child(body)
    }
}
