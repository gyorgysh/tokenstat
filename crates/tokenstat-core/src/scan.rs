//! Discovery and parallel ingestion.

use std::path::PathBuf;

use rayon::prelude::*;

use crate::error::{CoreError, Warning};
use crate::model::SourceId;
use crate::sources::claude_stats::Reconciliation;
use crate::sources::{
    antigravity_cache, antigravity_cli, claude_code, claude_stats, cline, codex, copilot, grok,
    openclaw, opencode, zed,
};
use crate::store::Store;
use crate::watermark;

/// Result of considering one file during a scan.
struct FileOutcome {
    parsed: Parsed,
    /// False when the file was skipped because nothing had changed.
    read: bool,
    mark: Option<(String, watermark::Watermark)>,
}

/// Parser output, in the shape the pipeline needs regardless of source.
#[derive(Default)]
struct Parsed {
    events: Vec<crate::model::UsageEvent>,
    warnings: Vec<Warning>,
    rows_seen: u64,
}

macro_rules! from_parsed {
    ($($ty:ty),+ $(,)?) => {$(
        impl From<$ty> for Parsed {
            fn from(p: $ty) -> Parsed {
                Parsed {
                    events: p.events,
                    warnings: p.warnings,
                    rows_seen: p.rows_seen,
                }
            }
        }
    )+};
}

from_parsed!(
    claude_code::ParseOutput,
    codex::ParseOutput,
    grok::ParseOutput,
    opencode::ParseOutput,
    cline::ParseOutput,
    antigravity_cli::ParseOutput,
    antigravity_cache::ParseOutput,
    openclaw::ParseOutput,
    zed::ParseOutput,
    copilot::ParseOutput,
);

impl FileOutcome {
    fn skipped() -> Self {
        FileOutcome {
            parsed: Parsed::default(),
            read: false,
            mark: None,
        }
    }
}

/// What a scan found.
#[derive(Debug, Default)]
pub struct ScanReport {
    /// Files discovered on disk.
    pub files_found: u64,
    /// Files actually opened. The rest were unchanged since the last scan.
    pub files_read: u64,
    /// Assistant rows seen across all files, before deduplication.
    pub rows_seen: u64,
    /// Rows that were genuinely new to the archive.
    pub events_new: u64,
    pub warnings: Vec<Warning>,
    /// Rows recovered from Claude Code's rollup for days whose transcripts are
    /// already deleted.
    pub events_recovered: u64,
    pub days_recovered: u64,
    /// Days a vendor's own rollup says were worked and for which no token count
    /// exists anywhere: the transcripts were deleted before the first scan, and
    /// the vendor kept the activity but not the counts.
    ///
    /// Reported rather than estimated. These days are real and their usage is
    /// unknowable, and a chart that draws them the same as a day off is the
    /// thing that makes somebody distrust a total that is actually correct for
    /// what it can see.
    pub days_active_unmeasured: Vec<String>,
    pub elapsed_ms: u128,
}

impl ScanReport {
    /// Share of rows that were already present, either from an earlier scan or
    /// because a session resume rewrote them into another file.
    pub fn duplicate_ratio(&self) -> f64 {
        if self.rows_seen == 0 {
            return 0.0;
        }
        1.0 - (self.events_new as f64 / self.rows_seen as f64)
    }
}

