// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
use super::*;

impl Store {
    pub(crate) fn native_steer(&self, id: &str) -> Option<(String, Arc<crate::chat_live::Launch>)> {
        let live = self
            .live_speed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id)
            .cloned()?;
        let active = self
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id)
            .cloned();
        (active.as_deref() == Some(live.0.as_str())
            && live.1.ready_for_steer()
            && tokenstat_pty::manager()
                .info(&live.0)
                .is_ok_and(|info| info.alive))
        .then_some(live)
    }

    /// Timeout never means cancel the active turn or resend the same words.
    pub fn steer_send(
        &self,
        id: &str,
        text: &str,
        client_id: &str,
        created_at: i64,
        revision: u64,
    ) -> Result<Conversation, DispatchError> {
        validate_record_id(id)?;
        if !crate::chat_receipts::valid_id(client_id) {
            return Err("that clientMessageId is not usable".into());
        }
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        crate::account_session::check_current()?;
        crate::workspace_policy::require_current_access()?;
        let chat = self.current_send_conversation(id)?;
        let text = text.trim();
        if text.is_empty() || text.chars().count() > STEER_NOTE_MAX_CHARS || text.starts_with('/') {
            return Err(
                "Steer needs a short text message, without attachments or slash commands.".into(),
            );
        }
        let key =
            crate::chat_receipts::key(crate::request_context::remote_peer().as_deref(), client_id);
        let digest = format!("{}:steer", crate::chat_receipts::digest(text, &[]));
        let ledger = crate::chat_receipts::Ledger::load(self.receipts_path(id), now_ms())
            .map_err(DispatchError::delivery_unknown)?;
        if let Some(receipt) = ledger.get(&key) {
            if receipt.digest != digest {
                return Err("that message id was already used for a different message".into());
            }
            return if receipt.state == crate::chat_receipts::ReceiptState::Accepted {
                Ok(chat)
            } else {
                Err(DispatchError::delivery_unknown(
                    "This steering message may already have reached the agent. Check delivery before sending it again.",
                ))
            };
        }
        crate::chat_receipts::validate_created_at(Some(created_at), now_ms())?;
        if chat.send_revision != revision {
            return Err(DispatchError::new(
                "conversation_changed",
                "This conversation changed. Review it before steering. Your pending copy stays here.",
            ));
        }
        let (pty, live) = self.native_steer(id).filter(|_| chat.running)
            .ok_or_else(|| DispatchError::new("steer_unavailable", "This turn cannot accept live input now. Your message is saved; send it after the turn finishes."))?;
        self.write_receipt(
            id,
            &key,
            crate::chat_receipts::Receipt {
                state: crate::chat_receipts::ReceiptState::Pending,
                digest: digest.clone(),
                at_ms: now_ms(),
                event_at_ms: None,
            },
        )?;
        if let Err(error) = crate::account_session::check_current()
            .map_err(DispatchError::from)
            .and_then(|()| crate::workspace_policy::require_current_access())
        {
            self.drop_receipt(id, &key)
                .map_err(DispatchError::delivery_unknown)?;
            return Err(error);
        }
        match live.steer(&pty, text) {
            Ok(()) => {}
            Err(crate::chat_live::SteerError::Refused(error)) => {
                self.drop_receipt(id, &key)
                    .map_err(DispatchError::delivery_unknown)?;
                return Err(DispatchError::new("steer_refused", error));
            }
            Err(crate::chat_live::SteerError::Unknown(error)) => {
                return Err(DispatchError::delivery_unknown(error));
            }
        }
        let at_ms = now_ms();
        self.append(
            id,
            &StoredEvent::User {
                text: text.into(),
                at_ms,
                steer: true,
            },
        )
        .map_err(DispatchError::delivery_unknown)?;
        OpenOptions::new()
            .read(true)
            .open(self.events_path(id))
            .and_then(|file| file.sync_all())
            .map_err(|error| DispatchError::delivery_unknown(error.to_string()))?;
        self.mark_last_message(id, at_ms, "user")
            .map_err(DispatchError::delivery_unknown)?;
        self.write_receipt(
            id,
            &key,
            crate::chat_receipts::Receipt {
                state: crate::chat_receipts::ReceiptState::Accepted,
                digest,
                at_ms,
                event_at_ms: Some(at_ms),
            },
        )
        .map_err(DispatchError::delivery_unknown)?;
        self.get(id).map_err(Into::into)
    }
}
