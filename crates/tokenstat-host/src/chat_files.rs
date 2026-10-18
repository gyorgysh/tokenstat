// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Bounded, resumable attachment transfers. All bytes stay in chat storage.
use super::*;
use sha2::{Digest, Sha256};
use std::io::{Read, Seek, SeekFrom};

pub const CHUNK_BYTES: usize = 512 * 1024;
pub const FILE_BYTES: u64 = 256 * 1024 * 1024;
pub const RELAY_FILE_BYTES: u64 = 64 * 1024 * 1024;
const CHAT_BYTES: u64 = 2 * 1024 * 1024 * 1024;
const STAGING_BYTES: u64 = 1024 * 1024 * 1024;
const TTL_MS: i64 = 24 * 60 * 60 * 1000;

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Upload {
    attachment: Attachment,
    owner: String,
    peer: Option<String>,
    offset: u64,
    touched_at_ms: i64,
    sha256: String,
    finished: bool,
}

fn regular(path: &Path) -> Result<(), String> {
    let meta = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if !meta.is_file() {
        return Err("invalid attachment file".into());
    }
    Ok(())
}
fn directory(path: &Path) -> Result<(), String> {
    let meta = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if !meta.is_dir() {
        return Err("invalid attachment directory".into());
    }
    Ok(())
}
pub(super) fn open_regular(path: &Path) -> Result<fs::File, String> {
    regular(path)?;
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000); // FILE_FLAG_OPEN_REPARSE_POINT
    }
    let file = options.open(path).map_err(|e| e.to_string())?;
    // Validate the opened object too: the pathname can change after regular().
    // In particular, a no-follow Windows handle can name a reparse point.
    let metadata = file.metadata().map_err(|e| e.to_string())?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err("invalid attachment file".into());
    }
    Ok(file)
}
pub(super) fn create_attachment_directory(chat: &Path, id: &str) -> Result<(), String> {
    let files = chat.join("files");
    fs::create_dir_all(&files).map_err(|e| e.to_string())?;
    directory(&files)?;
    let parent = files.join(id);
    fs::create_dir_all(&parent).map_err(|e| e.to_string())?;
    directory(&parent)
}
fn hash_file(path: &Path) -> Result<String, String> {
    regular(path)?;
    let mut file = open_regular(path)?;
    let mut buffer = vec![0; CHUNK_BYTES];
    let mut hash = Sha256::new();
    let expected = file.metadata().map_err(|e| e.to_string())?.len();
    if expected > FILE_BYTES {
        return Err("file exceeds transfer limit".into());
    }
    let mut total = 0u64;
    loop {
        let count = file.read(&mut buffer).map_err(|e| e.to_string())?;
        if count == 0 {
            break;
        }
        total += count as u64;
        if total > FILE_BYTES {
            return Err("file exceeds transfer limit".into());
        }
        hash.update(&buffer[..count]);
    }
    if total != expected {
        return Err("the file changed while reading".into());
    }
    Ok(hash
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}
pub(super) fn copy_attachment(source: &Path, destination: &Path) -> Result<u64, String> {
    copy_open_attachment(open_regular(source)?, destination)
}

/// Keep an already validated image handle alive through publication. A tool
/// can remove or replace its temporary pathname as soon as it reports success.
pub(super) fn copy_open_attachment(mut input: fs::File, destination: &Path) -> Result<u64, String> {
    let metadata = input.metadata().map_err(|e| e.to_string())?;
    if !metadata.is_file() {
        return Err("invalid attachment file".into());
    }
    let expected = metadata.len();
    if expected == 0 || expected > FILE_BYTES {
        return Err("file exceeds transfer limit".into());
    }
    input.rewind().map_err(|e| e.to_string())?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut output = options.open(destination).map_err(|e| e.to_string())?;
    let result =
        std::io::copy(&mut input.take(FILE_BYTES + 1), &mut output).map_err(|e| e.to_string());
    match result {
        Ok(count) if count == expected && count <= FILE_BYTES => {
            if let Err(error) = output.sync_all() {
                drop(output);
                let _ = fs::remove_file(destination);
                return Err(error.to_string());
            }
            Ok(count)
        }
        _ => {
            drop(output);
            let _ = fs::remove_file(destination);
            Err("the file changed while copying".into())
        }
    }
}

fn save_upload(path: &Path, upload: &Upload) -> Result<(), String> {
    let temporary = path.with_extension(format!("{}.tmp", rand::random::<u64>()));
    let result = (|| {
        write_private_file(
            &temporary,
            &serde_json::to_vec(upload).map_err(|e| e.to_string())?,
        )?;
        // FlushFileBuffers on Windows requires a writable handle.
        OpenOptions::new()
            .write(true)
            .open(&temporary)
            .and_then(|file| file.sync_all())
            .map_err(|e| e.to_string())?;
        fs::rename(&temporary, path).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            fs::File::open(path.parent().ok_or("invalid file transfer path")?)
                .and_then(|dir| dir.sync_all())
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    })();
    let _ = fs::remove_file(temporary);
    result
}
fn remove_partial(path: &Path) -> Result<(), String> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.to_string()),
    }
}