/// Read every discoverable source into the archive.
pub fn scan(store: &mut Store, tz: &jiff::tz::TimeZone) -> Result<ScanReport, CoreError> {
    let started = std::time::Instant::now();
    let mut report = ScanReport::default();

    let Some(home) = home_dir() else {
        report
            .warnings
            .push(Warning::SourceNotInstalled { source: "home" });
        return Ok(report);
    };

    let marks = store.watermarks()?;
    let mut all_events = Vec::new();
    let mut marks_to_store = Vec::new();

    // Claude Code.
    if let Some(projects) = claude_code::discover(&home) {
        let files = claude_code::shards(&projects);
        report.files_found += files.len() as u64;
        let parsed: Vec<_> = files
            .par_iter()
            .map(|path| {
                read_shard(path, &marks, |p, text| {
                    claude_code::parse_file(p, &projects, text).into()
                })
            })
            .collect();
        absorb(&mut report, &mut all_events, &mut marks_to_store, parsed);

        // Recover history the transcripts no longer hold.
        if let Some(stats_path) = claude_stats::path_for(&projects) {
            let stats_key = stats_path.to_string_lossy().into_owned();
            let stats_prev = marks.get(&stats_key);
            let stats_meta = std::fs::metadata(&stats_path).ok();
            let stats_size = stats_meta.as_ref().map(|m| m.len()).unwrap_or(0);
            let stats_mtime = stats_meta
                .as_ref()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            // How the numbers in this file are read, not what is in it.
            //
            // The recovered rows are derived, so a fix to the derivation makes
            // every row already in the archive wrong, and the watermark cannot
            // see that: the file has not changed, only our reading of it. A
            // version stamped in the archive is what lets a corrected build
            // rebuild rows an older one got wrong, instead of leaving them
            // until Claude Code happens to touch the file again.
            //
            // Bump this whenever `claude_stats::backfill_events` changes what
            // it would produce from the same input.
            const RECOVERY_LOGIC_VERSION: &str = "3";
            // Ours and the vendor's, together. Either moving makes the stored
            // rows stale: a fix here changes what the same input produces, and
            // a bump there changes what the input means.
            let vendor_version = std::fs::read_to_string(&stats_path)
                .ok()
                .and_then(|c| claude_stats::daily_tokens_version(&c));
            let stamp = format!(
                "{RECOVERY_LOGIC_VERSION}/{}",
                vendor_version
                    .map(|v| v.to_string())
                    .unwrap_or_else(|| "-".into())
            );
            let recovery_stale =
                store.meta("claude_rollup_logic").ok().flatten().as_deref() != Some(stamp.as_str());
            let stats_unchanged = watermark::classify(stats_prev, stats_size, stats_mtime)
                == watermark::Change::Unchanged
                && !recovery_stale;
            // Keep our own copy of the vendor's window, whether or not the
            // recovery below has anything to do. The vendor's window slides and
            // ours never shrinks, so history stops being as short as whatever
            // Claude Code still happens to publish. Runs on every scan, not
            // only when the recovery is stale, because the point is to catch a
            // day before it falls off the far end.
            if let Ok(contents) = std::fs::read_to_string(&stats_path) {
                let now = jiff::Timestamp::now().to_string();
                let mut seen: Vec<crate::store::VendorDay> = Vec::new();
                for (date, by_model) in claude_stats::daily_model_tokens(&contents) {
                    for (model, tokens) in by_model {
                        seen.push(crate::store::VendorDay {
                            day: date.clone(),
                            model,
                            tokens,
                            ..Default::default()
                        });
                    }
                }
                for a in claude_stats::daily_activity(&contents) {
                    seen.push(crate::store::VendorDay {
                        day: a.date,
                        model: String::new(),
                        messages: a.messages,
                        sessions: a.sessions,
                        ..Default::default()
                    });
                }
                store.record_vendor_days("claude_code", &seen, &now)?;
            }
            report.days_active_unmeasured = store.days_active_without_usage("claude_code")?;
            if !stats_unchanged {
                if let Ok(contents) = std::fs::read_to_string(&stats_path) {
                    if let Some(stats) = claude_stats::parse(&contents) {
                        // From our copy, not the file: a day the vendor has
                        // since dropped is still recoverable from here.
                        let daily = vendor_daily_tokens(store)?;
                        store.clear_recovered()?;
                        store.set_meta("claude_rollup_logic", &stamp)?;
                        let have = store.archive_by_date_model()?;
                        let recovered = claude_stats::backfill_events(&stats, &daily, &have, tz);
                        report.warnings.extend(recovered.warnings);
                        let events = recovered.events;
                        report.days_recovered = events
                            .iter()
                            .map(|e| e.ts.local_date(tz))
                            .collect::<std::collections::HashSet<_>>()
                            .len() as u64;
                        report.events_recovered = events.len() as u64;
                        all_events.extend(events);
                        let (head_sig, sig_len) = watermark::head_signature(contents.as_bytes());
                        marks_to_store.push((
                            stats_key,
                            watermark::Watermark {
                                size: stats_size,
                                mtime_ms: stats_mtime,
                                head_sig,
                                sig_len,
                                byte_offset: contents.len() as u64,
                            },
                        ));
                    }
                }
            }
        }
    }

    // Codex: JSONL, but session_meta / turn_context live at the start of the
    // file. An append-only reparse of the tail would lose that context and
    // reset ordinals, so any change re-reads the whole rollout.
    if let Some(sessions) = codex::discover(&home) {
        let files = codex::shards(&sessions);
        report.files_found += files.len() as u64;
        let outcomes: Vec<_> = files
            .par_iter()
            .map(|path| {
                read_document_shard(path, &marks, |p, text| codex::parse_file(p, text).into())
            })
            .collect();
        absorb(&mut report, &mut all_events, &mut marks_to_store, outcomes);
    }

    // Grok: one append-only log plus a session summary index for model/project.
    if let Some(grok_home) = grok::discover(&home) {
        if let Some(log) = grok::log_path(&grok_home) {
            report.files_found += 1;
            let sessions = grok::session_index(&grok_home);
            let outcome = read_shard(&log, &marks, |p, text| {
                grok::parse_file(p, text, &sessions).into()
            });
            absorb(
                &mut report,
                &mut all_events,
                &mut marks_to_store,
                vec![outcome],
            );
        }
    }

    // OpenCode: SQLite. Re-parse when the db file changes.
    if let Some(db) = opencode::discover(&home) {
        report.files_found += 1;
        let outcome = read_db_shard(&db, &marks, |p| opencode::parse_db(p).into());
        absorb(
            &mut report,
            &mut all_events,
            &mut marks_to_store,
            vec![outcome],
        );
    }

    // Cline: whole-document JSON. Always re-parse the full file on change;
    // append-tail parsing would leave an invalid JSON fragment and permanently
    // miss growth while the head signature stayed stable.
    if let Some(sessions) = cline::discover(&home) {
        let files = cline::shards(&sessions);
        report.files_found += files.len() as u64;
        let outcomes: Vec<_> = files
            .par_iter()
            .map(|path| {
                read_document_shard(path, &marks, |p, text| cline::parse_file(p, text).into())
            })
            .collect();
        absorb(&mut report, &mut all_events, &mut marks_to_store, outcomes);
    }

    // Antigravity CLI: SQLite + protobuf gen_metadata (offline).
    if let Some(conversations) = antigravity_cli::discover(&home) {
        let files = antigravity_cli::shards(&conversations);
        report.files_found += files.len() as u64;
        let outcomes: Vec<_> = files
            .par_iter()
            .map(|path| read_db_shard(path, &marks, |p| antigravity_cli::parse_db(p).into()))
            .collect();
        absorb(&mut report, &mut all_events, &mut marks_to_store, outcomes);
    }

    // Antigravity IDE: JSONL written by tokenstat-sync when the language server
    // is reachable. Soft-empty when the IDE has never been synced.
    if let Some(cache) = antigravity_cache::discover() {
        let files = antigravity_cache::shards(&cache);
        report.files_found += files.len() as u64;
        let outcomes: Vec<_> = files
            .par_iter()
            .map(|path| {
                read_shard(path, &marks, |p, text| {
                    antigravity_cache::parse_file(p, text).into()
                })
            })
            .collect();
        absorb(&mut report, &mut all_events, &mut marks_to_store, outcomes);
    }

    // OpenClaw: trajectory turns preferred; session rollups only when a session
    // has no turn-level usage (otherwise the same tokens would count twice).
    if let Some(agents) = openclaw::discover(&home) {
        let trajectories = openclaw::trajectory_shards(&agents);
        report.files_found += trajectories.len() as u64;
        let outcomes: Vec<_> = trajectories
            .par_iter()
            .map(|path| {
                read_shard(path, &marks, |p, text| {
                    openclaw::parse_trajectory_file(p, text).into()
                })
            })
            .collect();
        let mut turn_sessions = std::collections::HashSet::new();
        for outcome in &outcomes {
            for e in &outcome.parsed.events {
                turn_sessions.insert(e.session.clone());
            }
        }
        absorb(&mut report, &mut all_events, &mut marks_to_store, outcomes);

        let sessions = openclaw::session_shards(&agents);
        report.files_found += sessions.len() as u64;
        let outcomes: Vec<_> = sessions
            .par_iter()
            .map(|path| {
                read_document_shard(path, &marks, |p, text| {
                    openclaw::parse_sessions_file(p, text).into()
                })
            })
            .collect();
        let outcomes: Vec<_> = outcomes
            .into_iter()
            .map(|mut outcome| {
                outcome
                    .parsed
                    .events
                    .retain(|e| !turn_sessions.contains(&e.session));
                outcome
            })
            .collect();
        absorb(&mut report, &mut all_events, &mut marks_to_store, outcomes);
    }

    // Zed agent threads (zstd JSON in SQLite). Empty usage is a no-op.
    if let Some(db) = zed::discover(&home) {
        report.files_found += 1;
        let outcome = read_db_shard(&db, &marks, |p| zed::parse_db(p).into());
        absorb(
            &mut report,
            &mut all_events,
            &mut marks_to_store,
            vec![outcome],
        );
    }

    // Copilot CLI: session-store.db assistant_usage_events (not the plain logs).
    if let Some(db) = copilot::discover(&home) {
        report.files_found += 1;
        let outcome = read_db_shard(&db, &marks, |p| copilot::parse_db(p).into());
        absorb(
            &mut report,
            &mut all_events,
            &mut marks_to_store,
            vec![outcome],
        );
    }

    let recovered = all_events
        .iter()
        .filter(|e| e.source == SourceId::ClaudeCodeRollup)
        .count() as u64;
    report.events_new = store.insert_events(&all_events, tz)?;
    report.events_recovered = recovered;
    store.set_watermarks(&marks_to_store)?;

    store.set_meta("last_scan_ms", &now_ms().to_string())?;
    report.elapsed_ms = started.elapsed().as_millis();
    Ok(report)
}

