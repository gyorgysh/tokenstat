// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::tunnel_runtime::{Attempt, Live, Runtime, Scope};
use super::*;
use crate::account_session::{AccountSnapshot, current_or_capture, with_snapshot};
use tokenstat_remote::tunnel::TunnelSession;

fn runtime() -> &'static Mutex<Runtime<TunnelSession>> {
    static RUNTIME: OnceLock<Mutex<Runtime<TunnelSession>>> = OnceLock::new();
    RUNTIME.get_or_init(|| Mutex::new(Runtime::default()))
}

#[derive(Clone)]
pub(super) struct OwnedTunnel {
    live: Live<TunnelSession>,
    owner: AccountSnapshot,
}

fn scope(owner: &AccountSnapshot, identity: &MachineIdentity, settings: &RemoteSettings) -> Scope {
    Scope {
        owner: owner.id.clone(),
        key: identity.public_key(),
        endpoint: settings.tunnel_endpoint.clone(),
    }
}

fn available(settings: &RemoteSettings, scope: &Scope) -> bool {
    !tunnel_paused().load(Ordering::Acquire)
        && settings.tunnel_endpoint == scope.endpoint
        && (settings.tunnel || super::team_reach::active(scope))
}

pub(super) fn wanted() -> bool {
    if tunnel_paused().load(Ordering::Acquire) {
        return false;
    }
    let settings = load_settings();
    if settings.tunnel {
        return true;
    }
    let Ok(owner) = current_or_capture() else {
        return false;
    };
    let Ok(Some(identity)) = MachineIdentity::load() else {
        return false;
    };
    super::team_reach::wanted(&scope(&owner, &identity, &settings))
}

pub(super) fn retire_if_unused(scope: &Scope) {
    let retired = runtime().lock().ok().and_then(|mut held| {
        if available(&load_settings(), scope) {
            return None;
        }
        let live = held.active(scope)?;
        held.finish(&live)
    });
    if let Some(socket) = retired {
        socket.shutdown();
    }
}

pub(super) fn personal_disabled() {
    let (live, retired) = match runtime().lock() {
        Ok(mut held) => {
            let Some(scope) = held.scope().cloned() else {
                return;
            };
            let live = held.active(&scope);
            let retired = if available(&load_settings(), &scope) {
                None
            } else {
                held.stop()
            };
            (live, retired)
        }
        Err(_) => return,
    };
    if let Some(live) = live {
        live.socket.close_personal_channels();
    }
    if let Some(socket) = retired {
        socket.shutdown();
    }
}

struct Pending(Attempt);
impl Drop for Pending {
    fn drop(&mut self) {
        if let Ok(mut held) = runtime().lock() {
            held.fail(&self.0, None);
        }
    }
}

impl OwnedTunnel {
    pub fn ensure_current(&self) -> Result<(), String> {
        self.owner.ensure_current()?;
        let settings = load_settings();
        let identity = MachineIdentity::load()
            .map_err(|_| "This device's connection key is unavailable.")?
            .ok_or("This device's connection key changed. Connect again.")?;
        if !available(&settings, &self.live.attempt.scope)
            || self.live.attempt.scope != scope(&self.owner, &identity, &settings)
        {
            return Err("This device's remote connection changed. Connect again.".into());
        }
        runtime()
            .lock()
            .map_err(|_| "Remote connection state is unavailable.")?
            .with_live(&self.live, |_, _| ())
            .ok_or("This remote connection ended. Connect again.")?;
        self.owner.ensure_current()
    }

    pub fn socket(&self) -> Result<&Arc<TunnelSession>, String> {
        self.ensure_current()?;
        Ok(&self.live.socket)
    }

    pub fn update(&self, action: impl FnOnce(&mut TunnelState)) -> Result<(), String> {
        self.ensure_current()?;
        runtime()
            .lock()
            .map_err(|_| "Remote connection state is unavailable.")?
            .with_live(&self.live, |_, state| action(state))
            .ok_or("This remote connection ended. Connect again.")?;
        self.owner.ensure_current()
    }

    pub fn set_token(&self, token: &str) -> Result<(), String> {
        self.ensure_current()?;
        runtime()
            .lock()
            .map_err(|_| "Remote connection state is unavailable.")?
            .with_live(&self.live, |socket, state| {
                socket.set_token(token);
                state.error = None;
                state.registered = true;
            })
            .ok_or("This remote connection ended. Connect again.")?;
        self.owner.ensure_current()
    }

    fn finish(&self) {
        let retired = runtime()
            .lock()
            .ok()
            .and_then(|mut held| held.finish(&self.live));
        if let Some(socket) = retired {
            socket.shutdown();
        }
    }
}

