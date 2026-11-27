// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
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
use tokenstat_workspace::gitwrite::lane::Landing;
#[path = "guardian/output.rs"]
mod output;

const FIX_ATTEMPTS: u32 = 2;

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
    if fixture_enabled() && std::env::var_os("TOKENSTAT_TEAMS_KEEP_FIXTURE").is_some() {
        let trace = std::backtrace::Backtrace::force_capture().to_string();
        eprintln!(
            "Team fixture refusal:\n{}",
            trace.lines().take(24).collect::<Vec<_>>().join("\n")
        );
    }
    DispatchError::new(
        "team_run_recovery_required",
        "This Team run needs recovery on its publishing computer.",
    )
}
fn map_io(error: io::Error) -> DispatchError {
    if fixture_enabled() && std::env::var_os("TOKENSTAT_TEAMS_KEEP_FIXTURE").is_some() {
        eprintln!(
            "Team fixture I/O: {:?}, OS code {:?}",
            error.kind(),
            error.raw_os_error()
        );
    }
    unavailable()
}
fn fixture_stop(reason: &str) {
    if fixture_enabled() && std::env::var_os("TOKENSTAT_TEAMS_KEEP_FIXTURE").is_some() {
        eprintln!("Team fixture guardian stopped: {reason}");
    }
}
fn event(value: Value) -> Result<(), DispatchError> {
    team_process::send(&mut io::stdout().lock(), &value).map_err(map_io)
}

