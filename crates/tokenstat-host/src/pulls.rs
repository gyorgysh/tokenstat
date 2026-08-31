//! Pull-request connection methods for registered workspaces.
//!
//! The authorization secret stays in this process while the UI shows only the
//! short device code. A paired client may inspect a workspace's availability,
//! but it cannot start, poll, replace, or remove credentials on this machine.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Params {
    workspace_id: String,
    host: String,
    token: String,
    scope: Option<tokenstat_sync::forge::Scope>,
    state: Option<tokenstat_sync::forge::State>,
    limit: Option<u32>,
    number: Option<u32>,
    cursor: Option<String>,
    body: String,
    branch: String,
    verdict: Option<tokenstat_sync::forge::Verdict>,
    merge_method: Option<tokenstat_sync::forge::MergeMethod>,
    refresh: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct ListKey {
    workspace_id: String,
    repo: tokenstat_sync::forge::Repo,
    scope: tokenstat_sync::forge::Scope,
    state: tokenstat_sync::forge::State,
    limit: u32,
}

#[derive(Clone)]
struct ListEntry {
    at: Instant,
    rows: Vec<tokenstat_sync::forge::PullSummary>,
}

fn list_cache() -> &'static Mutex<HashMap<ListKey, ListEntry>> {
    static CACHE: OnceLock<Mutex<HashMap<ListKey, ListEntry>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The complete open list already fetched for this workspace, if one is still
/// fresh. Sidebar summaries call this instead of making a forge request.
pub(crate) fn cached_open_count(workspace_id: &str) -> Option<usize> {
    list_cache()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .filter(|(key, entry)| {
            key.workspace_id == workspace_id
                && key.scope == tokenstat_sync::forge::Scope::All
                && key.state == tokenstat_sync::forge::State::Open
                && entry.at.elapsed() < Duration::from_secs(60)
        })
        .max_by_key(|(_, entry)| entry.at)
        .map(|(_, entry)| entry.rows.len())
}

fn clear_list_cache() {
    list_cache()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clear();
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct DetailKey {
    workspace_id: String,
    number: u32,
}

#[derive(Clone)]
struct DetailEntry<T> {
    at: Instant,
    value: T,
}

/// How long a detail, timeline page or diff is worth reusing.
const DETAIL_TTL: Duration = Duration::from_secs(30);

/// Read one of the read caches, if what is in it is still worth having.
fn cached<K: Eq + std::hash::Hash, V: Clone>(
    cache: &Mutex<HashMap<K, DetailEntry<V>>>,
    key: &K,
) -> Option<V> {
    cache
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get(key)
        .filter(|entry| entry.at.elapsed() < DETAIL_TTL)
        .map(|entry| entry.value.clone())
}

/// Put an answer in one of the read caches, dropping what has gone stale.
///
/// The pruning is the point. Reading is filtered by age, so an entry nobody
/// asks for again is never looked at and was never removed: a daemon that
/// runs for weeks kept every parsed diff it had ever shown, which for a
/// repository with large diffs is memory nothing can reclaim.
fn remember<K: Eq + std::hash::Hash, V>(
    cache: &Mutex<HashMap<K, DetailEntry<V>>>,
    key: K,
    value: V,
) {
    let mut cache = cache.lock().unwrap_or_else(PoisonError::into_inner);
    cache.retain(|_, entry| entry.at.elapsed() < DETAIL_TTL);
    cache.insert(
        key,
        DetailEntry {
            at: Instant::now(),
            value,
        },
    );
}

fn detail_cache()
-> &'static Mutex<HashMap<DetailKey, DetailEntry<tokenstat_sync::forge::PullDetail>>> {
    static CACHE: OnceLock<
        Mutex<HashMap<DetailKey, DetailEntry<tokenstat_sync::forge::PullDetail>>>,
    > = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct TimelineKey {
    workspace_id: String,
    number: u32,
    cursor: Option<String>,
}

fn timeline_cache()
-> &'static Mutex<HashMap<TimelineKey, DetailEntry<tokenstat_sync::forge::TimelinePage>>> {
    static CACHE: OnceLock<
        Mutex<HashMap<TimelineKey, DetailEntry<tokenstat_sync::forge::TimelinePage>>>,
    > = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn diff_cache()
-> &'static Mutex<HashMap<DetailKey, DetailEntry<Vec<tokenstat_workspace::git::FileDiff>>>> {
    static CACHE: OnceLock<
        Mutex<HashMap<DetailKey, DetailEntry<Vec<tokenstat_workspace::git::FileDiff>>>>,
    > = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn clear_read_cache() {
    clear_list_cache();
    detail_cache()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clear();
    timeline_cache()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clear();
    diff_cache()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clear();
}

fn invalidate_workspace(workspace_id: &str) {
    list_cache()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .retain(|key, _| key.workspace_id != workspace_id);
    detail_cache()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .retain(|key, _| key.workspace_id != workspace_id);
    timeline_cache()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .retain(|key, _| key.workspace_id != workspace_id);
    diff_cache()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .retain(|key, _| key.workspace_id != workspace_id);
}

fn pending() -> &'static Mutex<Option<tokenstat_sync::forge::DeviceLogin>> {
    static PENDING: OnceLock<Mutex<Option<tokenstat_sync::forge::DeviceLogin>>> = OnceLock::new();
    PENDING.get_or_init(|| Mutex::new(None))
}

