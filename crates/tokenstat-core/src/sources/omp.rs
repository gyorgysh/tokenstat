// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Oh My Pi session roots. The transcript parser is shared with Pi.

use std::path::{Path, PathBuf};

/// Include both legacy and XDG roots: machines can have history in either.
pub fn discover(home: &Path) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    add_tree(&mut roots, &home.join(".omp"), false);
    if let Some(xdg) = std::env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty()) {
        add_tree(&mut roots, &PathBuf::from(xdg).join("omp"), true);
    }
    // Explicit agent directories are shared with Pi. Only consider paths
    // inside .omp so the same Pi transcripts cannot be counted twice.
    if let Some(dir) = std::env::var_os("PI_CODING_AGENT_DIR") {
        let dir = PathBuf::from(dir);
        if dir.starts_with(home.join(".omp")) {
            add(&mut roots, dir.join("sessions"));
        }
    }
    roots
}

fn add_tree(roots: &mut Vec<PathBuf>, base: &Path, xdg: bool) {
    add(
        roots,
        if xdg {
            base.join("sessions")
        } else {
            base.join("agent/sessions")
        },
    );
    if let Ok(profiles) = std::fs::read_dir(base.join("profiles")) {
        for profile in profiles.flatten() {
            let profile = profile.path();
            add(
                roots,
                if xdg {
                    profile.join("sessions")
                } else {
                    profile.join("agent/sessions")
                },
            );
        }
    }
}

fn add(roots: &mut Vec<PathBuf>, path: PathBuf) {
    if let Ok(path) = path.canonicalize()
        && path.is_dir()
        && !roots.contains(&path)
    {
        roots.push(path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn finds_default_and_profile_roots_only_once() {
        let home = tempfile::tempdir().unwrap();
        let base = home.path().join(".omp");
        std::fs::create_dir_all(base.join("agent/sessions")).unwrap();
        std::fs::create_dir_all(base.join("profiles/work/agent/sessions")).unwrap();
        let mut roots = Vec::new();
        add_tree(&mut roots, &base, false);
        add_tree(&mut roots, &base, false);
        assert_eq!(roots.len(), 2);
    }
}
