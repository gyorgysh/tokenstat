// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Account ownership and non-reusable lifetimes for the shared relay socket.

use super::TunnelState;
use std::sync::Arc;
use tokenstat_identity::PublicKey;

#[derive(Clone, PartialEq, Eq)]
pub(super) struct Scope {
    pub owner: String,
    pub key: PublicKey,
    pub endpoint: String,
}

// A lifetime cannot be reconstructed from an account ID, key, or JSON input.
// Stopping and starting the same account still creates a different lifetime.
#[derive(Clone)]
pub(super) struct Attempt {
    pub scope: Scope,
    lifetime: Arc<()>,
}
impl Attempt {
    fn same(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.lifetime, &other.lifetime) && self.scope == other.scope
    }
}

pub(super) struct Live<T> {
    pub attempt: Attempt,
    pub socket: Arc<T>,
}
impl<T> Clone for Live<T> {
    fn clone(&self) -> Self {
        Self {
            attempt: self.attempt.clone(),
            socket: self.socket.clone(),
        }
    }
}

pub(super) struct Runtime<T> {
    attempt: Option<Attempt>,
    live: Option<Live<T>>,
    starting: bool,
    state: TunnelState,
}
impl<T> Default for Runtime<T> {
    fn default() -> Self {
        Self {
            attempt: None,
            live: None,
            starting: false,
            state: TunnelState::default(),
        }
    }
}
impl<T> Runtime<T> {
    pub fn begin(&mut self, scope: Scope) -> (Attempt, Option<Arc<T>>) {
        let retired = self.stop();
        let attempt = Attempt {
            scope,
            lifetime: Arc::new(()),
        };
        self.attempt = Some(attempt.clone());
        self.starting = true;
        (attempt, retired)
    }

    pub fn current_attempt(&self, attempt: &Attempt) -> bool {
        self.attempt.as_ref().is_some_and(|held| held.same(attempt))
    }

    pub fn install(&mut self, attempt: &Attempt, socket: Arc<T>) -> Option<Live<T>> {
        if !self.starting || !self.current_attempt(attempt) || self.live.is_some() {
            return None;
        }
        let live = Live {
            attempt: attempt.clone(),
            socket,
        };
        self.starting = false;
        self.live = Some(live.clone());
        Some(live)
    }

    pub fn running(&self) -> bool {
        self.starting || self.live.is_some()
    }

    pub fn active(&self, scope: &Scope) -> Option<Live<T>> {
        self.live
            .as_ref()
            .filter(|live| &live.attempt.scope == scope)
            .cloned()
    }

    pub fn update_attempt(
        &mut self,
        attempt: &Attempt,
        update: impl FnOnce(&mut TunnelState),
    ) -> bool {
        if !self.current_attempt(attempt) {
            return false;
        }
        update(&mut self.state);
        true
    }

    pub fn fail(&mut self, attempt: &Attempt, error: Option<String>) -> bool {
        if !self.starting || !self.current_attempt(attempt) || self.live.is_some() {
            return false;
        }
        self.starting = false;
        self.state.connected = false;
        self.state.error = error;
        true
    }

    pub fn with_live<R>(
        &mut self,
        live: &Live<T>,
        action: impl FnOnce(&Arc<T>, &mut TunnelState) -> R,
    ) -> Option<R> {
        let held = self.live.as_ref()?;
        if !held.attempt.same(&live.attempt) || !Arc::ptr_eq(&held.socket, &live.socket) {
            return None;
        }
        Some(action(&held.socket, &mut self.state))
    }

    pub fn finish(&mut self, live: &Live<T>) -> Option<Arc<T>> {
        self.with_live(live, |_, _| ())?;
        self.stop()
    }

    pub fn stop(&mut self) -> Option<Arc<T>> {
        self.attempt = None;
        self.starting = false;
        self.state = TunnelState::default();
        self.live.take().map(|live| live.socket)
    }