/// A debug build inside the disposable Team fixture. Both markers are made
/// by the fixture runner; a release build never answers yes.
pub(super) fn fixture_enabled() -> bool {
    if !cfg!(debug_assertions) {
        return false;
    }
    let (Some(data), Ok(identity)) = (
        tokenstat_paths::data_dir(),
        tokenstat_identity::identity_dir(),
    ) else {
        return false;
    };
    data.join(".teams-transport-fixture").is_file()
        && identity.join(".teams-transport-fixture").is_file()
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
    let mut stage = "bootstrap";
    let result = main_inner(&mut stage);
    if let Err(error) = &result
        && fixture_enabled()
        && std::env::var_os("TOKENSTAT_TEAMS_KEEP_FIXTURE").is_some()
    {
        eprintln!("Team fixture guardian stage={stage}; code={}", error.code);
    }
    result
}
fn main_inner(stage: &mut &'static str) -> Result<(), DispatchError> {
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
    *stage = "ticket";
    let principal = AuthorizedTeamPrincipal::guardian(&client, &ticket, device, init.publisher)?;
    let source = Source::capture(&principal)?;
    let checkout = checkout_digest(&source)?;
    let chats = crate::chat::shared();
    let Some(input) = init.input else {
        if init.program.is_some() {
            return Err(unavailable());
        }
        let review = chats.team_ask_review(
            source.target(),
            &principal,
            &source.checkout.folder.canonical,
            &checkout,
            || source.ensure_current(),
        )?;
        return event(json!({
            "event": "review",
            "review": review.digest,
            "agentRuns": false,
            "worktree": review.worktree
        }));
    };
    if let Some(program) = &init.program {
        fixture_program(program, &source, &init.issuer)?;
    }

    *stage = "lane";
    let lane_settings = super::lanes::settings(&principal.value().checkout_id)?;
    let mut lane = match &lane_settings {
        Some(settings) => Some(super::lanes::open(
            &source.checkout.folder.canonical,
            &principal.value().checkout_id,
            settings,
            &input.text,
            json!({"id": principal.value().person.id, "name": principal.value().person.name}),
            principal.value().share_id.clone(),
        )?),
        None => None,
    };
    let work_folder = match &lane {
        Some(lane) => lane.path.canonicalize().map_err(map_io)?,
        None => source.checkout.folder.canonical.clone(),
    };
    *stage = "prepare-ask";
    let mut prepared = match chats.prepare_team_ask(
        source.target(),
        &principal,
        &input,
        (
            &source.checkout.folder.canonical,
            &checkout,
            lane.as_ref().map(|lane| lane.path.as_path()),
        ),
        || source.ensure_current(),
    ) {
        Err(error) if error.code == "team_run_review_changed" => {
            drop(lane);
            return event(json!({"event":"rejected","code":"team_run_review_changed"}));
        }
        Err(error) => return Err(error),
        Ok(AskPreparation::Existing(receipt)) => {
            return event(json!({"event":"finished","result":receipt}));
        }
        Ok(AskPreparation::New(prepared)) => prepared,
    };
    let fixture = init.program.is_some();

    *stage = "provider";
    let launch = match init.program {
        Some(program) => Ok(program),
        None => (|| {
            super::provider::supported(prepared.backend())?;
            super::provider::program(
                &work_folder,
                &source.checkout.folder.canonical,
                prepared.backend(),
            )
        })(),
    };
    let mut program = match launch {
        Ok(mut program) => {
            program.folder.clone_from(&work_folder);
            program
        }
        Err(error) => {
            let _ = chats.refuse_prepared_ask(source.target(), *prepared);
            return Err(error);
        }
    };

    *stage = "authority";
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
    let helper = match std::env::current_exe() {
        Ok(helper) => helper,
        Err(error) => {
            let _ = authority.retire();
            let _ = chats.refuse_prepared_ask(source.target(), *prepared);
            return Err(map_io(error));
        }
    };
    let mut raw = std::fs::OpenOptions::new();
    raw.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        raw.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    *stage = "context";
    let context_written = (|| {
        if !fixture {
            return Ok(());
        }

        let context = prepared.context().sdk();
        let input = context.full_if_small(4 * 1024 * 1024)?.unwrap_or_else(|| {
            let mut metadata = context.metadata;
            metadata["contextViaSdk"] = json!(true);
            metadata
        });
        let mut file = raw.open(&program.input).map_err(map_io)?;
        serde_json::to_writer(&mut file, &input).map_err(|_| unavailable())?;
        file.sync_all().map_err(map_io)
    })();
    if let Err(error) = context_written {
        let _ = authority.retire();
        let _ = chats.refuse_prepared_ask(source.target(), *prepared);
        return Err(error);
    }
    *stage = "sdk";
    let sdk = (|| {
        let current = owner.clone();
        let sdk_source = Source::capture(&principal)?;
        source.ensure_current()?;
        crate::team_sdk::Service::start(
            &authority,
            prepared.context().sdk(),
            prepared.binding().fence.run_id().into(),
            lane.as_ref().map(|lane| lane.path.as_path()),
            move || {
                if current.ensure_current().is_err() {
                    fixture_stop("sdk account");
                    return false;
                }
                match sdk_source.ensure_current() {
                    Ok(()) => true,
                    Err(error) => {
                        fixture_stop(&format!("sdk source: {}", error.code));
                        false
                    }
                }
            },
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
    *stage = "run-home";
    let run_home = match super::run_home::prepare(
        &tokenstat_paths::data_dir()
            .ok_or_else(unavailable)?
            .join("team-run-homes"),
        &work_folder,
        &program,
    ) {
        Ok(home) => home,
        Err(error) => {
            let _ = authority.retire();
            let _ = chats.refuse_prepared_ask(source.target(), *prepared);
            return Err(map_io(error));
        }
    };
    program.folder.clone_from(&run_home.cwd);
    program.env.clone_from(&run_home.env);
    sdk.configure(&mut program);
    if !fixture
        && let Err(error) = super::provider::configure(
            &run_home,
            &mut program,
            &helper,
            prepared.backend(),
            lane.is_some(),
            &source.checkout.folder.canonical,
        )
    {
        let _ = authority.retire();
        let _ = chats.refuse_prepared_ask(source.target(), *prepared);
        return Err(map_io(error));
    }
    let mut output = output::Output::new(&program.output, prepared.backend());
    *stage = "writer-claim";
    prepared.claim_writer()?;
    let fence = prepared.binding().fence.clone();
    let (workspace, chat) = (
        source.target().workspace.to_string(),
        source.target().id.to_string(),
    );

    super::recovery::remember(&fence, &workspace, &chat, 0).map_err(map_io)?;
    chats.transition_owned_run(source.target(), &prepared, State::Launching)?;
    let base_program = program.clone();
    let message = input
        .text
        .lines()
        .next()
        .unwrap_or_default()
        .chars()
        .take(200)
        .collect::<String>();
    let birth = |group: u32, first: bool| -> io::Result<()> {
        super::recovery::remember(&fence, &workspace, &chat, group)?;
        source
            .ensure_current()
            .map_err(|_| io::Error::other("Run source changed."))?;
        if first {
            chats
                .ensure_launching_ask(source.target(), &prepared, || source.ensure_current())
                .map_err(|_| io::Error::other("Run source changed."))?;
        }
        Ok(())
    };
    *stage = "process-birth";
    let process = Owned::start(&helper, program, |group| {
        birth(group, true)?;
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
    *stage = "run-loop";
    let execution = (|| {
        control_thread.map_err(map_io)?;
        let mut renew = Instant::now() + Duration::from_secs(10);
        let mut ever_running = false;
        let mut attempt = 0u32;
        loop {
            let mut running = false;
            let terminal = loop {
                if authority.ensure_live().is_err() {
                    fixture_stop("authority");
                    break State::Stopped;
                }
                if source.ensure_current().is_err() {
                    fixture_stop("source");
                    break State::Stopped;
                }
                if sdk.ensure_live().is_err() {
                    fixture_stop("sdk");
                    break State::Stopped;
                }
                match control.try_recv() {
                    Ok(Ok(Control::Stop { fence })) if fence == prepared.binding().fence => {
                        fixture_stop("requested");
                        break State::Stopped;
                    }
                    Ok(Ok(_)) => {}
                    Ok(Err(_)) | Err(mpsc::TryRecvError::Disconnected) => {
                        fixture_stop("pipe closed");
                        break State::Stopped;
                    }
                    Err(mpsc::TryRecvError::Empty) => {}
                }
                match process.poll().map_err(map_io)? {
                    Poll::Started => {
                        if !ever_running {
                            chats.transition_owned_run(
                                source.target(),
                                &prepared,
                                State::Running,
                            )?;
                            sdk.running().map_err(map_io)?;
                            event(
                                json!({"event":"running","fence":prepared.binding().fence,"runId":prepared.binding().fence.run_id()}),
                            )?;
                        }
                        running = true;
                        ever_running = true;
                    }
                    Poll::Exited(code) => {
                        break if running && code == Some(0) {
                            State::Succeeded
                        } else {
                            State::Failed
                        };
                    }
                    Poll::LaunchFailed => {
                        break if ever_running {
                            State::Failed
                        } else {
                            State::NotStarted
                        };
                    }
                    Poll::Running => {}
                }
                if running {
                    output
                        .drain(false, |batch, events| {
                            chats
                                .append_owned_output(
                                    source.target(),
                                    &prepared,
                                    batch,
                                    events,
                                    || {
                                        authority.ensure_live().map_err(api_error)?;
                                        source.ensure_current()
                                    },
                                )
                                .map_err(|_| io::Error::other("Team output could not be verified."))
                        })
                        .map_err(map_io)?;
                }
                if Instant::now() >= renew {
                    if authority.renew().is_err() {
                        fixture_stop("authority renewal");
                        break State::Stopped;
                    }
                    if sdk.renew(&authority).is_err() {
                        fixture_stop("sdk renewal");
                        break State::Stopped;
                    }
                    renew = Instant::now() + Duration::from_secs(10);
                }
                std::thread::sleep(Duration::from_millis(100));
            };
            if terminal == State::Stopped {
                sdk.retire();
                chats.transition_owned_run(source.target(), &prepared, State::Stopping)?;
            }
            let proof = process.stop().map_err(map_io)?;
            sdk.pause_files();
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
            let (Some(lane), Some(settings)) = (lane.as_mut(), lane_settings.as_ref()) else {
                sdk.retire();
                return Ok((terminal, proof, final_output));
            };
            if terminal != State::Succeeded || final_output.is_err() {
                if terminal != State::NotStarted {
                    super::lanes::abandon(lane);
                }
                sdk.retire();
                return Ok((terminal, proof, final_output));
            }

            let stop_waiting = match control.try_recv() {
                Ok(Ok(Control::Stop { fence })) => fence == prepared.binding().fence,
                Ok(Err(_)) | Err(mpsc::TryRecvError::Disconnected) => true,
                Err(mpsc::TryRecvError::Empty) => false,
            };
            let may_land =
                !stop_waiting && authority.renew().is_ok() && source.ensure_current().is_ok();
            let mut cancelled = !may_land;
            let mut unproven_check = false;
            let mut renew_check = Instant::now() + Duration::from_secs(10);
            let mut allowed = || -> Result<(), String> {
                cancelled |= match control.try_recv() {
                    Ok(Ok(Control::Stop { fence })) => fence == prepared.binding().fence,
                    Ok(Err(_)) | Err(mpsc::TryRecvError::Disconnected) => true,
                    Err(mpsc::TryRecvError::Empty) => false,
                };
                if !cancelled && Instant::now() >= renew_check {
                    cancelled = authority.renew().is_err() || sdk.renew(&authority).is_err();
                    renew_check = Instant::now() + Duration::from_secs(10);
                }
                cancelled |= !authority
                    .remaining()
                    .is_ok_and(|left| left >= team_process::BIRTH)
                    || source.ensure_current().is_err();
                if cancelled {
                    Err("The run was stopped or lost its permission before landing.".into())
                } else {
                    Ok(())
                }
            };
            let mut landing_control =
                |step: tokenstat_workspace::gitwrite::lane::Control<'_>| match step {
                    tokenstat_workspace::gitwrite::lane::Control::Guard => allowed(),
                    tokenstat_workspace::gitwrite::lane::Control::Check(folder, command) => {
                        match super::lane_check::run(
                            &helper,
                            folder,
                            command,
                            &mut allowed,
                            |group| birth(group, false),
                        ) {
                            Ok(result) => result,
                            Err(error) => {
                                if fixture_enabled() {
                                    eprintln!("Fixture check cleanup: {error}");
                                }
                                unproven_check = true;
                                Err("The check process needs recovery on this computer.".into())
                            }
                        }
                    }
                };
            let landing = if !may_land {
                lane.keep();
                super::lanes::abandon(lane);
                Landing::Blocked {
                    message: "The run was stopped or lost its permission before landing.".into(),
                }
            } else if attempt == 0 {
                super::lanes::finish(lane, settings, &message, &mut landing_control)
            } else {
                super::lanes::finish_fix(lane, settings, &message, &mut landing_control)
            };
            if matches!(landing, Landing::Landed { .. }) {
                let _ = client.checkout_moved(
                    &principal.value().organization_id,
                    &principal.value().checkout_id,
                );
            }
            let pull_note = if settings.review
                && settings.pull_request
                && matches!(landing, Landing::Ready { .. })
            {
                Some(super::lanes::open_pull(
                    lane,
                    settings,
                    &message,
                    &workspace,
                    &mut landing_control,
                ))
            } else {
                None
            };
            let next = if attempt < FIX_ATTEMPTS
                && !matches!(
                    landing,
                    Landing::Landed { .. } | Landing::Ready { .. } | Landing::Nothing
                ) {
                super::lanes::next_step(lane, settings, landing, &message, &mut landing_control)
            } else {
                super::lanes::Next::Done(landing)
            };
            if unproven_check {
                lane.keep();
                return Err(DispatchError::new(
                    "team_run_recovery_required",
                    "The check process needs recovery on its publishing computer.",
                ));
            }

            let renewed = authority.renew().is_ok();
            let next = match next {
                super::lanes::Next::Agent(_) if !renewed => {
                    super::lanes::Next::Done(Landing::Blocked {
                        message: "This run's permission ended before the fix.".into(),
                    })
                }
                other => other,
            };
            let (note, instruction) = match next {
                super::lanes::Next::Done(landing) => (
                    pull_note.unwrap_or_else(|| super::lanes::describe(&landing, lane, settings)),
                    None,
                ),
                super::lanes::Next::Agent(instruction) => (
                    "This work could not land as it was, so the agent is working on it again."
                        .to_string(),
                    Some(instruction),
                ),
            };
            let posted = if !renewed {
                Ok(())
            } else {
                output.note(&note, |batch, events| {
                    chats
                        .append_owned_output(source.target(), &prepared, batch, events, || {
                            authority.ensure_live().map_err(api_error)?;
                            source.ensure_current()
                        })
                        .map_err(|_| io::Error::other("Team output could not be verified."))
                })
            };
            let Some(instruction) = instruction else {
                let terminal = if cancelled {
                    chats.transition_owned_run(source.target(), &prepared, State::Stopping)?;
                    State::Stopped
                } else {
                    terminal
                };
                sdk.retire();
                return Ok((terminal, proof, final_output.and(posted.map_err(map_io))));
            };
            attempt += 1;
            let mut follow = base_program.clone();
            if fixture {
                follow.input = run_home.file(&format!("input-{attempt}"));
                follow.output = run_home.file(&format!("output-{attempt}"));
                follow.errors = run_home.file(&format!("errors-{attempt}"));
                std::fs::write(&follow.input, &instruction).map_err(map_io)?;
            } else {
                super::provider::follow_up(
                    &run_home,
                    &mut follow,
                    &helper,
                    prepared.backend(),
                    attempt,
                    &instruction,
                )
                .map_err(map_io)?;
            }
            output.follow(&follow.output);
            let _ = proof;
            sdk.resume_files().map_err(map_io)?;
            sdk.configure(&mut follow);
            process = Owned::start(&helper, follow, |group| {
                birth(group, false)?;
                if authority
                    .remaining()
                    .map_err(|_| io::Error::other("Run authority expired."))?
                    < team_process::BIRTH
                {
                    return Err(io::Error::other("Run authority expired."));
                }
                Ok(())
            })
            .map_err(map_io)?;
        }
    })();
    let (terminal, proof) = match execution {
        Ok((terminal, proof, Ok(()))) => (terminal, proof),
        Ok((_, _, Err(error))) => {
            let _ = chats.transition_owned_run(source.target(), &prepared, State::NeedsRecovery);
            let _ = authority.retire();
            return Err(error);
        }
        Err(error) => {
            sdk.retire();

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

    drop(lane);
    if result.is_ok() {
        super::recovery::forget(&fence);
    }
    let _ = authority.retire();
    event(json!({"event":"finished","result":result?}))
}

pub(super) fn run(
    principal: &AuthorizedTeamPrincipal,
    input: &AskInput,
) -> Result<Value, DispatchError> {
    use std::process::{Command, Stdio};

    let (helper, program) = if fixture_enabled()
        && let Some(hostd) = std::env::var_os("TOKENSTAT_TEAM_FIXTURE_HOSTD")
    {
        let file = tokenstat_paths::data_dir()
            .ok_or_else(unavailable)?
            .join("guardian-fixture/program.json");
        let program = match std::fs::read(&file) {
            Ok(bytes) => {
                Some(serde_json::from_slice::<Program>(&bytes).map_err(|_| unavailable())?)
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(map_io(error)),
        };
        (std::path::PathBuf::from(hostd), program)
    } else {
        (std::env::current_exe().map_err(map_io)?, None)
    };
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
        program,
    };
    principal.ensure_account_current()?;
    let mut command = Command::new(&helper);
    command
        .arg("team-run-guardian")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    if fixture_enabled() && std::env::var_os("TOKENSTAT_TEAMS_KEEP_FIXTURE").is_some() {
        command.stderr(Stdio::inherit());
    }
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
    let response: Value = team_process::receive(&mut output).map_err(map_io)?;
    if response["event"] == "running" {
        let fence: Fence =
            serde_json::from_value(response["fence"].clone()).map_err(|_| unavailable())?;
        let input = parent.input.take().ok_or_else(unavailable)?;
        let child = parent.child.take().ok_or_else(unavailable)?;
        super::runs::register(principal, fence, input, child, output)?;
        return Ok(json!({"state":"running","runId":response["runId"],"fence":response["fence"]}));
    }
    drop(parent.input.take());
    let review_changed = response == json!({"event":"rejected","code":"team_run_review_changed"});
    if response["event"] != "finished" && !review_changed {
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
    if review_changed {
        return Err(DispatchError::new(
            "team_run_review_changed",
            "The shared conversation or checkout changed. Review it before asking the agent.",
        ));
    }
    let result = response["result"].clone();
    Ok(super::runs::resume(principal, &result).unwrap_or(result))
}
