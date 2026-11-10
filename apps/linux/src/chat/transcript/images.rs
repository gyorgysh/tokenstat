// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Galleries only join adjacent images or explicitly attributed tool output.

use super::{Kind, Row, has_prefix, nfc};
use crate::{drafts::Attachment, work::text};
use std::collections::HashMap;

fn append(file: &Attachment, id: &str, row: &mut Row) {
    if !row
        .image_attachments
        .iter()
        .any(|f| text::equal(&f.id, &file.id))
    {
        row.image_attachments.push(file.clone());
    }
    if !row.image_row_ids.iter().any(|f| text::equal(f, id)) {
        row.image_row_ids.push(id.into());
    }
}
pub fn prepare(rows: &[Row]) -> Vec<Row> {
    let mut result: Vec<Row> = vec![];
    let mut tools: HashMap<(String, Option<String>), usize> = HashMap::new();
    for row in rows {
        match &row.kind {
            Kind::User { .. } if !row.is_steer => tools.clear(),
            Kind::Handoff { .. } | Kind::TurnSeparator { .. } => tools.clear(),
            Kind::Tool { state } if !state.call_id.is_empty() => {
                tools.insert(
                    (nfc(&state.call_id), row.source_backend.as_deref().map(nfc)),
                    result.len(),
                );
            }
            _ => {}
        }
        let Kind::Attachment { file } = &row.kind else {
            result.push(row.clone());
            continue;
        };
        if !file
            .media_type
            .as_deref()
            .is_some_and(|m| has_prefix(m, "image/"))
        {
            result.push(row.clone());
            continue;
        }
        if let Some(index) = file
            .tool_call_id
            .as_ref()
            .and_then(|call| tools.get(&(nfc(call), row.source_backend.as_deref().map(nfc))))
        {
            append(file, &row.id, &mut result[*index]);
        } else if let Some(last) = result.last_mut()
            && let Kind::Attachment { file: previous } = &last.kind
            && previous
                .media_type
                .as_deref()
                .is_some_and(|m| has_prefix(m, "image/"))
            && super::SourceEq::source_eq(&previous.tool_call_id, &file.tool_call_id)
            && super::SourceEq::source_eq(&last.source_backend, &row.source_backend)
        {
            append(file, &row.id, last);
        } else {
            let mut gallery = row.clone();
            append(file, &row.id, &mut gallery);
            result.push(gallery);
        }
    }
    result
}
pub fn row_id(id: &str, rows: &[Row]) -> String {
    rows.iter()
        .find(|r| text::equal(&r.id, id) || r.image_row_ids.iter().any(|r| text::equal(r, id)))
        .map_or_else(|| id.into(), |r| r.id.clone())
}
