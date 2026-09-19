// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Persist daemon diagnostics even when launched without a console.

use std::fs::{File, OpenOptions};
use std::path::Path;

fn open_log(directory: &Path) -> std::io::Result<File> {
    std::fs::create_dir_all(directory)?;
    let path = directory.join("hostd.log");
    if std::fs::metadata(&path).is_ok_and(|meta| meta.len() >= 5 * 1024 * 1024) {
        let previous = directory.join("hostd.previous.log");
        let _ = std::fs::remove_file(&previous);
        // An older process may still hold the file. Append if rotation fails.
        let _ = std::fs::rename(&path, previous);
    }
    OpenOptions::new().create(true).append(true).open(path)
}

#[cfg(windows)]
pub fn initialize() {
    use std::os::windows::io::AsRawHandle;
    use std::sync::OnceLock;
    static LOG: OnceLock<File> = OnceLock::new();
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn SetStdHandle(kind: u32, handle: *mut std::ffi::c_void) -> i32;
    }
    let Some(local) = std::env::var_os("LOCALAPPDATA") else {
        return;
    };
    let directory = Path::new(&local).join("tokenstat").join("logs");
    let Ok(file) = open_log(&directory) else {
        return;
    };
    let file = LOG.get_or_init(|| file);
    // Retain the handle for the lifetime of the process. Rust's stderr uses
    // the standard handle, so startup failures and panic reports land here.
    if unsafe { SetStdHandle(-12_i32 as u32, file.as_raw_handle()) } != 0 {
        eprintln!(
            "\n{} hostd starting pid={} version={}",
            jiff::Timestamp::now(),
            std::process::id(),
            env!("CARGO_PKG_VERSION")
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn creates_appends_and_rotates_diagnostics() {
        let dir = tempfile::tempdir().unwrap();
        let logs = dir.path().join("logs");
        writeln!(open_log(&logs).unwrap(), "first start").unwrap();
        writeln!(open_log(&logs).unwrap(), "second start").unwrap();
        assert_eq!(
            std::fs::read_to_string(logs.join("hostd.log")).unwrap(),
            "first start\nsecond start\n"
        );
        // Windows append-only handles cannot resize a file. Use a separate
        // writable fixture handle; the daemon needs only append access.
        OpenOptions::new()
            .write(true)
            .open(logs.join("hostd.log"))
            .unwrap()
            .set_len(5 * 1024 * 1024)
            .unwrap();
        writeln!(open_log(&logs).unwrap(), "new start").unwrap();
        assert_eq!(
            std::fs::read_to_string(logs.join("hostd.log")).unwrap(),
            "new start\n"
        );
        assert_eq!(
            std::fs::metadata(logs.join("hostd.previous.log"))
                .unwrap()
                .len(),
            5 * 1024 * 1024
        );
    }
}
