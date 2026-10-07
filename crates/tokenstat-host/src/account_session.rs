// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Immutable login ownership for local status and forwarded presence requests.

use serde_json::Value;
use std::cell::RefCell;
use std::sync::{Arc, Mutex, OnceLock, atomic::Ordering};
use tokenstat_sync::profile::{ProfileError, StatusResult};
use tokenstat_sync::vault::{VaultClient, VaultError};

const CHANGED: &str = "the signed-in account changed; retry from the current account";

#[derive(Clone)]
pub(crate) struct AccountSnapshot {
    pub(crate) id: String,
    pub(crate) client: Option<VaultClient>,
    current: Arc<dyn Fn() -> Result<(), String> + Send + Sync>,
}

thread_local! {
    static PINNED: RefCell<Option<AccountSnapshot>> = const { RefCell::new(None) };
}

fn epoch_current(epoch: u64) -> Result<(), String> {
    if crate::vault::SIGNOUTS.load(Ordering::SeqCst) == 0
        && crate::vault::AUTH_EPOCH.load(Ordering::SeqCst) == epoch
    {
        Ok(())
    } else {
        Err(CHANGED.into())
    }
}

impl AccountSnapshot {
    pub(crate) fn capture() -> Result<Self, String> {
        let epoch = crate::vault::AUTH_EPOCH.load(Ordering::SeqCst);
        epoch_current(epoch)?;
        let client = match VaultClient::capture() {
            Ok(client) => Some(client.with_retirement_guard(move || {
                epoch_current(epoch).map_err(|_| VaultError::AccountChanged)
            })),
            Err(VaultError::NotSignedIn) => None,
            Err(error) => return Err(error.to_string()),
        };
        static NONCE: OnceLock<String> = OnceLock::new();
        let nonce = NONCE.get_or_init(|| {
            rand::random::<[u8; 16]>()
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect()
        });
        let owner = client
            .as_ref()
            .map(VaultClient::authentication_id)
            .unwrap_or_else(|| "local".into());
        let held = client.clone();
        let snapshot = Self {
            id: format!("{nonce}:{epoch}:{owner}"),
            client,
            current: Arc::new(move || {
                epoch_current(epoch)?;
                match &held {
                    Some(client) => client.ensure_current().map_err(|error| error.to_string())?,
                    None => match VaultClient::capture() {
                        Err(VaultError::NotSignedIn) => {}
                        _ => return Err(CHANGED.into()),
                    },
                }
                epoch_current(epoch)
            }),
        };
        snapshot.ensure_current()?;
        Ok(snapshot)
    }

    pub(crate) fn ensure_current(&self) -> Result<(), String> {
        (self.current)()
    }

    /// Presence reuses a server-proven identity, never a /me request per beat.
    pub(crate) fn status(&self, refresh: bool) -> Result<StatusResult, ProfileError> {
        static CACHE: OnceLock<Mutex<Option<(String, StatusResult)>>> = OnceLock::new();
        let cache = CACHE.get_or_init(|| Mutex::new(None));
        self.ensure_current().map_err(ProfileError::Message)?;
        if !refresh {
            let guard = cache
                .lock()
                .map_err(|_| ProfileError::Message("account status cache unavailable".into()))?;
            if let Some((_, status)) = guard.as_ref().filter(|(id, _)| id == &self.id) {
                self.ensure_current().map_err(ProfileError::Message)?;
                return Ok(status.clone());
            }
        }
        let client = self
            .client
            .as_ref()
            .ok_or_else(|| ProfileError::Message(tokenstat_sync::profile::NOT_LOGGED_IN.into()))?;
        let status = client.account_status()?;
        self.ensure_current().map_err(ProfileError::Message)?;
        let mut guard = cache
            .lock()
            .map_err(|_| ProfileError::Message("account status cache unavailable".into()))?;
        self.ensure_current().map_err(ProfileError::Message)?;
        *guard = Some((self.id.clone(), status.clone()));
        Ok(status)
    }

    pub(crate) fn for_request(params: &str) -> Result<Option<Self>, String> {
        let body: Value = serde_json::from_str(params).map_err(|error| error.to_string())?;
        let Some(scope) = body.get("_accountScope") else {
            return Ok(None);
        };
        let snapshot = Self::capture()?;
        snapshot.validate_receipt(&body)?;
        match scope.get("kind").and_then(Value::as_str) {
            Some("local") if snapshot.client.is_none() => {}
            Some("account") => {
                let status = snapshot.status(false).map_err(|error| error.to_string())?;
                validate_account(
                    scope,
                    &status.host,
                    status.handle.as_deref(),
                    status.account_id.as_deref(),
                )?;
            }
            _ => return Err(CHANGED.into()),
        }
        snapshot.ensure_current()?;
        Ok(Some(snapshot))
    }

    fn validate_receipt(&self, body: &Value) -> Result<(), String> {
        if let Some(receipt) = body.get("_accountSession") {
            if receipt.as_str() != Some(self.id.as_str()) {
                return Err(CHANGED.into());
            }
        }
        Ok(())
    }
}

