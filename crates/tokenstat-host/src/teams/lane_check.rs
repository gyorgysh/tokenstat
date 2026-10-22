// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Repository checks use the same owned groups/Jobs as agents. Permission
//! and Stop are checked while they run, and descendants must finish before
//! a landing can continue. Check output stays on this computer.

use crate::team_process::{Owned, Poll, Program};
use std::{
    io::{self, Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

const TIME: Duration = Duration::from_secs(20 * 60);
const LOG_LIMIT: u64 = 8 * 1024 * 1024;
const TAIL: u64 = 4096;

fn executable(name: &str, folder: &Path) -> Option<PathBuf> {
    let path = Path::new(name);
    if path.is_absolute() {
        return Some(path.into());
    }
    if path.components().count() > 1 {
        return Some(folder.join(path));
    }
    let name = if cfg!(windows) && path.extension().is_none() {
        format!("{name}.exe")
    } else {
        name.into()
    };
    std::env::split_paths(&std::env::var_os("PATH")?)
        .filter(|path| path.is_absolute())
        .map(|path| path.join(&name))
        .find(|path| path.is_file())
}

fn tail(path: &Path) -> io::Result<String> {
    let mut file = std::fs::File::open(path)?;
    let length = file.metadata()?.len();
    file.seek(SeekFrom::Start(length.saturating_sub(TAIL)))?;
    let mut bytes = Vec::new();
    file.take(TAIL).read_to_end(&mut bytes)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// An outer error means OS cleanup was not proven. The caller must retain
/// its durable writer fence, rather than reporting a completed check.
pub(super) fn run(
    helper: &Path,
    folder: &Path,
    command: &[String],
    guard: &mut impl FnMut() -> Result<(), String>,
    before_birth: impl FnOnce(u32) -> io::Result<()>,
) -> io::Result<Result<(), String>> {
    let Some((program, args)) = command.split_first() else {
        return Ok(guard());
    };
    if let Err(message) = guard() {
        return Ok(Err(message));
    }
    let Some(executable) = executable(program, folder) else {
        return Ok(Err("The check command could not be found.".into()));
    };
    let files = tempfile::tempdir()?;
    let input = files.path().join("input");
    std::fs::write(&input, [])?;
    let output = files.path().join("output");
    let errors = files.path().join("errors");
    let program = Program {
        executable,
        args: args.into(),
        folder: folder.into(),
        input,
        output: output.clone(),
        errors: errors.clone(),
        env: std::env::vars()
            .filter(|(key, _)| !key.starts_with("TOKENSTAT_TEAM_SDK_"))
            .collect(),
    };
    let mut process = Owned::start(helper, program, |anchor| {
        before_birth(anchor)?;
        guard().map_err(io::Error::other)
    })
    .map_err(|error| io::Error::other(format!("Starting the check: {error}")))?;
    let deadline = Instant::now() + TIME;
    let outcome = (|| {
        loop {
            guard()?;
            if Instant::now() >= deadline {
                return Err("The check command ran longer than 20 minutes.".into());
            }
            if [&output, &errors]
                .iter()
                .any(|path| std::fs::metadata(path).is_ok_and(|meta| meta.len() > LOG_LIMIT))
            {
                return Err("The check command produced too much output.".into());
            }
            match process
                .poll()
                .map_err(|_| "The check process could not be observed.".to_string())?
            {
                Poll::Exited(Some(0)) => return Ok(()),
                Poll::Exited(_) => {
                    return Err(format!(
                        "{}\n{}",
                        tail(&output).unwrap_or_default(),
                        tail(&errors).unwrap_or_default()
                    ));
                }
                Poll::LaunchFailed => return Err("The check command could not start.".into()),
                Poll::Running | Poll::Started => {}
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    })();
    let _completion = process
        .stop()
        .map_err(|error| io::Error::other(format!("Stopping the check: {error}")))?;
    Ok(outcome)
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Manual {
    claim: String,
    boot: Option<String>,
    group: u32,
    born: u64,
    completed: bool,
}

impl Manual {
    fn save(&self, lane: &Path) -> io::Result<()> {
        use std::io::Write;
        let staged = lane.with_extension("check.tmp");
        let mut options = std::fs::OpenOptions::new();
        options.create(true).truncate(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let mut file = options.open(&staged)?;
        file.write_all(&serde_json::to_vec(self).map_err(io::Error::other)?)?;
        file.sync_all()?;
        std::fs::rename(staged, lane.with_extension("check"))
    }

    pub fn begin(lane: &Path, lease: &mut tokenstat_workspace::writer::Lease) -> io::Result<Self> {
        let record = Self {
            claim: format!(
                "{:032x}{:032x}",
                rand::random::<u128>(),
                rand::random::<u128>()
            ),
            boot: crate::team_process::boot_identity(),
            group: 0,
            born: 0,
            completed: false,
        };
        record.save(lane)?;
        lease.claim_run(&record.claim).map_err(io::Error::other)?;
        Ok(record)
    }

    pub fn birth(&mut self, lane: &Path, anchor: u32) -> io::Result<()> {
        (self.group, self.born) = crate::team_process::run_owner(anchor);
        self.save(lane)
    }

    pub fn complete(
        mut self,
        lane: &Path,
        lease: &mut tokenstat_workspace::writer::Lease,
    ) -> io::Result<()> {
        self.completed = true;
        self.save(lane)?;
        lease
            .clear_completed_run(&self.claim)
            .map_err(io::Error::other)?;
        std::fs::remove_file(lane.with_extension("check"))
    }
}

/// An explicit Land or Discard may finish a previous interrupted check's
/// cleanup, after proving its owner gone. An uncertain claim stays fenced.
pub(super) fn recover_manual(lane: &Path) -> io::Result<()> {
    let path = lane.with_extension("check");
    let bytes = match std::fs::read(&path) {
        Ok(bytes) if bytes.len() <= 4096 => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        _ => return Err(io::Error::other("The check needs recovery.")),
    };
    let record: Manual = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    let restarted = matches!((record.boot.as_deref(), crate::team_process::boot_identity().as_deref()), (Some(then), Some(now)) if then != now);
    if !record.completed
        && !restarted
        && !crate::team_process::run_owner_gone(record.group, record.born)
    {
        return Err(io::Error::other("The check process may still be running."));
    }
    tokenstat_workspace::writer::clear_orphaned_run(&record.claim).map_err(io::Error::other)?;
    std::fs::remove_file(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unproven_manual_check_keeps_its_writer_claim() {
        let root = tempfile::tempdir().unwrap();
        let lane = root.path().join("lane");
        std::fs::create_dir(&lane).unwrap();
        let mut lease = tokenstat_workspace::writer::Lease::acquire_lane(&lane).unwrap();
        let record = Manual::begin(&lane, &mut lease).unwrap();
        let claim = record.claim.clone();
        drop(lease);
        assert!(tokenstat_workspace::writer::Lease::acquire_lane(&lane).is_err());
        assert!(recover_manual(&lane).is_err());
        // No child was born in this fixture. Record the same durable completed
        // step used after a real owned-process completion, then restart cleanup.
        let mut record = record;
        record.completed = true;
        record.save(&lane).unwrap();
        recover_manual(&lane).unwrap();
        assert!(!lane.with_extension("check").exists());
        assert!(tokenstat_workspace::writer::Lease::acquire_lane(&lane).is_ok());
        tokenstat_workspace::writer::clear_orphaned_run(&claim).unwrap();
    }

    #[test]
    fn a_completed_manual_check_releases_the_claim_and_record() {
        let root = tempfile::tempdir().unwrap();
        let lane = root.path().join("lane");
        std::fs::create_dir(&lane).unwrap();
        let mut lease = tokenstat_workspace::writer::Lease::acquire_lane(&lane).unwrap();
        Manual::begin(&lane, &mut lease)
            .unwrap()
            .complete(&lane, &mut lease)
            .unwrap();
        lease.ensure_current().unwrap();
        assert!(!lane.with_extension("check").exists());
        drop(lease);
        assert!(tokenstat_workspace::writer::Lease::acquire_lane(&lane).is_ok());
    }
}
