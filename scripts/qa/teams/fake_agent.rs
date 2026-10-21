// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Disposable Team process fixture. No provider, network or account access.

use std::{
    fs,
    io::{self, Read},
    path::PathBuf,
    process::{Command, Stdio},
    time::Duration,
};

fn main() {
    let args = std::env::args().collect::<Vec<_>>();
    if args.get(1).is_some_and(|arg| arg == "leaf") {
        let beat = args.get(2).expect("fixture heartbeat");
        let mut count = 0u64;
        loop {
            fs::write(beat, count.to_string()).unwrap();
            count += 1;
            std::thread::sleep(Duration::from_millis(40));
        }
    }
    let mode = args.get(1).expect("fixture mode");
    let state = PathBuf::from(args.get(2).expect("fixture state"));
    let mut context = String::new();
    io::stdin().read_to_string(&mut context).unwrap();
    assert!(context.contains("Fictional supervised Ask"));
    assert!(!context.contains("PRIVATE_FIXTURE"));
    assert!(std::env::var_os("TOKENSTAT_GUARDIAN_PRIVATE_SENTINEL").is_none());
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .arg("leaf")
        .arg(state.with_extension("leaf"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    let child = command.spawn().unwrap();
    fs::write(&state, format!("{} {}", std::process::id(), child.id())).unwrap();
    if mode == "finish" {
        return;
    }
    #[cfg(unix)]
    unsafe {
        use std::os::fd::FromRawFd;
        drop(fs::File::from_raw_fd(1));
        drop(fs::File::from_raw_fd(2));
    }
    #[cfg(windows)]
    unsafe {
        use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
        drop(OwnedHandle::from_raw_handle(io::stdout().as_raw_handle()));
        drop(OwnedHandle::from_raw_handle(io::stderr().as_raw_handle()));
    }
    let mut count = 0u64;
    loop {
        fs::write(state.with_extension("root"), count.to_string()).unwrap();
        count += 1;
        std::thread::sleep(Duration::from_millis(40));
    }
}
