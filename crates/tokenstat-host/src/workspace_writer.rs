// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Retain a writer after a lost response, failed persistence or early drain.
//! This is process observation, not a sandbox or durable crash recovery.

#[cfg(all(test, unix))]
mod tests;

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::Duration;
use tokenstat_pty::ProcessWitness;
use tokenstat_workspace::writer::{Error, Lease};

struct Entry {
    process: ProcessWitness,
    _writer: Arc<Lease>,
}
struct Registry {
    entries: Mutex<HashMap<String, Entry>>,
    wake: Condvar,
}
static REGISTRY: OnceLock<Option<Arc<Registry>>> = OnceLock::new();

pub(crate) fn pending_count() -> usize {
    REGISTRY
        .get()
        .and_then(Option::as_ref)
        .map_or(0, |registry| {
            registry
                .entries
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .values()
                .filter(|entry| !entry.process.completed())
                .count()
        })
}
impl Registry {
    fn start() -> Option<Arc<Self>> {
        let registry = Arc::new(Self {
            entries: Mutex::new(HashMap::new()),
            wake: Condvar::new(),
        });
        let worker = Arc::clone(&registry);
        std::thread::Builder::new()
            .name("workspace-writers".into())
            .spawn(move || worker.watch())
            .ok()?;
        Some(registry)
    }
    fn watch(&self) {
        loop {
            let mut entries = self
                .entries
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            while entries.is_empty() {
                entries = self
                    .wake
                    .wait(entries)
                    .unwrap_or_else(|error| error.into_inner());
            }
            let observed: Vec<_> = entries
                .values()
                .map(|entry| entry.process.clone())
                .collect();
            drop(entries);
            for process in observed {
                self.release_completed(&process);
            }
            let entries = self
                .entries
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            drop(
                self.wake
                    .wait_timeout(entries, Duration::from_millis(100))
                    .unwrap_or_else(|error| error.into_inner()),
            );
        }
    }
    fn release_completed(&self, process: &ProcessWitness) {
        // Never block other checkouts behind a child whose stop holds its
        // process mutex; the witness conservatively answers false instead.
        if process.completed() {
            self.entries
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .remove(process.id());
        }
    }
}

pub(crate) struct Guard {
    writer: Arc<Lease>,
    registry: Arc<Registry>,
    process: Option<ProcessWitness>,
}
impl Guard {
    pub fn acquire(path: &Path) -> Result<Self, Error> {
        let registry = REGISTRY
            .get_or_init(Registry::start)
            .as_ref()
            .ok_or(Error::Unavailable)?;
        Ok(Self {
            writer: Arc::new(Lease::acquire(path)?),
            registry: Arc::clone(registry),
            process: None,
        })
    }
    pub fn ensure_current(&self) -> Result<(), Error> {
        self.writer.ensure_current()
    }
    pub fn spawn(
        &mut self,
        request: &tokenstat_pty::Spawn,
    ) -> Result<tokenstat_pty::SessionInfo, tokenstat_pty::PtyError> {
        self.spawn_with_io(request, false)
    }
    #[cfg(all(test, unix))]
    fn spawn_piped(
        &mut self,
        request: &tokenstat_pty::Spawn,
    ) -> Result<tokenstat_pty::SessionInfo, tokenstat_pty::PtyError> {
        self.spawn_with_io(request, true)
    }
    fn spawn_with_io(
        &mut self,
        request: &tokenstat_pty::Spawn,
        piped: bool,
    ) -> Result<tokenstat_pty::SessionInfo, tokenstat_pty::PtyError> {
        self.writer
            .ensure_for(&request.cwd)
            .map_err(|error| tokenstat_pty::PtyError::Spawn(error.to_string()))?;
        let mut anchored = request.clone();
        anchored.cwd = self.writer.folder().to_owned();
        let check = || {
            self.ensure_current()
                .map_err(|error| tokenstat_pty::PtyError::Spawn(error.to_string()))
        };
        let (info, process) = if piped {
            tokenstat_pty::manager().spawn_piped_owned_checked(&anchored, check)
        } else {
            tokenstat_pty::manager().spawn_owned_checked(&anchored, check)
        }?;
        self.attach(process);
        Ok(info)
    }
    fn attach(&mut self, process: ProcessWitness) {
        self.registry
            .entries
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .insert(
                process.id().into(),
                Entry {
                    process: process.clone(),
                    _writer: Arc::clone(&self.writer),
                },
            );
        self.process = Some(process);
        self.registry.wake.notify_one();
    }
}
impl Drop for Guard {
    fn drop(&mut self) {
        if let Some(process) = &self.process {
            self.registry.release_completed(process);
        }
    }
}