fn absorb(
    report: &mut ScanReport,
    all_events: &mut Vec<crate::model::UsageEvent>,
    marks_to_store: &mut Vec<(String, watermark::Watermark)>,
    outcomes: Vec<FileOutcome>,
) {
    for mut o in outcomes {
        if o.read {
            report.files_read += 1;
        }
        report.rows_seen += o.parsed.rows_seen;
        report.warnings.append(&mut o.parsed.warnings);
        all_events.extend(o.parsed.events);
        if let Some(m) = o.mark {
            marks_to_store.push(m);
        }
    }
}

/// Read one text shard incrementally and hand its new content to a parser.
fn read_shard(
    path: &std::path::Path,
    marks: &std::collections::HashMap<String, watermark::Watermark>,
    parse: impl Fn(&std::path::Path, &str) -> Parsed,
) -> FileOutcome {
    use std::io::{Read, Seek, SeekFrom};

    let key = path.to_string_lossy().into_owned();
    let previous = marks.get(&key);

    let Ok(meta) = std::fs::metadata(path) else {
        return FileOutcome::skipped();
    };
    let size = meta.len();
    let mtime_ms = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);

    let provisional = watermark::classify(previous, size, mtime_ms);
    if provisional == watermark::Change::Unchanged {
        return FileOutcome::skipped();
    }

    let mut file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) => {
            let mut out = FileOutcome::skipped();
            out.parsed.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: e.to_string(),
            });
            return out;
        }
    };

    // Confirm append vs rewrite using only the previously signed head, not the
    // whole multi-hundred-MB file.
    let change = match (provisional, previous) {
        (watermark::Change::Appended { from_byte }, Some(w)) => {
            let mut head = vec![0u8; w.sig_len as usize];
            match file.read_exact(&mut head) {
                Ok(()) if watermark::signature_of(&head, head.len()) == w.head_sig => {
                    watermark::Change::Appended { from_byte }
                }
                Ok(()) | Err(_) => watermark::Change::Rewritten,
            }
        }
        (other, _) => other,
    };

    let start = match change {
        watermark::Change::Appended { from_byte } => from_byte as usize,
        _ => 0,
    };

    let (tail, head_for_sig): (Vec<u8>, Vec<u8>) = if start == 0 {
        let mut contents = Vec::new();
        if let Err(e) = file
            .seek(SeekFrom::Start(0))
            .and_then(|_| file.read_to_end(&mut contents))
        {
            let mut out = FileOutcome::skipped();
            out.parsed.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: e.to_string(),
            });
            return out;
        }
        let head = contents
            .get(..contents.len().min(watermark::HEAD_BYTES))
            .unwrap_or(&[])
            .to_vec();
        (contents, head)
    } else {
        // Keep the prior head signature on pure appends (prefix unchanged).
        let head = {
            let mut h = vec![0u8; previous.map(|w| w.sig_len as usize).unwrap_or(0)];
            if let Err(e) = file
                .seek(SeekFrom::Start(0))
                .and_then(|_| file.read_exact(&mut h))
            {
                let mut out = FileOutcome::skipped();
                out.parsed.warnings.push(Warning::Unreadable {
                    path: path.to_path_buf(),
                    reason: e.to_string(),
                });
                return out;
            }
            h
        };
        let mut tail = Vec::new();
        if let Err(e) = file
            .seek(SeekFrom::Start(start as u64))
            .and_then(|_| file.read_to_end(&mut tail))
        {
            let mut out = FileOutcome::skipped();
            out.parsed.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: e.to_string(),
            });
            return out;
        }
        (tail, head)
    };

    let text = String::from_utf8_lossy(&tail);
    let parsed = parse(path, &text);
    let consumed = start as u64 + watermark::last_complete_line_end(&tail);
    let (head_sig, sig_len) = if start == 0 {
        watermark::head_signature(&tail)
    } else if let Some(w) = previous {
        // Append: same signed prefix as before.
        (w.head_sig.clone(), w.sig_len)
    } else {
        let len = head_for_sig.len().min(watermark::HEAD_BYTES);
        (watermark::signature_of(&head_for_sig, len), len as u64)
    };

    FileOutcome {
        parsed,
        read: true,
        mark: Some((
            key,
            watermark::Watermark {
                size,
                mtime_ms,
                head_sig,
                sig_len,
                byte_offset: consumed,
            },
        )),
    }
}