fn with_pending<T>(
    work: impl FnOnce(&mut Option<tokenstat_sync::forge::DeviceLogin>) -> Result<T, String>,
) -> Result<T, String> {
    let mut guard = pending().lock().unwrap_or_else(PoisonError::into_inner);
    work(&mut guard)
}

pub(crate) fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("pulls.") {
        return None;
    }
    Some(call_inner(method, params))
}

fn call_inner(method: &str, params: &str) -> Result<Value, String> {
    let p: Params = serde_json::from_str(params.trim()).map_err(|error| error.to_string())?;
    match method {
        "pulls.availability" => availability(&p.workspace_id),
        "pulls.connection" => {
            local_credentials_only()?;
            serde_json::to_value(
                tokenstat_sync::forge::connection(host_or_default(&p.host))
                    .map_err(|error| error.to_string())?,
            )
            .map_err(|error| error.to_string())
        }
        "pulls.signIn" => {
            local_credentials_only()?;
            let host = host_or_default(&p.host);
            let login = tokenstat_sync::forge::device_start(host).map_err(|e| e.to_string())?;
            let value = json!({
                "host": login.host,
                "userCode": login.user_code,
                "openUrl": login.verification_uri,
                "expiresIn": login.expires_in,
                "interval": login.interval,
            });
            with_pending(|pending| {
                *pending = Some(login);
                Ok(())
            })?;
            Ok(value)
        }
        "pulls.signInPoll" => {
            local_credentials_only()?;
            let login = with_pending(|pending| {
                pending
                    .clone()
                    .ok_or_else(|| "no pull-request connection is in progress".into())
            })?;
            match tokenstat_sync::forge::device_poll(&login).map_err(|e| e.to_string())? {
                tokenstat_sync::forge::DeviceStatus::Pending { interval } => {
                    Ok(json!({"state": "pending", "interval": interval}))
                }
                tokenstat_sync::forge::DeviceStatus::Confirmed(credential) => {
                    with_pending(|pending| {
                        *pending = None;
                        Ok(())
                    })?;
                    clear_read_cache();
                    Ok(json!({
                        "state": "confirmed",
                        "source": credential.source(),
                    }))
                }
            }
        }
        "pulls.cancelSignIn" => {
            local_credentials_only()?;
            with_pending(|pending| {
                *pending = None;
                Ok(())
            })?;
            Ok(json!({"cancelled": true}))
        }
        "pulls.signOut" => {
            local_credentials_only()?;
            tokenstat_sync::forge::sign_out(host_or_default(&p.host)).map_err(|e| e.to_string())?;
            clear_read_cache();
            Ok(json!({"signedOut": true}))
        }
        "pulls.setToken" => {
            local_credentials_only()?;
            tokenstat_sync::forge::set_token(host_or_default(&p.host), &p.token)
                .map_err(|e| e.to_string())?;
            clear_read_cache();
            Ok(json!({"stored": true}))
        }
        "pulls.list" => list(&p),
        "pulls.view" => view(&p),
        "pulls.timeline" => timeline(&p),
        "pulls.diff" => diff(&p),
        "pulls.comment" => write(&p, "pulls.comment", |repo, number| {
            tokenstat_sync::forge::comment(repo, number, &p.body)
        }),
        "pulls.close" => write(&p, "pulls.close", tokenstat_sync::forge::close),
        "pulls.reopen" => write(&p, "pulls.reopen", tokenstat_sync::forge::reopen),
        "pulls.ready" => write(&p, "pulls.ready", tokenstat_sync::forge::ready),
        "pulls.review" => write(&p, "pulls.review", |repo, number| {
            let verdict = p.verdict.ok_or_else(|| {
                tokenstat_sync::forge::ForgeError::Api("pulls.review needs verdict".into())
            })?;
            tokenstat_sync::forge::review(repo, number, verdict, Some(&p.body))
        }),
        "pulls.merge" => write(&p, "pulls.merge", |repo, number| {
            let method = p.merge_method.ok_or_else(|| {
                tokenstat_sync::forge::ForgeError::Api("pulls.merge needs mergeMethod".into())
            })?;
            tokenstat_sync::forge::merge(repo, number, method)
        }),
        "pulls.checkout" => checkout(&p),
        other => Err(format!("unknown pull-request method: {other}")),
    }
}

