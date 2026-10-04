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
    base: String,
    title: String,
    expected_head: String,
    expected_repository: String,
    draft: bool,
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

/// What the forge last said about one branch. `None` is an answer too: the
/// branch has no pull request.
#[derive(Clone)]
struct BranchEntry {
    at: Instant,
    pull: Option<tokenstat_sync::forge::BranchPull>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct BranchKey {
    workspace_id: String,
    branch: String,
    repo: tokenstat_sync::forge::Repo,
}

/// How long `pulls.branch` reuses an answer before asking the forge again.
const BRANCH_TTL: Duration = Duration::from_secs(60);
/// How long a chat list keeps showing what was last learned. Chat lists
/// never ask the forge themselves, so this is all they have, and a badge a
/// few minutes old beats none.
const BRANCH_SHOWN: Duration = Duration::from_secs(15 * 60);

fn branch_cache() -> &'static Mutex<HashMap<BranchKey, BranchEntry>> {
    static CACHE: OnceLock<Mutex<HashMap<BranchKey, BranchEntry>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn forget_branch(workspace_id: &str, branch: &str) {
    branch_cache()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .retain(|key, _| key.workspace_id != workspace_id || key.branch != branch);
}

fn cached_for_repository(key: &BranchKey) -> Option<BranchEntry> {
    let mut cache = branch_cache()
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    // A failed query against a new remote must not leave the old remote's
    // badge in chat lists. Learning the repository is enough to retire it.
    cache.retain(|cached, entry| {
        entry.at.elapsed() < BRANCH_SHOWN
            && (cached.workspace_id != key.workspace_id
                || cached.branch != key.branch
                || cached.repo == key.repo)
    });
    cache
        .get(key)
        .filter(|entry| entry.at.elapsed() < BRANCH_TTL)
        .cloned()
}

fn remember_branch(
    workspace_id: &str,
    branch: &str,
    repo: &tokenstat_sync::forge::Repo,
    pull: Option<tokenstat_sync::forge::BranchPull>,
) {
    let mut cache = branch_cache()
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    cache.retain(|key, entry| {
        entry.at.elapsed() < BRANCH_SHOWN
            && !(key.workspace_id == workspace_id && key.branch == branch)
    });
    cache.insert(
        BranchKey {
            workspace_id: workspace_id.to_string(),
            branch: branch.to_string(),
            repo: repo.clone(),
        },
        BranchEntry {
            at: Instant::now(),
            pull,
        },
    );
}

/// The pull request last seen for a workspace's branch, without a request.
/// Chat lists read this, so a sidebar never makes a forge call of its own.
pub(crate) fn cached_branch_pull(
    workspace_id: &str,
    branch: &str,
) -> Option<tokenstat_sync::forge::BranchPull> {
    branch_cache()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .find(|(key, entry)| {
            key.workspace_id == workspace_id
                && key.branch == branch
                && entry.at.elapsed() < BRANCH_SHOWN
        })
        .and_then(|(_, entry)| entry.pull.clone())
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
    branch_cache()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clear();
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
    branch_cache()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .retain(|key, _| key.workspace_id != workspace_id);
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
        "pulls.branch" => branch(&p),
        "pulls.prepareCreate" => prepare_create(&p),
        "pulls.create" => create(&p),
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

/// The pull request for one branch of a workspace: the named one, or the
/// branch the folder is on. A workspace that is not connected to its forge
/// answers with no pull request rather than an error, because the chips that
/// ask are decoration and must not turn into warnings.
fn branch(p: &Params) -> Result<Value, String> {
    if p.workspace_id.trim().is_empty() {
        return Err("pulls.branch needs workspaceId".into());
    }
    let workspace = crate::workspaces::folder(&p.workspace_id)?;
    let named = p.branch.trim();
    let branch = if named.is_empty() {
        match tokenstat_workspace::git::current_branch(&workspace.path) {
            Some(branch) => branch,
            None => return Ok(json!({"branch": null, "pull": null, "connected": true})),
        }
    } else {
        named.to_string()
    };
    let Some(remote) = tokenstat_workspace::git::remote(&workspace.path) else {
        forget_branch(&p.workspace_id, &branch);
        return Ok(json!({"branch": branch, "pull": null, "connected": false}));
    };
    let repo = forge_repo(remote);
    let key = BranchKey {
        workspace_id: p.workspace_id.clone(),
        branch: branch.clone(),
        repo: repo.clone(),
    };
    let hit = cached_for_repository(&key);
    if !p.refresh
        && let Some(hit) = hit
    {
        return Ok(json!({"branch": branch, "pull": hit.pull, "connected": true}));
    }
    match tokenstat_sync::forge::for_branch(&repo, &branch) {
        Ok(pull) => {
            remember_branch(&p.workspace_id, &branch, &repo, pull.clone());
            Ok(json!({"branch": branch, "pull": pull, "connected": true}))
        }
        Err(tokenstat_sync::forge::ForgeError::NotSignedIn) => {
            forget_branch(&p.workspace_id, &branch);
            Ok(json!({"branch": branch, "pull": null, "connected": false}))
        }
        Err(error) => Err(error.to_string()),
    }
}

fn prepare_create(p: &Params) -> Result<Value, String> {
    let repo = repo_for(&p.workspace_id, "pulls.prepareCreate")?;
    let workspace = crate::workspaces::folder(&p.workspace_id)?;
    let base = tokenstat_sync::forge::default_branch(&repo).map_err(|e| e.to_string())?;
    let status = tokenstat_workspace::git::status(&workspace.path);
    // A Git credential problem is actionable at the push step, and must not
    // hide the pending files or prevent creating a feature branch.
    let (branch, problem) = match tokenstat_workspace::git::pull_branch(&workspace.path) {
        Ok(branch) => (
            serde_json::to_value(branch).map_err(|e| e.to_string())?,
            None,
        ),
        Err(problem) => (
            json!({"branch": status.branch, "head": "", "published": false}),
            Some(problem),
        ),
    };
    Ok(
        json!({"branch": branch["branch"], "head": branch["head"], "published": branch["published"], "repository": repository_key(&repo),
        "defaultBase": base, "files": status.files, "problem": problem}),
    )
}

fn create(p: &Params) -> Result<Value, String> {
    if p.title.trim().is_empty()
        || p.branch.is_empty()
        || p.base.is_empty()
        || p.branch == p.base
        || p.expected_head.is_empty()
    {
        return Err("Add a title and choose different source and target branches before creating the pull request.".into());
    }
    let repo = repo_for(&p.workspace_id, "pulls.create")?;
    if p.expected_repository != repository_key(&repo) {
        return Err("The GitHub repository changed. Check the branch again before creating the pull request.".into());
    }
    let workspace = crate::workspaces::folder(&p.workspace_id)?;
    let branch = tokenstat_workspace::git::pull_branch(&workspace.path)?;
    validate_published_branch(p, &branch)?;
    let result =
        tokenstat_sync::forge::create(&repo, &p.branch, &p.base, &p.title, &p.body, p.draft)
            .map_err(|e| e.to_string())?;
    invalidate_workspace(&p.workspace_id);
    // The chat that asked for it can show its badge straight away. A pull
    // request that already existed is left for the next look, since its
    // title and draft state are its own, not this request's.
    if !result.existing {
        remember_branch(
            &p.workspace_id,
            &p.branch,
            &repo,
            Some(tokenstat_sync::forge::BranchPull {
                number: result.number,
                title: p.title.trim().to_string(),
                url: result.url.clone(),
                state: "open".into(),
                draft: p.draft,
                base_ref: p.base.clone(),
            }),
        );
    }
    serde_json::to_value(result).map_err(|e| e.to_string())
}

fn validate_published_branch(
    p: &Params,
    branch: &tokenstat_workspace::git::PullBranch,
) -> Result<(), String> {
    if branch.branch != p.branch || branch.head != p.expected_head {
        return Err("The branch or commit changed. Check the branch again before creating the pull request.".into());
    }
    if !branch.published {
        return Err("Push the current commit to origin before creating the pull request. Your local work is still here.".into());
    }
    Ok(())
}

fn repository_key(repo: &tokenstat_sync::forge::Repo) -> String {
    format!("{}/{}/{}", repo.host, repo.owner, repo.repo)
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
    fn branch_cache_binds_the_repository_and_supersedes_old_badges() {
        let workspace = "branch-cache-repository-test";
        let repo = tokenstat_sync::forge::Repo {
            host: "github.com".into(),
            owner: "owner".into(),
            repo: "first".into(),
        };
        let changed = tokenstat_sync::forge::Repo {
            repo: "second".into(),
            ..repo.clone()
        };
        remember_branch(
            workspace,
            "feature",
            &repo,
            Some(tokenstat_sync::forge::BranchPull {
                number: 1,
                title: "First".into(),
                url: "https://github.com/owner/first/pull/1".into(),
                state: "open".into(),
                draft: false,
                base_ref: "main".into(),
            }),
        );
        let changed_key = BranchKey {
            workspace_id: workspace.into(),
            branch: "feature".into(),
            repo: changed.clone(),
        };
        assert!(!branch_cache().lock().unwrap().contains_key(&changed_key));
        assert_eq!(cached_branch_pull(workspace, "feature").unwrap().number, 1);
        assert!(cached_for_repository(&changed_key).is_none());
        assert!(cached_branch_pull(workspace, "feature").is_none());
        remember_branch(workspace, "feature", &changed, None);
        assert!(cached_branch_pull(workspace, "feature").is_none());
        invalidate_workspace(workspace);
    }

    #[test]
    fn defaults_to_github_without_rewriting_enterprise_hosts() {
        assert_eq!(host_or_default(""), "github.com");
        assert_eq!(host_or_default("git.example.com"), "git.example.com");
    }

    #[test]
    fn create_refuses_changed_or_unpublished_commits_before_the_forge_write() {
        let params = Params {
            branch: "feature".into(),
            expected_head: "reviewed-commit".into(),
            ..Default::default()
        };
        let mut branch = tokenstat_workspace::git::PullBranch {
            branch: "feature".into(),
            head: "reviewed-commit".into(),
            published: true,
        };
        assert!(validate_published_branch(&params, &branch).is_ok());
        branch.head = "newer-commit".into();
        assert!(
            validate_published_branch(&params, &branch)
                .unwrap_err()
                .contains("changed")
        );
        branch.head = params.expected_head.clone();
        branch.branch = "another-branch".into();
        assert!(
            validate_published_branch(&params, &branch)
                .unwrap_err()
                .contains("changed")
        );
        branch.branch = params.branch.clone();
        branch.published = false;
        assert!(
            validate_published_branch(&params, &branch)
                .unwrap_err()
                .contains("Push")
        );
    }
}
