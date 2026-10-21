// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! One host-owned run in an independent process. The viewer never owns its
//! authority or lifetime. The physical host's private pipe may request Stop;
//! its EOF stops work, while a lost guardian leaves durable writer claims.

use super::{
    AuthorizedTeamPrincipal, api_error, client, scoped_runs::checkout_digest, scoped_source::Source,
};
use crate::{
    account_session::AccountSnapshot,
    chat::sharing::{AskInput, AskPreparation},
    chat_receipts::team_runs::{Fence, State},
    error::DispatchError,
    team_process::{self, Owned, Poll, Program},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    io::{self, BufReader},
    sync::mpsc,
    time::{Duration, Instant},
};
use tokenstat_identity::teams::TeamTicket;
#[path = "guardian/output.rs"]
mod output;

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Init {
    ticket: String,
    device_key: String,
    publisher: String,
    issuer: String,
    host_authentication: String,
    input: Option<AskInput>,
    #[serde(default)]
    program: Option<Program>,
}
#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "camelCase", deny_unknown_fields)]
enum Control {
    Stop { fence: Fence },
}
struct Parent {
    child: Option<std::process::Child>,
    input: Option<std::process::ChildStdin>,
}
impl Drop for Parent {
    fn drop(&mut self) {
        // Close control before reaping. Even a failed request cannot leave a
        // pipe silently authorizing its guardian, or leak a waitable child.
        drop(self.input.take());
        if let Some(child) = self.child.take() {
            let held = std::sync::Arc::new(std::sync::Mutex::new(Some(child)));
            let worker = held.clone();
            let spawned = std::thread::Builder::new()
                .name("team-guardian-reap".into())
                .spawn(move || {
                    if let Some(mut child) = worker.lock().unwrap_or_else(|e| e.into_inner()).take()
                    {
                        let _ = child.wait();
                    }
                });
            if spawned.is_err()
                && let Some(mut child) = held.lock().unwrap_or_else(|e| e.into_inner()).take()
            {
                let _ = child.wait();
            }
        }
    }
}
fn unavailable() -> DispatchError {
    DispatchError::new(
        "team_run_recovery_required",
        "This Team run needs recovery on its publishing computer.",
    )
}
fn map_io(_: io::Error) -> DispatchError {
    unavailable()
}
fn event(value: Value) -> Result<(), DispatchError> {
    team_process::send(&mut io::stdout().lock(), &value).map_err(map_io)
}

fn fixture_program(program: &Program, source: &Source, issuer: &str) -> Result<(), DispatchError> {
    if !cfg!(debug_assertions) {
        return Err(unavailable());
    }
    let origin = reqwest::Url::parse(issuer).map_err(|_| unavailable())?;
    if origin.scheme() != "http" || origin.host_str() != Some("127.0.0.1") {
        return Err(unavailable());
    }
    let data = tokenstat_paths::data_dir().ok_or_else(unavailable)?;
    let identity = tokenstat_identity::identity_dir().map_err(|_| unavailable())?;
    if !data.join(".teams-transport-fixture").is_file()
        || !identity.join(".teams-transport-fixture").is_file()
    {
        return Err(unavailable());
    }
    let base = data
        .join("guardian-fixture")
        .canonicalize()
        .map_err(|_| unavailable())?;
    if !program
        .executable
        .canonicalize()
        .map_err(|_| unavailable())?
        .starts_with(&base)
        || program.folder.canonicalize().map_err(|_| unavailable())?
            != source.checkout.folder.canonical
        || [&program.input, &program.output, &program.errors]
            .into_iter()
            .any(|p| {
                p.parent()
                    .and_then(|p| p.canonicalize().ok())
                    .is_none_or(|p| !p.starts_with(&base))
            })
    {
        return Err(unavailable());
    }
    Ok(())
}

