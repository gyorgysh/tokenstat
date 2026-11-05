// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Observe launched processes after a lost response or early stream closure.
//! Launches verify folder identity without reserving a checkout.

#[cfg(all(test, unix))]
mod tests;

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::Duration;
use tokenstat_pty::ProcessWitness;
use tokenstat_workspace::writer::{Error, Location};

struct Registry {
    entries: Mutex<HashMap<String, ProcessWitness>>,
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
                .filter(|process| !process.completed())
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
            .name("workspace-processes".into())
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
            let observed: Vec<_> = entries.values().cloned().collect();
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
        // A child whose stop holds its process mutex conservatively answers
        // false, so observation does not wait behind that stop.
        if process.completed() {
            self.entries
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .remove(process.id());
        }
    }
}

pub(crate) struct Guard {
    location: Location,
    registry: Arc<Registry>,
    process: Option<ProcessWitness>,
}
impl Guard {
    pub fn acquire(path: &Path) -> Result<Self, Error> {
        let registry = Self::registry()?;
        Ok(Self {
            location: Location::capture(path)?,
            registry,
            process: None,
        })
    }
    fn registry() -> Result<Arc<Registry>, Error> {
        REGISTRY
            .get_or_init(Registry::start)
            .as_ref()
            .map(Arc::clone)
            .ok_or(Error::Unavailable)
    }
    pub fn ensure_current(&self) -> Result<(), Error> {
        self.location.ensure_current()
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
        self.location
            .ensure_for(&request.cwd)
            .map_err(|error| tokenstat_pty::PtyError::Spawn(error.to_string()))?;
        let mut anchored = request.clone();
        anchored.cwd = self.location.folder().to_owned();
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
            .insert(process.id().into(), process.clone());
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
