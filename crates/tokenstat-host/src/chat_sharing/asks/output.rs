// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use crate::transcript::Event;

/// Coalesce adjacent deltas and split at UTF-8 boundaries before persistence.
/// Continuation IDs and unscoped attachment references never become output.
fn normalized(events: Vec<Event>) -> Result<Vec<Event>, DispatchError> {
    let mut rows = Vec::new();
    for event in events {
        let thinking = matches!(event, Event::Thinking { .. });
        match event {
            Event::Session { .. } | Event::Attachment { .. } => continue,
            Event::Text { delta } | Event::Thinking { delta } => {
                let mut rest = delta.as_str();
                while !rest.is_empty() {
                    let mut end = rest.len().min(16 * 1024);
                    while !rest.is_char_boundary(end) {
                        end -= 1;
                    }
                    let part = &rest[..end];
                    match rows.last_mut() {
                        Some(Event::Thinking { delta })
                            if thinking && delta.len() + part.len() <= 16 * 1024 =>
                        {
                            delta.push_str(part)
                        }
                        Some(Event::Text { delta })
                            if !thinking && delta.len() + part.len() <= 16 * 1024 =>
                        {
                            delta.push_str(part)
                        }
                        _ => rows.push(if thinking {
                            Event::Thinking { delta: part.into() }
                        } else {
                            Event::Text { delta: part.into() }
                        }),
                    }
                    rest = &rest[end..];
                }
            }
            other => rows.push(other),
        }
        if rows.len() > 128 {
            return Err(unavailable());
        }
    }
    Ok(rows)
}

impl Store {
    pub(crate) fn append_owned_output(
        &self,
        target: SharedSource<'_>,
        prepared: &PreparedAsk,
        batch: u32,
        events: Vec<Event>,
        current: impl Fn() -> Result<(), DispatchError>,
    ) -> Result<(), DispatchError> {
        self.append_owned_output_at(target, prepared, batch, events, current, |_| Ok(()))
    }
    fn append_owned_output_at(
        &self,
        target: SharedSource<'_>,
        prepared: &PreparedAsk,
        batch: u32,
        events: Vec<Event>,
        current: impl Fn() -> Result<(), DispatchError>,
        checkpoint: impl Fn(Step) -> Result<(), DispatchError>,
    ) -> Result<(), DispatchError> {
        let events = normalized(events)?;
        if events.is_empty() {
            return Ok(());
        }
        let request_digest = hash(&events)?;
        let s = &prepared.request.scope;
        let scope = journal::Scope {
            issuer: s.issuer.clone(),
            organization: s.organization.clone(),
            repository: s.repository.clone(),
            checkout: s.checkout.clone(),
            share: s.share.clone(),
        };
        let key = journal::agent_batch_key(&scope, prepared.binding.fence.run_id(), batch)
            .map_err(|_| unavailable())?;
        self.source_locked(
            target.workspace,
            target.id,
            false,
            |mut index, chat, bytes| {
                current()?;
                prepared.ensure_writer_current()?;
                let directory = safe_join(&self.root, target.id).map_err(|_| unavailable())?;
                let mut journal = writer::load(&directory, chat, bytes)?.ok_or_else(unavailable)?;
                if writer::source(chat) != prepared.source
                    || chat.team_run_fence.as_ref() != Some(&prepared.binding.fence)
                {
                    return Err(unavailable());
                }
                let run = journal
                    .run_status(
                        &prepared.request.scope,
                        &prepared.request.actor.person,
                        &prepared.request.client_message_id,
                    )
                    .map_err(|_| unavailable())?
                    .ok_or_else(unavailable)?;
                if run.request() != &prepared.request
                    || run.binding() != &prepared.binding
                    || run.state() != runs::State::Running
                {
                    return Err(unavailable());
                }
                shared_project(
                    chat,
                    bytes,
                    &scope.share,
                    target.preview,
                    Some(&journal),
                    &directory,
                    false,
                )?;
                let chain = journal::read_chain(&directory)?;
                if journal
                    .agent_recorded(&key, &request_digest)
                    .map_err(|_| unavailable())?
                    || journal::recorded(
                        &chain,
                        &scope,
                        prepared.binding.fence.run_id(),
                        batch,
                        &request_digest,
                        events.len() as u32,
                    )
                    .map_err(|_| unavailable())?
                {
                    return Ok(());
                }
                let start = journal::next_shared(bytes, &chain).map_err(|_| unavailable())?;
                let at_ms = now_ms();
                let rows = events
                    .into_iter()
                    .enumerate()
                    .map(|(i, event)| {
                        Ok(journal::AgentRecord::new(
                            start.checked_add(i as u64).ok_or_else(unavailable)?,
                            event,
                            at_ms,
                            prepared.context.backend.clone(),
                            scope.clone(),
                            prepared.actor.clone(),
                            prepared.binding.fence.run_id().into(),
                            batch,
                            i as u16,
                        ))
                    })
                    .collect::<Result<Vec<_>, DispatchError>>()?;
                let prepared_output =
                    journal::prepare(&directory, &journal, &chain, &rows, &request_digest)?;
                journal
                    .reserve_segments(prepared_output.pending)
                    .map_err(|_| unavailable())?;
                writer::save(&directory.join(writer::JOURNAL), &journal)?;
                checkpoint(Step::Reserved)?;
                current()?;
                prepared.ensure_writer_current()?;
                let chain_path = directory.join("team-output").join("chain.ndjson");
                replace_chat_file(&chain_path, &prepared_output.canonical)
                    .map_err(|_| unavailable())?;
                checkpoint(Step::Canonical)?;
                journal
                    .observe_chain(&prepared_output.canonical)
                    .map_err(|_| unavailable())?;
                writer::save(&directory.join(writer::JOURNAL), &journal)?;
                checkpoint(Step::Proven)?;
                self.record_comment_time(&mut index, target.id, at_ms)
            },
        )
    }
}

#[cfg(test)]
#[path = "output_tests.rs"]
mod tests;
