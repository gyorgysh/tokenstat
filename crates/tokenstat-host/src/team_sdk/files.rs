// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The only filesystem capability offered to a Team agent. Native file and
//! command tools stay disabled. Relative opens never follow links, Git metadata
//! is unavailable, and writes cannot change a multiply-linked file.

use serde_json::{Value, json};
use std::{
    fs,
    io::{self, Read, Write},
    path::{Component, Path, PathBuf},
};

const LIMIT: u64 = 4 * 1024 * 1024;
const PAGE: usize = 256 * 1024;
const ERROR: &str =
    "That lane file is unavailable. Use a relative project path, without links or Git metadata.";

pub(super) struct LaneFiles {
    root: PathBuf,
    directory: fs::File,
}

impl LaneFiles {
    pub(super) fn bind(root: &Path) -> io::Result<Self> {
        let root = root.canonicalize()?;
        let directory = directory(&root)?;
        Ok(Self { root, directory })
    }

    fn current(&self) -> io::Result<()> {
        let current = directory(&self.root)?;
        if identity(&current)? != identity(&self.directory)? {
            return Err(io::Error::other(ERROR));
        }
        Ok(())
    }

    fn open(&self, path: &str, write: bool) -> io::Result<fs::File> {
        self.open_guarded(path, write, &|| Ok(()))
    }

    fn open_guarded(
        &self,
        path: &str,
        write: bool,
        live: &impl Fn() -> io::Result<()>,
    ) -> io::Result<fs::File> {
        self.current()?;
        let names = names(path)?;
        #[cfg(unix)]
        {
            let mut parent = relative(&self.directory, ".", libc::O_RDONLY | libc::O_DIRECTORY)?;
            for (index, name) in names.iter().enumerate() {
                let last = index + 1 == names.len();
                if last && write {
                    live()?;
                }
                let flags = if last && write {
                    libc::O_RDWR | libc::O_CREAT
                } else {
                    libc::O_RDONLY
                };
                parent = relative(&parent, name, flags)?;
                let metadata = parent.metadata()?;
                if (!last && !metadata.is_dir()) || (last && write && !regular(&parent)?) {
                    return Err(io::Error::other(ERROR));
                }
            }
            Ok(parent)
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            let mut held = vec![self.directory.try_clone()?];
            let mut path = self.root.clone();
            for (index, name) in names.iter().enumerate() {
                path.push(name);
                let last = index + 1 == names.len();
                if last && write {
                    live()?;
                }
                let mut options = fs::OpenOptions::new();
                options
                    .read(true)
                    .write(last && write)
                    .create(last && write)
                    .custom_flags(0x02000000 | 0x00200000)
                    .share_mode(3);
                let file = options.open(&path)?;
                let metadata = file.metadata()?;
                use std::os::windows::fs::MetadataExt;
                if metadata.file_attributes() & 0x400 != 0
                    || (!last && !metadata.is_dir())
                    || (last && write && !regular(&file)?)
                {
                    return Err(io::Error::other(ERROR));
                }
                let resolved = path.canonicalize()?;
                if !resolved.starts_with(&self.root)
                    || resolved
                        .strip_prefix(&self.root)
                        .map_err(|_| io::Error::other(ERROR))?
                        .components()
                        .any(|part| {
                            part.as_os_str()
                                .to_string_lossy()
                                .eq_ignore_ascii_case(".git")
                        })
                {
                    return Err(io::Error::other(ERROR));
                }
                held.push(file);
            }
            held.pop().ok_or_else(|| io::Error::other(ERROR))
        }
        #[cfg(not(any(unix, windows)))]
        Err(io::Error::other(ERROR))
    }

    fn read(&self, path: &str) -> io::Result<String> {
        let file = self.open(path, false)?;
        if !regular(&file)? || file.metadata()?.len() > LIMIT {
            return Err(io::Error::other(ERROR));
        }
        let mut text = String::new();
        file.take(LIMIT + 1).read_to_string(&mut text)?;
        if text.len() as u64 > LIMIT {
            return Err(io::Error::other(ERROR));
        }
        Ok(text)
    }

