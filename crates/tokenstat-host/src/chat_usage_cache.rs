// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use std::collections::VecDeque;
use std::time::SystemTime;

const ENTRIES: usize = 8;
const RECORDS: usize = 4096;
const ENTRY_BYTES: usize = 512 * 1024;

#[derive(PartialEq, Eq)]
struct Stamp {
    length: u64,
    modified: SystemTime,
    created: Option<SystemTime>,
    #[cfg(unix)]
    identity: (u64, u64, i64, i64),
    #[cfg(windows)]
    identity: (u64, [u8; 16]),
}
impl Stamp {
    fn read(file: &fs::File) -> Option<Self> {
        let metadata = file.metadata().ok()?;
        Some(Self {
            length: metadata.len(),
            modified: metadata.modified().ok()?,
            created: metadata.created().ok(),
            #[cfg(windows)]
            identity: crate::win32::file_identity(file)?,
            #[cfg(unix)]
            identity: {
                use std::os::unix::fs::MetadataExt;
                (
                    metadata.dev(),
                    metadata.ino(),
                    metadata.ctime(),
                    metadata.ctime_nsec(),
                )
            },
        })
    }
}

struct Entry {
    path: PathBuf,
    muse: bool,
    stamp: Stamp,
    totals: Value,
    records: Vec<Value>,
}

/// Only transcript-derived counters and repair metadata are cached. Vendor logs
/// and the shared output chain remain live inputs. Large metadata sets bypass
/// the cache while continuing through the same bounded transcript reader.
#[derive(Default)]
pub(super) struct Cache {
    entries: VecDeque<Entry>,
}
impl Cache {
    pub(super) fn visit(
        &mut self,
        path: &Path,
        muse: bool,
        mut visit: impl FnMut(Value) -> Result<(), String>,
    ) -> Result<Option<Value>, String> {
        // Open before lookup so a missing, replaced or unreadable leaf cannot
        // be hidden by a previously cached result.
        let Some(file) = open_transcript(path)? else {
            self.entries.retain(|entry| entry.path != path);
            return Ok(None);
        };
        let stamp = Stamp::read(&file);
        if let Some(index) = self.entries.iter().position(|entry| {
            entry.path == path && entry.muse == muse && Some(&entry.stamp) == stamp.as_ref()
        }) {
            let entry = self.entries.remove(index).unwrap();
            for record in &entry.records {
                visit(record.clone())?;
            }
            let totals = entry.totals.clone();
            self.entries.push_back(entry);
            return Ok(Some(totals));
        }
        self.entries.retain(|entry| entry.path != path);
        let mut records = Vec::new();
        let mut bytes = 0usize;
        let mut cacheable = stamp.is_some();
        let mut seen_codex = false;
        let check_file = file.try_clone().ok();
        cacheable &= check_file.is_some();
        let totals = usage_totals_in_file(file, |line| {
            if let Some(record) = usage_repair_record(line, muse, &mut seen_codex) {
                let record = metadata_only(record);
                if cacheable {
                    bytes = bytes.saturating_add(
                        serde_json::to_vec(&record)
                            .map_err(|error| error.to_string())?
                            .len(),
                    );
                    if records.len() < RECORDS && bytes <= ENTRY_BYTES {
                        records.push(record.clone());
                    } else {
                        records.clear();
                        cacheable = false;
                    }
                }
                visit(record)?;
            }
            Ok(())
        })?;
        if cacheable && stamp == check_file.as_ref().and_then(Stamp::read) {
            if self.entries.len() == ENTRIES {
                self.entries.pop_front();
            }
            self.entries.push_back(Entry {
                path: path.to_owned(),
                muse,
                stamp: stamp.unwrap(),
                totals: totals.clone(),
                records,
            });
        }
        Ok(Some(totals))
    }
}

