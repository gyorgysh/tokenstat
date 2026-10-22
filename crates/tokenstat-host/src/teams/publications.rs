// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Host-private bindings between opaque Team references and physical folders.
//! Prepared entries never authorize reads. Withdrawal is durable locally
//! before contacting the account server, so a network outage cannot keep a
//! revoked local publication readable.

use crate::{chat_receipts::OwnerLease, error::DispatchError};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
};

const MAX_BYTES: u64 = 16 * 1024 * 1024;
const MAX_CHECKOUTS: usize = 4096;
mod chats;
pub(super) use chats::{ChatShare, ChatTarget};
#[cfg(test)]
mod tests;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Owner {
    pub issuer: String,
    pub publisher_id: String,
    pub host_key: String,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Folder {
    pub canonical: PathBuf,
    volume: u64,
    file: [u8; 16],
    #[serde(default)]
    created: Option<(u64, u32)>,
}
impl Folder {
    pub(super) fn capture(path: &Path) -> Result<Self, DispatchError> {
        let canonical = path.canonicalize().map_err(|_| {
            unavailable(
                "checkout_missing",
                "This checkout is missing. Choose its folder again.",
            )
        })?;
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.custom_flags(0x02000000); // FILE_FLAG_BACKUP_SEMANTICS opens a directory.
        }
        let file = options.open(&canonical).map_err(|_| {
            unavailable(
                "checkout_missing",
                "This checkout is unavailable. Check its folder.",
            )
        })?;
        if !file.metadata().is_ok_and(|metadata| metadata.is_dir()) {
            return Err(unavailable(
                "checkout_missing",
                "Choose a folder for this checkout.",
            ));
        }
        #[cfg(unix)]
        let identity = {
            use std::os::unix::fs::MetadataExt;
            let metadata = file.metadata().map_err(|_| storage())?;
            let mut id = [0; 16];
            id[..8].copy_from_slice(&metadata.ino().to_be_bytes());
            (metadata.dev(), id)
        };
        #[cfg(windows)]
        let identity = crate::win32::file_identity(&file).ok_or_else(storage)?;
        #[cfg(not(any(unix, windows)))]
        return Err(storage());
        let created = file
            .metadata()
            .ok()
            .and_then(|metadata| metadata.created().ok())
            .and_then(|created| created.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|duration| (duration.as_secs(), duration.subsec_nanos()));
        Ok(Self {
            canonical,
            volume: identity.0,
            file: identity.1,
            created,
        })
    }
    pub(super) fn ensure_current(&self) -> Result<(), DispatchError> {
        if Self::capture(&self.canonical)? != *self {
            return Err(unavailable(
                "checkout_changed",
                "This checkout was replaced. Share its current folder again.",
            ));
        }
        Ok(())
    }
    fn physical_match(&self, other: &Self) -> bool {
        self.volume == other.volume && self.file == other.file && self.created == other.created
    }
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) enum Phase {
    Prepared,
    Active,
    Withdrawn,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Checkout {
    pub id: String,
    pub owner: Owner,
    pub organization_id: String,
    pub repository_id: String,
    pub workspace_id: String,
    pub folder: Folder,
    pub phase: Phase,
    pub request_id: String,
    pub revision: u64,
    pub cloud_revision: Option<u64>,
    #[serde(default)]
    pub cloud_withdrawn: bool,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Index {
    version: u32,
    checkouts: Vec<Checkout>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    chats: Vec<ChatShare>,
}
impl Default for Index {
    fn default() -> Self {
        Self {
            version: 1,
            checkouts: Vec::new(),
            chats: Vec::new(),
        }
    }
}

pub(super) struct Store {
    root: PathBuf,
}
impl Store {
    pub(super) fn capture() -> Result<Self, DispatchError> {
        Ok(Self {
            root: tokenstat_paths::data_dir()
                .ok_or_else(storage)?
                .join("team-publications"),
        })
    }
    pub(super) fn prepare(
        &self,
        owner: &Owner,
        organization: &str,
        repository: &str,
        workspace: &str,
        folder: &Folder,
        request: &str,
    ) -> Result<Checkout, DispatchError> {
        if !identifier(organization)
            || !identifier(repository)
            || !crate::chat_receipts::valid_id(request)
            || workspace.is_empty()
            || workspace.len() > 16 * 1024
        {
            return Err(unavailable(
                "invalid_request",
                "Choose a repository and checkout, then review sharing again.",
            ));
        }
        folder.ensure_current()?;
        self.transaction(|index| {
            if let Some(existing) = index.checkouts.iter().find(|row| row.owner == *owner && row.request_id == request) {
                if existing.organization_id != organization || existing.repository_id != repository || existing.workspace_id != workspace || existing.folder != *folder || existing.phase == Phase::Withdrawn {
                    return Err(unavailable("publication_conflict", "This sharing request changed or was withdrawn. Review a new request."));
                }
                return Ok(existing.clone());
            }
            if let Some(existing) = index.checkouts.iter().find(|row| row.phase != Phase::Withdrawn && row.folder.physical_match(folder)) {
                if existing.owner != *owner || existing.organization_id != organization || existing.repository_id != repository || existing.folder.canonical != folder.canonical {
                    return Err(unavailable("checkout_already_shared", "This folder already has a Team publication. Stop its current sharing before linking it elsewhere."));
                }
                return Ok(existing.clone());
            }
            if index.checkouts.len() >= MAX_CHECKOUTS { return Err(unavailable("publication_limit", "Sharing records on this computer have reached their limit.")); }
            let row = Checkout { id: opaque("checkout"), owner: owner.clone(), organization_id: organization.into(), repository_id: repository.into(), workspace_id: workspace.into(), folder: folder.clone(), phase: Phase::Prepared, request_id: request.into(), revision: 1, cloud_revision: None, cloud_withdrawn: false };
            index.checkouts.push(row.clone()); Ok(row)
        })
    }
    pub(super) fn activate(
        &self,
        owner: &Owner,
        id: &str,
        expected: u64,
        cloud_revision: u64,
    ) -> Result<Checkout, DispatchError> {
        if cloud_revision == 0 || cloud_revision > 9_007_199_254_740_991 {
            return Err(storage());
        }
        // Inspect the folder outside the index lock. A slow or disconnected
        // volume must not hold up revocation of another checkout.
        let folder = self.read(|index| {
            index
                .checkouts
                .iter()
                .find(|row| row.id == id && row.owner == *owner)
                .map(|row| row.folder.clone())
                .ok_or_else(not_shared)
        })?;
        folder.ensure_current()?;
        self.transaction(|index| {
            let row = owned(index, owner, id)?;
            if row.folder != folder {
                return Err(changed());
            }
            if row.phase == Phase::Active
                && (row.revision == expected || expected.checked_add(1) == Some(row.revision))
            {
                return Ok(row.clone());
            }
            if row.phase != Phase::Prepared || row.revision != expected {
                return Err(changed());
            }
            row.phase = Phase::Active;
            row.cloud_revision = Some(cloud_revision);
            row.revision = next_revision(row.revision)?;
            Ok(row.clone())
        })
    }
    pub(super) fn withdraw(
        &self,
        owner: &Owner,
        id: &str,
        expected: u64,
    ) -> Result<Checkout, DispatchError> {
        self.transaction(|index| {
            let row = owned(index, owner, id)?;
            if row.phase == Phase::Withdrawn {
                return Ok(row.clone());
            }
            if row.revision != expected {
                return Err(changed());
            }
            row.phase = Phase::Withdrawn;
            row.revision = next_revision(row.revision)?;
            Ok(row.clone())
        })
    }
    pub(super) fn list(&self, owner: &Owner) -> Result<Vec<Checkout>, DispatchError> {
        self.read(|index| {
            Ok(index
                .checkouts
                .iter()
                .filter(|row| row.owner == *owner)
                .cloned()
                .collect())
        })
    }
    /// Every active publication of a repository on this computer, whoever
    /// published it. Used to catch up after a teammate landed work.
    pub(super) fn active_for_repository(
        &self,
        repository: &str,
    ) -> Result<Vec<Checkout>, DispatchError> {
        self.read(|index| {
            Ok(index
                .checkouts
                .iter()
                .filter(|row| row.repository_id == repository && row.phase == Phase::Active)
                .cloned()
                .collect())
        })
    }
    /// The principal's own publication, with its folder unchanged on this
    /// computer. Every Team read or action on a checkout passes this first.
    pub(super) fn current_for(
        principal: &super::AuthorizedTeamPrincipal,
    ) -> Result<Checkout, DispatchError> {
        let scope = principal.value();
        let owner = Owner {
            issuer: principal.issuer().into(),
            publisher_id: scope.publisher_id.clone(),
            host_key: scope.host_key.clone(),
        };
        let row = Self::capture()?.resolve(
            &owner,
            &scope.organization_id,
            &scope.repository_id,
            &scope.checkout_id,
        )?;
        let workspace = crate::workspaces::get(&row.workspace_id).map_err(|_| {
            DispatchError::new(
                "checkout_not_shared",
                "This checkout is no longer registered on this computer.",
            )
        })?;
        if Folder::capture(&workspace.path)? != row.folder {
            return Err(DispatchError::new(
                "checkout_changed",
                "This checkout changed. Ask its publisher to review sharing.",
            ));
        }
        Ok(row)
    }
    pub(super) fn has_active_key(&self, key: &str) -> Result<bool, DispatchError> {
        if !self
            .root
            .join("index.json")
            .try_exists()
            .map_err(|_| storage())?
        {
            return Ok(false);
        }
        self.read(|index| {
            Ok(index
                .checkouts
                .iter()
                .any(|row| row.phase == Phase::Active && row.owner.host_key == key))
        })
    }
    pub(super) fn has_active(&self, owner: &Owner) -> Result<bool, DispatchError> {
        if !self
            .root
            .join("index.json")
            .try_exists()
            .map_err(|_| storage())?
        {
            return Ok(false);
        }
        self.read(|index| {
            Ok(index
                .checkouts
                .iter()
                .any(|row| row.phase == Phase::Active && &row.owner == owner))
        })
    }
    pub(super) fn confirm_cloud_withdrawal(
        &self,
        owner: &Owner,
        id: &str,
    ) -> Result<(), DispatchError> {
        self.transaction(|index| {
            let row = owned(index, owner, id)?;
            if row.phase != Phase::Withdrawn {
                return Err(changed());
            }
            if !row.cloud_withdrawn {
                row.cloud_withdrawn = true;
                row.revision = next_revision(row.revision)?;
            }
            Ok(())
        })
    }
    pub(super) fn resolve(
        &self,
        owner: &Owner,
        organization: &str,
        repository: &str,
        id: &str,
    ) -> Result<Checkout, DispatchError> {
        let row = self.read(|index| {
            let row = index
                .checkouts
                .iter()
                .find(|row| row.id == id && row.owner == *owner)
                .ok_or_else(not_shared)?;
            if row.organization_id != organization
                || row.repository_id != repository
                || row.phase != Phase::Active
            {
                return Err(not_shared());
            }
            Ok(row.clone())
        })?;
        row.folder.ensure_current()?;
        Ok(row)
    }
    fn transaction<T>(
        &self,
        operation: impl FnOnce(&mut Index) -> Result<T, DispatchError>,
    ) -> Result<T, DispatchError> {
        self.with_index(|cached| {
            let mut working = cached.index.clone();
            let result = operation(&mut working)?;
            if working != cached.index {
                let path = self.root.join("index.json");
                save(&self.root, &path, &working)?;
                initialized(&self.root)?;
                cached.path = None;
            }
            Ok(result)
        })
    }
    fn read<T>(
        &self,
        operation: impl FnOnce(&Index) -> Result<T, DispatchError>,
    ) -> Result<T, DispatchError> {
        self.with_index(|cached| operation(&cached.index))
    }
    fn with_index<T>(
        &self,
        operation: impl FnOnce(&mut Cached) -> Result<T, DispatchError>,
    ) -> Result<T, DispatchError> {
        // Metadata reads are frequent. Parse the private index only when its
        // file identity changes, including replacement by another process.
        static CACHE: OnceLock<Mutex<Cached>> = OnceLock::new();
        let mut cached = CACHE
            .get_or_init(|| Mutex::new(Cached::default()))
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        private_directory(&self.root)?;
        let _lease = OwnerLease::try_acquire(&self.root.join("index.lock"))
            .map_err(|_| storage())?
            .ok_or_else(|| {
                unavailable(
                    "sharing_busy",
                    "Another sharing change is being saved. Try again shortly.",
                )
            })?;
        let path = self.root.join("index.json");
        let stamp = stamp(&path)?;
        if stamp.is_none() && fs::symlink_metadata(self.root.join("initialized")).is_ok() {
            return Err(storage());
        }
        if cached.path.as_ref() != Some(&path) || cached.stamp != stamp {
            let index = load(&path)?;
            if stamp.is_some() {
                initialized(&self.root)?;
            }
            *cached = Cached {
                path: Some(path),
                stamp,
                index,
            };
        }
        operation(&mut cached)
    }
}
#[derive(Default)]
struct Cached {
    path: Option<PathBuf>,
    stamp: Option<Stamp>,
    index: Index,
}
#[derive(PartialEq, Eq)]
struct Stamp {
    volume: u64,
    file: [u8; 16],
    size: u64,
    modified: Option<std::time::SystemTime>,
    changed: [i64; 2],
}
fn stamp(path: &Path) -> Result<Option<Stamp>, DispatchError> {
    let file = match private_options().read(true).open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(storage()),
    };
    let metadata = file.metadata().map_err(|_| storage())?;
    if !metadata.is_file() || metadata.len() > MAX_BYTES {
        return Err(storage());
    }
    #[cfg(unix)]
    let (volume, identity, changed) = {
        use std::os::unix::fs::MetadataExt;
        let mut identity = [0; 16];
        identity[..8].copy_from_slice(&metadata.ino().to_be_bytes());
        (
            metadata.dev(),
            identity,
            [metadata.ctime(), metadata.ctime_nsec()],
        )
    };
    #[cfg(windows)]
    let (volume, identity, changed) = {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(storage());
        }
        let (volume, identity) = crate::win32::file_identity(&file).ok_or_else(storage)?;
        (
            volume,
            identity,
            [
                metadata.creation_time() as i64,
                metadata.last_write_time() as i64,
            ],
        )
    };
    #[cfg(not(any(unix, windows)))]
    return Err(storage());
    Ok(Some(Stamp {
        volume,
        file: identity,
        size: metadata.len(),
        modified: metadata.modified().ok(),
        changed,
    }))
}
fn initialized(root: &Path) -> Result<(), DispatchError> {
    let path = root.join("initialized");
    match private_options().write(true).create_new(true).open(&path) {
        Ok(mut file) => {
            file.write_all(b"1\n")
                .and_then(|()| file.sync_all())
                .map_err(|_| storage())?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            let metadata = fs::symlink_metadata(&path).map_err(|_| storage())?;
            if !metadata.is_file() || metadata.file_type().is_symlink() {
                return Err(storage());
            }
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if metadata.file_attributes() & 0x400 != 0 {
                    return Err(storage());
                }
            }
            return Ok(());
        }
        Err(_) => return Err(storage()),
    }
    #[cfg(unix)]
    std::fs::File::open(root)
        .and_then(|folder| folder.sync_all())
        .map_err(|_| storage())?;
    Ok(())
}
fn owned<'a>(
    index: &'a mut Index,
    owner: &Owner,
    id: &str,
) -> Result<&'a mut Checkout, DispatchError> {
    index
        .checkouts
        .iter_mut()
        .find(|row| row.id == id && row.owner == *owner)
        .ok_or_else(not_shared)
}
pub(super) fn opaque(prefix: &str) -> String {
    format!("{prefix}_{:032x}", rand::random::<u128>())
}
fn identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}
fn next_revision(value: u64) -> Result<u64, DispatchError> {
    value
        .checked_add(1)
        .filter(|value| *value <= 9_007_199_254_740_991)
        .ok_or_else(storage)
}
fn unavailable(code: &str, message: &str) -> DispatchError {
    DispatchError::new(code, message)
}
fn storage() -> DispatchError {
    unavailable(
        "sharing_storage_unavailable",
        "Sharing records could not be read or saved. Existing local files were kept.",
    )
}
fn not_shared() -> DispatchError {
    unavailable(
        "checkout_not_shared",
        "This checkout is not shared from this computer.",
    )
}
fn changed() -> DispatchError {
    unavailable(
        "publication_changed",
        "Sharing changed since you opened it. Review the current checkout and try again.",
    )
}
fn private_directory(path: &Path) -> Result<(), DispatchError> {
    let parent = path.parent().ok_or_else(storage)?;
    fs::create_dir_all(parent).map_err(|_| storage())?;
    match fs::create_dir(path) {
        Ok(()) => {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(path, fs::Permissions::from_mode(0o700))
                    .map_err(|_| storage())?;
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(_) => return Err(storage()),
    }
    let metadata = fs::symlink_metadata(path).map_err(|_| storage())?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(storage());
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(storage());
        }
    }
    Ok(())
}
fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000);
    } // OPEN_REPARSE_POINT.
    options
}
fn load(path: &Path) -> Result<Index, DispatchError> {
    let file = match private_options().read(true).open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Index::default()),
        Err(_) => return Err(storage()),
    };
    let metadata = file.metadata().map_err(|_| storage())?;
    if !metadata.is_file() || metadata.len() > MAX_BYTES {
        return Err(storage());
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(storage());
        }
    }
    let mut body = Vec::new();
    file.take(MAX_BYTES + 1)
        .read_to_end(&mut body)
        .map_err(|_| storage())?;
    if body.len() as u64 > MAX_BYTES {
        return Err(storage());
    }
    let index: Index = serde_json::from_slice(&body).map_err(|_| storage())?;
    let mut references = std::collections::HashSet::new();
    if index.version != 1
        || index.checkouts.len() > MAX_CHECKOUTS
        || index.checkouts.iter().any(|row| {
            !references.insert(row.id.as_str())
                || !row.id.strip_prefix("checkout_").is_some_and(|id| {
                    id.len() == 32 && id.bytes().all(|byte| byte.is_ascii_hexdigit())
                })
                || !identifier(&row.organization_id)
                || !identifier(&row.repository_id)
                || !identifier(&row.owner.publisher_id)
                || row.owner.issuer.is_empty()
                || row.owner.issuer.len() > 2048
                || row.owner.issuer.chars().any(char::is_control)
                || row.owner.host_key.len() != 64
                || !row
                    .owner
                    .host_key
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit())
                || row.workspace_id.is_empty()
                || row.workspace_id.len() > 16 * 1024
                || !crate::chat_receipts::valid_id(&row.request_id)
                || !row.folder.canonical.is_absolute()
                || row
                    .folder
                    .created
                    .is_some_and(|(_, nanos)| nanos >= 1_000_000_000)
                || row.revision == 0
                || row.revision > 9_007_199_254_740_991
                || row
                    .cloud_revision
                    .is_some_and(|revision| revision == 0 || revision > 9_007_199_254_740_991)
                || row.cloud_withdrawn && row.phase != Phase::Withdrawn
                || row.phase == Phase::Active
                    && row.cloud_revision.is_none_or(|revision| revision == 0)
        })
    {
        return Err(storage());
    }
    chats::validate(&index)?;
    Ok(index)
}
fn save(root: &Path, destination: &Path, index: &Index) -> Result<(), DispatchError> {
    let bytes = serde_json::to_vec(index).map_err(|_| storage())?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(storage());
    }
    let mut temporary = tempfile::Builder::new()
        .prefix(".publication-")
        .tempfile_in(root)
        .map_err(|_| storage())?;
    temporary
        .write_all(&bytes)
        .and_then(|()| temporary.as_file().sync_all())
        .map_err(|_| storage())?;
    for attempt in 0..=50 {
        match temporary.persist(destination) {
            Ok(_) => {
                #[cfg(unix)]
                std::fs::File::open(root)
                    .and_then(|folder| folder.sync_all())
                    .map_err(|_| storage())?;
                return Ok(());
            }
            Err(error)
                if cfg!(windows)
                    && error.error.kind() == std::io::ErrorKind::PermissionDenied
                    && attempt < 50 =>
            {
                temporary = error.file;
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            Err(_) => return Err(storage()),
        }
    }
    Err(storage())
}