/// Watermark a whole-document text file (JSON object/array, or JSONL that
/// needs early context). Any change re-parses the full contents; append-tail
/// parsing would leave an invalid fragment or drop session headers.
fn read_document_shard(
    path: &std::path::Path,
    marks: &std::collections::HashMap<String, watermark::Watermark>,
    parse: impl Fn(&std::path::Path, &str) -> Parsed,
) -> FileOutcome {
    let key = path.to_string_lossy().into_owned();
    let previous = marks.get(&key);

    let Ok(meta) = std::fs::metadata(path) else {
        return FileOutcome::skipped();
    };
    let size = meta.len();
    let mtime_ms = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);

    if watermark::classify(previous, size, mtime_ms) == watermark::Change::Unchanged {
        return FileOutcome::skipped();
    }

    let contents = match std::fs::read(path) {
        Ok(c) => c,
        Err(e) => {
            let mut out = FileOutcome::skipped();
            out.parsed.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: e.to_string(),
            });
            return out;
        }
    };
    let change = watermark::confirm(
        watermark::classify(previous, size, mtime_ms),
        previous,
        &contents,
    );
    if change == watermark::Change::Unchanged {
        return FileOutcome::skipped();
    }

    let text = String::from_utf8_lossy(&contents);
    let parsed = parse(path, &text);
    FileOutcome {
        parsed,
        read: true,
        mark: Some((key, {
            let (head_sig, sig_len) = watermark::head_signature(&contents);
            watermark::Watermark {
                size,
                mtime_ms,
                head_sig,
                sig_len,
                byte_offset: size,
            }
        })),
    }
}

