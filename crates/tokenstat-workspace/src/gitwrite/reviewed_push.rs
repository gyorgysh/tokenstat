// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Explicit, current-branch pushes bind the submitted commit and destination.
//! Receipt reads never resend a push. Recovery only observes the remote ref.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::lease::Lease;
use super::selected::{command, digest, index_path, receipt_path, save, text};

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Review {
    pub branch: String,
    pub head: String,
    pub remote: String,
    pub remote_ref: String,
    /// A configured URL can contain credentials. Only its fingerprint crosses
    /// the bridge; submission resolves and checks it on the host again.
    pub endpoint_digest: String,
    pub remote_head: Option<String>,
    pub outgoing: Option<u64>,
    pub set_upstream: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Receipt {
    pub operation_id: String,
    pub review: Review,
    pub state: String,
    pub message: String,
    pub retry_allowed: bool,
}

/// URLs stay in the private host receipt, never in the client response. A
/// later remote rename must not retarget recovery or make its old URL vanish.
#[derive(Serialize, Deserialize)]
struct StoredReceipt {
    result: Receipt,
    endpoint: Option<String>,
}

fn save_receipt(path: &Path, result: &Receipt, endpoint: Option<&str>) -> Result<(), String> {
    save(
        path,
        &StoredReceipt {
            result: result.clone(),
            endpoint: endpoint.map(str::to_owned),
        },
    )
}

fn config(dir: &Path, key: &str) -> Result<Option<String>, String> {
    let out = command(dir, &["config", "--get", key])
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.code() == Some(1) {
        return Ok(None);
    }
    if !out.status.success() {
        return Err(super::GitOutcome::from(out).message);
    }
    Ok(Some(
        String::from_utf8(out.stdout)
            .map_err(|e| e.to_string())?
            .trim()
            .into(),
    ))
}

fn endpoint(dir: &Path, remote: &str) -> Result<String, String> {
    let urls = text(dir, &["remote", "get-url", "--push", "--all", remote])?;
    let lines: Vec<_> = urls.lines().filter(|s| !s.is_empty()).collect();
    if lines.len() != 1 {
        return Err("This remote has multiple push destinations. Choose a single destination on the computer before pushing here.".into());
    }
    Ok(lines[0].into())
}

fn remote_head(dir: &Path, url: &str, reference: &str) -> Result<Option<String>, String> {
    let refs = text(dir, &["ls-remote", "--refs", "--", url, reference])?;
    for line in refs.lines() {
        if let Some((oid, name)) = line.split_once('\t') {
            if name == reference {
                return Ok(Some(oid.into()));
            }
        }
    }
    Ok(None)
}

/// Resolve the current branch's one destination and read its live remote ref.
/// This runs from the Push review action, never workspace refresh.
pub fn review(dir: &Path) -> Result<Review, String> {
    let branch = text(dir, &["symbolic-ref", "-q", "HEAD"])
        .map_err(|_| "Choose a branch before pushing. HEAD is detached.".to_string())?;
    let short = branch
        .strip_prefix("refs/heads/")
        .ok_or("Choose a local branch before pushing.")?;
    let head = text(dir, &["rev-parse", "--verify", "HEAD^{commit}"])
        .map_err(|_| "Make a commit before publishing this branch.".to_string())?;
    let upstream_remote = config(dir, &format!("branch.{short}.remote"))?;
    let merge = config(dir, &format!("branch.{short}.merge"))?;
    let remote = config(dir, &format!("branch.{short}.pushRemote"))?
        .or(config(dir, "remote.pushDefault")?)
        .or(upstream_remote.clone())
        .unwrap_or_else(|| "origin".into());
    if remote.is_empty() || remote.starts_with('-') || remote.contains(['\n', '\r']) {
        return Err("Choose a valid push remote on the computer.".into());
    }
    let remote_ref = if upstream_remote.as_ref() == Some(&remote) {
        merge.clone().unwrap_or_else(|| branch.clone())
    } else {
        branch.clone()
    };
    if !remote_ref.starts_with("refs/heads/") {
        return Err("The push destination must be a branch.".into());
    }
    text(dir, &["check-ref-format", &remote_ref])?;
    let url = endpoint(dir, &remote)?;
    let remote_head = remote_head(dir, &url, &remote_ref)?;
    let range = remote_head
        .as_ref()
        .map_or_else(|| head.clone(), |old| format!("{old}..{head}"));
    let outgoing = text(dir, &["rev-list", "--count", &range])
        .ok()
        .and_then(|s| s.parse().ok());
    Ok(Review {
        branch,
        head,
        remote,
        remote_ref,
        endpoint_digest: digest(url.as_bytes()),
        remote_head,
        outgoing,
        set_upstream: upstream_remote.is_none() && merge.is_none(),
    })
}

fn path(dir: &Path, id: &str) -> Result<PathBuf, String> {
    Ok(receipt_path(dir, id)?.with_file_name(format!("push-{id}.json")))
}

pub fn receipt(dir: &Path, id: &str) -> Result<Option<Receipt>, String> {
    Ok(stored_receipt(dir, id)?.map(|stored| stored.result))
}

fn stored_receipt(dir: &Path, id: &str) -> Result<Option<StoredReceipt>, String> {
    match fs::read(path(dir, id)?) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| e.to_string()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

/// Publish only the submitted object ID. Branch switches, new local commits,
/// push.default=matching, mirror remotes and follow-tags cannot widen the push.
pub fn push(dir: &Path, id: &str, reviewed: &Review, retry: bool) -> Result<Receipt, String> {
    let path = path(dir, id)?;
    let _lease = Lease::acquire(&index_path(dir)?.with_file_name("tokenstat-git-operation.lock"))?;
    let previous = stored_receipt(dir, id)?;
    if let Some(stored) = &previous {
        let previous = &stored.result;
        if &previous.review != reviewed {
            return Err("This operation identifier belongs to another push.".into());
        }
        if !(retry && previous.retry_allowed && previous.state == "unknown") {
            return Ok(previous.clone());
        }
    }
    let mut result = Receipt {
        operation_id: id.into(),
        review: reviewed.clone(),
        state: "started".into(),
        message: "Pushing the reviewed commit.".into(),
        retry_allowed: false,
    };
    // Keep an interrupted attempt's original endpoint through preflight.
    let previous_endpoint = previous
        .as_ref()
        .and_then(|stored| stored.endpoint.as_deref());
    save_receipt(&path, &result, previous_endpoint)?;
    let prepared = (|| {
        let fresh = review(dir)?;
        if fresh != *reviewed {
            return Err(
                "The branch or push destination changed. Review the current branch before pushing."
                    .into(),
            );
        }
        let url = endpoint(dir, &reviewed.remote)?;
        if digest(url.as_bytes()) != reviewed.endpoint_digest {
            return Err("The push destination changed. Review it again.".into());
        }
        Ok(url)
    })();
    let url = match prepared {
        Ok(url) => url,
        Err(error) => {
            if previous.is_some() {
                result.state = "unknown".into();
                result.retry_allowed = true;
                result.message =
                    format!("This retry did not run. {error} Check the original push's outcome.");
            } else {
                result.state = "failed".into();
                result.message = error;
            }
            save_receipt(&path, &result, previous_endpoint)?;
            return Ok(result);
        }
    };
    save_receipt(&path, &result, Some(&url))?;
    let spec = format!("{}:{}", reviewed.head, reviewed.remote_ref);
    // A URL pins the endpoint without re-reading remote.* configuration in
    // git push. Credentials and pre-push hooks still run in the host Git env.
    match command(
        dir,
        &[
            "push",
            "--porcelain",
            "--no-force",
            "--no-follow-tags",
            "--",
            &url,
            &spec,
        ],
    )
    .output()
    {
        Ok(out) if out.status.success() => {
            result.state = "succeeded".into();
            result.message = "Pushed the reviewed commit.".into();
            if let Err(error) = refresh_tracking(dir, reviewed) {
                result
                    .message
                    .push_str(&format!(" Local tracking could not be refreshed: {error}"));
            }
            if reviewed.set_upstream {
                if let Err(error) = set_upstream(dir, reviewed) {
                    result.message =
                        format!("Pushed the reviewed commit. Tracking could not be set: {error}");
                }
            }
        }
        Ok(out) => {
            // A network failure may follow a successful receive on the remote.
            // Keep the identity; explicit recovery reads the destination.
            let rejected = String::from_utf8_lossy(&out.stdout)
                .lines()
                .any(|line| line.starts_with("!\t"));
            result.state = if rejected { "failed" } else { "unknown" }.into();
            result.message = super::GitOutcome::from(out).message;
        }
        Err(error) => {
            result.state = "failed".into();
            result.message = error.to_string();
        }
    }
    save_receipt(&path, &result, Some(&url))?;
    Ok(result)
}

/// Explicit recovery observes the exact destination. It neither fetches nor
/// pushes, and an unreachable remote remains an unknown outcome.
pub fn recover(dir: &Path, id: &str) -> Result<Receipt, String> {
    let _lease = Lease::acquire(&index_path(dir)?.with_file_name("tokenstat-git-operation.lock"))?;
    let stored = stored_receipt(dir, id)?.ok_or("No submitted push was found.")?;
    let mut result = stored.result;
    if result.state == "succeeded" || result.state == "failed" {
        return Ok(result);
    }
    let Some(url) = stored.endpoint else {
        result.state = "failed".into();
        result.message =
            "This push ended before it was sent. Review the branch to start again.".into();
        result.retry_allowed = false;
        save_receipt(&path(dir, id)?, &result, None)?;
        return Ok(result);
    };
    let current = remote_head(dir, &url, &result.review.remote_ref)?;
    let includes = current.as_ref().is_some_and(|oid| {
        oid == &result.review.head
            || command(
                dir,
                &["merge-base", "--is-ancestor", &result.review.head, oid],
            )
            .output()
            .is_ok_and(|out| out.status.success())
    });
    if includes {
        result.state = "succeeded".into();
        result.message = "The remote branch contains the submitted commit.".into();
        result.retry_allowed = false;
        let same_destination =
            endpoint(dir, &result.review.remote).is_ok_and(|current| current == url);
        if same_destination && current.as_ref() == Some(&result.review.head) {
            if let Err(error) = refresh_tracking(dir, &result.review) {
                result
                    .message
                    .push_str(&format!(" Local tracking could not be refreshed: {error}"));
            }
        }
        if same_destination && result.review.set_upstream {
            if let Err(error) = set_upstream(dir, &result.review) {
                result
                    .message
                    .push_str(&format!(" Tracking could not be set: {error}"));
            }
        }
    } else {
        result.state = "unknown".into();
        result.retry_allowed = true;
        result.message = "The remote branch does not currently confirm this commit. You can explicitly retry the same push; it will still refuse to overwrite remote work.".into();
    }
    save_receipt(&path(dir, id)?, &result, Some(&url))?;
    Ok(result)
}

/// Tracking configuration is installed as one locked file replacement. A
/// concurrent configuration edit is never overwritten by a partial pair.
fn set_upstream(dir: &Path, reviewed: &Review) -> Result<(), String> {
    let short = reviewed
        .branch
        .strip_prefix("refs/heads/")
        .ok_or("Invalid local branch")?;
    let common = text(
        dir,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )?;
    let config_file = PathBuf::from(common).join("config");
    let lock_path = config_file.with_extension("lock");
    let mut lock = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&lock_path)
        .map_err(|e| e.to_string())?;
    let identity = super::lease::identity(&lock)?;
    let result = (|| {
        if digest(endpoint(dir, &reviewed.remote)?.as_bytes()) != reviewed.endpoint_digest {
            return Err("The push destination changed.".into());
        }
        let remote_key = format!("branch.{short}.remote");
        let merge_key = format!("branch.{short}.merge");
        let current_remote = config(dir, &remote_key)?;
        let current_merge = config(dir, &merge_key)?;
        if current_remote.as_deref() == Some(&reviewed.remote)
            && current_merge.as_deref() == Some(&reviewed.remote_ref)
        {
            return Ok(());
        }
        if current_remote.is_some() || current_merge.is_some() {
            return Err("The branch tracking configuration changed.".into());
        }
        let parent = config_file
            .parent()
            .ok_or("Missing Git configuration directory")?;
        lock.set_permissions(
            fs::metadata(&config_file)
                .map_err(|e| e.to_string())?
                .permissions(),
        )
        .map_err(|e| e.to_string())?;
        let mut temp = tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
        temp.write_all(&fs::read(&config_file).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        let filename = temp.path().to_str().ok_or("Invalid configuration path")?;
        text(
            dir,
            &["config", "--file", filename, &remote_key, &reviewed.remote],
        )?;
        text(
            dir,
            &[
                "config",
                "--file",
                filename,
                &merge_key,
                &reviewed.remote_ref,
            ],
        )?;
        lock.write_all(&fs::read(temp.path()).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        lock.sync_all().map_err(|e| e.to_string())?;
        fs::rename(&lock_path, &config_file).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        fs::File::open(parent)
            .and_then(|file| file.sync_all())
            .map_err(|e| e.to_string())?;
        Ok(())
    })();
    drop(lock);
    if fs::File::open(&lock_path)
        .ok()
        .and_then(|file| super::lease::identity(&file).ok())
        == Some(identity)
    {
        let _ = fs::remove_file(lock_path);
    }
    result
}

fn refresh_tracking(dir: &Path, reviewed: &Review) -> Result<(), String> {
    if digest(endpoint(dir, &reviewed.remote)?.as_bytes()) != reviewed.endpoint_digest {
        return Err("The push destination changed.".into());
    }
    let mappings = text(
        dir,
        &[
            "config",
            "--get-all",
            &format!("remote.{}.fetch", reviewed.remote),
        ],
    )?;
    for mapping in mappings.lines() {
        let Some((source, destination)) = mapping.trim_start_matches('+').split_once(':') else {
            continue;
        };
        let target = if let Some((prefix, suffix)) = source.split_once('*') {
            reviewed
                .remote_ref
                .strip_prefix(prefix)
                .and_then(|s| s.strip_suffix(suffix))
                .map(|part| destination.replacen('*', part, 1))
        } else if source == reviewed.remote_ref {
            Some(destination.to_owned())
        } else {
            None
        };
        let Some(target) = target else { continue };
        if !target.starts_with("refs/remotes/") {
            return Err("The remote uses a custom tracking destination.".into());
        }
        text(dir, &["check-ref-format", &target])?;
        let old = text(dir, &["rev-parse", "--verify", &target])
            .unwrap_or_else(|_| "0".repeat(reviewed.head.len()));
        text(dir, &["update-ref", &target, &reviewed.head, &old])?;
        return Ok(());
    }
    Err("No tracking reference matches this branch.".into())
}

#[cfg(test)]
mod tests;