fn validate_account(
    scope: &Value,
    host: &str,
    handle: Option<&str>,
    id: Option<&str>,
) -> Result<(), String> {
    let matches = scope.get("kind").and_then(Value::as_str) == Some("account")
        && scope
            .get("origin")
            .and_then(Value::as_str)
            .and_then(canonical_origin)
            .zip(canonical_origin(host))
            .is_some_and(|(requested, verified)| requested == verified)
        && scope
            .get("identity")
            .and_then(Value::as_str)
            .is_some_and(|identity| {
                !identity.is_empty() && (Some(identity) == handle || Some(identity) == id)
            });
    if matches { Ok(()) } else { Err(CHANGED.into()) }
}

/// Match the client's account origin spelling without weakening origin checks.
fn canonical_origin(raw: &str) -> Option<String> {
    let mut url = reqwest::Url::parse(raw).ok()?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return None;
    }
    url.set_query(None);
    url.set_fragment(None);
    Some(url.as_str().trim_end_matches('/').to_owned())
}

pub(crate) fn current_snapshot() -> Option<AccountSnapshot> {
    PINNED.with(|slot| slot.borrow().clone())
}

pub(crate) fn current_or_capture() -> Result<AccountSnapshot, String> {
    let held = current_snapshot();
    let held = match held {
        Some(held) => held,
        None => AccountSnapshot::capture()?,
    };
    held.ensure_current()?;
    Ok(held)
}

pub(crate) fn check_current() -> Result<(), String> {
    PINNED.with(|slot| {
        slot.borrow()
            .as_ref()
            .map_or(Ok(()), AccountSnapshot::ensure_current)
    })
}

pub(crate) fn with_snapshot<T>(
    snapshot: Option<AccountSnapshot>,
    action: impl FnOnce() -> Result<T, String>,
) -> Result<T, String> {
    struct Restore(Option<AccountSnapshot>);
    impl Drop for Restore {
        fn drop(&mut self) {
            PINNED.with(|slot| *slot.borrow_mut() = self.0.take());
        }
    }
    if let Some(snapshot) = &snapshot {
        snapshot.ensure_current()?;
    }
    let previous = PINNED.with(|slot| std::mem::replace(&mut *slot.borrow_mut(), snapshot));
    let _restore = Restore(previous);
    let result = action();
    check_current()?;
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicU64;
    #[test]
    fn nested_transport_guards_retire_held_work_and_restore_their_owner() {
        let epoch = Arc::new(AtomicU64::new(1));
        let checked = epoch.clone();
        let first = AccountSnapshot {
            id: "first".into(),
            client: None,
            current: Arc::new(move || {
                if checked.load(Ordering::SeqCst) == 1 {
                    Ok(())
                } else {
                    Err(CHANGED.into())
                }
            }),
        };
        with_snapshot(Some(first.clone()), || {
            assert_eq!(current_or_capture()?.id, "first");
            let second = AccountSnapshot {
                id: "second".into(),
                client: None,
                current: Arc::new(|| Ok(())),
            };
            with_snapshot(Some(second), || {
                assert_eq!(current_or_capture()?.id, "second");
                Ok(())
            })?;
            assert_eq!(current_or_capture()?.id, "first");
            Ok(())
        })
        .unwrap();
        assert!(check_current().is_ok());
        assert!(
            with_snapshot(Some(first), || {
                epoch.store(2, Ordering::SeqCst);
                check_current()
            })
            .is_err()
        );
        assert!(check_current().is_ok());
    }
    #[test]
    fn receipts_and_server_identity_reject_restarts_other_origins_and_accounts() {
        let snapshot = AccountSnapshot {
            id: "nonce:3:credential".into(),
            client: None,
            current: Arc::new(|| Ok(())),
        };
        assert!(
            snapshot
                .validate_receipt(&serde_json::json!({"_accountSession":"nonce:3:credential"}))
                .is_ok()
        );
        for receipt in [
            "nonce:1:credential",
            "another-process:3:credential",
            "nonce:3:other",
        ] {
            assert!(
                snapshot
                    .validate_receipt(&serde_json::json!({"_accountSession":receipt}))
                    .is_err()
            );
        }
        let scope = serde_json::json!({"kind":"account", "origin":"https://mock.example", "identity":"alice"});
        assert!(
            validate_account(&scope, "https://mock.example", Some("alice"), Some("id-a")).is_ok()
        );
        assert!(
            validate_account(
                &scope,
                "https://MOCK.example:443/",
                Some("alice"),
                Some("id-a")
            )
            .is_ok()
        );
        let prefixed = serde_json::json!({"kind":"account", "origin":"https://mock.example/service", "identity":"alice"});
        assert!(
            validate_account(
                &prefixed,
                "https://MOCK.example:443/service/",
                Some("alice"),
                Some("id-a")
            )
            .is_ok()
        );
        assert!(
            validate_account(
                &prefixed,
                "https://mock.example/other",
                Some("alice"),
                Some("id-a")
            )
            .is_err()
        );
        assert!(
            validate_account(&scope, "http://mock.example", Some("alice"), Some("id-a")).is_err()
        );
        assert!(
            validate_account(
                &scope,
                "https://user@mock.example",
                Some("alice"),
                Some("id-a")
            )
            .is_err()
        );
        assert!(
            validate_account(&scope, "https://other.example", Some("alice"), Some("id-a")).is_err()
        );
        assert!(
            validate_account(&scope, "https://mock.example", Some("bob"), Some("id-b")).is_err()
        );
    }
}