    fn list(
        &self,
        path: &str,
        live: &impl Fn() -> io::Result<()>,
    ) -> io::Result<Vec<(String, bool)>> {
        let file = self.open(path, false)?;
        if !file.metadata()?.is_dir() {
            return Err(io::Error::other(ERROR));
        }
        #[cfg(unix)]
        {
            use std::{ffi::CStr, os::fd::IntoRawFd};
            let duplicate = file.try_clone()?.into_raw_fd();
            let stream = unsafe { libc::fdopendir(duplicate) };
            if stream.is_null() {
                unsafe {
                    libc::close(duplicate);
                }
                return Err(io::Error::last_os_error());
            }
            struct Entries(*mut libc::DIR);
            impl Drop for Entries {
                fn drop(&mut self) {
                    unsafe {
                        libc::closedir(self.0);
                    }
                }
            }
            let stream = Entries(stream);
            let mut rows = Vec::new();
            let mut inspected = 0;
            loop {
                let entry = unsafe { libc::readdir(stream.0) };
                if entry.is_null() {
                    break;
                }
                let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }
                    .to_str()
                    .map_err(|_| io::Error::other(ERROR))?;
                if name == "." || name == ".." {
                    continue;
                }
                inspected += 1;
                if inspected > 1000 {
                    return Err(io::Error::other("This directory has too many entries."));
                }
                if inspected % 32 == 1 {
                    live()?;
                }
                if names(name).is_err() {
                    continue;
                }
                if let Ok(child) = relative(&file, name, libc::O_RDONLY) {
                    let metadata = child.metadata()?;
                    if metadata.is_dir() || regular(&child)? {
                        rows.push((name.into(), metadata.is_dir()));
                    }
                }
                if rows.len() > 1000 {
                    return Err(io::Error::other("This directory has too many entries."));
                }
            }
            rows.sort();
            Ok(rows)
        }
        #[cfg(windows)]
        {
            let mut rows = Vec::new();
            for (index, entry) in fs::read_dir(self.root.join(path))?.enumerate() {
                if index >= 1000 {
                    return Err(io::Error::other("This directory has too many entries."));
                }
                if index % 32 == 0 {
                    live()?;
                }
                let entry = entry?;
                let name = entry
                    .file_name()
                    .into_string()
                    .map_err(|_| io::Error::other(ERROR))?;
                if names(&name).is_err() {
                    continue;
                }
                let child = if path.is_empty() {
                    name.clone()
                } else {
                    format!("{path}/{name}")
                };
                if let Ok(child) = self.open(&child, false) {
                    let metadata = child.metadata()?;
                    if metadata.is_dir() || regular(&child)? {
                        rows.push((name, metadata.is_dir()));
                    }
                }
                if rows.len() > 1000 {
                    return Err(io::Error::other(ERROR));
                }
            }
            rows.sort();
            Ok(rows)
        }
        #[cfg(not(any(unix, windows)))]
        Err(io::Error::other(ERROR))
    }

    fn create_directory(&self, path: &str, live: &impl Fn() -> io::Result<()>) -> io::Result<()> {
        self.current()?;
        let names = names(path)?;
        if names.is_empty() {
            return Err(io::Error::other(ERROR));
        }
        #[cfg(unix)]
        {
            use std::{ffi::CString, os::fd::AsRawFd};
            let mut parent = relative(&self.directory, ".", libc::O_RDONLY | libc::O_DIRECTORY)?;
            for name in names {
                match relative(&parent, name, libc::O_RDONLY | libc::O_DIRECTORY) {
                    Ok(next) => parent = next,
                    Err(error) if error.kind() == io::ErrorKind::NotFound => {
                        live()?;
                        let name_c = CString::new(name).map_err(|_| io::Error::other(ERROR))?;
                        if unsafe { libc::mkdirat(parent.as_raw_fd(), name_c.as_ptr(), 0o700) } != 0
                        {
                            return Err(io::Error::last_os_error());
                        }
                        parent = relative(&parent, name, libc::O_RDONLY | libc::O_DIRECTORY)?;
                    }
                    Err(error) => return Err(error),
                }
            }
        }
        #[cfg(windows)]
        {
            let mut held = vec![self.directory.try_clone()?];
            let mut relative = String::new();
            for name in names {
                if !relative.is_empty() {
                    relative.push('/');
                }
                relative.push_str(name);
                match self.open(&relative, false) {
                    Ok(file) if file.metadata()?.is_dir() => held.push(file),
                    Err(error) if error.kind() == io::ErrorKind::NotFound => {
                        live()?;
                        fs::create_dir(self.root.join(&relative))?;
                        held.push(self.open(&relative, false)?);
                    }
                    _ => return Err(io::Error::other(ERROR)),
                }
            }
        }
        #[cfg(not(any(unix, windows)))]
        return Err(io::Error::other(ERROR));
        Ok(())
    }

    pub(super) fn call(
        &self,
        name: &str,
        args: &Value,
        live: impl Fn() -> io::Result<()>,
    ) -> Result<Value, &'static str> {
        let operation = || -> io::Result<Value> {
            live()?;
            let path = args.get("path").and_then(Value::as_str).unwrap_or("");
            if args.get("path").is_some_and(|path| !path.is_string()) {
                return Err(io::Error::other(ERROR));
            }
            match name {
                "team_directory_create" if super::keys(args, &["path"]) => {
                    self.create_directory(path, &live)?;
                    Ok(json!({"created":true}))
                }
                "team_files_list" if super::keys(args, &["path"]) => {
                    let entries = self
                        .list(path, &live)?
                        .into_iter()
                        .map(|(name, directory)| json!({"name":name,"directory":directory}))
                        .collect::<Vec<_>>();
                    Ok(json!({"entries":entries}))
                }
                "team_file_read"
                    if super::keys(args, &["path", "startLine", "maxLines"])
                        && !path.is_empty() =>
                {
                    let start = args
                        .get("startLine")
                        .map_or(Some(1), Value::as_u64)
                        .filter(|n| *n > 0 && *n <= u64::from(u32::MAX))
                        .ok_or_else(|| io::Error::other(ERROR))?
                        as usize;
                    let count = args
                        .get("maxLines")
                        .map_or(Some(200), Value::as_u64)
                        .filter(|n| *n > 0 && *n <= 2000)
                        .ok_or_else(|| io::Error::other(ERROR))?
                        as usize;
                    let full = self.read(path)?;
                    let lines = full.split_inclusive('\n').collect::<Vec<_>>();
                    if start > lines.len() + 1 {
                        return Err(io::Error::other(ERROR));
                    }
                    let mut selected = String::new();
                    let mut next = start;
                    for line in lines.iter().skip(start - 1).take(count) {
                        if selected.len() + line.len() > PAGE {
                            if selected.is_empty() {
                                return Err(io::Error::other(
                                    "This source line exceeds the read page limit.",
                                ));
                            }
                            break;
                        }
                        selected.push_str(line);
                        next += 1;
                    }
                    Ok(
                        json!({"text":selected,"startLine":start,"totalLines":lines.len(),"nextLine":(next<=lines.len()).then_some(next)}),
                    )
                }
                "team_file_write"
                    if super::keys(args, &["path", "content"]) && !path.is_empty() =>
                {
                    let text = args["content"]
                        .as_str()
                        .filter(|text| text.len() as u64 <= LIMIT)
                        .ok_or_else(|| io::Error::other(ERROR))?;
                    let mut file = self.open_guarded(path, true, &live)?;
                    live()?;
                    self.current()?;
                    file.set_len(0)?;
                    file.write_all(text.as_bytes())?;
                    file.sync_all()?;
                    Ok(json!({"written":true}))
                }
                "team_file_edit"
                    if super::keys(args, &["path", "old", "new"]) && !path.is_empty() =>
                {
                    let old = args["old"]
                        .as_str()
                        .filter(|s| !s.is_empty())
                        .ok_or_else(|| io::Error::other(ERROR))?;
                    let new = args["new"]
                        .as_str()
                        .ok_or_else(|| io::Error::other(ERROR))?;
                    let text = self.read(path)?;
                    if text.matches(old).count() != 1 {
                        return Err(io::Error::other(ERROR));
                    }
                    let changed = text.replacen(old, new, 1);
                    if changed.len() as u64 > LIMIT {
                        return Err(io::Error::other(ERROR));
                    }
                    let mut file = self.open_guarded(path, true, &live)?;
                    live()?;
                    self.current()?;
                    file.set_len(0)?;
                    file.write_all(changed.as_bytes())?;
                    file.sync_all()?;
                    Ok(json!({"edited":true}))
                }
                "team_file_search" if super::keys(args, &["path", "query"]) => {
                    let query = args["query"]
                        .as_str()
                        .filter(|s| !s.is_empty() && s.len() <= 4096)
                        .ok_or_else(|| io::Error::other(ERROR))?;
                    let mut pending = vec![path.to_string()];
                    let mut matches = Vec::new();
                    let mut visited = 0;
                    let mut scanned = 0;
                    while let Some(path) = pending.pop() {
                        live()?;
                        visited += 1;
                        if visited > 1000 || matches.len() >= 100 {
                            return Ok(json!({"matches":matches,"truncated":true}));
                        }
                        let file = self.open(&path, false)?;
                        if file.metadata()?.is_dir() {
                            for (name, _) in self.list(&path, &live)? {
                                if pending.len() + visited >= 1000 {
                                    return Ok(json!({"matches":matches,"truncated":true}));
                                }
                                pending.push(if path.is_empty() {
                                    name
                                } else {
                                    format!("{path}/{name}")
                                });
                            }
                        } else if let Ok(text) = self.read(&path) {
                            scanned += text.len();
                            if scanned > 32 * 1024 * 1024 {
                                return Ok(json!({"matches":matches,"truncated":true}));
                            }
                            for (line, text) in text.lines().enumerate() {
                                if text.contains(query) {
                                    matches.push(json!({"path":path,"line":line+1,"text":text.chars().take(1000).collect::<String>()}));
                                    if matches.len() >= 100 {
                                        return Ok(json!({"matches":matches,"truncated":true}));
                                    }
                                }
                            }
                        }
                    }
                    Ok(json!({"matches":matches,"truncated":false}))
                }
                _ => Err(io::Error::other(ERROR)),
            }
        };
        operation().map_err(|_| ERROR)
    }
}

