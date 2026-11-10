// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! App-owned serialized draft work. The cache/occupied set changes on the UI
//! executor; blocking registration and durable writes belong to worker jobs.

use super::{
    Attachment, Draft, Model, Mutation, Reference,
    storage::{Storage, Writer},
};
use crate::work::continuity::Date;
use std::{
    collections::{BTreeSet, VecDeque},
    sync::{Arc, Mutex},
};

#[derive(Clone)]
enum Operation {
    Bootstrap,
    Flush(Option<(String, Mutation)>),
    Prepare(Command),
}
#[derive(Clone)]
enum Command {
    Save(Save),
    Clear(Reference),
    ClearExpected(Draft),
}
impl Command {
    fn apply(&self, model: &mut Model) -> anyhow::Result<Option<(String, Mutation)>> {
        match self {
            Self::Save(save) => model.save(
                save.reference.clone(),
                save.text.clone(),
                save.attachments.clone(),
                save.at,
                save.new_message,
            ),
            Self::Clear(reference) => Ok(model.clear(reference)),
            Self::ClearExpected(expected) => Ok(model.clear_expected(expected)),
        }
    }
}
#[derive(Clone)]
struct Save {
    reference: Reference,
    text: String,
    attachments: Vec<Attachment>,
    at: Date,
    new_message: bool,
}
#[derive(Clone)]
/// One captured operation; execute once on a blocking worker, then deliver it.
pub struct Job {
    id: u64,
    generation: u64,
    operation: Operation,
    storage: Storage,
    writer: Arc<Mutex<Writer>>,
}
/// Worker output is applied only by its matching active service operation.
pub enum Output {
    Bootstrap {
        model: Model,
        registered: bool,
        error: Option<String>,
    },
    Flushed {
        failed: bool,
        error: Option<String>,
    },
    Registered,
}
impl Job {
    /// Perform bounded file work away from the GUI executor.
    pub fn execute(&self) -> Result<Output, String> {
        self.run().map_err(|e| format!("{e:#}"))
    }
    fn run(&self) -> anyhow::Result<Output> {
        if matches!(self.operation, Operation::Bootstrap) {
            let prepared = self.storage.prepare();
            let registered = prepared.is_ok();
            let result = prepared.and_then(|_| self.storage.read());
            return Ok(match result {
                Ok(records) => Output::Bootstrap {
                    model: Model::from_records(records),
                    registered: true,
                    error: None,
                },
                Err(error) => Output::Bootstrap {
                    model: Model::default(),
                    registered,
                    error: Some(format!("{error:#}")),
                },
            });
        }
        if matches!(self.operation, Operation::Prepare(_)) {
            self.storage.prepare()?;
            return Ok(Output::Registered);
        }
        let mut writer = self
            .writer
            .lock()
            .map_err(|_| anyhow::anyhow!("Draft writer state was poisoned"))?;
        if let Operation::Flush(Some((key, mutation))) = &self.operation {
            writer.pending.insert(key.clone(), mutation.clone());
        }
        writer.flush(&self.storage);
        Ok(Output::Flushed {
            failed: writer.failed,
            error: writer.error.clone(),
        })
    }
}
/// Readiness is distinct from an empty restored snapshot; failures follow the
/// original empty-memory/saveFailed outcome while leaving damaged bytes alone.
pub struct Service {
    storage: Storage,
    writer: Arc<Mutex<Writer>>,
    enabled: bool,
    pub model: Model,
    pub initialized: bool,
    pub save_failed: bool,
    pub error: Option<String>,
    registered: bool,
    preparing: usize,
    queue: VecDeque<Job>,
    active: Option<u64>,
    next: u64,
    generation: u64,
    closing: bool,
}
impl Service {
    /// `None` is an immediately ready private in-memory fixture store.
    pub fn new(storage: Option<Storage>) -> Self {
        let enabled = storage.is_some();
        let mut service = Self {
            storage: storage.unwrap_or_default(),
            writer: Arc::new(Mutex::new(Writer::default())),
            enabled,
            model: Model::default(),
            initialized: !enabled,
            save_failed: false,
            error: None,
            registered: !enabled,
            preparing: 0,
            queue: VecDeque::new(),
            active: None,
            next: 0,
            generation: 0,
            closing: false,
        };
        if enabled {
            service.enqueue(Operation::Bootstrap);
        }
        service
    }
    /// Unknown while restoration is pending; thereafter follows source memory.
    pub fn presence(&self, reference: &Reference) -> Option<bool> {
        self.initialized.then(|| self.model.has_draft(reference))
    }
    /// Mark observers use membership, never every edit to an existing draft.
    pub fn occupied(&self) -> &BTreeSet<String> {
        &self.model.occupied
    }
    /// Preserve input immediately after successful registration; queue durable IO.
    pub fn save(
        &mut self,
        reference: Reference,
        text: String,
        attachments: Vec<Attachment>,
        at: Date,
        new_message: bool,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(self.initialized, "Draft storage is still loading");
        anyhow::ensure!(!self.closing, "Draft storage is closing");
        if !self.registered || self.preparing != 0 {
            self.defer(Command::Save(Save {
                reference,
                text,
                attachments,
                at,
                new_message,
            }));
            return Ok(());
        }
        if let Some(change) = self
            .model
            .save(reference, text, attachments, at, new_message)?
        {
            self.flush(Some(change));
        }
        Ok(())
    }
    /// Capture an explicit deletion, ordered after earlier accepted operations.
    pub fn clear(&mut self, reference: &Reference) {
        if !self.closing && self.preparing != 0 {
            self.defer(Command::Clear(reference.clone()));
            return;
        }
        if !self.closing
            && let Some(change) = self.model.clear(reference)
        {
            self.flush(Some(change));
        }
    }
    /// Remove only this submitted version in memory and again against latest disk.
    pub fn clear_expected(&mut self, expected: &Draft) {
        if !self.closing && self.preparing != 0 {
            self.defer(Command::ClearExpected(expected.clone()));
            return;
        }
        if !self.closing
            && let Some(change) = self.model.clear_expected(expected)
        {
            self.flush(Some(change));
        }
    }
    /// Retry every failed pending change, including a failed deletion.
    pub fn retry_failed_save(&mut self) {
        if !self.closing {
            self.flush(None);
        }
    }
    fn defer(&mut self, command: Command) {
        self.generation = self.generation.wrapping_add(1);
        self.preparing += 1;
        self.enqueue(Operation::Prepare(command));
    }
    fn flush(&mut self, change: Option<(String, Mutation)>) {
        self.generation = self.generation.wrapping_add(1);
        if self.enabled {
            self.enqueue(Operation::Flush(change));
        } else {
            if let Ok(mut writer) = self.writer.lock() {
                if let Some((key, mutation)) = change {
                    writer.pending.insert(key, mutation);
                }
                writer.flush(&self.storage);
                self.save_failed = writer.failed;
                self.error = writer.error.clone();
            }
        }
    }
    fn enqueue(&mut self, operation: Operation) {
        self.next = self.next.wrapping_add(1);
        self.queue.push_back(Job {
            id: self.next,
            generation: self.generation,
            operation,
            storage: self.storage.clone(),
            writer: self.writer.clone(),
        });
    }
    /// Take one operation; callers must finish it before requesting the next.
    pub fn next_job(&mut self) -> Option<Job> {
        if self.active.is_some() {
            return None;
        }
        let job = self.queue.pop_front()?;
        self.active = Some(job.id);
        Some(job)
    }
    /// Apply the matching delivery; old or duplicate completions have no effect.
    pub fn finish(&mut self, job: &Job, result: Result<Output, String>) -> bool {
        if self.active != Some(job.id) {
            return false;
        }
        self.active = None;
        if matches!(job.operation, Operation::Prepare(_)) {
            self.preparing = self.preparing.saturating_sub(1);
        }
        match result {
            Ok(Output::Bootstrap {
                model,
                registered,
                error,
            }) => {
                self.model = model;
                self.initialized = true;
                self.registered = registered;
                self.save_failed = error.is_some();
                self.error = error;
            }
            Ok(Output::Registered) => {
                self.registered = true;
                if let Operation::Prepare(command) = &job.operation {
                    // Preflight is ordered with every other save. Accepted writing
                    // is kept even if its initiating window/account has retired.
                    match command.apply(&mut self.model) {
                        Ok(Some(change)) => {
                            // Registration already owns this lane. Put its captured
                            // write before later queued registration/save operations.
                            self.next = self.next.wrapping_add(1);
                            self.queue.push_front(Job {
                                id: self.next,
                                generation: job.generation,
                                operation: Operation::Flush(Some(change)),
                                storage: self.storage.clone(),
                                writer: self.writer.clone(),
                            });
                        }
                        Ok(None) => {}
                        Err(error) => {
                            self.save_failed = true;
                            self.error = Some(format!("{error:#}"));
                        }
                    }
                }
            }
            Ok(Output::Flushed { failed, error }) if job.generation == self.generation => {
                self.save_failed = failed;
                self.error = error;
            }
            Err(error)
                if job.generation == self.generation
                    || matches!(job.operation, Operation::Bootstrap) =>
            {
                self.save_failed = true;
                self.error = Some(error);
                if matches!(job.operation, Operation::Bootstrap) {
                    self.initialized = true;
                }
            }
            _ => {}
        }
        true
    }
    /// Refuse new input while draining every already accepted operation.
    pub fn start_shutdown(&mut self) {
        self.closing = true;
    }
    /// All queued IO has settled; a failed pending mutation may still need retry.
    pub fn idle(&self) -> bool {
        self.active.is_none() && self.queue.is_empty()
    }
}