fn repo_for(workspace_id: &str, method: &str) -> Result<tokenstat_sync::forge::Repo, String> {
    if workspace_id.trim().is_empty() {
        return Err(format!("{method} needs workspaceId"));
    }
    let workspace = crate::workspaces::folder(workspace_id)?;
    let remote = tokenstat_workspace::git::remote(&workspace.path)
        .ok_or_else(|| "this workspace has no GitHub remote".to_string())?;
    Ok(forge_repo(remote))
}

fn pull_number(p: &Params, method: &str) -> Result<u32, String> {
    p.number
        .filter(|number| *number > 0)
        .ok_or_else(|| format!("{method} needs number"))
}

fn write(
    p: &Params,
    method: &str,
    action: impl FnOnce(
        &tokenstat_sync::forge::Repo,
        u32,
    ) -> Result<(), tokenstat_sync::forge::ForgeError>,
) -> Result<Value, String> {
    let number = pull_number(p, method)?;
    let repo = repo_for(&p.workspace_id, method)?;
    action(&repo, number).map_err(|error| error.to_string())?;
    invalidate_workspace(&p.workspace_id);
    Ok(json!({"ok": true}))
}

fn checkout(p: &Params) -> Result<Value, String> {
    let number = pull_number(p, "pulls.checkout")?;
    let workspace = crate::workspaces::folder(&p.workspace_id)?;
    let outcome = tokenstat_workspace::gitwrite::fetch_pull(&workspace.path, number, &p.branch);
    if outcome.ok {
        invalidate_workspace(&p.workspace_id);
    }
    serde_json::to_value(outcome).map_err(|error| error.to_string())
}

fn view(p: &Params) -> Result<Value, String> {
    let number = pull_number(p, "pulls.view")?;
    let key = DetailKey {
        workspace_id: p.workspace_id.clone(),
        number,
    };
    if !p.refresh
        && let Some(hit) = cached(detail_cache(), &key)
    {
        return serde_json::to_value(hit).map_err(|error| error.to_string());
    }
    let value = tokenstat_sync::forge::view(&repo_for(&p.workspace_id, "pulls.view")?, number)
        .map_err(|error| error.to_string())?;
    remember(detail_cache(), key, value.clone());
    serde_json::to_value(value).map_err(|error| error.to_string())
}

fn timeline(p: &Params) -> Result<Value, String> {
    let number = pull_number(p, "pulls.timeline")?;
    let key = TimelineKey {
        workspace_id: p.workspace_id.clone(),
        number,
        cursor: p.cursor.clone(),
    };
    if !p.refresh
        && let Some(hit) = cached(timeline_cache(), &key)
    {
        return serde_json::to_value(hit).map_err(|error| error.to_string());
    }
    let value = tokenstat_sync::forge::timeline(
        &repo_for(&p.workspace_id, "pulls.timeline")?,
        number,
        p.cursor.as_deref(),
    )
    .map_err(|error| error.to_string())?;
    remember(timeline_cache(), key, value.clone());
    serde_json::to_value(value).map_err(|error| error.to_string())
}