fn valid_name(name: &str) -> bool {
    let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
    !name.eq_ignore_ascii_case(".git")
        && !name.ends_with(['.', ' '])
        && !matches!(
            stem.as_str(),
            "CON"
                | "PRN"
                | "AUX"
                | "NUL"
                | "COM1"
                | "COM2"
                | "COM3"
                | "COM4"
                | "COM5"
                | "COM6"
                | "COM7"
                | "COM8"
                | "COM9"
                | "LPT1"
                | "LPT2"
                | "LPT3"
                | "LPT4"
                | "LPT5"
                | "LPT6"
                | "LPT7"
                | "LPT8"
                | "LPT9"
        )
}

fn names(path: &str) -> io::Result<Vec<&str>> {
    if path == "." {
        return Ok(Vec::new());
    }
    if path.len() > 4096 || path.contains(['\\', ':', '\0']) {
        return Err(io::Error::other(ERROR));
    }
    Path::new(path)
        .components()
        .map(|component| match component {
            Component::Normal(name) => name
                .to_str()
                .filter(|name| valid_name(name))
                .ok_or_else(|| io::Error::other(ERROR)),
            _ => Err(io::Error::other(ERROR)),
        })
        .collect()
}

fn directory(path: &Path) -> io::Result<fs::File> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x02000000 | 0x00200000).share_mode(3);
    }
    let file = options.open(path)?;
    if !file.metadata()?.is_dir() {
        return Err(io::Error::other(ERROR));
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if file.metadata()?.file_attributes() & 0x400 != 0 {
            return Err(io::Error::other(ERROR));
        }
    }
    Ok(file)
}

