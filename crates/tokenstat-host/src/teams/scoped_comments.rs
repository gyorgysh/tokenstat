// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{AuthorizedTeamPrincipal, scoped_source::Source};
use crate::{chat::sharing::CommentInput, error::DispatchError};
use serde_json::Value;

pub(super) fn send(
    principal: &AuthorizedTeamPrincipal,
    input: &CommentInput,
) -> Result<Value, DispatchError> {
    input.validate()?;
    let source = Source::capture(principal)?;
    let result = crate::chat::shared().team_comment(source.target(), principal, input, || {
        source.ensure_current()
    })?;
    source.ensure_current()?;
    principal.ensure_account_current()?;
    Ok(result)
}
pub(super) fn status(
    principal: &AuthorizedTeamPrincipal,
    message: &str,
) -> Result<Value, DispatchError> {
    let source = Source::capture(principal)?;
    let target = source.target();
    let result = crate::chat::shared().team_comment_status(
        target.workspace,
        target.id,
        target.preview,
        principal,
        message,
    )?;
    source.ensure_current()?;
    principal.ensure_account_current()?;
    Ok(result)
}