fn diff(p: &Params) -> Result<Value, String> {
    let number = pull_number(p, "pulls.diff")?;
    let key = DetailKey {
        workspace_id: p.workspace_id.clone(),
        number,
    };
    if !p.refresh
        && let Some(hit) = cached(diff_cache(), &key)
    {
        return serde_json::to_value(hit).map_err(|error| error.to_string());
    }
    let raw = tokenstat_sync::forge::diff_text(&repo_for(&p.workspace_id, "pulls.diff")?, number)
        .map_err(|error| error.to_string())?;
    let value = tokenstat_workspace::git::split_unified(&raw);
    remember(diff_cache(), key, value.clone());
    serde_json::to_value(value).map_err(|error| error.to_string())
}

fn availability(workspace_id: &str) -> Result<Value, String> {
    if workspace_id.trim().is_empty() {
        return Err("pulls.availability needs workspaceId".into());
    }
    let workspace = crate::workspaces::folder(workspace_id)?;
    if !tokenstat_workspace::git::status(&workspace.path).is_repo {
        return Ok(json!({"state": "notRepository"}));
    }
    let Some(remote) = tokenstat_workspace::git::remote(&workspace.path) else {
        return Ok(json!({"state": "noRemote"}));
    };
    let repo = forge_repo(remote);
    let mut value = serde_json::to_value(
        tokenstat_sync::forge::availability(&repo).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    if let Value::Object(ref mut fields) = value {
        fields.insert("host".into(), json!(repo.host));
        fields.insert("owner".into(), json!(repo.owner));
        fields.insert("repo".into(), json!(repo.repo));
    }
    Ok(value)
}

fn list(p: &Params) -> Result<Value, String> {
    if p.workspace_id.trim().is_empty() {
        return Err("pulls.list needs workspaceId".into());
    }
    let workspace = crate::workspaces::folder(&p.workspace_id)?;
    let remote = tokenstat_workspace::git::remote(&workspace.path)
        .ok_or_else(|| "this workspace has no GitHub remote".to_string())?;
    let repo = forge_repo(remote);
    let scope = p.scope.unwrap_or(tokenstat_sync::forge::Scope::All);
    let state = p.state.unwrap_or(tokenstat_sync::forge::State::Open);
    let limit = p.limit.unwrap_or(40).clamp(1, 40);
    let key = ListKey {
        workspace_id: p.workspace_id.clone(),
        repo: repo.clone(),
        scope,
        state,
        limit,
    };
    if !p.refresh {
        let hit = list_cache()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&key)
            .filter(|entry| entry.at.elapsed() < Duration::from_secs(60))
            .cloned();
        if let Some(hit) = hit {
            return serde_json::to_value(hit.rows).map_err(|error| error.to_string());
        }
    }
    let rows = tokenstat_sync::forge::list(&repo, scope, state, limit)
        .map_err(|error| error.to_string())?;
    let mut cache = list_cache().lock().unwrap_or_else(PoisonError::into_inner);
    cache.retain(|_, entry| entry.at.elapsed() < Duration::from_secs(60));
    cache.insert(
        key,
        ListEntry {
            at: Instant::now(),
            rows: rows.clone(),
        },
    );
    serde_json::to_value(rows).map_err(|error| error.to_string())
}

fn forge_repo(remote: tokenstat_workspace::git::Remote) -> tokenstat_sync::forge::Repo {
    tokenstat_sync::forge::Repo {
        host: remote.host,
        owner: remote.owner,
        repo: remote.repo,
    }
}

fn host_or_default(host: &str) -> &str {
    if host.trim().is_empty() {
        "github.com"
    } else {
        host
    }
}

fn local_credentials_only() -> Result<(), String> {
    crate::request_context::refuse_remote("pull-request connection settings")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_to_github_without_rewriting_enterprise_hosts() {
        assert_eq!(host_or_default(""), "github.com");
        assert_eq!(host_or_default("git.example.com"), "git.example.com");
    }
}