fn identity(file: &fs::File) -> io::Result<(u64, [u8; 16])> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let metadata = file.metadata()?;
        let mut id = [0; 16];
        id[..8].copy_from_slice(&metadata.ino().to_be_bytes());
        Ok((metadata.dev(), id))
    }
    #[cfg(windows)]
    {
        crate::win32::file_identity(file).ok_or_else(|| io::Error::other(ERROR))
    }
    #[cfg(not(any(unix, windows)))]
    Err(io::Error::other(ERROR))
}

fn regular(file: &fs::File) -> io::Result<bool> {
    let metadata = file.metadata()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Ok(metadata.is_file() && metadata.nlink() == 1)
    }
    #[cfg(windows)]
    {
        use std::{
            ffi::c_void,
            os::windows::{fs::MetadataExt, io::AsRawHandle},
        };
        #[repr(C)]
        struct Standard {
            allocation: i64,
            end: i64,
            links: u32,
            deleted: u8,
            directory: u8,
        }
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn GetFileInformationByHandleEx(
                file: *mut c_void,
                class: i32,
                value: *mut c_void,
                size: u32,
            ) -> i32;
        }
        let mut info: Standard = unsafe { std::mem::zeroed() };
        let ok = unsafe {
            GetFileInformationByHandleEx(
                file.as_raw_handle(),
                1,
                (&mut info as *mut Standard).cast(),
                std::mem::size_of::<Standard>() as u32,
            )
        };
        Ok(ok != 0
            && info.links == 1
            && metadata.is_file()
            && metadata.file_attributes() & 0x400 == 0)
    }
    #[cfg(not(any(unix, windows)))]
    Ok(false)
}