/// Watermark a binary/SQLite file and re-parse it wholesale when it changes.
fn read_db_shard(
    path: &std::path::Path,
    marks: &std::collections::HashMap<String, watermark::Watermark>,
    parse: impl Fn(&std::path::Path) -> Parsed,
) -> FileOutcome {
    let key = path.to_string_lossy().into_owned();
    let previous = marks.get(&key);

    let Ok(meta) = std::fs::metadata(path) else {
        return FileOutcome::skipped();
    };
    let size = meta.len();
    let mtime_ms = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);

    if watermark::classify(previous, size, mtime_ms) == watermark::Change::Unchanged {
        return FileOutcome::skipped();
    }

    // Confirm with a head signature so a same-size rewrite is still caught.
    let head = match std::fs::File::open(path).and_then(|mut f| {
        use std::io::Read;
        let mut buf = vec![0u8; 4096.min(size as usize)];
        let n = f.read(&mut buf)?;
        buf.truncate(n);
        Ok(buf)
    }) {
        Ok(b) => b,
        Err(e) => {
            let mut out = FileOutcome::skipped();
            out.parsed.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: e.to_string(),
            });
            return out;
        }
    };
    let change = watermark::confirm(
        watermark::classify(previous, size, mtime_ms),
        previous,
        &head,
    );
    if change == watermark::Change::Unchanged {
        return FileOutcome::skipped();
    }

    let parsed = parse(path);
    FileOutcome {
        parsed,
        read: true,
        mark: Some((key, {
            let (head_sig, sig_len) = watermark::head_signature(&head);
            watermark::Watermark {
                size,
                mtime_ms,
                head_sig,
                sig_len,
                byte_offset: size,
            }
        })),
    }
}