pub(crate) fn main() -> Result<(), DispatchError> {
    let mut reader = BufReader::new(io::stdin());
    let init: Init = team_process::receive(&mut reader).map_err(map_io)?;
    let owner = AccountSnapshot::capture().map_err(|_| unavailable())?;
    if owner
        .client
        .as_ref()
        .map(|c| c.authentication_id())
        .as_deref()
        != Some(&init.host_authentication)
    {
        return Err(unavailable());
    }
    let client = client(&owner)?;
    if client.origin() != init.issuer {
        return Err(unavailable());
    }
    let device =
        tokenstat_identity::public_key_from_hex(&init.device_key).map_err(|_| unavailable())?;
    let ticket = TeamTicket::try_from(init.ticket).map_err(|_| unavailable())?;
    let principal = AuthorizedTeamPrincipal::guardian(&client, &ticket, device, init.publisher)?;
    let source = Source::capture(&principal)?;
    let checkout = checkout_digest(&source)?;
    let chats = crate::chat::shared();
    let Some(input) = init.input else {
        if init.program.is_some() {
            return Err(unavailable());
        }
        let review = chats.team_ask_review(source.target(), &principal, &checkout, || {
            source.ensure_current()
        })?;
        return event(json!({"event":"review","review":review,"agentRuns":false}));
    };
    if let Some(program) = &init.program {
        fixture_program(program, &source, &init.issuer)?;
    }
    let mut prepared = match chats.prepare_team_ask(
        source.target(),
        &principal,
        &input,
        &source.checkout.folder.canonical,
        &checkout,
        || source.ensure_current(),
    )? {
        AskPreparation::Existing(receipt) => {
            return event(json!({"event":"finished","result":receipt}));
        }
        AskPreparation::New(prepared) => prepared,
    };
    // No canonical/index/transcript lock is held across account HTTP.
    let admission = (|| {
        principal.ensure_account_current()?;
        source.ensure_current()?;
        chats.ensure_prepared_ask(source.target(), &prepared, || source.ensure_current())?;
        let authority = client
            .admit_host_run_authority(&prepared.binding().cloud_reference, principal.run_ticket()?)
            .map_err(api_error)?;
        Ok(authority)
    })();
    let mut authority = match admission {
        Ok(authority) => authority,
        Err(error) => {
            let _ = chats.refuse_prepared_ask(source.target(), *prepared);
            return Err(error);
        }
    };
    let Some(mut program) = init.program else {
        // Production agent adapters remain disabled until scoped SDK, full
        // context/state review and physical grant UI are ready.
        let _ = authority.retire();
        let result = chats.refuse_prepared_ask(source.target(), *prepared)?;
        return event(json!({"event":"finished","result":result}));
    };
    let mut raw = std::fs::OpenOptions::new();
    raw.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        raw.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let context_written = (|| {
        use std::io::Write;
        let mut file = raw.open(&program.input).map_err(map_io)?;
        file.write_all(&serde_json::to_vec(prepared.context()).map_err(|_| unavailable())?)
            .map_err(map_io)?;
        file.sync_all().map_err(map_io)
    })();
    if let Err(error) = context_written {
        let _ = authority.retire();
        let _ = chats.refuse_prepared_ask(source.target(), *prepared);
        return Err(error);
    }
    let sdk = (|| {
        let current = owner.clone();
        let sdk_source = Source::capture(&principal)?;
        source.ensure_current()?;
        crate::team_sdk::Service::start(
            &authority,
            serde_json::to_value(prepared.context()).map_err(|_| unavailable())?,
            prepared.binding().fence.run_id().into(),
            move || current.ensure_current().is_ok() && sdk_source.ensure_current().is_ok(),
        )
        .map_err(map_io)
    })();
    let sdk = match sdk {
        Ok(sdk) => sdk,
        Err(error) => {
            let _ = authority.retire();
            let _ = chats.refuse_prepared_ask(source.target(), *prepared);
            return Err(error);
        }
    };
    sdk.configure(&mut program);
    let mut output = output::Output::new(&program.output, prepared.backend());
    prepared.claim_writer()?;
    chats.transition_owned_run(source.target(), &prepared, State::Launching)?;
    let helper = std::env::current_exe().map_err(map_io)?;
    let process = Owned::start(&helper, program, || {
        source
            .ensure_current()
            .map_err(|_| io::Error::other("Run source changed."))?;
        chats
            .ensure_launching_ask(source.target(), &prepared, || source.ensure_current())
            .map_err(|_| io::Error::other("Run source changed."))?;
        if authority
            .remaining()
            .map_err(|_| io::Error::other("Run authority expired."))?
            < team_process::BIRTH
        {
            return Err(io::Error::other("Run authority expired."));
        }
        Ok(())
    });
    let mut process = match process {
        Ok(process) => process,
        Err(error) => {
            // A failed send after anchor admission is ambiguous. Never turn it
            // into NotStarted or clear a durable claim from an error alone.
            let _ = chats.transition_owned_run(source.target(), &prepared, State::NeedsRecovery);
            let _ = authority.retire();
            return Err(map_io(error));
        }
    };
    let (commands, control) = mpsc::sync_channel(8);
    let control_thread = std::thread::Builder::new()
        .name("team-guardian-control".into())
        .spawn(move || {
            loop {
                let request = team_process::receive::<Control>(&mut reader);
                let ended = request.is_err();
                if commands.send(request).is_err() || ended {
                    break;
                }
            }
        });
    let execution = (|| {
        control_thread.map_err(map_io)?;
        let mut renew = Instant::now() + Duration::from_secs(10);
        let mut running = false;
        let terminal = loop {
            if authority.ensure_live().is_err()
                || source.ensure_current().is_err()
                || sdk.ensure_live().is_err()
            {
                break State::Stopped;
            }
            match control.try_recv() {
                Ok(Ok(Control::Stop { fence })) if fence == prepared.binding().fence => {
                    break State::Stopped;
                }
                Ok(Ok(_)) => {}
                Ok(Err(_)) | Err(mpsc::TryRecvError::Disconnected) => break State::Stopped,
                Err(mpsc::TryRecvError::Empty) => {}
            }
            match process.poll().map_err(map_io)? {
                Poll::Started => {
                    chats.transition_owned_run(source.target(), &prepared, State::Running)?;
                    sdk.running().map_err(map_io)?;
                    running = true;
                    event(
                        json!({"event":"running","fence":prepared.binding().fence,"runId":prepared.binding().fence.run_id()}),
                    )?;
                }
                Poll::Exited(code) => {
                    break if running && code == Some(0) {
                        State::Succeeded
                    } else {
                        State::Failed
                    };
                }
                Poll::LaunchFailed => break State::NotStarted,
                Poll::Running => {}
            }
            if running {
                output
                    .drain(false, |batch, events| {
                        chats
                            .append_owned_output(source.target(), &prepared, batch, events, || {
                                authority.ensure_live().map_err(api_error)?;
                                source.ensure_current()
                            })
                            .map_err(|_| io::Error::other("Team output could not be verified."))
                    })
                    .map_err(map_io)?;
            }
            if Instant::now() >= renew {
                if authority.renew().is_err() {
                    break State::Stopped;
                }
                if sdk.renew(&authority).is_err() {
                    break State::Stopped;
                }
                renew = Instant::now() + Duration::from_secs(10);
            }
            std::thread::sleep(Duration::from_millis(100));
        };
        sdk.retire();
        if terminal == State::Stopped {
            chats.transition_owned_run(source.target(), &prepared, State::Stopping)?;
        }
        let proof = process.stop().map_err(map_io)?;
        let final_output = if running && matches!(terminal, State::Succeeded | State::Failed) {
            output
                .drain(true, |batch, events| {
                    chats
                        .append_owned_output(source.target(), &prepared, batch, events, || {
                            authority.ensure_live().map_err(api_error)?;
                            source.ensure_current()
                        })
                        .map_err(|_| io::Error::other("Team output could not be verified."))
                })
                .map_err(map_io)
        } else {
            Ok(())
        };
        Ok((terminal, proof, final_output))
    })();
    let (terminal, proof) = match execution {
        Ok((terminal, proof, Ok(()))) => (terminal, proof),
        Ok((_, _, Err(error))) => {
            // OS cleanup is proven, but output persistence needs repair.
            // Keep both durable fences; never attempt a second stop using a
            // completed process handle or report successful output delivery.
            let _ = chats.transition_owned_run(source.target(), &prepared, State::NeedsRecovery);
            let _ = authority.retire();
            return Err(error);
        }
        Err(error) => {
            sdk.retire();
            // A lost host output pipe can still have a fully owned process.
            // Persist proven cleanup when possible instead of leaving a
            // needless orphan. Unknown outcomes always keep both fences.
            let stopping = chats.transition_owned_run(source.target(), &prepared, State::Stopping);
            if let (Ok(_), Ok(proof)) = (stopping, process.stop()) {
                let _ = chats.complete_owned_run(source.target(), *prepared, proof, State::Failed);
            } else {
                let _ =
                    chats.transition_owned_run(source.target(), &prepared, State::NeedsRecovery);
            }
            let _ = authority.retire();
            return Err(error);
        }
    };
    let result = chats.complete_owned_run(source.target(), *prepared, proof, terminal);
    let _ = authority.retire();
    event(json!({"event":"finished","result":result?}))
}