pub(super) fn current() -> Result<Option<OwnedTunnel>, String> {
    let owner = current_or_capture()?;
    let identity = MachineIdentity::load_or_create()
        .map_err(|_| "This device's connection key is unavailable.")?;
    let settings = load_settings();
    if !available(&settings, &scope(&owner, &identity, &settings)) {
        return Ok(None);
    }
    let live = runtime()
        .lock()
        .map_err(|_| "Remote connection state is unavailable.")?
        .active(&scope(&owner, &identity, &settings));
    let owned = live.map(|live| OwnedTunnel { live, owner });
    if let Some(owned) = &owned {
        owned.ensure_current()?;
    }
    Ok(owned)
}

pub(super) fn state() -> Result<TunnelState, String> {
    let owner = current_or_capture()?;
    let identity = MachineIdentity::load_or_create()
        .map_err(|_| "This device's connection key is unavailable.")?;
    let settings = load_settings();
    let (mut state, live) = runtime()
        .lock()
        .map_err(|_| "Remote connection state is unavailable.")?
        .snapshot(&scope(&owner, &identity, &settings));
    if let Some(live) = live {
        let owned = OwnedTunnel {
            live,
            owner: owner.clone(),
        };
        if let Ok(socket) = owned.socket() {
            merge_live_tunnel_status(&mut state, &socket.status());
        } else {
            state.connected = false;
        }
    }
    owner.ensure_current()?;
    Ok(state)
}

pub(super) fn running() -> bool {
    runtime().lock().is_ok_and(|held| held.running())
}

pub(super) fn stop() {
    super::team_reach::clear();
    let retired = runtime().lock().ok().and_then(|mut held| held.stop());
    if let Some(socket) = retired {
        socket.shutdown();
    }
    clear_held_credential();
    clear_account_directory();
}

pub(super) fn start(session: Arc<Mutex<Session>>, settings: &RemoteSettings) {
    if let Err(error) = ensure(Arc::clone(&session), settings, false) {
        eprintln!("remote: tunnel is enabled but unavailable: {error}");
        if wanted() && !is_permanent_start_error(&error) {
            retry_start_later(session);
        }
    }
}

