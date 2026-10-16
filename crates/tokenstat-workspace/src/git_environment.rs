// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

/// Finder and launchd omit Homebrew from PATH. Git's filters and hooks need
/// the same executable search path as Git itself, including git-lfs.
pub(crate) fn executable_path(path: Option<&std::ffi::OsStr>) -> Option<std::ffi::OsString> {
    let mut paths: Vec<_> = path
        .map(std::env::split_paths)
        .into_iter()
        .flatten()
        .collect();
    #[cfg(unix)]
    for directory in [
        #[cfg(target_os = "macos")]
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ] {
        let directory = std::path::PathBuf::from(directory);
        if !paths.contains(&directory) {
            paths.push(directory);
        }
    }
    if let Some(home) = tokenstat_paths::home_dir() {
        let directory = home.join(".local/bin");
        if !paths.contains(&directory) {
            paths.push(directory);
        }
    }
    std::env::join_paths(paths).ok()
}

#[cfg(all(test, unix))]
mod tests {
    #[test]
    fn a_missing_path_keeps_system_git_available() {
        let path = super::executable_path(None).unwrap();
        let paths: Vec<_> = std::env::split_paths(&path).collect();
        assert!(paths.contains(&std::path::PathBuf::from("/usr/bin")));
        assert!(paths.contains(&std::path::PathBuf::from("/bin")));
    }
}