pub(super) fn run(
    principal: &AuthorizedTeamPrincipal,
    input: &AskInput,
) -> Result<Value, DispatchError> {
    use std::process::{Command, Stdio};
    let helper = std::env::current_exe().map_err(map_io)?;
    if helper.file_stem() != Some(std::ffi::OsStr::new("tokenstat-hostd")) {
        return Err(DispatchError::new(
            "host_required",
            "Open this chat through its publishing computer.",
        ));
    }
    let owner = AccountSnapshot::capture().map_err(|_| unavailable())?;
    let init = Init {
        ticket: principal.run_ticket()?.ticket().wire_value().into(),
        device_key: principal.value().device_key.clone(),
        publisher: principal.value().publisher_id.clone(),
        issuer: principal.issuer().into(),
        host_authentication: owner
            .client
            .as_ref()
            .ok_or_else(unavailable)?
            .authentication_id(),
        input: Some(input.clone()),
        program: None,
    };
    principal.ensure_account_current()?;
    let mut command = Command::new(&helper);
    command
        .arg("team-run-guardian")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(())
                }
            });
        }
    }
    let mut child = command.spawn().map_err(map_io)?;
    let input = child.stdin.take().ok_or_else(unavailable)?;
    let mut parent = Parent {
        child: Some(child),
        input: Some(input),
    };
    team_process::send(parent.input.as_mut().ok_or_else(unavailable)?, &init).map_err(map_io)?;
    let mut output = BufReader::new(
        parent
            .child
            .as_mut()
            .ok_or_else(unavailable)?
            .stdout
            .take()
            .ok_or_else(unavailable)?,
    );
    // The production adapter is disabled and can only finish NotStarted.
    // Enabling real adapters requires a retained host registry/control owner.
    let response: Value = team_process::receive(&mut output).map_err(map_io)?;
    drop(parent.input.take());
    if response["event"] != "finished" {
        return Err(unavailable());
    }
    let status = parent
        .child
        .as_mut()
        .ok_or_else(unavailable)?
        .wait()
        .map_err(map_io)?;
    parent.child.take();
    if !status.success() {
        return Err(unavailable());
    }
    Ok(response["result"].clone())
}