fn stored_bytes(chat: &Path) -> Result<u64, String> {
    let files = chat.join("files");
    if !files.exists() {
        return Ok(0);
    }
    directory(&files)?;
    let mut bytes = 0u64;
    let mut count = 0usize;
    for folder in fs::read_dir(&files).map_err(|e| e.to_string())? {
        let folder = folder.map_err(|e| e.to_string())?.path();
        count += 1;
        if count > 4096 {
            return Err("this conversation has too many files".into());
        }
        directory(&folder)?;
        for file in fs::read_dir(&folder).map_err(|e| e.to_string())? {
            let file = file.map_err(|e| e.to_string())?.path();
            regular(&file)?;
            count += 1;
            if count > 4096 {
                return Err("this conversation has too many files".into());
            }
            bytes = bytes.saturating_add(fs::metadata(file).map_err(|e| e.to_string())?.len());
        }
    }
    Ok(bytes)
}

pub(super) fn ensure_storage(chat: &Path, size: u64) -> Result<(), String> {
    if stored_bytes(chat)?.saturating_add(size) > CHAT_BYTES {
        return Err("This conversation has reached its 2 GB file budget. Start a new chat or remove unused files.".into());
    }
    Ok(())
}

fn file_cap() -> u64 {
    if crate::request_context::is_relay() {
        RELAY_FILE_BYTES
    } else {
        FILE_BYTES
    }
}
fn consent(allow_relay: bool) -> Result<(), DispatchError> {
    crate::workspace_policy::require_current_access()?;
    crate::account_session::check_current()?;
    if crate::request_context::is_relay() && !allow_relay {
        return Err(DispatchError::new(
            "relay_consent_required",
            "This file uses your relay allowance. Confirm the transfer to continue.",
        ));
    }
    Ok(())
}