    pub fn snapshot(&self, scope: &Scope) -> (TunnelState, Option<Live<T>>) {
        if !self
            .attempt
            .as_ref()
            .is_some_and(|held| &held.scope == scope)
        {
            return (TunnelState::default(), None);
        }
        (self.state.clone(), self.active(scope))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[derive(Default)]
    struct Socket {
        tokens: Mutex<Vec<&'static str>>,
    }
    fn scope(owner: &str, key: u8) -> Scope {
        Scope {
            owner: owner.into(),
            key: [key; 32],
            endpoint: "ws://127.0.0.1:1".into(),
        }
    }
    fn start(runtime: &mut Runtime<Socket>, scope: Scope) -> Live<Socket> {
        let (attempt, _) = runtime.begin(scope);
        runtime
            .install(&attempt, Arc::new(Socket::default()))
            .unwrap()
    }

    #[test]
    fn late_credentials_cannot_install_after_stop_or_into_a_new_account() {
        let mut runtime = Runtime::<Socket>::default();
        let (old, _) = runtime.begin(scope("first", 1));
        runtime.stop();
        assert!(runtime.install(&old, Arc::new(Socket::default())).is_none());
        let new = start(&mut runtime, scope("second", 1));
        assert!(runtime.install(&old, Arc::new(Socket::default())).is_none());
        assert!(!runtime.fail(&old, Some("old account error".into())));
        assert!(runtime.snapshot(&new.attempt.scope).0.error.is_none());
        assert!(runtime.running());
    }

    #[test]
    fn old_inbound_and_refresh_completions_cannot_clear_or_change_a_replacement() {
        let mut runtime = Runtime::<Socket>::default();
        let scope = scope("same account", 1);
        let old = start(&mut runtime, scope.clone());
        let new = start(&mut runtime, scope.clone());
        assert!(
            runtime
                .with_live(&old, |socket, state| {
                    socket.tokens.lock().unwrap().push("old credential");
                    state.error = Some("old refresh error".into());
                })
                .is_none()
        );
        assert!(runtime.finish(&old).is_none());
        assert!(runtime.active(&scope).is_some());
        assert!(new.socket.tokens.lock().unwrap().is_empty());
        assert!(runtime.snapshot(&scope).0.error.is_none());
        runtime
            .with_live(&new, |socket, state| {
                socket.tokens.lock().unwrap().push("new credential");
                state.connected = true;
            })
            .unwrap();
        assert_eq!(*new.socket.tokens.lock().unwrap(), ["new credential"]);
        assert!(runtime.snapshot(&scope).0.connected);
    }

    #[test]
    fn a_socket_is_not_reused_for_another_login_key_or_relay_endpoint() {
        let mut runtime = Runtime::<Socket>::default();
        let first = scope("first", 1);
        let live = start(&mut runtime, first.clone());
        runtime.with_live(&live, |_, state| {
            state.error = Some("private start error".into())
        });
        for other in [
            scope("second", 1),
            scope("first", 2),
            Scope {
                endpoint: "ws://127.0.0.1:2".into(),
                ..first
            },
        ] {
            assert!(runtime.active(&other).is_none());
            let (state, socket) = runtime.snapshot(&other);
            assert!(state.error.is_none());
            assert!(!state.connected);
            assert!(socket.is_none());
        }
    }

    #[test]
    fn a_credential_response_waiting_on_another_thread_cannot_revive_a_retired_start() {
        for replacement in [scope("first", 1), scope("second", 1), scope("first", 2)] {
            let runtime = Arc::new(Mutex::new(Runtime::<Socket>::default()));
            let (old, _) = runtime.lock().unwrap().begin(scope("first", 1));
            let (release, waiting) = std::sync::mpsc::channel();
            let delayed = runtime.clone();
            let worker =
                std::thread::spawn(move || {
                    waiting.recv().unwrap();
                    let mut held = delayed.lock().unwrap();
                    assert!(held.install(&old, Arc::new(Socket::default())).is_none());
                    assert!(!held.update_attempt(&old, |state| state.error =
                        Some("retired account".into())));
                });
            runtime.lock().unwrap().stop();
            let current = start(&mut runtime.lock().unwrap(), replacement.clone());
            runtime
                .lock()
                .unwrap()
                .with_live(&current, |socket, state| {
                    socket
                        .tokens
                        .lock()
                        .unwrap()
                        .push("current account credential");
                    state.connected = true;
                });
            release.send(()).unwrap();
            worker.join().unwrap();
            let held = runtime.lock().unwrap();
            assert!(held.running());
            assert!(held.snapshot(&replacement).0.connected);
            assert!(held.snapshot(&replacement).0.error.is_none());
            assert_eq!(
                *current.socket.tokens.lock().unwrap(),
                ["current account credential"]
            );
        }
    }

    #[test]
    fn a_failed_attempt_stops_running_and_keeps_its_error_until_the_next_attempt() {
        let mut runtime = Runtime::<Socket>::default();
        let scope = scope("first", 1);
        let (old, _) = runtime.begin(scope.clone());
        assert!(runtime.fail(&old, Some("plan refused".into())));
        assert!(!runtime.running());
        assert!(!runtime.fail(&old, None));
        assert_eq!(
            runtime.snapshot(&scope).0.error.as_deref(),
            Some("plan refused")
        );
        let next = start(&mut runtime, scope.clone());
        assert!(runtime.snapshot(&scope).0.error.is_none());
        assert!(runtime.finish(&next).is_some());
        assert!(!runtime.running());
    }
}
