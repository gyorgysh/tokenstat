// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Advance a displayed context only for a single acknowledged edit of its own.

pub fn after_own_edit(
    context: Option<u64>,
    previous: Option<u64>,
    updated: Option<u64>,
) -> Option<u64> {
    match (previous, updated) {
        (Some(previous), Some(updated))
            if context == Some(previous) && previous.checked_add(1) == Some(updated) =>
        {
            Some(updated)
        }
        _ => context,
    }
}
