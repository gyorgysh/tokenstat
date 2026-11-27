// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use super::{
    DirectMapping, direct_bound, direct_generation, direct_mapping, direct_running,
    local_ipv6_addresses, preferred_route_ipv4, usable_direct_ipv4, usable_public_address,
};

const LEASE_SECS: u32 = 1_800;
const RENEW_AFTER: Duration = Duration::from_secs(600);
const ROUTE_CHECK: Duration = Duration::from_secs(30);
const FIRST_RETRY: Duration = Duration::from_secs(30);
const MAX_RETRY: Duration = Duration::from_secs(600);
const DESCRIPTION: &str = "tokenstat direct connection";
const PCP_PORT: u16 = 5351;
const MAX_PINHOLES: usize = 2;

/// Set once a router refused to map anything but the same port number while
/// another host held it. The listener then binds a free port instead of 7878
/// for the rest of this process, so it does not walk into the same refusal.
pub(super) fn avoid_default_port() -> &'static AtomicBool {
    static AVOID: AtomicBool = AtomicBool::new(false);
    &AVOID
}

pub(super) fn start(generation: usize, port: u16) {
    if let Err(error) = std::thread::Builder::new()
        .name("direct-mapping".into())
        .spawn(move || supervise(generation, port))
    {
        eprintln!("remote: could not start direct mapping: {error}");
    }
}

/// A network change was reported. Check the route and retry a failed mapping
/// now instead of at the end of the backoff.
pub(super) fn nudge() {
    let wake = wake();
    *wake.pending.lock().unwrap_or_else(|e| e.into_inner()) = true;
    wake.signal.notify_all();
}

struct Wake {
    pending: Mutex<bool>,
    signal: Condvar,
}

fn wake() -> &'static Wake {
    static WAKE: OnceLock<Wake> = OnceLock::new();
    WAKE.get_or_init(|| Wake {
        pending: Mutex::new(false),
        signal: Condvar::new(),
    })
}

enum Waited {
    Stopped,
    Nudged,
    Elapsed,
}

fn current(generation: usize) -> bool {
    direct_generation().load(Ordering::Acquire) == generation
        && direct_running().load(Ordering::Acquire)
}

