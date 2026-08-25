// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! Typed client for tokenstat.ai's ciphertext-only SSH vault service.

use std::time::Duration;

use reqwest::blocking::{Client, RequestBuilder};
use serde::{Deserialize, Serialize, de::DeserializeOwned};

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
    #[error("not signed in")]
    NotSignedIn,
    #[error("this device is not enrolled in the SSH vault")]
    NotEnrolled,
    /// The account does not know this machine, so nothing it holds can be
    /// reached from here. Recoverable without the user doing anything: the
    /// machine record is published at login and can be published again.
    ///
    /// Carries the server sentence, because two causes share one code: a
    /// login with no machine id, and a machine id the account has no row
    /// for. The screen has to tell them apart.
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

fn auth() -> Result<(String, String, Client), VaultError> {
    let host = profile::resolve_api_host(None)?;
    let token = keychain::load_token(&host)
        .map_err(ProfileError::from)?
        .ok_or(VaultError::NotSignedIn)?;
    let client = Client::builder()
        .timeout(Duration::from_secs(30))
        .connect_timeout(Duration::from_secs(5))
        .user_agent(format!("tokenstat/{}", env!("CARGO_PKG_VERSION")))
        .redirect(reqwest::redirect::Policy::none())
        .build()?;
    Ok((host, token, client))
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
        "machine_required" | "machine_not_registered" => {
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

fn send<T: DeserializeOwned>(request: RequestBuilder) -> Result<T, VaultError> {
    let response = request.send()?;
    let status = response.status();
    let bytes = response.bytes()?;
    if status.is_success() {
        return Ok(serde_json::from_slice(&bytes)?);
    }
    Err(read_error(status, &bytes))
}

fn send_empty(request: RequestBuilder) -> Result<(), VaultError> {
    let response = request.send()?;
    let status = response.status();
    let bytes = response.bytes()?;
    if status.is_success() {
        return Ok(());
    }
    Err(read_error(status, &bytes))
}

pub fn get() -> Result<RemoteVault, VaultError> {
    let (host, token, client) = auth()?;
    send(
        client
            .get(format!("{host}/api/v1/vault/ssh"))
            .bearer_auth(token),
    )
}

pub fn create(body: &CreateVault<'_>) -> Result<Revision, VaultError> {
    let (host, token, client) = auth()?;
    send(
        client
            .post(format!("{host}/api/v1/vault/ssh"))
            .bearer_auth(token)
            .json(body),
    )
}

pub fn update(body: &UpdateVault<'_>) -> Result<Revision, VaultError> {
    let (host, token, client) = auth()?;
    send(
        client
            .put(format!("{host}/api/v1/vault/ssh"))
            .bearer_auth(token)
            .json(body),
    )
}

/// Replace the password wrap on the vault that already exists.
pub fn rewrap(body: &RewrapVault<'_>) -> Result<(), VaultError> {
    let (host, token, client) = auth()?;
    send_empty(
        client
            .post(format!("{host}/api/v1/vault/ssh/rewrap"))
            .bearer_auth(token)
            .json(body),
    )
}

/// Permanently deletes the account vault. A missing vault is success: the
/// caller is trying to reach a clean slate, not inspect one.
pub fn remove() -> Result<(), VaultError> {
    let (host, token, client) = auth()?;
    match send_empty(
        client
            .delete(format!("{host}/api/v1/vault/ssh"))
            .bearer_auth(token),
    ) {
        Ok(()) | Err(VaultError::NotFound) => Ok(()),
        Err(e) => Err(e),
    }
}

pub fn request_enrollment(nonce: &str) -> Result<EnrollmentRequest, VaultError> {
    let (host, token, client) = auth()?;
    send(
        client
            .post(format!("{host}/api/v1/vault/ssh/enrollment-requests"))
            .bearer_auth(token)
            .json(&EnrollmentNonce { nonce }),
    )
}

pub fn approve_enrollment(
    machine_id: &str,
    request_id: &str,
    device_wrap: &str,
    wrap_version: u32,
) -> Result<EnrollmentResult, VaultError> {
    let (host, token, client) = auth()?;
    send(
        client
            .put(format!("{host}/api/v1/vault/ssh/devices/{machine_id}"))
            .bearer_auth(token)
            .json(&EnrollmentApproval {
                request_id,
                device_wrap,
                wrap_version,
            }),
    )
}

pub fn list_enrollments() -> Result<Vec<EnrollmentRequest>, VaultError> {
    let (host, token, client) = auth()?;
    Ok(send::<EnrollmentRequests>(
        client
            .get(format!("{host}/api/v1/vault/ssh/enrollment-requests"))
            .bearer_auth(token),
    )?
    .requests)
}
