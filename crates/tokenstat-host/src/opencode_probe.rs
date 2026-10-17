// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! A leased local server for read-only discovery. It never depends on or
//! restarts the user's background service, including during CLI upgrades.

use std::io::{BufRead, BufReader, Read};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

pub(super) struct Server {
    child: Child,
    client: reqwest::blocking::Client,
    url: reqwest::Url,
    password: String,
    directory: String,
    deadline: Instant,
}

impl Server {
    pub(super) fn start(binary: &str, directory: &Path, timeout: Duration) -> Option<Self> {
        let deadline = Instant::now() + timeout;
        let client = tokenstat_sync::http::client_builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .ok()?;
        let mut secret = [0u8; 24];
        getrandom::fill(&mut secret).ok()?;
        let password: String = secret.iter().map(|byte| format!("{byte:02x}")).collect();
        let mut command = Command::new(binary);
        if let Some(login) = tokenstat_pty::login_env() {
            command.env_clear().envs(&login.vars);
        }
        command
            .args(["serve", "--stdio", "--hostname", "127.0.0.1", "--port", "0"])
            .current_dir(directory)
            .env("PWD", directory)
            .env("PATH", crate::launcher::search_path_var())
            .env("OPENCODE_PASSWORD", &password)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000);
        }
        let child = command.spawn().ok()?;
        let mut server = Self {
            child,
            client,
            url: reqwest::Url::parse("http://127.0.0.1").ok()?,
            password,
            directory: super::directory_header(directory)
                .trim_start_matches("x-opencode-directory:")
                .to_string(),
            deadline,
        };
        let stdout = server.child.stdout.take()?;
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            let mut ready = Vec::new();
            let read = reader
                .by_ref()
                .take(64 * 1024 + 1)
                .read_until(b'\n', &mut ready);
            let _ = tx.send(
                read.ok()
                    .filter(|_| ready.len() <= 64 * 1024)
                    .map(|_| ready),
            );
            // A service may log after readiness; keep its stdout open and
            // draining without retaining that output in memory.
            let _ = std::io::copy(&mut reader, &mut std::io::sink());
        });
        let ready = rx
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .ok()??;
        let value: serde_json::Value = serde_json::from_slice(&ready).ok()?;
        let url = reqwest::Url::parse(value.get("url")?.as_str()?).ok()?;
        if url.scheme() != "http" || url.host_str() != Some("127.0.0.1") || url.port().is_none() {
            return None;
        }
        server.url = url;
        Some(server)
    }

    pub(super) fn get(&self, route: &str, cap: usize) -> Option<(bool, String)> {
        let remaining = self.deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return None;
        }
        let response = self
            .client
            .get(self.url.join(route).ok()?)
            .basic_auth("opencode", Some(&self.password))
            .header("x-opencode-directory", &self.directory)
            .timeout(remaining.min(Duration::from_secs(2)))
            .send()
            .ok()?;
        let success = response.status().is_success();
        let mut bytes = Vec::new();
        response.take(cap as u64 + 1).read_to_end(&mut bytes).ok()?;
        (bytes.len() <= cap).then(|| (success, String::from_utf8_lossy_owned(bytes)))
    }

    pub(super) fn expired(&self) -> bool {
        Instant::now() >= self.deadline
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        // EOF ends the service's lease, also when the owning host crashes.
        self.child.stdin.take();
        let deadline = Instant::now() + Duration::from_millis(250);
        while Instant::now() < deadline {
            if matches!(self.child.try_wait(), Ok(Some(_))) {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        #[cfg(unix)]
        if let Ok(pid) = i32::try_from(self.child.id()) {
            // SAFETY: this child owns a dedicated process group.
            unsafe {
                libc::kill(-pid, libc::SIGKILL);
            }
        }
        #[cfg(windows)]
        tokenstat_pty::kill_windows_process_tree(self.child.id());
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