#[cfg(unix)]
fn relative(parent: &fs::File, name: &str, flags: i32) -> io::Result<fs::File> {
    use std::{
        ffi::CString,
        os::fd::{AsRawFd, FromRawFd},
    };
    let name = CString::new(name).map_err(|_| io::Error::other(ERROR))?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
            0o600,
        )
    };
    if fd < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(unsafe { fs::File::from_raw_fd(fd) })
    }
}

pub(super) fn tools() -> Vec<Value> {
    [
        ("team_directory_create", "Create directories inside the lane.",json!({"path":{"type":"string"}}),vec!["path"]),
        ("team_files_list", "List one lane directory (path defaults to its root).",json!({"path":{"type":"string"}}),vec![]),
        ("team_file_read", "Read a page of a UTF-8 lane file (up to 4 MiB total). Follow nextLine as startLine. Pages default to 200 lines, at most 2000 lines or 256 KiB.",json!({"path":{"type":"string"},"startLine":{"type":"integer","minimum":1},"maxLines":{"type":"integer","minimum":1,"maximum":2000}}),vec!["path"]),
        ("team_file_write", "Create or replace a UTF-8 file in an existing lane directory. Use edit for existing large files.",json!({"path":{"type":"string"},"content":{"type":"string"}}),vec!["path","content"]),
        ("team_file_edit", "Replace one exact, unique text occurrence in a lane file.",json!({"path":{"type":"string"},"old":{"type":"string"},"new":{"type":"string"}}),vec!["path","old","new"]),
        ("team_file_search", "Search lane files for literal text (up to 1000 entries and 100 matches).",json!({"path":{"type":"string"},"query":{"type":"string"}}),vec!["query"]),
    ].into_iter().map(|(name,description,properties,required)|json!({"name":name,"description":description,"inputSchema":{"type":"object","properties":properties,"required":required,"additionalProperties":false}})).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lane_tools_create_inspect_search_and_edit_without_shell() {
        let root = tempfile::tempdir().unwrap();
        let lane = LaneFiles::bind(root.path()).unwrap();
        let call = |name, args| lane.call(name, &args, || Ok(())).unwrap();
        call("team_directory_create", json!({"path":"src/nested"}));
        call(
            "team_file_write",
            json!({"path":"src/nested/new.rs","content":"first\nneedle\nlast\n"}),
        );
        let first = call("team_files_list", json!({}));
        assert_eq!(
            first,
            call("team_files_list", json!({})),
            "directory iteration must not consume a shared file offset"
        );
        assert_eq!(first["entries"][0]["name"], "src");
        assert_eq!(
            call("team_file_search", json!({"query":"needle"}))["matches"][0]["line"],
            2
        );
        call(
            "team_file_edit",
            json!({"path":"src/nested/new.rs","old":"needle","new":"replacement"}),
        );
        assert_eq!(
            call("team_file_read", json!({"path":"src/nested/new.rs"}))["text"],
            "first\nreplacement\nlast\n"
        );
        assert!(
            lane.call(
                "team_file_edit",
                &json!({"path":"src/nested/new.rs","old":"missing","new":"no"}),
                || Ok(())
            )
            .is_err()
        );
        let before = fs::read(root.path().join("src/nested/new.rs")).unwrap();
        assert!(
            lane.call(
                "team_file_write",
                &json!({"path":"src/nested/new.rs","content":"denied"}),
                || Err(io::Error::other("retired"))
            )
            .is_err()
        );
        assert_eq!(
            fs::read(root.path().join("src/nested/new.rs")).unwrap(),
            before
        );
    }

    #[test]
    fn lane_tools_refuse_git_traversal_devices_and_arbitrary_targets() {
        let root = tempfile::tempdir().unwrap();
        let lane = LaneFiles::bind(root.path()).unwrap();
        fs::create_dir(root.path().join(".git")).unwrap();
        fs::write(root.path().join(".git/config"), "private Git config").unwrap();
        for path in [
            "../private",
            "/etc/passwd",
            ".git/config",
            "src/../../private",
            ".GiT/config",
            "NUL",
            "file:stream",
            ".git./config",
            "dir\\escape",
        ] {
            assert!(
                lane.call("team_file_read", &json!({"path":path}), || Ok(()))
                    .is_err(),
                "{path}"
            );
            assert!(
                lane.call(
                    "team_file_write",
                    &json!({"path":path,"content":"bad"}),
                    || Ok(())
                )
                .is_err(),
                "{path}"
            );
        }
        assert_eq!(
            lane.call("team_files_list", &json!({}), || Ok(())).unwrap()["entries"],
            json!([])
        );
        assert!(
            lane.call("team_files_list", &json!({"path":null}), || Ok(()))
                .is_err()
        );
        assert!(
            lane.call(
                "team_file_read",
                &json!({"path":"x","workspace":"other"}),
                || Ok(())
            )
            .is_err()
        );
    }

    #[test]
    fn exact_directory_limit_and_expiry_before_creation_are_safe() {
        let root = tempfile::tempdir().unwrap();
        let lane = LaneFiles::bind(root.path()).unwrap();
        for index in 0..1000 {
            fs::write(root.path().join(format!("file-{index}")), []).unwrap();
        }
        assert_eq!(
            lane.call("team_files_list", &json!({}), || Ok(())).unwrap()["entries"]
                .as_array()
                .unwrap()
                .len(),
            1000
        );
        fs::write(root.path().join("overflow"), []).unwrap();
        assert!(lane.call("team_files_list", &json!({}), || Ok(())).is_err());
        let checks = std::cell::Cell::new(0);
        assert!(
            lane.call(
                "team_file_write",
                &json!({"path":"expired-new-file","content":"no"}),
                || {
                    checks.set(checks.get() + 1);
                    if checks.get() == 1 {
                        Ok(())
                    } else {
                        Err(io::Error::other("expired"))
                    }
                }
            )
            .is_err()
        );
        assert!(!root.path().join("expired-new-file").exists());
    }

    #[test]
    fn large_source_files_can_be_paged_and_edited_without_native_exec() {
        let root = tempfile::tempdir().unwrap();
        let source = (0..6000)
            .map(|line| format!("line-{line:04} {}\n", "source text ".repeat(8)))
            .collect::<String>();
        assert!(source.len() > PAGE);
        fs::write(root.path().join("large.rs"), &source).unwrap();
        let lane = LaneFiles::bind(root.path()).unwrap();
        let page = lane
            .call(
                "team_file_read",
                &json!({"path":"large.rs","startLine":4500,"maxLines":2}),
                || Ok(()),
            )
            .unwrap();
        assert_eq!(page["nextLine"], 4502);
        assert_eq!(page["totalLines"], 6000);
        assert!(page["text"].as_str().unwrap().starts_with("line-4499 "));
        lane.call(
            "team_file_edit",
            &json!({"path":"large.rs","old":"line-4500 ","new":"fixed-4500 "}),
            || Ok(()),
        )
        .unwrap();
        assert_eq!(
            fs::read_to_string(root.path().join("large.rs")).unwrap(),
            source.replacen("line-4500 ", "fixed-4500 ", 1)
        );
    }

    #[cfg(unix)]
    #[test]
    fn filtered_directory_entries_are_still_bounded() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        let lane = LaneFiles::bind(root.path()).unwrap();
        for index in 0..1001 {
            symlink(
                "missing-private-file",
                root.path().join(format!("link-{index}")),
            )
            .unwrap();
        }
        assert!(lane.call("team_files_list", &json!({}), || Ok(())).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn links_and_replaced_lane_roots_never_disclose_or_overwrite_other_files() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("lane");
        fs::create_dir(&path).unwrap();
        let outside = root.path().join("private");
        fs::write(&outside, "personal").unwrap();
        symlink(&outside, path.join("linked")).unwrap();
        fs::hard_link(&outside, path.join("hardlinked")).unwrap();
        symlink(root.path(), path.join("directory-link")).unwrap();
        let lane = LaneFiles::bind(&path).unwrap();
        for name in ["linked", "hardlinked", "directory-link/private"] {
            assert!(
                lane.call("team_file_read", &json!({"path":name}), || Ok(()))
                    .is_err()
            );
            assert!(
                lane.call(
                    "team_file_write",
                    &json!({"path":name,"content":"bad"}),
                    || Ok(())
                )
                .is_err()
            );
        }
        assert_eq!(fs::read_to_string(&outside).unwrap(), "personal");
        fs::rename(&path, root.path().join("old-lane")).unwrap();
        fs::create_dir(&path).unwrap();
        fs::write(path.join("replacement"), "another checkout").unwrap();
        assert!(
            lane.call("team_file_read", &json!({"path":"replacement"}), || Ok(()))
                .is_err()
        );
        assert!(
            lane.call(
                "team_file_write",
                &json!({"path":"replacement","content":"bad"}),
                || Ok(())
            )
            .is_err()
        );
        assert_eq!(
            fs::read_to_string(path.join("replacement")).unwrap(),
            "another checkout"
        );
    }
}