pub(super) fn ensure(
    session: Arc<Mutex<Session>>,
    settings: &RemoteSettings,
    force: bool,
) -> Result<Option<OwnedTunnel>, String> {
    if tunnel_paused().load(Ordering::Acquire) {
        return Ok(None);
    }
    let _starting = STARTING.lock().unwrap_or_else(|e| e.into_inner());
    let latest = load_settings();
    if tunnel_paused().load(Ordering::Acquire) || latest.tunnel_endpoint != settings.tunnel_endpoint
    {
        return Ok(None);
    }
    let owner = current_or_capture()?;
    let identity = match MachineIdentity::load()
        .map_err(|_| "This device's connection key is unavailable.")?
    {
        Some(identity) => identity,
        None if !latest.tunnel => return Ok(None),
        None => MachineIdentity::load_or_create()
            .map_err(|_| "This device's connection key is unavailable.")?,
    };
    let wanted = scope(&owner, &identity, settings);
    if !available(&latest, &wanted) {
        crate::teams::restore_remote_reach(&owner, &identity).map_err(|error| error.to_string())?;
        if !available(&load_settings(), &wanted) {
            return Ok(None);
        }
    }
    let existing = runtime()
        .lock()
        .map_err(|_| "Remote connection state is unavailable.")?
        .active(&wanted);
    if let Some(live) = existing {
        let owned = OwnedTunnel {
            live,
            owner: owner.clone(),
        };
        let (token, _) = with_snapshot(Some(owner), || tunnel_hello_token(force))?;
        owned.set_token(&token)?;
        return Ok(Some(owned));
    }
    let (attempt, retired) = runtime()
        .lock()
        .map_err(|_| "Remote connection state is unavailable.")?
        .begin(wanted);
    let _pending = Pending(attempt.clone());
    if let Some(socket) = retired {
        socket.shutdown();
    }
    let result = with_snapshot(Some(owner.clone()), || tunnel_hello_token(force));
    let (token, ttl) = match result {
        Ok(value) => value,
        Err(error) => {
            if let Ok(mut held) = runtime().lock() {
                held.fail(&attempt, Some(error.clone()));
            }
            return Err(error);
        }
    };
    owner.ensure_current()?;
    let latest = load_settings();
    let latest_identity =
        MachineIdentity::load().map_err(|_| "This device's connection key is unavailable.")?;
    if !available(&latest, &attempt.scope)
        || latest_identity
            .as_ref()
            .is_none_or(|key| scope(&owner, key, &latest) != attempt.scope)
    {
        if let Ok(mut held) = runtime().lock() {
            held.fail(&attempt, None);
        }
        return Ok(None);
    }
    // Installation and stop share this lock. A stop during a slow mint cannot
    // resurrect the old lifetime, even when the next login uses the same key.
    let owned = {
        let mut held = runtime()
            .lock()
            .map_err(|_| "Remote connection state is unavailable.")?;
        if !held.current_attempt(&attempt) {
            return Ok(None);
        }
        let socket = TunnelSession::spawn(&settings.tunnel_endpoint, &identity, &token);
        let live = held
            .install(&attempt, socket.clone())
            .ok_or("The remote connection changed. Connect again.")?;
        held.update_attempt(&attempt, |state| {
            state.error = None;
            state.registered = true;
        });
        OwnedTunnel {
            live,
            owner: owner.clone(),
        }
    };
    // Weak socket reference: the renewal callback must not retain its own
    // socket forever, or keep an old tenant alive after retirement.
    let weak = Arc::downgrade(&owned.live.socket);
    let renewal_attempt = attempt.clone();
    let renewal_owner = owner.clone();
    owned.live.socket.set_renew(Box::new(move || {
        let socket = weak.upgrade().ok_or("The remote connection ended.")?;
        let owned = OwnedTunnel {
            live: Live {
                attempt: renewal_attempt.clone(),
                socket,
            },
            owner: renewal_owner.clone(),
        };
        owned.ensure_current()?;
        match with_snapshot(Some(renewal_owner.clone()), || tunnel_hello_token(true)) {
            Ok((token, _)) => {
                owned.set_token(&token)?;
                Ok(token)
            }
            Err(error) => {
                owned.update(|state| state.error = Some(error.clone()))?;
                Err(error)
            }
        }
    }));

    if let Some(ttl) = ttl {
        let refresh = owned.clone();
        thread::spawn(move || refresh_loop(refresh, ttl));
    }
    let inbound_owned = owned.clone();
    thread::spawn(move || {
        let Some(inbound) = inbound_owned.live.socket.take_inbound() else {
            return;
        };
        while inbound_owned.ensure_current().is_ok() {
            let channel = match inbound.recv() {
                Ok(channel) => channel,
                Err(_) => break,
            };
            if inbound_owned.ensure_current().is_err() {
                break;
            }
            let transport = tokenstat_remote::tunnel::ChannelTransport::from_inbound(
                inbound_owned.live.socket.clone(),
                channel,
            );
            if let Some(team) = transport.team_authorization() {
                crate::teams::accept_channel(
                    transport,
                    team,
                    owner.clone(),
                    MachineIdentity::from_secret(identity.secret_bytes()),
                    Arc::clone(&session),
                );
                continue;
            }
            if !load_settings().tunnel {
                drop(transport);
                continue;
            }
            let accepted = with_snapshot(Some(owner.clone()), || {
                let connection =
                    tokenstat_remote::handshake_responder(Box::new(transport), &identity)
                        .map_err(|error| error.to_string())?;
                inbound_owned.ensure_current()?;
                if !load_settings().tunnel {
                    return Err("Personal remote reach is off.".into());
                }
                authorize_with(connection, "tunnel", Some(&account_peer_label)).map_err(|refused| {
                    report(&refused);
                    "This machine has not approved the connection.".into()
                })
            });
            match accepted {
                Ok(connection)
                    if load_settings().tunnel && inbound_owned.ensure_current().is_ok() =>
                {
                    let _ = inbound_owned.update(|state| {
                        state.connected = true;
                        state.error = None;
                    });
                    let peer_session = Arc::clone(&session);
                    thread::spawn(move || serve_peer(connection, &peer_session, Route::Relay));
                }
                Ok(_) => break,
                Err(error) => eprintln!("remote: inbound tunnel connection refused: {error}"),
            }
        }
        inbound_owned.finish();
    });
    owned.ensure_current()?;
    Ok(Some(owned))
}

fn refresh_loop(owned: OwnedTunnel, initial_ttl: u64) {
    let mut ttl = initial_ttl.max(300);
    let mut retry = None;
    loop {
        let sleep = retry.unwrap_or((ttl / 2).max(120));
        let wake = (jiff::Timestamp::now() + Duration::from_secs(sleep)).as_millisecond();
        while jiff::Timestamp::now().as_millisecond() < wake {
            if runtime()
                .lock()
                .ok()
                .and_then(|mut held| held.with_live(&owned.live, |_, _| ()))
                .is_none()
            {
                return;
            }
            thread::sleep(Duration::from_secs(1));
        }
        if owned.ensure_current().is_err() {
            return;
        }
        match with_snapshot(Some(owned.owner.clone()), || tunnel_hello_token(true)) {
            Ok((token, expires)) => {
                if owned.set_token(&token).is_err() {
                    return;
                }
                ttl = expires.unwrap_or(ttl).max(300);
                retry = None;
            }
            Err(error) => {
                if owned
                    .update(|state| {
                        state.error = Some(format!("tunnel credential renewal failed: {error}"))
                    })
                    .is_err()
                {
                    return;
                }
                retry = Some(next_retry(retry));
            }
        }
    }
}