/// Compare the archive against Claude Code's own rollup.
pub fn reconcile(store: &Store) -> Result<Option<Reconciliation>, CoreError> {
    let Some(home) = home_dir() else {
        return Ok(None);
    };
    let Some(projects) = claude_code::discover(&home) else {
        return Ok(None);
    };
    let Some(stats_path) = claude_stats::path_for(&projects) else {
        return Ok(None);
    };
    let Ok(contents) = std::fs::read_to_string(&stats_path) else {
        return Ok(None);
    };
    let Some(stats) = claude_stats::parse(&contents) else {
        return Ok(None);
    };

    let totals = store.totals(&crate::store::Query::default())?;
    Ok(Some(Reconciliation {
        vendor_in_out: stats.in_out_total(),
        archive_in_out: store.in_out_total()?,
        vendor_sessions: stats.total_sessions,
        archive_sessions: totals.sessions,
        vendor_first_date: stats
            .first_session_date
            .as_deref()
            .and_then(|s| s.get(..10))
            .map(str::to_string),
        archive_first_date: totals.first_date,
        vendor_last_computed: stats.last_computed_date.clone(),
    }))
}

fn home_dir() -> Option<PathBuf> {
    directories::BaseDirs::new().map(|d| d.home_dir().to_path_buf())
}

fn now_ms() -> i64 {
    jiff::Timestamp::now().as_millisecond()
}

/// One day of vendor-reported tokens, by model.
type DailyModelTokens = (String, std::collections::BTreeMap<String, u64>);

/// The per-day model tokens the archive has ever seen, newest reading winning.
///
/// The recovery reads this rather than the vendor's file so a day that has
/// fallen out of the vendor's window is still recoverable from our own copy.
fn vendor_daily_tokens(store: &Store) -> Result<Vec<DailyModelTokens>, CoreError> {
    let mut by_day: std::collections::BTreeMap<String, std::collections::BTreeMap<String, u64>> =
        std::collections::BTreeMap::new();
    for row in store.vendor_days("claude_code")? {
        if row.model.is_empty() || row.tokens == 0 {
            continue;
        }
        by_day
            .entry(row.day)
            .or_default()
            .insert(row.model, row.tokens);
    }
    Ok(by_day.into_iter().collect())
}