fn wait(generation: usize, duration: Duration) -> Waited {
    let deadline = Instant::now() + duration;
    let wake = wake();
    let mut pending = wake.pending.lock().unwrap_or_else(|e| e.into_inner());
    loop {
        if !current(generation) {
            return Waited::Stopped;
        }
        if *pending {
            *pending = false;
            return Waited::Nudged;
        }
        let Some(left) = deadline.checked_duration_since(Instant::now()) else {
            return Waited::Elapsed;
        };

        pending = wake
            .signal
            .wait_timeout(pending, left.min(Duration::from_secs(1)))
            .unwrap_or_else(|e| e.into_inner())
            .0;
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Route {
    gateway: Option<Ipv4Addr>,
    local: Ipv4Addr,
}

fn route() -> Option<Route> {
    let gateway = default_gateway();
    let local = gateway
        .and_then(local_toward)
        .or_else(preferred_route_ipv4)?;
    usable_direct_ipv4(local).then_some(Route { gateway, local })
}

fn local_toward(gateway: Ipv4Addr) -> Option<Ipv4Addr> {
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).ok()?;
    socket.connect((gateway, PCP_PORT)).ok()?;
    match socket.local_addr().ok()?.ip() {
        IpAddr::V4(address) => Some(address),
        IpAddr::V6(_) => None,
    }
}

enum Method {
    Pcp { nonce: [u8; 12] },
    NatPmp,
    Upnp(Box<igd_next::Gateway>),
}

struct Lease {
    method: Method,
    route: Route,
    port: u16,
    external: SocketAddr,
    renew_after: Duration,
}

enum Failure {
    SamePortTaken,
    Unavailable,
}

struct Pinhole {
    gateway: Box<igd_next::Gateway>,
    id: u16,
    port: u16,
}

fn listening6() -> u16 {
    super::direct_port6().load(Ordering::Acquire) as u16
}

fn supervise(generation: usize, port: u16) {
    let mut lease: Option<Lease> = None;
    let mut pinholes: Vec<Pinhole> = Vec::new();
    let mut seen: Option<Route> = None;
    let mut backoff = FIRST_RETRY;
    let mut retry_at = Instant::now();
    let mut renew_at = Instant::now();
    let mut checked_at: Option<Instant> = None;
    let mut rebind = false;

    while current(generation) {
        let now = Instant::now();
        let port6 = listening6();
        if pinholes.iter().any(|pinhole| pinhole.port != port6) {
            close_pinholes(&mut pinholes);
        }
        if checked_at.is_none_or(|at| now.duration_since(at) >= ROUTE_CHECK) {
            checked_at = Some(now);
            let fresh = route();
            if fresh != seen {
                if let Some(old) = lease.take() {
                    release(&old);
                    publish(generation, None);
                }
                close_pinholes(&mut pinholes);
                seen = fresh;
                retry_at = now;
                backoff = FIRST_RETRY;
            }
        }

        if lease.is_none() && now >= retry_at {
            match seen.map(|route| acquire(route, port)) {
                Some(Ok(acquired)) => {
                    publish(generation, Some(acquired.external));
                    renew_at = Instant::now() + acquired.renew_after;
                    backoff = FIRST_RETRY;
                    lease = Some(acquired);
                }
                Some(Err(Failure::SamePortTaken)) if port == tokenstat_remote::DEFAULT_PORT => {
                    rebind = true;
                    break;
                }
                _ => {
                    retry_at = Instant::now() + backoff;
                    backoff = (backoff * 2).min(MAX_RETRY);
                }
            }
            if pinholes.is_empty() {
                pinholes = open_pinholes(seen, lease.as_ref());
            }
        }

        if let Some(held) = lease.as_mut()
            && Instant::now() >= renew_at
        {
            if renew(held) {
                publish(generation, Some(held.external));
                renew_at = Instant::now() + held.renew_after;
            } else {
                release(held);
                lease = None;
                publish(generation, None);
                retry_at = Instant::now();
            }
            let port6 = listening6();
            pinholes.retain(|pinhole| {
                if pinhole.port != port6 {
                    let _ = pinhole.gateway.remove_pinhole(pinhole.id);
                    return false;
                }
                pinhole
                    .gateway
                    .update_pinhole(pinhole.id, LEASE_SECS)
                    .is_ok()
            });
            if pinholes.is_empty() {
                pinholes = open_pinholes(seen, lease.as_ref());
            }
        }

        let mut next = ROUTE_CHECK;
        if lease.is_none() {
            next = next.min(retry_at.saturating_duration_since(Instant::now()));
        } else {
            next = next.min(renew_at.saturating_duration_since(Instant::now()));
        }
        match wait(generation, next.max(Duration::from_millis(100))) {
            Waited::Stopped => break,
            Waited::Nudged => {
                checked_at = None;
                if lease.is_none() {
                    retry_at = Instant::now();
                    backoff = FIRST_RETRY;
                }
            }
            Waited::Elapsed => {}
        }
    }

    close_pinholes(&mut pinholes);
    let held = lease.map(|lease| (lease.external, lease));
    if let Ok(mut mapping) = direct_mapping().lock()
        && mapping
            .as_ref()
            .is_some_and(|mapping| mapping.generation == generation)
    {
        *mapping = None;
    }
    if rebind {
        restart_listener();
    }
    let Some((external, lease)) = held else {
        return;
    };

    if direct_generation().load(Ordering::Acquire) != generation {
        std::thread::sleep(Duration::from_secs(3));
    }
    let reused = direct_mapping()
        .lock()
        .ok()
        .and_then(|mapping| mapping.clone())
        .is_some_and(|mapping| mapping.generation != generation && mapping.address == external);
    if !reused {
        release(&lease);
    }
}

fn publish(generation: usize, address: Option<SocketAddr>) {
    if let Ok(mut mapping) = direct_mapping().lock() {
        if address.is_some() && !current(generation) {
            return;
        }
        let ours = mapping
            .as_ref()
            .is_none_or(|mapping| mapping.generation == generation);
        if ours {
            *mapping = address.map(|address| DirectMapping {
                generation,
                address,
            });
        }
    }
}

fn restart_listener() {
    if avoid_default_port().swap(true, Ordering::AcqRel) {
        return;
    }
    let _ = std::thread::Builder::new()
        .name("direct-rebind".into())
        .spawn(|| {
            super::stop_direct();

            for _ in 0..100 {
                if !direct_bound().load(Ordering::Acquire) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            std::thread::sleep(Duration::from_millis(200));
            super::start_direct_if_enabled();
        });
}

fn acquire(route: Route, port: u16) -> Result<Lease, Failure> {
    if let Some(gateway) = route.gateway {
        let nonce = pcp_nonce();
        match pcp_map(gateway, route.local, port, port, LEASE_SECS, &nonce) {
            Ok((external, lifetime)) if lifetime > 0 => {
                return Ok(Lease {
                    method: Method::Pcp { nonce },
                    route,
                    port,
                    external,
                    renew_after: renew_interval(lifetime),
                });
            }
            Ok(_) => {}
            Err(PcpError::OldVersion) => {
                if let Some((external, lifetime)) =
                    natpmp_map(gateway, route.local, port, port, LEASE_SECS)
                    && lifetime > 0
                {
                    return Ok(Lease {
                        method: Method::NatPmp,
                        route,
                        port,
                        external,
                        renew_after: renew_interval(lifetime),
                    });
                }
            }
            Err(PcpError::NoAnswer | PcpError::Refused) => {}
        }
    }
    upnp_map(route, port)
}

fn renew_interval(lifetime: u32) -> Duration {
    RENEW_AFTER
        .min(Duration::from_secs(u64::from(lifetime) / 2))
        .max(Duration::from_secs(30))
}

fn renew(lease: &mut Lease) -> bool {
    let Some(gateway) = lease.route.gateway else {
        if let Method::Upnp(gateway) = &lease.method {
            let gateway = gateway.clone();
            return upnp_renew(&gateway, lease);
        }
        return false;
    };
    let suggested = lease.external.port();
    let renewed = match &lease.method {
        Method::Pcp { nonce } => pcp_map(
            gateway,
            lease.route.local,
            lease.port,
            suggested,
            LEASE_SECS,
            nonce,
        )
        .ok(),
        Method::NatPmp => natpmp_map(
            gateway,
            lease.route.local,
            lease.port,
            suggested,
            LEASE_SECS,
        ),
        Method::Upnp(gateway) => {
            let gateway = gateway.clone();
            return upnp_renew(&gateway, lease);
        }
    };
    match renewed {
        Some((external, lifetime)) => {
            lease.external = external;
            lease.renew_after = renew_interval(lifetime);
            true
        }
        None => false,
    }
}

fn upnp_renew(gateway: &igd_next::Gateway, lease: &mut Lease) -> bool {
    let local = SocketAddr::from((lease.route.local, lease.port));
    let ok = gateway
        .add_port(
            igd_next::PortMappingProtocol::TCP,
            lease.external.port(),
            local,
            LEASE_SECS,
            DESCRIPTION,
        )
        .is_ok();
    if ok {
        lease.renew_after = renew_interval(LEASE_SECS);
    }
    ok
}

fn release(lease: &Lease) {
    match (&lease.method, lease.route.gateway) {
        (Method::Pcp { nonce }, Some(gateway)) => {
            let _ = pcp_map(gateway, lease.route.local, lease.port, 0, 0, nonce);
        }
        (Method::NatPmp, Some(gateway)) => {
            let _ = natpmp_map(gateway, lease.route.local, lease.port, 0, 0);
        }
        (Method::Upnp(gateway), _) => {
            let _ = gateway.remove_port(igd_next::PortMappingProtocol::TCP, lease.external.port());
        }
        _ => {}
    }
}

fn upnp_gateway(local: Ipv4Addr) -> Option<igd_next::Gateway> {
    let mut options = igd_next::SearchOptions::default();
    options.bind_addr = SocketAddr::from((local, 0));
    options.timeout = Some(Duration::from_secs(3));
    options.single_search_timeout = Some(Duration::from_secs(3));
    igd_next::search_gateway(options).ok()
}

fn upnp_map(route: Route, port: u16) -> Result<Lease, Failure> {
    let gateway = upnp_gateway(route.local).ok_or(Failure::Unavailable)?;
    let local = SocketAddr::from((route.local, port));
    match gateway.get_any_address(
        igd_next::PortMappingProtocol::TCP,
        local,
        LEASE_SECS,
        DESCRIPTION,
    ) {
        Ok(external) if usable_public_address(external) => Ok(Lease {
            method: Method::Upnp(Box::new(gateway)),
            route,
            port,
            external,
            renew_after: renew_interval(LEASE_SECS),
        }),
        Ok(external) => {
            let _ = gateway.remove_port(igd_next::PortMappingProtocol::TCP, external.port());
            Err(Failure::Unavailable)
        }
        Err(igd_next::AddAnyPortError::ExternalPortInUse) => Err(Failure::SamePortTaken),
        Err(_) => Err(Failure::Unavailable),
    }
}

fn open_pinholes(route: Option<Route>, lease: Option<&Lease>) -> Vec<Pinhole> {
    let port = listening6();
    if port == 0 {
        return Vec::new();
    }
    let addresses = local_ipv6_addresses();
    if addresses.is_empty() {
        return Vec::new();
    }
    let gateway = match lease.map(|lease| &lease.method) {
        Some(Method::Upnp(gateway)) => Some((**gateway).clone()),
        _ => route.and_then(|route| upnp_gateway(route.local)),
    };
    let Some(gateway) = gateway else {
        return Vec::new();
    };
    addresses
        .into_iter()
        .take(MAX_PINHOLES)
        .filter_map(|address| {
            gateway
                .add_pinhole(
                    igd_next::PortMappingProtocol::TCP,
                    SocketAddrV6::new(address, port, 0, 0),
                    LEASE_SECS,
                )
                .ok()
                .map(|id| Pinhole {
                    gateway: Box::new(gateway.clone()),
                    id,
                    port,
                })
        })
        .collect()
}

fn close_pinholes(pinholes: &mut Vec<Pinhole>) {
    for pinhole in pinholes.drain(..) {
        let _ = pinhole.gateway.remove_pinhole(pinhole.id);
    }
}

fn pcp_nonce() -> [u8; 12] {
    static NONCE: OnceLock<[u8; 12]> = OnceLock::new();
    *NONCE.get_or_init(|| {
        let mut nonce = [0u8; 12];
        if getrandom::fill(&mut nonce).is_err() {
            let seed = std::process::id().to_be_bytes();
            nonce[..4].copy_from_slice(&seed);
        }
        nonce
    })
}

#[derive(Debug, PartialEq, Eq)]
enum PcpError {
    NoAnswer,
    OldVersion,
    Refused,
}

fn pcp_map(
    gateway: Ipv4Addr,
    local: Ipv4Addr,
    port: u16,
    suggested: u16,
    lifetime: u32,
    nonce: &[u8; 12],
) -> Result<(SocketAddr, u32), PcpError> {
    let request = pcp_map_request(local, port, suggested, lifetime, nonce);
    match exchange(gateway, local, &request, |reply| {
        parse_pcp_reply(reply, nonce, port)
    }) {
        Some(PcpReply::Mapped { external, lifetime }) => {
            if lifetime == 0 || usable_public_address(external) {
                Ok((external, lifetime))
            } else {
                Err(PcpError::Refused)
            }
        }
        Some(PcpReply::OldVersion) => Err(PcpError::OldVersion),
        Some(PcpReply::Refused) => Err(PcpError::Refused),
        None => Err(PcpError::NoAnswer),
    }
}

fn natpmp_map(
    gateway: Ipv4Addr,
    local: Ipv4Addr,
    port: u16,
    suggested: u16,
    lifetime: u32,
) -> Option<(SocketAddr, u32)> {
    let address = if lifetime == 0 {
        Ipv4Addr::UNSPECIFIED
    } else {
        exchange(gateway, local, &[0, 0], parse_natpmp_address)??
    };
    let request = natpmp_map_request(port, suggested, lifetime);
    let (external_port, granted) = exchange(gateway, local, &request, |reply| {
        parse_natpmp_map(reply, port)
    })??;
    let external = SocketAddr::from((address, external_port));
    (lifetime == 0 || usable_public_address(external)).then_some((external, granted))
}

fn exchange<T>(
    gateway: Ipv4Addr,
    local: Ipv4Addr,
    request: &[u8],
    accept: impl Fn(&[u8]) -> Option<T>,
) -> Option<T> {
    let socket = UdpSocket::bind((local, 0)).ok()?;
    socket.connect(SocketAddrV4::new(gateway, PCP_PORT)).ok()?;
    let mut buffer = [0u8; 1100];
    for wait in [250u64, 500, 1_000] {
        socket.send(request).ok()?;
        let deadline = Instant::now() + Duration::from_millis(wait);
        while let Some(left) = deadline.checked_duration_since(Instant::now()) {
            if socket
                .set_read_timeout(Some(left.max(Duration::from_millis(1))))
                .is_err()
            {
                return None;
            }
            match socket.recv(&mut buffer) {
                Ok(read) => {
                    if let Some(answer) = accept(&buffer[..read]) {
                        return Some(answer);
                    }
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    break;
                }

                Err(_) => return None,
            }
        }
    }
    None
}

fn pcp_map_request(
    local: Ipv4Addr,
    port: u16,
    suggested: u16,
    lifetime: u32,
    nonce: &[u8; 12],
) -> [u8; 60] {
    let mut request = [0u8; 60];
    request[0] = 2;
    request[1] = 1;
    request[4..8].copy_from_slice(&lifetime.to_be_bytes());
    request[8..24].copy_from_slice(&local.to_ipv6_mapped().octets());
    request[24..36].copy_from_slice(nonce);
    request[36] = 6;
    request[40..42].copy_from_slice(&port.to_be_bytes());
    request[42..44].copy_from_slice(&suggested.to_be_bytes());
    request[44..60].copy_from_slice(&Ipv4Addr::UNSPECIFIED.to_ipv6_mapped().octets());
    request
}

#[derive(Debug, PartialEq, Eq)]
enum PcpReply {
    Mapped { external: SocketAddr, lifetime: u32 },
    OldVersion,
    Refused,
}

fn parse_pcp_reply(reply: &[u8], nonce: &[u8; 12], port: u16) -> Option<PcpReply> {
    if reply.len() >= 4 && reply[0] == 0 && reply[1] & 0x80 != 0 {
        return Some(PcpReply::OldVersion);
    }
    if reply.len() < 60 || reply[0] != 2 || reply[1] != 0x81 {
        return None;
    }
    if &reply[24..36] != nonce
        || reply[36] != 6
        || u16::from_be_bytes([reply[40], reply[41]]) != port
    {
        return None;
    }
    if reply[3] != 0 {
        return Some(PcpReply::Refused);
    }
    let lifetime = u32::from_be_bytes([reply[4], reply[5], reply[6], reply[7]]);
    let external_port = u16::from_be_bytes([reply[42], reply[43]]);
    let mut octets = [0u8; 16];
    octets.copy_from_slice(&reply[44..60]);
    let external = Ipv6Addr::from(octets).to_ipv4_mapped()?;
    Some(PcpReply::Mapped {
        external: SocketAddr::from((external, external_port)),
        lifetime,
    })
}

fn natpmp_map_request(port: u16, suggested: u16, lifetime: u32) -> [u8; 12] {
    let mut request = [0u8; 12];
    request[1] = 2;
    request[4..6].copy_from_slice(&port.to_be_bytes());
    request[6..8].copy_from_slice(&suggested.to_be_bytes());
    request[8..12].copy_from_slice(&lifetime.to_be_bytes());
    request
}

fn parse_natpmp_map(reply: &[u8], port: u16) -> Option<Option<(u16, u32)>> {
    if reply.len() < 16 || reply[0] != 0 || reply[1] != 130 {
        return None;
    }
    if u16::from_be_bytes([reply[8], reply[9]]) != port {
        return None;
    }
    if u16::from_be_bytes([reply[2], reply[3]]) != 0 {
        return Some(None);
    }
    let external = u16::from_be_bytes([reply[10], reply[11]]);
    let lifetime = u32::from_be_bytes([reply[12], reply[13], reply[14], reply[15]]);
    Some(Some((external, lifetime)))
}

fn parse_natpmp_address(reply: &[u8]) -> Option<Option<Ipv4Addr>> {
    if reply.len() < 12 || reply[0] != 0 || reply[1] != 128 {
        return None;
    }
    if u16::from_be_bytes([reply[2], reply[3]]) != 0 {
        return Some(None);
    }
    Some(Some(Ipv4Addr::new(
        reply[8], reply[9], reply[10], reply[11],
    )))
}

#[cfg_attr(windows, allow(dead_code))]
fn tunnel_interface(name: &str) -> bool {
    const PREFIXES: [&str; 10] = [
        "utun",
        "ipsec",
        "tun",
        "tap",
        "wg",
        "ppp",
        "tailscale",
        "zt",
        "gif",
        "stf",
    ];
    PREFIXES.iter().any(|prefix| name.starts_with(prefix))
}

#[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
fn default_gateway() -> Option<Ipv4Addr> {
    let output = std::process::Command::new("/usr/sbin/netstat")
        .args(["-rn", "-f", "inet"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    parse_netstat_default(&String::from_utf8_lossy(&output.stdout))
}

#[cfg(target_os = "linux")]
fn default_gateway() -> Option<Ipv4Addr> {
    parse_proc_route(&std::fs::read_to_string("/proc/net/route").ok()?)
}

#[cfg(windows)]
fn default_gateway() -> Option<Ipv4Addr> {
    use std::os::windows::process::CommandExt;
    let output = std::process::Command::new("route")
        .args(["print", "-4", "0.0.0.0"])
        .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    parse_route_print(&String::from_utf8_lossy(&output.stdout))
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "freebsd",
    target_os = "linux",
    windows
)))]
fn default_gateway() -> Option<Ipv4Addr> {
    None
}

#[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd", test))]
fn parse_netstat_default(text: &str) -> Option<Ipv4Addr> {
    text.lines().find_map(|line| {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 4 || fields[0] != "default" {
            return None;
        }
        let gateway: Ipv4Addr = fields[1].parse().ok()?;
        (!tunnel_interface(fields[3])).then_some(gateway)
    })
}

#[cfg(any(target_os = "linux", test))]
fn parse_proc_route(text: &str) -> Option<Ipv4Addr> {
    text.lines()
        .skip(1)
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            if fields.len() < 7 || fields[1] != "00000000" || tunnel_interface(fields[0]) {
                return None;
            }
            let raw = u32::from_str_radix(fields[2], 16).ok()?;
            let gateway = Ipv4Addr::from(raw.to_le_bytes());
            let metric: u32 = fields[6].parse().ok()?;
            (!gateway.is_unspecified()).then_some((metric, gateway))
        })
        .min_by_key(|(metric, _)| *metric)
        .map(|(_, gateway)| gateway)
}