/// The repair pass needs selectors, timestamps, counters and session identity,
/// never a prompt, tool result or arbitrary provider fields.
fn metadata_only(mut record: Value) -> Value {
    if !record.is_object() {
        return Value::Null;
    }
    if let Some(object) = record.as_object_mut() {
        object.retain(|key, _| {
            matches!(
                key.as_str(),
                "kind" | "backend" | "at_ms" | "atMs" | "event" | "usage"
            )
        });
        if let Some(event) = object.get_mut("event").and_then(Value::as_object_mut) {
            event.retain(|key, _| {
                matches!(
                    key.as_str(),
                    "kind"
                        | "id"
                        | "input"
                        | "output"
                        | "cache_read"
                        | "cacheRead"
                        | "cache_write"
                        | "cacheWrite"
                        | "cost_usd"
                        | "costUsd"
                )
            });
        }
        if object.get("event").is_some_and(|event| !event.is_object()) {
            object.insert("event".into(), Value::Null);
        }
        if !matches!(
            object.get("kind").and_then(Value::as_str),
            Some("retainedUsage" | "teamAgentSegment")
        ) {
            object.remove("usage");
        }
    }
    record
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(cache: &mut Cache, path: &Path, muse: bool) -> (Value, Vec<Value>) {
        let mut records = Vec::new();
        let totals = cache
            .visit(path, muse, |row| {
                records.push(row);
                Ok(())
            })
            .unwrap();
        (totals.unwrap_or(Value::Null), records)
    }
    fn usage(input: u64) -> String {
        format!(
            "{}\n",
            json!({"kind":"agent","backend":"codex","at_ms":42,"event":{"kind":"usage","input":input}})
        )
    }

    #[test]
    #[ignore = "manual release-build usage cache measurement"]
    fn benchmark_cold_warm_and_appended_history() {
        use std::io::Write;
        use std::time::Instant;
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("events.ndjson");
        for backend in ["codex", "muse"] {
            let mut file = fs::File::create(&path).unwrap();
            let row = json!({"kind":"agent", "backend":backend, "event":{"kind":"toolEnd", "detail":"output 😀 \"line\"\n".repeat(8_000)}}).to_string() + "\n";
            for _ in 0..256 {
                file.write_all(row.as_bytes()).unwrap();
            }
            file.write_all(usage(42).replace("codex", backend).as_bytes())
                .unwrap();
            file.flush().unwrap();
            let mut cold = Vec::new();
            let mut warm = Vec::new();
            let mut changed = Vec::new();
            for iteration in 0..9 {
                let mut cache = Cache::default();
                let expected = 42 + iteration;
                let start = Instant::now();
                let first = read(&mut cache, &path, backend == "muse");
                cold.push(start.elapsed());
                assert_eq!(first.0["input"], expected);
                let start = Instant::now();
                let cached = read(&mut cache, &path, backend == "muse");
                warm.push(start.elapsed());
                assert_eq!(first, cached);
                file.write_all(usage(1).replace("codex", backend).as_bytes())
                    .unwrap();
                file.flush().unwrap();
                let start = Instant::now();
                let appended = read(&mut cache, &path, backend == "muse");
                changed.push(start.elapsed());
                assert_eq!(appended.0["input"], expected + 1);
            }
            cold.sort();
            warm.sort();
            changed.sort();
            eprintln!(
                "usage cache {backend}: bytes={} cold_ms={:.3} warm_ms={:.3} appended_ms={:.3}",
                file.metadata().unwrap().len(),
                cold[4].as_secs_f64() * 1000.0,
                warm[4].as_secs_f64() * 1000.0,
                changed[4].as_secs_f64() * 1000.0
            );
        }
    }

    #[test]
    fn cached_metadata_keeps_counters_and_boundaries_without_tool_bodies() {
        assert_eq!(
            metadata_only(json!(["private malformed content"])),
            Value::Null
        );
        assert_eq!(
            metadata_only(json!({"event":["private content"],"usage":"unrelated"})),
            json!({"event":null})
        );
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("events.ndjson");
        let rows = [
            json!({"kind":"agent","backend":"codex","event":{"kind":"toolEnd","detail":"private tool output"}}),
            json!({"kind":"user","text":"private prompt","atMs":3}),
            json!({"kind":"agent","backend":"muse","at_ms":4,"event":{"kind":"session","id":"session-a"}}),
            json!({"kind":"agent","backend":"muse","at_ms":5,"event":{"kind":"usage","input":8,"cache_read":7,"cost_usd":0.4}}),
        ];
        fs::write(
            &path,
            rows.iter()
                .map(|row| format!("{row}\n"))
                .collect::<String>(),
        )
        .unwrap();
        let mut cache = Cache::default();
        let cold = read(&mut cache, &path, true);
        let hot = read(&mut cache, &path, true);
        assert_eq!(cold, hot);
        assert_eq!(cold.0["input"], 8);
        assert_eq!(cold.0["cacheRead"], 7);
        assert_eq!(cold.1.len(), 4);
        assert_eq!(cold.1[2]["event"]["id"], "session-a");
        assert!(!serde_json::to_string(&cold.1).unwrap().contains("private"));
        assert_eq!(cache.entries.len(), 1);
        assert_eq!(
            read(&mut cache, &path, false).1.len(),
            1,
            "Muse boundary collection changes the cache key"
        );
    }

    #[test]
    fn appends_rewrites_replacements_and_missing_files_invalidate_the_cache() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("events.ndjson");
        let mut cache = Cache::default();
        fs::write(&path, usage(10)).unwrap();
        assert_eq!(read(&mut cache, &path, false).0["input"], 10);
        OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(usage(20).as_bytes())
            .unwrap();
        assert_eq!(read(&mut cache, &path, false).0["input"], 30);
        fs::write(&path, usage(40)).unwrap();
        assert_eq!(read(&mut cache, &path, false).0["input"], 40);
        let time = fs::metadata(&path).unwrap().modified().unwrap();
        let replacement = root.path().join("replacement");
        fs::write(&replacement, usage(60)).unwrap();
        fs::File::options()
            .write(true)
            .open(&replacement)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(time))
            .unwrap();
        fs::rename(&replacement, &path).unwrap();
        assert_eq!(
            read(&mut cache, &path, false).0["input"],
            60,
            "same size and mtime on another inode must miss"
        );
        fs::write(&path, "").unwrap();
        assert_eq!(read(&mut cache, &path, false).0["input"], 0);
        fs::remove_file(&path).unwrap();
        assert!(read(&mut cache, &path, false).0.is_null());
        assert!(cache.entries.is_empty());
    }

    #[test]
    fn metadata_caps_bypass_caching_without_truncating_the_repair_pass() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("events.ndjson");
        let mut cache = Cache::default();
        fs::write(&path, usage(1).repeat(RECORDS + 1)).unwrap();
        let result = read(&mut cache, &path, false);
        assert_eq!(result.0["input"], RECORDS + 1);
        assert_eq!(result.1.len(), RECORDS + 1);
        assert!(cache.entries.is_empty());
        fs::write(&path, format!("{}\n", json!({"backend":"muse","kind":"agent","event":{"kind":"session","id":"x".repeat(ENTRY_BYTES)}}))).unwrap();
        assert_eq!(read(&mut cache, &path, true).1.len(), 1);
        assert!(cache.entries.is_empty());
        for index in 0..ENTRIES + 1 {
            let path = root.path().join(index.to_string());
            fs::write(&path, usage(index as u64)).unwrap();
            read(&mut cache, &path, false);
        }
        assert_eq!(cache.entries.len(), ENTRIES);
        assert!(
            !cache
                .entries
                .iter()
                .any(|entry| entry.path == root.path().join("0"))
        );
    }

    #[test]
    fn an_append_during_the_snapshot_is_not_cached_as_the_new_archive() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("events.ndjson");
        fs::write(&path, usage(10)).unwrap();
        let mut cache = Cache::default();
        let first = cache
            .visit(&path, false, |_| {
                OpenOptions::new()
                    .append(true)
                    .open(&path)
                    .unwrap()
                    .write_all(usage(20).as_bytes())
                    .unwrap();
                Ok(())
            })
            .unwrap()
            .unwrap();
        assert_eq!(first["input"], 10);
        assert!(cache.entries.is_empty());
        assert_eq!(read(&mut cache, &path, false).0["input"], 30);
    }

    #[cfg(unix)]
    #[test]
    fn cached_results_do_not_hide_symlinks_or_restored_mtime_rewrites() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("events.ndjson");
        let mut cache = Cache::default();
        fs::write(&path, usage(10)).unwrap();
        read(&mut cache, &path, false);
        let time = fs::metadata(&path).unwrap().modified().unwrap();
        fs::write(&path, usage(20)).unwrap();
        fs::File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(time))
            .unwrap();
        assert_eq!(read(&mut cache, &path, false).0["input"], 20);
        fs::remove_file(&path).unwrap();
        let other = root.path().join("other");
        fs::write(&other, usage(30)).unwrap();
        std::os::unix::fs::symlink(&other, &path).unwrap();
        assert!(cache.visit(&path, false, |_| Ok(())).is_err());
    }
}
