// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! Typed client for tokenstat.ai's ciphertext-only SSH vault service.

use std::sync::Arc;
use std::time::Duration;

use reqwest::Method;
use reqwest::blocking::Client;
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE, HeaderValue};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use zeroize::Zeroizing;

use crate::keychain;
use crate::profile::{self, ProfileError};

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteVault {
    pub schema_version: u32,
    pub revision: u64,
    pub ciphertext: String,
    pub nonce: String,
    pub recovery_salt: String,
    pub recovery_wrap: String,
    pub device_wrap: Option<String>,
    pub wrap_version: Option<u32>,
    /// Absent on a vault made before password unlock existed.
    pub password_salt: Option<String>,
    pub password_wrap: Option<String>,
    /// The KDF the password wrap was made with, written down so a later change
    /// of cost can be read rather than guessed.
    pub kdf: Option<String>,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateVault<'a> {
    pub schema_version: u32,
    pub ciphertext: &'a str,
    pub nonce: &'a str,
    pub recovery_salt: &'a str,
    pub recovery_wrap: &'a str,
    pub device_wrap: &'a str,
    pub wrap_version: u32,
    pub password_salt: &'a str,
    pub password_wrap: &'a str,
    pub kdf: &'a str,
}

/// Compare-and-swap replacement of all encryption material, with old device
/// enrollments invalidated in the same server transaction.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RotateVault<'a> {
    pub expected_revision: u64,
    #[serde(flatten)]
    pub vault: CreateVault<'a>,
}

/// A new password wrap for a vault that already exists.
///
/// The snapshot is not part of this. Changing a password changes the wrap
/// around the key and nothing about the records, so it is not a new revision
/// and cannot collide with a device writing one.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RewrapVault<'a> {
    pub password_salt: &'a str,
    pub password_wrap: &'a str,
    pub kdf: &'a str,
    /// Set only on a recovery reset, which retires the code it just spent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recovery_salt: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recovery_wrap: Option<&'a str>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateVault<'a> {
    pub expected_revision: u64,
    pub schema_version: u32,
    pub ciphertext: &'a str,
    pub nonce: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recovery_salt: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recovery_wrap: Option<&'a str>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Revision {
    pub revision: u64,
    #[serde(default)]
    pub updated_at: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnrollmentRequest {
    pub id: String,
    pub machine_id: String,
    pub public_identity: String,
    pub nonce: String,
    pub expires_at: String,
}

#[derive(Serialize)]
struct EnrollmentNonce<'a> {
    nonce: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EnrollmentApproval<'a> {
    request_id: &'a str,
    device_wrap: &'a str,
    wrap_version: u32,
}

#[derive(Deserialize)]
pub struct EnrollmentResult {
    pub enrolled: bool,
}

#[derive(Deserialize)]
pub struct EnrollmentRequests {
    pub requests: Vec<EnrollmentRequest>,
}

#[derive(Debug, Deserialize)]
struct ErrorBody {
    #[serde(default)]
    error: String,
    #[serde(default)]
    message: String,
    #[serde(default)]
    revision: Option<u64>,
}