#[cfg(any(windows, test))]
fn parse_route_print(text: &str) -> Option<Ipv4Addr> {
    text.lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            if fields.len() < 5 || fields[0] != "0.0.0.0" || fields[1] != "0.0.0.0" {
                return None;
            }
            let gateway: Ipv4Addr = fields[2].parse().ok()?;
            let metric: u32 = fields[4].parse().ok()?;
            Some((metric, gateway))
        })
        .min_by_key(|(metric, _)| *metric)
        .map(|(_, gateway)| gateway)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pcp_request_and_reply_round_trip() {
        let nonce = [7u8; 12];
        let request = pcp_map_request(Ipv4Addr::new(192, 168, 1, 20), 7878, 7878, 1800, &nonce);
        assert_eq!(request[0], 2);
        assert_eq!(request[1], 1);
        assert_eq!(
            &request[8..24],
            &Ipv4Addr::new(192, 168, 1, 20).to_ipv6_mapped().octets()
        );
        assert_eq!(u16::from_be_bytes([request[40], request[41]]), 7878);

        let mut reply = request;
        reply[1] = 0x81;
        reply[3] = 0;
        reply[42..44].copy_from_slice(&40_001u16.to_be_bytes());
        reply[44..60].copy_from_slice(&Ipv4Addr::new(203, 0, 113, 9).to_ipv6_mapped().octets());
        assert_eq!(
            parse_pcp_reply(&reply, &nonce, 7878),
            Some(PcpReply::Mapped {
                external: "203.0.113.9:40001".parse().unwrap(),
                lifetime: 1800,
            })
        );
        assert_eq!(parse_pcp_reply(&reply, &[0u8; 12], 7878), None);

        reply[4..8].copy_from_slice(&0u32.to_be_bytes());
        reply[3] = 0;
        assert_eq!(
            parse_pcp_reply(&reply, &nonce, 7878),
            Some(PcpReply::Mapped {
                external: "203.0.113.9:40001".parse().unwrap(),
                lifetime: 0,
            })
        );
        reply[4..8].copy_from_slice(&1800u32.to_be_bytes());
        reply[3] = 2;
        assert_eq!(
            parse_pcp_reply(&reply, &nonce, 7878),
            Some(PcpReply::Refused)
        );
    }

    #[test]
    fn a_natpmp_router_answering_pcp_is_recognised() {
        let reply = [0u8, 0x81, 0, 1, 0, 0, 0, 0];
        assert_eq!(
            parse_pcp_reply(&reply, &[0; 12], 7878),
            Some(PcpReply::OldVersion)
        );
    }

    #[test]
    fn natpmp_replies_parse() {
        let request = natpmp_map_request(7878, 7878, 1800);
        assert_eq!(request[..4], [0, 2, 0, 0]);
        let mut reply = [0u8; 16];
        reply[1] = 130;
        reply[8..10].copy_from_slice(&7878u16.to_be_bytes());
        reply[10..12].copy_from_slice(&50_000u16.to_be_bytes());
        reply[12..16].copy_from_slice(&1800u32.to_be_bytes());
        assert_eq!(parse_natpmp_map(&reply, 7878), Some(Some((50_000, 1800))));
        assert_eq!(parse_natpmp_map(&reply, 9999), None);
        reply[3] = 3;
        assert_eq!(parse_natpmp_map(&reply, 7878), Some(None));

        let address = [0u8, 128, 0, 0, 0, 0, 0, 1, 198, 51, 100, 7];
        assert_eq!(
            parse_natpmp_address(&address),
            Some(Some(Ipv4Addr::new(198, 51, 100, 7)))
        );
    }

    #[test]
    fn default_gateway_skips_vpn_routes() {
        let netstat = "Routing tables\n\nInternet:\nDestination        Gateway            Flags               Netif Expire\ndefault            link#22            UCSIg               utun4\ndefault            10.8.0.1           UGScIg              utun3\ndefault            192.168.1.1        UGScg                 en0\n";
        assert_eq!(
            parse_netstat_default(netstat),
            Some(Ipv4Addr::new(192, 168, 1, 1))
        );

        let proc = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\nwg0\t00000000\t0100080A\t0003\t0\t0\t0\t00000000\neth0\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\n";
        assert_eq!(parse_proc_route(proc), Some(Ipv4Addr::new(192, 168, 1, 1)));

        let windows = "Active Routes:\nNetwork Destination        Netmask          Gateway       Interface  Metric\n          0.0.0.0          0.0.0.0         On-link      10.8.0.2      5\n          0.0.0.0          0.0.0.0      192.168.1.1   192.168.1.20     25\n";
        assert_eq!(
            parse_route_print(windows),
            Some(Ipv4Addr::new(192, 168, 1, 1))
        );
    }

    #[test]
    fn renewal_runs_well_inside_the_lease() {
        assert_eq!(renew_interval(1800), RENEW_AFTER);
        assert_eq!(renew_interval(120), Duration::from_secs(60));
        assert_eq!(renew_interval(10), Duration::from_secs(30));
    }
}
