// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Ownership derived only from an accepted account.status response. The host
//! already normalizes API origins in tokenstat-sync::host::resolve_host.
//! This is the in-process login lifetime gate. Durable installation identity,
//! saved-access authentication and model loading have separate owners.

use crate::desktop_data::Account;
use crate::work::{Scope, text};

#[derive(Clone, Debug, PartialEq, Eq)]
enum Identity {
    Local,
    Account(Scope),
}
#[derive(Clone, Debug, Default)]
pub struct LoginOwner {
    identity: Option<Identity>,
    session: Option<String>,
    generation: u64,
}
fn account_identity(account: &Account) -> Option<String> {
    Scope::account_identity(account.handle.as_deref(), account.account_id.as_deref())
        .map(str::to_owned)
}
impl LoginOwner {
    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub fn account_session(&self) -> Option<&str> {
        self.session.as_deref()
    }
    /// Installation identity is supplied by the local metadata owner. Unknown
    /// account state never becomes signed-out local continuity.
    pub fn work_scope(&self, installation: &str) -> Option<Scope> {
        match &self.identity {
            Some(Identity::Local) => Some(Scope::local(installation)),
            Some(Identity::Account(scope)) => Some(scope.clone()),
            None => None,
        }
    }
    /// Mirrors WorkSessionContext.update's generation/receipt behavior for
    /// already-normalized host account responses. Missing state is unknown.
    pub fn update(&mut self, account: Option<&Account>) -> bool {
        let next = account.and_then(|account| {
            if account.signed_in {
                account_identity(account)
                    .and_then(|identity| Scope::account(&account.host, &identity))
                    .map(Identity::Account)
            } else {
                Some(Identity::Local)
            }
        });
        let next_session = account.and_then(|a| a.account_session.clone()).or_else(|| {
            (next.is_some() && next == self.identity)
                .then(|| self.session.clone())
                .flatten()
        });
        let same_session = match (&next_session, &self.session) {
            (Some(a), Some(b)) => text::equal(a, b),
            (None, None) => true,
            _ => false,
        };
        if next == self.identity && same_session {
            return false;
        }
        self.generation = self.generation.wrapping_add(1);
        self.identity = next;
        self.session = next_session;
        true
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReadTicket(u64);
#[derive(Clone, Debug, Default)]
pub struct AccountState {
    pub account: Option<Account>,
    pub error: Option<String>,
    pub owner: LoginOwner,
    read_generation: u64,
}
impl AccountState {
    pub fn begin(&mut self) -> ReadTicket {
        self.read_generation = self.read_generation.wrapping_add(1);
        ReadTicket(self.read_generation)
    }
    pub fn accept(&mut self, ticket: ReadTicket, result: Result<Account, String>) -> bool {
        if ticket.0 != self.read_generation {
            return false;
        }
        match result {
            Ok(account) => {
                self.owner.update(Some(&account));
                self.account = Some(account);
                self.error = None;
            }
            Err(error) => self.error = Some(error),
        }
        true
    }
    pub fn fixture() -> Self {
        let mut state = Self::default();
        let ticket = state.begin();
        state.accept(ticket, crate::desktop_data::DesktopData::fixture().account);
        state
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn account(handle: Option<&str>, id: Option<&str>, session: Option<&str>) -> Account {
        Account {
            signed_in: true,
            host: "https://fixture.invalid".into(),
            handle: handle.map(str::to_owned),
            account_id: id.map(str::to_owned),
            account_session: session.map(str::to_owned),
            display_name: None,
            tier: None,
            avatar: None,
            machines: Vec::new(),
        }
    }
    #[test]
    fn login_restart_same_identity_receipt_omission_and_signout_have_source_lifetimes() {
        let mut owner = LoginOwner::default();
        assert!(!owner.update(None));
        let mut account = account(Some(" alice "), Some("id"), Some("helper:login1"));
        assert!(owner.update(Some(&account)));
        assert_eq!(owner.generation(), 1);
        assert!(!owner.update(Some(&account)));
        account.account_session = None;
        assert!(!owner.update(Some(&account)));
        assert_eq!(owner.account_session(), Some("helper:login1"));
        account.account_session = Some("helper:login2".into());
        assert!(owner.update(Some(&account)));
        account.account_session = Some("restart:login2".into());
        assert!(owner.update(Some(&account)));
        account.signed_in = false;
        assert!(owner.update(Some(&account)));
        assert_eq!(owner.generation(), 4);
        assert!(owner.update(None));
        assert!(owner.account_session().is_none());
    }
    #[test]
    fn handleless_accounts_and_unknown_identity_are_not_signedout_local_work() {
        let mut owner = LoginOwner::default();
        let mut account = account(None, Some("server-id"), None);
        assert!(owner.update(Some(&account)));
        account.handle = Some("\u{200b}\n ".into());
        assert!(!owner.update(Some(&account)));
        account.handle = Some("alice".into());
        assert!(owner.update(Some(&account)));
        account.host = "https://other.invalid".into();
        assert!(owner.update(Some(&account)));
        account.handle = None;
        account.account_id = None;
        assert!(owner.update(Some(&account)));
        assert_eq!(owner.identity, None);
        account.signed_in = false;
        assert!(owner.update(Some(&account)));
        assert_eq!(owner.identity, Some(Identity::Local));
    }
    #[test]
    fn old_account_reads_cannot_reverse_a_new_login_and_errors_retain_verified_state() {
        let mut state = AccountState::default();
        let old = state.begin();
        let new = state.begin();
        assert!(state.accept(new, Ok(account(Some("bob"), None, Some("second")))));
        assert!(!state.accept(old, Ok(account(Some("alice"), None, Some("first")))));
        assert_eq!(state.owner.account_session(), Some("second"));
        let read = state.begin();
        assert!(state.accept(read, Err("offline".into())));
        assert_eq!(
            state.account.as_ref().unwrap().handle.as_deref(),
            Some("bob")
        );
        assert_eq!(state.owner.generation(), 1);
        assert_eq!(state.error.as_deref(), Some("offline"));
    }
}