impl Store {
    pub fn file_capabilities(&self, id: &str) -> Result<Value, String> {
        self.get(id)?;
        Ok(
            json!({"chunkBytes":CHUNK_BYTES,"maxFileBytes":file_cap(),"directMaxFileBytes":FILE_BYTES,
            "relayMaxFileBytes":RELAY_FILE_BYTES,"relay":crate::request_context::is_relay(),
            "maxChatBytes":CHAT_BYTES,"maxUploads":4,"maxAttachments":20,"integrity":"sha256","types":"any","nativeImages":["png","jpeg","gif","webp"]}),
        )
    }
    fn upload_directory(&self, id: &str) -> Result<PathBuf, String> {
        let chat = self.verified_append_directory(id)?;
        // New chats exist in the index before their first turn creates a
        // transcript. Attachments must be able to initialize storage first.
        // The caller holds the lifecycle lock and verification above refuses
        // conversations removed from the persisted index.
        fs::create_dir_all(&chat).map_err(|e| e.to_string())?;
        directory(&chat)?;
        let path = chat.join("transfers");
        fs::create_dir_all(&path).map_err(|e| e.to_string())?;
        directory(&path)?;
        Ok(path)
    }
    fn upload_load(&self, id: &str, transfer: &str) -> Result<(PathBuf, Upload), String> {
        validate_record_id(transfer)?;
        let root = self.upload_directory(id)?;
        let path = root.join(format!("{transfer}.json"));
        regular(&path)?;
        if fs::metadata(&path).map_err(|e| e.to_string())?.len() > 8192 {
            return Err("invalid file transfer".into());
        }
        let upload: Upload = serde_json::from_slice(&read_fork_file(&path, 8192, false)?)
            .map_err(|e| e.to_string())?;
        if upload.owner != self.router_owner()?
            || upload.peer != crate::request_context::remote_peer()
        {
            return Err("the file transfer belongs to another account or device".into());
        }
        if now_ms().saturating_sub(upload.touched_at_ms) > TTL_MS {
            return Err("the file transfer expired; choose the file again".into());
        }
        Ok((path, upload))
    }
    pub fn file_upload_start(
        &self,
        id: &str,
        name: &str,
        size: u64,
        sha256: &str,
        media_type: Option<String>,
    ) -> Result<Value, String> {
        crate::workspace_policy::require_current_access().map_err(|e| e.to_string())?;
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        if size == 0 || size > file_cap() {
            return Err(format!(
                "Choose a non-empty file up to {} MB.",
                file_cap() / 1048576
            ));
        }
        if sha256.len() != 64 || !sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("file SHA-256 is required".into());
        }
        if name.len() > 512 || media_type.as_ref().is_some_and(|m| m.len() > 128) {
            return Err("invalid file metadata".into());
        }
        let root = self.upload_directory(id)?;
        let owner = self.router_owner()?;
        let peer = crate::request_context::remote_peer();
        let name = safe_file_name(name);
        let mut matching = None;
        let mut reserved = 0u64;
        let mut active = 0usize;
        // Expired incomplete uploads never consume a permanent staging budget.
        for (index, entry) in fs::read_dir(&root).map_err(|e| e.to_string())?.enumerate() {
            if index >= 4096 {
                return Err("this conversation has too many transfer records".into());
            }
            let entry = entry.map_err(|e| e.to_string())?;
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            regular(&path)?;
            if fs::metadata(&path).map_err(|e| e.to_string())?.len() > 8192 {
                return Err("invalid file transfer".into());
            }
            if let Ok(upload) =
                serde_json::from_slice::<Upload>(&read_fork_file(&path, 8192, false)?)
            {
                if now_ms().saturating_sub(upload.touched_at_ms) > TTL_MS {
                    remove_partial(&path.with_extension("part"))?;
                    fs::remove_file(path).map_err(|e| e.to_string())?;
                } else if !upload.finished {
                    if upload.owner == owner
                        && upload.peer == peer
                        && upload.attachment.name == name
                        && upload.attachment.size == Some(size)
                        && upload.attachment.media_type == media_type
                        && upload.sha256.eq_ignore_ascii_case(sha256)
                    {
                        matching = path
                            .file_stem()
                            .and_then(|s| s.to_str())
                            .map(|s| (s.to_owned(), upload.offset));
                    }
                    active += 1;
                    reserved =
                        reserved.saturating_add(upload.attachment.size.unwrap_or(FILE_BYTES));
                }
            }
        }
        // A lost start acknowledgement must not consume another reservation.
        if let Some((transfer, offset)) = matching {
            return Ok(json!({"transferId":transfer,"offset":offset,"chunkBytes":CHUNK_BYTES}));
        }
        if active >= 4
            || reserved.saturating_add(size) > STAGING_BYTES
            || stored_bytes(&self.verified_append_directory(id)?)?
                .saturating_add(reserved)
                .saturating_add(size)
                > CHAT_BYTES
        {
            return Err("Finish or cancel another file transfer first.".into());
        }
        let transfer = mint_record_id("transfer");
        let upload = Upload {
            attachment: Attachment {
                id: mint_record_id("file"),
                name,
                size: Some(size),
                media_type,
            },
            owner,
            peer,
            offset: 0,
            touched_at_ms: now_ms(),
            sha256: sha256.to_ascii_lowercase(),
            finished: false,
        };
        let path = root.join(format!("{transfer}.json"));
        write_private_file(&path.with_extension("part"), &[])?;
        if let Err(error) = save_upload(&path, &upload) {
            let _ = fs::remove_file(path.with_extension("part"));
            return Err(error);
        }
        Ok(json!({"transferId":transfer,"offset":0,"chunkBytes":CHUNK_BYTES}))
    }
    pub fn file_upload_status(&self, id: &str, transfer: &str) -> Result<Value, String> {
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        let (_, upload) = self.upload_load(id, transfer)?;
        if upload.finished {
            self.single_attachment_path(id, &upload.attachment.id)?;
        }
        Ok(
            json!({"transferId":transfer,"offset":upload.offset,"finished":upload.finished,"attachment":if upload.finished {Some(upload.attachment)} else {None}}),
        )
    }
    pub fn file_upload_chunk(
        &self,
        id: &str,
        transfer: &str,
        offset: u64,
        data: &str,
        allow_relay: bool,
    ) -> Result<Value, DispatchError> {
        consent(allow_relay)?;
        if data.len() > CHUNK_BYTES.div_ceil(3) * 4 {
            return Err("file chunk is too large".into());
        }
        let bytes = crate::base64::decode(data)?;
        if bytes.is_empty() || bytes.len() > CHUNK_BYTES {
            return Err("invalid file chunk".into());
        }
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        let (path, mut upload) = self.upload_load(id, transfer)?;
        if upload.finished {
            return Err("this file transfer is already complete".into());
        }
        if upload.attachment.size.unwrap_or(u64::MAX) > file_cap() {
            return Err("this file exceeds the current connection limit".into());
        }
        let end = offset
            .checked_add(bytes.len() as u64)
            .ok_or("invalid file offset")?;
        if end > upload.attachment.size.unwrap_or(0) || offset > upload.offset {
            return Err("invalid file offset; resume from the confirmed offset".into());
        }
        let part = path.with_extension("part");
        regular(&part)?;
        let mut options = OpenOptions::new();
        options.read(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
        }
        let mut file = options.open(&part).map_err(|e| e.to_string())?;
        if offset < upload.offset {
            if end > upload.offset {
                return Err("overlapping file chunk".into());
            }
            file.seek(SeekFrom::Start(offset))
                .map_err(|e| e.to_string())?;
            let mut previous = vec![0; bytes.len()];
            file.read_exact(&mut previous).map_err(|e| e.to_string())?;
            if previous != bytes {
                return Err("the repeated file chunk changed".into());
            }
        } else {
            // Bytes beyond the durable offset can be left by an interrupted save.
            file.set_len(upload.offset).map_err(|e| e.to_string())?;
            file.seek(SeekFrom::Start(offset))
                .map_err(|e| e.to_string())?;
            file.write_all(&bytes).map_err(|e| e.to_string())?;
            file.sync_all().map_err(|e| e.to_string())?;
            upload.offset = end;
        }
        upload.touched_at_ms = now_ms();
        consent(allow_relay)?;
        save_upload(&path, &upload)?;
        Ok(json!({"offset":upload.offset}))
    }
    pub fn file_upload_finish(&self, id: &str, transfer: &str) -> Result<Attachment, String> {
        crate::workspace_policy::require_current_access().map_err(|e| e.to_string())?;
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        let (path, mut upload) = self.upload_load(id, transfer)?;
        if upload.finished {
            self.single_attachment_path(id, &upload.attachment.id)?;
            return Ok(upload.attachment);
        }
        if upload.offset != upload.attachment.size.unwrap_or(0) {
            return Err("the file transfer is incomplete".into());
        }
        let destination = self.attachment_path(id, &upload.attachment.id, &upload.attachment.name);
        let part = path.with_extension("part");
        // A helper can die after rename, before recording completion.
        let source = if part.exists() { &part } else { &destination };
        if hash_file(source)? != upload.sha256 {
            return Err("file integrity check failed; choose the file again".into());
        }
        self.router_owner().and_then(|owner| {
            if owner == upload.owner {
                Ok(())
            } else {
                Err("the file transfer account changed".into())
            }
        })?;
        if source == &part {
            ensure_storage(&self.verified_append_directory(id)?, upload.offset)?;
            create_attachment_directory(
                &self.verified_append_directory(id)?,
                &upload.attachment.id,
            )?;
            fs::rename(&part, &destination).map_err(|e| e.to_string())?;
        }
        crate::workspace_policy::require_current_access().map_err(|e| e.to_string())?;
        crate::account_session::check_current()?;
        upload.finished = true;
        upload.touched_at_ms = now_ms();
        save_upload(&path, &upload)?;
        Ok(upload.attachment)
    }
    pub fn file_upload_cancel(&self, id: &str, transfer: &str) -> Result<Value, String> {
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        let (path, upload) = self.upload_load(id, transfer)?;
        if !upload.finished {
            remove_partial(&path.with_extension("part"))?;
        }
        fs::remove_file(path).map_err(|e| e.to_string())?;
        Ok(json!({"cancelled":true}))
    }
    pub fn file_download_info(&self, id: &str, attachment: &str) -> Result<Value, String> {
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        self.get(id)?;
        let path = self.single_attachment_path(id, attachment)?;
        let size = fs::metadata(&path).map_err(|e| e.to_string())?.len();
        if size == 0 || size > file_cap() {
            return Err("this file exceeds the current connection limit".into());
        }
        Ok(
            json!({"attachment":Attachment{id:attachment.into(),name:safe_file_name(path.file_name().and_then(|n|n.to_str()).unwrap_or("attachment")),media_type:media_type_for_path(&path),size:Some(size)},"sha256":hash_file(&path)?,"chunkBytes":CHUNK_BYTES}),
        )
    }
    pub fn file_download_chunk(
        &self,
        id: &str,
        attachment: &str,
        offset: u64,
        allow_relay: bool,
    ) -> Result<Value, DispatchError> {
        consent(allow_relay)?;
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        self.get(id)?;
        let path = self.single_attachment_path(id, attachment)?;
        let mut file = open_regular(&path)?;
        let size = file.metadata().map_err(|e| e.to_string())?.len();
        if size > file_cap() || offset >= size {
            return Err("invalid file offset or connection limit".into());
        }
        file.seek(SeekFrom::Start(offset))
            .map_err(|e| e.to_string())?;
        let mut bytes = vec![0; (size - offset).min(CHUNK_BYTES as u64) as usize];
        file.read_exact(&mut bytes).map_err(|e| e.to_string())?;
        consent(allow_relay)?;
        Ok(
            json!({"offset":offset,"nextOffset":offset+bytes.len() as u64,"data":crate::base64::encode(&bytes),"done":offset+bytes.len() as u64 ==size}),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn regular_attachment_handles_reject_directories() {
        let root = tempfile::tempdir().unwrap();
        assert!(open_regular(root.path()).is_err());
        let source = root.path().join("attachment");
        fs::write(&source, b"original").unwrap();
        assert!(open_regular(&source).is_ok());
        fs::remove_file(&source).unwrap();
        fs::create_dir(&source).unwrap();
        assert!(open_regular(&source).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn regular_attachment_handles_reject_symlinks_and_special_files() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("private");
        let link = root.path().join("link");
        fs::write(&source, b"private").unwrap();
        symlink(&source, &link).unwrap();
        assert!(open_regular(&link).is_err());
        assert!(open_regular(Path::new("/dev/null")).is_err());
    }

    #[test]
    fn image_copy_retains_the_validated_file_after_its_path_is_replaced() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("screen.png");
        let replacement = root.path().join("replacement");
        let destination = root.path().join("saved.png");
        let original = b"\x89PNG\r\n\x1a\noriginal image";
        fs::write(&source, original).unwrap();
        let mut opened = open_regular(&source).unwrap();
        let mut header = [0; 8];
        opened.read_exact(&mut header).unwrap();
        assert_eq!(&header, b"\x89PNG\r\n\x1a\n");
        fs::write(&replacement, b"unrelated replacement content").unwrap();
        fs::rename(replacement, &source).unwrap();
        assert_eq!(
            copy_open_attachment(opened, &destination).unwrap(),
            original.len() as u64
        );
        assert_eq!(fs::read(destination).unwrap(), original);
        assert_eq!(fs::read(source).unwrap(), b"unrelated replacement content");
    }

    fn fixture() -> (tempfile::TempDir, Store) {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::at(temp.path().join("chat"));
        let chat: Conversation = serde_json::from_value(json!({"id":"file-test","workspaceId":"workspace-test","title":"Files","backend":"codex","createdAtMs":1,"updatedAtMs":1})).unwrap();
        store.conversations.lock().unwrap().push(chat);
        store.save().unwrap();
        fs::create_dir_all(store.root.join("file-test")).unwrap();
        (temp, store)
    }
    fn digest(bytes: &[u8]) -> String {
        Sha256::digest(bytes)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }
    fn start(store: &Store, bytes: &[u8]) -> String {
        store
            .file_upload_start(
                "file-test",
                "test.zip",
                bytes.len() as u64,
                &digest(bytes),
                None,
            )
            .unwrap()["transferId"]
            .as_str()
            .unwrap()
            .into()
    }
    #[test]
    fn first_message_attachments_create_storage_before_a_turn_starts() {
        let (_temp, store) = fixture();
        let chat_directory = store.root.join("file-test");
        // create() persists the conversation index only. A send held for
        // sign-in has no transcript or per-conversation directory yet.
        fs::remove_dir(&chat_directory).unwrap();
        assert!(store.file_capabilities("file-test").is_ok());
        assert!(!chat_directory.exists());
        let bytes = b"first message image";
        let transfer = start(&store, bytes);
        store
            .file_upload_chunk(
                "file-test",
                &transfer,
                0,
                &crate::base64::encode(bytes),
                false,
            )
            .unwrap();
        let attachment = store.file_upload_finish("file-test", &transfer).unwrap();
        assert_eq!(
            fs::read(store.attachment_path("file-test", &attachment.id, &attachment.name)).unwrap(),
            bytes
        );
        assert!(!chat_directory.join("events.ndjson").exists());
        let chat = store.get("file-test").unwrap();
        assert!(!chat.running);
        assert_eq!(chat.send_revision, 0);
    }

    #[test]
    fn first_upload_does_not_recreate_a_removed_conversation() {
        let (_temp, store) = fixture();
        let chat_directory = store.root.join("file-test");
        fs::remove_dir(&chat_directory).unwrap();
        // Another host removes the persisted chat while this Store still
        // has its old in-memory index.
        fs::write(
            store.root.join("conversations.json"),
            br#"{"conversations":[]}"#,
        )
        .unwrap();
        assert!(
            store
                .file_upload_start("file-test", "image.png", 1, &digest(b"x"), None)
                .is_err()
        );
        assert!(!chat_directory.exists());
    }

    #[cfg(unix)]
    #[test]
    fn first_upload_refuses_a_symlinked_conversation_directory() {
        use std::os::unix::fs::symlink;
        let (temp, store) = fixture();
        let chat_directory = store.root.join("file-test");
        fs::remove_dir(&chat_directory).unwrap();
        let outside = temp.path().join("outside");
        fs::create_dir(&outside).unwrap();
        symlink(&outside, &chat_directory).unwrap();
        assert!(
            store
                .file_upload_start("file-test", "image.png", 1, &digest(b"x"), None)
                .is_err()
        );
        assert_eq!(fs::read_dir(outside).unwrap().count(), 0);
    }

    #[test]
    fn failed_partial_cleanup_preserves_the_transfer_for_retry() {
        let (_temp, store) = fixture();
        let transfer = start(&store, b"file");
        let (path, _) = store.upload_load("file-test", &transfer).unwrap();
        let part = path.with_extension("part");
        fs::remove_file(&part).unwrap();
        fs::create_dir(&part).unwrap();
        assert!(store.file_upload_cancel("file-test", &transfer).is_err());
        assert!(path.exists());
        fs::remove_dir(&part).unwrap();
        store.file_upload_cancel("file-test", &transfer).unwrap();
        assert!(!path.exists());
    }

    #[test]
    fn failed_metadata_save_does_not_leak_temporary_transfer_records() {
        let (_temp, store) = fixture();
        let transfer = start(&store, b"file");
        let (path, upload) = store.upload_load("file-test", &transfer).unwrap();
        let directory = path.parent().unwrap();
        let blocked = directory.join("blocked.json");
        fs::create_dir(&blocked).unwrap();
        assert!(save_upload(&blocked, &upload).is_err());
        assert!(fs::read_dir(directory).unwrap().all(|entry| {
            entry
                .unwrap()
                .path()
                .extension()
                .and_then(|value| value.to_str())
                != Some("tmp")
        }));
        assert_eq!(
            store.file_upload_status("file-test", &transfer).unwrap()["offset"],
            0
        );
    }
    #[test]
    fn resumes_after_reload_repeats_exact_chunk_and_downloads_identical_bytes() {
        let (_temp, store) = fixture();
        let bytes: Vec<u8> = (0..CHUNK_BYTES + 153).map(|n| (n % 251) as u8).collect();
        let transfer = start(&store, &bytes);
        let chunk = crate::base64::encode(&bytes[..CHUNK_BYTES]);
        store
            .file_upload_chunk("file-test", &transfer, 0, &chunk, false)
            .unwrap();
        let store = Store::load_at(store.root.clone());
        assert_eq!(
            store.file_upload_status("file-test", &transfer).unwrap()["offset"],
            CHUNK_BYTES
        );
        assert_eq!(
            store
                .file_upload_chunk("file-test", &transfer, 0, &chunk, false)
                .unwrap()["offset"],
            CHUNK_BYTES
        );
        assert!(
            store
                .file_upload_chunk(
                    "file-test",
                    &transfer,
                    0,
                    &crate::base64::encode(b"changed"),
                    false
                )
                .is_err()
        );
        assert!(store.file_upload_finish("file-test", &transfer).is_err());
        store
            .file_upload_chunk(
                "file-test",
                &transfer,
                CHUNK_BYTES as u64,
                &crate::base64::encode(&bytes[CHUNK_BYTES..]),
                false,
            )
            .unwrap();
        let attachment = store.file_upload_finish("file-test", &transfer).unwrap();
        assert_eq!(
            store.file_upload_finish("file-test", &transfer).unwrap().id,
            attachment.id
        );
        assert_eq!(
            store
                .file_download_info("file-test", &attachment.id)
                .unwrap()["sha256"],
            digest(&bytes)
        );
        let mut downloaded = Vec::new();
        while downloaded.len() < bytes.len() {
            let value = store
                .file_download_chunk("file-test", &attachment.id, downloaded.len() as u64, false)
                .unwrap();
            downloaded.extend(crate::base64::decode(value["data"].as_str().unwrap()).unwrap());
        }
        assert_eq!(downloaded, bytes);
        fs::remove_file(store.attachment_path("file-test", &attachment.id, &attachment.name))
            .unwrap();
        assert!(store.file_upload_status("file-test", &transfer).is_err());
        assert!(store.file_upload_finish("file-test", &transfer).is_err());
    }
    #[test]
    fn large_file_round_trip_uses_only_one_chunk_at_a_time() {
        let (_temp, store) = fixture();
        let chunk = vec![0x5a; CHUNK_BYTES];
        let count = 40u64;
        let mut hash = Sha256::new();
        for _ in 0..count {
            hash.update(&chunk);
        }
        let digest: String = hash.finalize().iter().map(|b| format!("{b:02x}")).collect();
        let start = store
            .file_upload_start(
                "file-test",
                "large.mov",
                count * CHUNK_BYTES as u64,
                &digest,
                Some("video/quicktime".into()),
            )
            .unwrap();
        let transfer = start["transferId"].as_str().unwrap();
        let encoded = crate::base64::encode(&chunk);
        for index in 0..count {
            store
                .file_upload_chunk(
                    "file-test",
                    transfer,
                    index * CHUNK_BYTES as u64,
                    &encoded,
                    false,
                )
                .unwrap();
        }
        let attachment = store.file_upload_finish("file-test", transfer).unwrap();
        for index in 0..count {
            let downloaded = store
                .file_download_chunk(
                    "file-test",
                    &attachment.id,
                    index * CHUNK_BYTES as u64,
                    false,
                )
                .unwrap();
            assert_eq!(downloaded["data"], encoded);
        }
        assert_eq!(
            store
                .file_download_info("file-test", &attachment.id)
                .unwrap()["sha256"],
            digest
        );
    }
    #[test]
    fn consent_is_required_on_actual_relay_and_direct_fallback_is_bounded() {
        let (_temp, store) = fixture();
        let bytes = b"zip contents";
        let transfer = start(&store, bytes);
        crate::request_context::with_relay(true, || {
            let error = store
                .file_upload_chunk(
                    "file-test",
                    &transfer,
                    0,
                    &crate::base64::encode(bytes),
                    false,
                )
                .unwrap_err();
            assert_eq!(error.code, "relay_consent_required");
            assert_eq!(
                store.file_upload_status("file-test", &transfer).unwrap()["offset"],
                0
            );
            store
                .file_upload_chunk(
                    "file-test",
                    &transfer,
                    0,
                    &crate::base64::encode(bytes),
                    true,
                )
                .unwrap();
            assert!(
                store
                    .file_upload_start(
                        "file-test",
                        "video.mov",
                        RELAY_FILE_BYTES + 1,
                        &digest(bytes),
                        None
                    )
                    .is_err()
            );
        });
        let attachment = store.file_upload_finish("file-test", &transfer).unwrap();
        crate::request_context::with_relay(true, || {
            assert_eq!(
                store
                    .file_download_chunk("file-test", &attachment.id, 0, false)
                    .unwrap_err()
                    .code,
                "relay_consent_required"
            );
            assert!(
                store
                    .file_download_chunk("file-test", &attachment.id, 0, true)
                    .is_ok()
            );
        });
    }
    #[test]
    fn corrupt_expired_cancelled_and_retired_transfers_never_publish() {
        let (_temp, store) = fixture();
        let transfer = start(&store, b"correct");
        store
            .file_upload_chunk(
                "file-test",
                &transfer,
                0,
                &crate::base64::encode(b"corrupt"),
                false,
            )
            .unwrap();
        assert!(store.file_upload_finish("file-test", &transfer).is_err());
        let (path, mut upload) = store.upload_load("file-test", &transfer).unwrap();
        upload.owner = "retired-account".into();
        save_upload(&path, &upload).unwrap();
        assert!(store.file_upload_status("file-test", &transfer).is_err());
        let transfer = start(&store, b"second");
        let (path, mut upload) = store.upload_load("file-test", &transfer).unwrap();
        upload.touched_at_ms = now_ms() - TTL_MS - 1;
        save_upload(&path, &upload).unwrap();
        assert!(store.file_upload_status("file-test", &transfer).is_err());
        let transfer = start(&store, b"third");
        store.file_upload_cancel("file-test", &transfer).unwrap();
        assert!(store.file_upload_status("file-test", &transfer).is_err());
        assert!(
            store
                .file_upload_start("file-test", "empty", 0, &digest(b""), None)
                .is_err()
        );
        assert!(
            store
                .file_upload_start("file-test", "huge", FILE_BYTES + 1, &digest(b""), None)
                .is_err()
        );
    }
    #[test]
    fn upload_budget_and_chunk_limit_prevent_unbounded_allocations() {
        let (_temp, store) = fixture();
        for index in 0..4 {
            store
                .file_upload_start(
                    "file-test",
                    &format!("large-{index}.mp4"),
                    FILE_BYTES,
                    &digest(b""),
                    None,
                )
                .unwrap();
        }
        assert!(
            store
                .file_upload_start("file-test", "fifth", 1, &digest(b"x"), None)
                .is_err()
        );
        assert!(
            store
                .file_upload_chunk(
                    "file-test",
                    "absent",
                    0,
                    &"a".repeat(CHUNK_BYTES.div_ceil(3) * 4 + 1),
                    false
                )
                .is_err()
        );
    }
    #[test]
    fn storage_budget_and_deleted_chat_refuse_publication() {
        let (_temp, store) = fixture();
        let transfer = start(&store, b"bytes");
        store
            .file_upload_chunk(
                "file-test",
                &transfer,
                0,
                &crate::base64::encode(b"bytes"),
                false,
            )
            .unwrap();
        let files = store.root.join("file-test/files/existing");
        fs::create_dir_all(&files).unwrap();
        let huge = fs::File::create(files.join("video.mp4")).unwrap();
        huge.set_len(CHAT_BYTES).unwrap();
        assert!(store.file_upload_finish("file-test", &transfer).is_err());
        assert!(
            store
                .file_upload_start("file-test", "new", 1, &digest(b"x"), None)
                .is_err()
        );
        drop(huge);
        store.remove("file-test").unwrap();
        assert!(store.file_upload_status("file-test", &transfer).is_err());
        assert!(!store.root.join("file-test").exists());
    }
    #[test]
    fn repeated_start_resumes_one_reservation_after_a_lost_acknowledgement() {
        let (_temp, store) = fixture();
        let bytes = b"archive";
        let transfer = start(&store, bytes);
        store
            .file_upload_chunk(
                "file-test",
                &transfer,
                0,
                &crate::base64::encode(&bytes[..3]),
                false,
            )
            .unwrap();
        let resumed = start(&store, bytes);
        assert_eq!(resumed, transfer);
        assert_eq!(
            store.file_upload_status("file-test", &resumed).unwrap()["offset"],
            3
        );
        assert_eq!(
            fs::read_dir(store.root.join("file-test/transfers"))
                .unwrap()
                .count(),
            2
        );
    }
    #[cfg(unix)]
    #[test]
    fn attachment_and_staging_symlinks_are_refused() {
        use std::os::unix::fs::symlink;
        let (temp, store) = fixture();
        fs::create_dir_all(store.root.join("file-test/files/file-linked")).unwrap();
        fs::write(temp.path().join("secret"), b"secret").unwrap();
        symlink(
            temp.path().join("secret"),
            store.root.join("file-test/files/file-linked/secret"),
        )
        .unwrap();
        assert!(
            store
                .file_download_info("file-test", "file-linked")
                .is_err()
        );
        fs::remove_dir_all(store.root.join("file-test/files")).unwrap();
        let outside = temp.path().join("outside");
        fs::create_dir(&outside).unwrap();
        symlink(&outside, store.root.join("file-test/files")).unwrap();
        assert!(
            store
                .attach("file-test", "x", &crate::base64::encode(b"x"), None)
                .is_err()
        );
        assert_eq!(fs::read_dir(&outside).unwrap().count(), 0);
        symlink(temp.path(), store.root.join("file-test/transfers")).unwrap();
        assert!(
            store
                .file_upload_start("file-test", "x", 1, &digest(b"x"), None)
                .is_err()
        );
    }
}