#[derive(Debug, thiserror::Error)]
pub enum VaultError {
    #[error(transparent)]
    Profile(#[from] ProfileError),
    #[error(transparent)]
    Http(#[from] reqwest::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("not signed in")]
    NotSignedIn,
    #[error("this device is not enrolled in the SSH vault")]
    NotEnrolled,
    #[error("the signed-in account changed; retry from the current account")]
    AccountChanged,
    /// The account does not know this machine, so nothing it holds can be
    /// reached from here. Recoverable without the user doing anything: the
    /// machine record is published at login and can be published again.
    ///
    /// Also covers a registered profile whose public identity is missing.
    /// Republish the identity, not only the display name, before retrying.
    #[error("{0}")]
    MachineNotRegistered(String),
    #[error("a vault already exists")]
    AlreadyExists,
    #[error("no SSH vault exists")]
    NotFound,
    #[error("vault revision conflict (server revision {0})")]
    Conflict(u64),
    #[error("{0}")]
    Server(String),
}

#[derive(Clone)]
struct Authentication {
    host: String,
    token: Zeroizing<String>,
}

fn auth() -> Result<Authentication, VaultError> {
    let host = profile::resolve_api_host(None)?;
    let token = keychain::load_token(&host)
        .map_err(ProfileError::from)?
        .ok_or(VaultError::NotSignedIn)?;
    Ok(Authentication {
        host,
        token: Zeroizing::new(token),
    })
}

struct VaultRequest {
    method: Method,
    url: String,
    authorization: HeaderValue,
    body: Option<Vec<u8>>,
    response_limit: u64,
}

trait VaultWire: Send + Sync {
    fn send(&self, request: VaultRequest) -> Result<(reqwest::StatusCode, Vec<u8>), VaultError>;
}

struct HttpVaultWire(Client);
impl VaultWire for HttpVaultWire {
    fn send(&self, request: VaultRequest) -> Result<(reqwest::StatusCode, Vec<u8>), VaultError> {
        let mut builder = self
            .0
            .request(request.method, request.url)
            .header(AUTHORIZATION, request.authorization);
        if let Some(body) = request.body {
            builder = builder.header(CONTENT_TYPE, "application/json").body(body);
        }
        let response = builder.send()?;
        let status = response.status();
        Ok((status, read_capped(response, request.response_limit)?))
    }
}

/// An operation's immutable origin and bearer. Subsequent reads, writes,
/// registration and plan checks never adopt credentials from another account.
/// Debug is deliberately absent: credentials must not reach logs.
#[derive(Clone)]
pub struct VaultClient {
    authentication: Arc<Authentication>,
    wire: Arc<dyn VaultWire>,
    current: Arc<dyn Fn() -> Result<Authentication, VaultError> + Send + Sync>,
}

impl VaultClient {
    pub fn capture() -> Result<Self, VaultError> {
        let authentication = Arc::new(auth()?);
        let client = Client::builder()
            .timeout(Duration::from_secs(30))
            .connect_timeout(Duration::from_secs(5))
            .user_agent(format!("tokenstat/{}", env!("CARGO_PKG_VERSION")))
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        let made = Self {
            authentication,
            wire: Arc::new(HttpVaultWire(client)),
            current: Arc::new(auth),
        };
        made.ensure_current()?;
        Ok(made)
    }

    /// The embedding host can immediately retire all work from an earlier
    /// login lifetime without waiting for a blocking HTTP call to finish.
    pub fn with_retirement_guard(
        mut self,
        check: impl Fn() -> Result<(), VaultError> + Send + Sync + 'static,
    ) -> Self {
        let current = self.current.clone();
        self.current = Arc::new(move || {
            check()?;
            let authentication = current()?;
            check()?;
            Ok(authentication)
        });
        self
    }

    /// Use before publishing/cache changes as well as before network work.
    pub fn ensure_current(&self) -> Result<(), VaultError> {
        let current = (self.current)()?;
        if current.host != self.authentication.host || current.token != self.authentication.token {
            return Err(VaultError::AccountChanged);
        }
        Ok(())
    }

    fn response(
        &self,
        method: Method,
        path: &str,
        body: Option<Vec<u8>>,
    ) -> Result<Vec<u8>, VaultError> {
        self.ensure_current()?;
        let mut authorization =
            HeaderValue::from_str(&format!("Bearer {}", self.authentication.token.as_str()))
                .map_err(|_| VaultError::NotSignedIn)?;
        authorization.set_sensitive(true);
        let response_limit = if matches!(path, "/api/v1/me" | "/api/v1/machines/me") {
            256 * 1024
        } else {
            32 * 1024 * 1024
        };
        let result = self.wire.send(VaultRequest {
            method,
            url: format!("{}{path}", self.authentication.host),
            authorization,
            body,
            response_limit,
        });
        // Both branches are retired before a caller can cache or act on them.
        self.ensure_current()?;
        let (status, bytes) = result?;
        if bytes.len() as u64 > response_limit {
            return Err(VaultError::Server(
                "vault response exceeded its size limit".into(),
            ));
        }
        if status.is_success() {
            Ok(bytes)
        } else {
            Err(read_error(status, &bytes))
        }
    }

    fn send<T: DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        body: Option<Vec<u8>>,
    ) -> Result<T, VaultError> {
        Ok(serde_json::from_slice(&self.response(method, path, body)?)?)
    }

    pub fn status(&self) -> Result<profile::StatusResult, VaultError> {
        let raw = self.send(Method::GET, "/api/v1/me", None)?;
        Ok(profile::status_from_value(
            self.authentication.host.clone(),
            raw,
        ))
    }

    pub fn register_machine(
        &self,
        machine: &str,
        identity: &str,
        label: &str,
        kind: &str,
    ) -> Result<(), VaultError> {
        let body = serde_json::json!({ "machine": machine, "public_identity": identity, "label": label,
            "kind": if kind == "client" { "client" } else { "host" },
            "platform": tokenstat_identity::platform().pretty() });
        self.response(
            Method::PUT,
            "/api/v1/machines/me",
            Some(serde_json::to_vec(&body)?),
        )?;
        Ok(())
    }

    pub fn publish_machine_identity(&self) -> Result<(), VaultError> {
        self.ensure_current()?;
        let identity = tokenstat_identity::MachineIdentity::load_or_create()
            .map_err(|e| VaultError::Server(e.to_string()))?;
        let machine = crate::config::ensure_machine_id().map_err(ProfileError::from)?;
        self.register_machine(
            &machine,
            &identity.public_key_hex(),
            &tokenstat_identity::machine_label(),
            if cfg!(target_os = "ios") {
                "client"
            } else {
                "host"
            },
        )
    }

    pub fn get(&self) -> Result<RemoteVault, VaultError> {
        self.send(Method::GET, "/api/v1/vault/ssh", None)
    }
    pub fn create(&self, body: &CreateVault<'_>) -> Result<Revision, VaultError> {
        self.send(
            Method::POST,
            "/api/v1/vault/ssh",
            Some(serde_json::to_vec(body)?),
        )
    }
    pub fn update(&self, body: &UpdateVault<'_>) -> Result<Revision, VaultError> {
        self.send(
            Method::PUT,
            "/api/v1/vault/ssh",
            Some(serde_json::to_vec(body)?),
        )
    }
    pub fn rotate(&self, body: &RotateVault<'_>) -> Result<Revision, VaultError> {
        self.send(
            Method::POST,
            "/api/v1/vault/ssh/rotate",
            Some(serde_json::to_vec(body)?),
        )
    }
    pub fn rewrap(&self, body: &RewrapVault<'_>) -> Result<(), VaultError> {
        self.response(
            Method::POST,
            "/api/v1/vault/ssh/rewrap",
            Some(serde_json::to_vec(body)?),
        )?;
        Ok(())
    }
    pub fn remove(&self) -> Result<(), VaultError> {
        match self.response(Method::DELETE, "/api/v1/vault/ssh", None) {
            Ok(_) | Err(VaultError::NotFound) => Ok(()),
            Err(error) => Err(error),
        }
    }
    pub fn request_enrollment(&self, nonce: &str) -> Result<EnrollmentRequest, VaultError> {
        self.send(
            Method::POST,
            "/api/v1/vault/ssh/enrollment-requests",
            Some(serde_json::to_vec(&EnrollmentNonce { nonce })?),
        )
    }
    pub fn approve_enrollment(
        &self,
        machine: &str,
        request_id: &str,
        device_wrap: &str,
        wrap_version: u32,
    ) -> Result<EnrollmentResult, VaultError> {
        self.send(
            Method::PUT,
            &format!("/api/v1/vault/ssh/devices/{machine}"),
            Some(serde_json::to_vec(&EnrollmentApproval {
                request_id,
                device_wrap,
                wrap_version,
            })?),
        )
    }
    pub fn list_enrollments(&self) -> Result<Vec<EnrollmentRequest>, VaultError> {
        Ok(self
            .send::<EnrollmentRequests>(Method::GET, "/api/v1/vault/ssh/enrollment-requests", None)?
            .requests)
    }
}

fn read_error(status: reqwest::StatusCode, bytes: &[u8]) -> VaultError {
    let error: ErrorBody = serde_json::from_slice(bytes).unwrap_or(ErrorBody {
        error: String::new(),
        message: String::from_utf8_lossy(bytes).chars().take(240).collect(),
        revision: None,
    });
    match error.error.as_str() {
        "not_enrolled" => VaultError::NotEnrolled,
        // Typed rather than left as a server sentence, because the host acts
        // on this one: it republishes the machine record and tries again.
        "machine_required" | "machine_not_registered" | "identity_required" => {
            VaultError::MachineNotRegistered(if error.message.is_empty() {
                "this machine is not registered on the account".into()
            } else {
                error.message
            })
        }
        "already_exists" => VaultError::AlreadyExists,
        "not_found" => VaultError::NotFound,
        "revision_conflict" => VaultError::Conflict(error.revision.unwrap_or(0)),
        _ => VaultError::Server(if error.message.is_empty() {
            format!("vault request failed ({status})")
        } else {
            error.message
        }),
    }
}

/// Read a response body with a hard size cap.
///
/// A vault payload can be large, but not unbounded: the server does not get to
/// decide how much memory one answer costs. Reading through the `Read` impl
/// rather than `bytes()` also bounds what is buffered before the cap is known.
fn read_capped(response: reqwest::blocking::Response, maximum: u64) -> Result<Vec<u8>, VaultError> {
    use std::io::Read;
    let mut bytes = Vec::new();
    response.take(maximum + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > maximum {
        return Err(VaultError::Server(format!(
            "vault response exceeded {maximum} bytes"
        )));
    }
    Ok(bytes)
}

// Single-call compatibility entry points. Multi-step owners capture one client.
pub fn get() -> Result<RemoteVault, VaultError> {
    VaultClient::capture()?.get()
}
pub fn create(body: &CreateVault<'_>) -> Result<Revision, VaultError> {
    VaultClient::capture()?.create(body)
}
pub fn update(body: &UpdateVault<'_>) -> Result<Revision, VaultError> {
    VaultClient::capture()?.update(body)
}
pub fn rotate(body: &RotateVault<'_>) -> Result<Revision, VaultError> {
    VaultClient::capture()?.rotate(body)
}
pub fn rewrap(body: &RewrapVault<'_>) -> Result<(), VaultError> {
    VaultClient::capture()?.rewrap(body)
}
pub fn remove() -> Result<(), VaultError> {
    VaultClient::capture()?.remove()
}
pub fn request_enrollment(nonce: &str) -> Result<EnrollmentRequest, VaultError> {
    VaultClient::capture()?.request_enrollment(nonce)
}
pub fn approve_enrollment(
    machine: &str,
    request: &str,
    wrap: &str,
    version: u32,
) -> Result<EnrollmentResult, VaultError> {
    VaultClient::capture()?.approve_enrollment(machine, request, wrap, version)
}
pub fn list_enrollments() -> Result<Vec<EnrollmentRequest>, VaultError> {
    VaultClient::capture()?.list_enrollments()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_public_identity_requests_registration_retry() {
        let error = read_error(reqwest::StatusCode::BAD_REQUEST,
            br#"{"error":"identity_required","message":"Register the device public identity first."}"#);
        assert!(matches!(error, VaultError::MachineNotRegistered(_)));
    }

    #[test]
    fn unrelated_refusals_do_not_request_registration() {
        let error = read_error(
            reqwest::StatusCode::FORBIDDEN,
            br#"{"error":"not_enrolled","message":"Not enrolled."}"#,
        );
        assert!(matches!(error, VaultError::NotEnrolled));
    }

    struct TestWire {
        calls: std::sync::Mutex<Vec<(Method, String, HeaderValue)>>,
        hold:
            std::sync::Mutex<Option<(std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>)>>,
        fail: std::sync::atomic::AtomicBool,
    }
    impl VaultWire for TestWire {
        fn send(
            &self,
            request: VaultRequest,
        ) -> Result<(reqwest::StatusCode, Vec<u8>), VaultError> {
            assert!(request.authorization.is_sensitive());
            if let Some(body) = request.body {
                assert!(serde_json::from_slice::<serde_json::Value>(&body).is_ok());
            }
            self.calls
                .lock()
                .unwrap()
                .push((request.method, request.url, request.authorization));
            if let Some((started, resume)) = self.hold.lock().unwrap().take() {
                started.send(()).unwrap();
                resume.recv_timeout(Duration::from_secs(5)).unwrap();
            }
            if self.fail.load(std::sync::atomic::Ordering::SeqCst) {
                return Err(VaultError::Server("old transport failure".into()));
            }
            Ok((reqwest::StatusCode::OK, br#"{"schemaVersion":4,"revision":1,"ciphertext":"fixture","nonce":"nonce","recoverySalt":"salt","recoveryWrap":"wrap","updatedAt":"now","id":"account-a","handle":"alice","tier":"supporter","machineId":"machine","publicIdentity":"identity","expiresAt":"later","enrolled":true,"requests":[]}"#.to_vec()))
        }
    }
    fn fixture() -> (
        VaultClient,
        Arc<TestWire>,
        Arc<std::sync::Mutex<Authentication>>,
    ) {
        let current = Arc::new(std::sync::Mutex::new(Authentication {
            host: "https://a.example".into(),
            token: Zeroizing::new("dummy-a".into()),
        }));
        let wire = Arc::new(TestWire {
            calls: Default::default(),
            hold: Default::default(),
            fail: Default::default(),
        });
        let read_current = current.clone();
        let client = VaultClient {
            authentication: Arc::new(current.lock().unwrap().clone()),
            wire: wire.clone(),
            current: Arc::new(move || Ok(read_current.lock().unwrap().clone())),
        };
        (client, wire, current)
    }
    fn update_fixture() -> UpdateVault<'static> {
        UpdateVault {
            expected_revision: 1,
            schema_version: 4,
            ciphertext: "ciphertext",
            nonce: "nonce",
            recovery_salt: None,
            recovery_wrap: None,
        }
    }
    fn create_fixture() -> CreateVault<'static> {
        CreateVault {
            schema_version: 4,
            ciphertext: "ciphertext",
            nonce: "nonce",
            recovery_salt: "salt",
            recovery_wrap: "wrap",
            device_wrap: "password-only-v4",
            wrap_version: 4,
            password_salt: "salt",
            password_wrap: "wrap",
            kdf: "fixture",
        }
    }

    #[test]
    fn operation_never_adopts_another_accounts_bearer_or_origin() {
        let (a, wire, current) = fixture();
        a.get().unwrap();
        current.lock().unwrap().token = Zeroizing::new("dummy-b".into());
        assert!(matches!(
            a.update(&update_fixture()),
            Err(VaultError::AccountChanged)
        ));
        assert!(matches!(a.status(), Err(VaultError::AccountChanged)));
        assert!(matches!(
            a.register_machine("machine", "identity", "label", "client"),
            Err(VaultError::AccountChanged)
        ));
        assert_eq!(wire.calls.lock().unwrap().len(), 1);
        // A fresh operation can use B, while the captured A object remains retired.
        let b = VaultClient {
            authentication: Arc::new(current.lock().unwrap().clone()),
            ..a.clone()
        };
        b.update(&update_fixture()).unwrap();
        assert_eq!(
            wire.calls.lock().unwrap()[1].2.to_str().unwrap(),
            "Bearer dummy-b"
        );
        current.lock().unwrap().host = "https://b.example".into();
        assert!(matches!(b.remove(), Err(VaultError::AccountChanged)));
        assert_eq!(wire.calls.lock().unwrap().len(), 2);
    }

    #[test]
    fn suspended_success_and_failure_are_retired_before_publication() {
        for fail in [false, true] {
            let (client, wire, current) = fixture();
            wire.fail.store(fail, std::sync::atomic::Ordering::SeqCst);
            let (started_send, started) = std::sync::mpsc::channel();
            let (resume, resume_receive) = std::sync::mpsc::channel();
            *wire.hold.lock().unwrap() = Some((started_send, resume_receive));
            let waiting = std::thread::spawn(move || client.get());
            started.recv_timeout(Duration::from_secs(5)).unwrap();
            current.lock().unwrap().token = Zeroizing::new("dummy-b".into());
            resume.send(()).unwrap();
            assert!(matches!(
                waiting.join().unwrap(),
                Err(VaultError::AccountChanged)
            ));
            let calls = wire.calls.lock().unwrap();
            assert_eq!(calls.len(), 1);
            assert_eq!(calls[0].2.to_str().unwrap(), "Bearer dummy-a");
        }
    }

    #[test]
    fn login_retirement_rejects_suspended_replies_even_when_the_old_bearer_is_unchanged() {
        for fail in [false, true] {
            let (client, wire, _) = fixture();
            wire.fail.store(fail, std::sync::atomic::Ordering::SeqCst);
            let epoch = Arc::new(std::sync::atomic::AtomicU64::new(1));
            let checked = epoch.clone();
            let client = client.with_retirement_guard(move || {
                if checked.load(std::sync::atomic::Ordering::SeqCst) == 1 {
                    Ok(())
                } else {
                    Err(VaultError::AccountChanged)
                }
            });
            let (started_send, started) = std::sync::mpsc::channel();
            let (resume, resume_receive) = std::sync::mpsc::channel();
            *wire.hold.lock().unwrap() = Some((started_send, resume_receive));
            let old = client.clone();
            let waiting = std::thread::spawn(move || old.get());
            started.recv_timeout(Duration::from_secs(5)).unwrap();
            epoch.store(2, std::sync::atomic::Ordering::SeqCst);
            resume.send(()).unwrap();
            assert!(matches!(
                waiting.join().unwrap(),
                Err(VaultError::AccountChanged)
            ));
            assert!(matches!(
                client.update(&update_fixture()),
                Err(VaultError::AccountChanged)
            ));
            assert_eq!(wire.calls.lock().unwrap().len(), 1);
        }
    }

    #[test]
    fn oversized_responses_are_rejected_before_json_decoding() {
        struct Oversized;
        impl VaultWire for Oversized {
            fn send(
                &self,
                request: VaultRequest,
            ) -> Result<(reqwest::StatusCode, Vec<u8>), VaultError> {
                Ok((
                    reqwest::StatusCode::OK,
                    vec![b' '; request.response_limit as usize + 1],
                ))
            }
        }
        let (mut client, _, _) = fixture();
        client.wire = Arc::new(Oversized);
        for path in ["/api/v1/me", "/api/v1/machines/me", "/api/v1/vault/ssh"] {
            let error = client.response(Method::GET, path, None).unwrap_err();
            assert!(
                matches!(error, VaultError::Server(ref message) if message.contains("size limit"))
            );
        }
    }

    #[test]
    fn every_vault_plan_and_registration_route_uses_the_captured_authentication() {
        let (client, wire, _) = fixture();
        let status = client.status().unwrap();
        assert_eq!(status.account_id.as_deref(), Some("account-a"));
        assert_eq!(status.host, "https://a.example");
        client.get().unwrap();
        client.create(&create_fixture()).unwrap();
        client.update(&update_fixture()).unwrap();
        client
            .rotate(&RotateVault {
                expected_revision: 1,
                vault: create_fixture(),
            })
            .unwrap();
        client
            .rewrap(&RewrapVault {
                password_salt: "salt",
                password_wrap: "wrap",
                kdf: "fixture",
                recovery_salt: None,
                recovery_wrap: None,
            })
            .unwrap();
        client.remove().unwrap();
        client.request_enrollment("nonce").unwrap();
        client
            .approve_enrollment("machine", "request", "wrap", 4)
            .unwrap();
        client.list_enrollments().unwrap();
        client
            .register_machine("machine", "identity", "label", "client")
            .unwrap();
        let calls = wire.calls.lock().unwrap();
        assert_eq!(calls.len(), 11);
        for (_, url, authorization) in calls.iter() {
            assert!(url.starts_with("https://a.example/api/v1/"));
            assert_eq!(authorization.to_str().unwrap(), "Bearer dummy-a");
        }
    }
}
