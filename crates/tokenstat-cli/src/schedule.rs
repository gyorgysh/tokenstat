//! Generate and install the scheduler entry that keeps the archive current.
//!
//! This matters more than it looks. Claude Code deletes its transcripts after
//! `cleanupPeriodDays`, 30 by default, so usage that is never scanned before
//! then is gone from the machine for good. On the machine this was developed
//! against, half of all recorded history was already unrecoverable by the time
//! the first scan ran.
//!
//! Nothing is written unless the user asks. By default the entry is printed for
//! them to install, because a tool that silently registers a background job is
//! doing something the user did not ask for.

use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};

/// Which scheduler to emit for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Launchd,
    SystemdUser,
    WindowsTaskScheduler,
}

impl Platform {
    pub fn detect() -> Platform {
        if cfg!(target_os = "macos") {
            Platform::Launchd
        } else if cfg!(target_os = "windows") {
            Platform::WindowsTaskScheduler
        } else {
            Platform::SystemdUser
        }
    }
}

/// The unit label, shared by every platform so uninstall instructions match.
pub const LABEL: &str = "ai.tokenstat.scan";

/// The things worth putting on a timer, as separate units on purpose.
///
/// Scanning is local, cheap, and wants to run often, because the logs it reads
/// are deleted from under it. Syncing talks to a server that meters how often it
/// will accept one, and only matters for people with an account. Updating
/// replaces this binary and runs daily, and only for people who asked for that.
/// One combined entry would tie the scan cadence to a plan, and would install
/// machinery for the majority who never sign in or never opt into auto-update.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unit {
    Scan,
    Sync,
    Update,
}

impl Unit {
    pub fn label(self) -> &'static str {
        match self {
            Unit::Scan => LABEL,
            Unit::Sync => "ai.tokenstat.sync",
            Unit::Update => "ai.tokenstat.update",
        }
    }

    /// Arguments passed to the tokenstat binary.
    pub fn args(self) -> &'static [&'static str] {
        match self {
            Unit::Scan => &["scan"],
            // --scheduled adds the jitter and the self-pacing, and keeps quiet
            // (exit 0) when there is no account or the interval has not elapsed.
            Unit::Sync => &["sync", "--scheduled"],
            // Same idea: quiet when auto-update is off, and it verifies the
            // downloaded binary before letting it replace this one.
            Unit::Update => &["update", "--scheduled"],
        }
    }

    pub fn description(self) -> &'static str {
        match self {
            Unit::Scan => "Archive AI tool token usage",
            Unit::Sync => "Upload aggregate token counts to tokenstat.ai",
            Unit::Update => "Check for a newer tokenstat release",
        }
    }

    /// Whether to run once immediately when the entry is loaded.
    ///
    /// The scan does: after sleep or a logout the first thing that should happen
    /// is a catch-up, and that is exactly when it matters most. The others do
    /// not: a machine that just booted has nothing new to send that waiting one
    /// interval would lose, a fleet coming back together is the one case worth
    /// not piling onto, and replacing a binary seconds after login is a poor
    /// moment to pick.
    pub fn run_at_load(self) -> bool {
        matches!(self, Unit::Scan)
    }

    /// How wide a jitter window this unit spreads itself over, in seconds.
    ///
    /// 0 for the scan: it touches nothing shared, and delaying it works against
    /// the whole point of running it.
    pub fn jitter_window(self) -> u64 {
        match self {
            Unit::Scan => 0,
            Unit::Sync => tokenstat_sync::JITTER_WINDOW_SECS,
            Unit::Update => tokenstat_sync::UPDATE_JITTER_WINDOW_SECS,
        }
    }

    /// Default seconds between runs when the caller has nothing better.
    ///
    /// The sync default matches the free plan's interval, which is the floor the
    /// server enforces anyway.
    pub fn default_interval(self) -> u64 {
        match self {
            Unit::Scan => 60 * 60,
            Unit::Sync => 60 * 60,
            Unit::Update => 24 * 60 * 60,
        }
    }
}

/// Result of writing and activating a scheduler entry.
#[derive(Debug, Clone)]
pub struct InstallReport {
    /// Paths written (plist, unit files). Empty on Windows (task registry only).
    pub paths: Vec<PathBuf>,
    /// One-line hint for the user (linger, unload, etc.).
    pub hint: Option<String>,
}

/// A macOS LaunchAgent that runs one unit on an interval.
///
/// `StartInterval` counts from load, so two machines that installed at different
/// moments are already out of phase with each other. The sync unit adds its own
/// jitter on top for the case where they did not.
pub fn launchd_plist(unit: Unit, exe: &str, interval_secs: u64, log_path: &str) -> String {
    let label = unit.label();
    let args = unit
        .args()
        .iter()
        .map(|a| format!("    <string>{a}</string>\n"))
        .collect::<String>();
    let run_at_load = if unit.run_at_load() {
        "  <key>RunAtLoad</key>\n  <true/>\n"
    } else {
        ""
    };
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{exe}</string>
{args}  </array>
  <key>StartInterval</key>
  <integer>{interval_secs}</integer>
{run_at_load}  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>{log_path}</string>
  <key>StandardErrorPath</key>
  <string>{log_path}</string>
</dict>
</plist>
"#
    )
}

/// Service + timer for a systemd user unit.
///
/// systemd is the one platform where timers really do align across machines:
/// `OnBootSec` counts from boot, and `Persistent=true` replays a missed run the
/// moment the machine comes back. That is right for a scan, which is racing log
/// cleanup, and wrong for a sync, which would turn a fleet coming back online
/// into one burst. So the sync timer drops `Persistent` and takes
/// `RandomizedDelaySec` instead.
pub fn systemd_units(unit: Unit, exe: &str, interval_secs: u64) -> (String, String) {
    let desc = unit.description();
    let args = unit.args().join(" ");
    let service = format!(
        "[Unit]\n\
         Description={desc}\n\n\
         [Service]\n\
         Type=oneshot\n\
         ExecStart={exe} {args}\n"
    );
    let pacing = match unit {
        Unit::Scan => "OnBootSec=2min\nPersistent=true\n".to_string(),
        _ => format!(
            "OnBootSec=5min\nRandomizedDelaySec={}\nAccuracySec=1min\n",
            unit.jitter_window()
        ),
    };
    let timer = format!(
        "[Unit]\n\
         Description={desc} on a timer\n\n\
         [Timer]\n\
         OnUnitActiveSec={interval_secs}s\n\
         {pacing}\n\
         [Install]\n\
         WantedBy=timers.target\n"
    );
    (service, timer)
}

pub fn windows_command(unit: Unit, exe: &str, interval_secs: u64) -> String {
    let minutes = (interval_secs / 60).max(1);
    let label = unit.label();
    let args = unit.args().join(" ");
    format!(
        "schtasks /Create /TN \"{label}\" /TR \"\\\"{exe}\\\" {args}\" \
         /SC MINUTE /MO {minutes} /F"
    )
}

/// Where a LaunchAgent belongs.
pub fn launchd_path(home: &Path, unit: Unit) -> PathBuf {
    home.join("Library/LaunchAgents")
        .join(format!("{}.plist", unit.label()))
}

/// Default log file for the LaunchAgent.
pub fn launchd_log_path(home: &Path, unit: Unit) -> PathBuf {
    home.join("Library/Logs")
        .join(format!("{}.log", unit.label()))
}

/// Where systemd user units belong.
pub fn systemd_unit_dir(home: &Path) -> PathBuf {
    home.join(".config/systemd/user")
}

/// Write the LaunchAgent, load it, and return where it went.
///
/// Overwrites an existing plist so a re-install (website installer, path
/// change) updates the entry instead of failing. Only called when the user
/// explicitly asked to install.
pub fn install_launchd(
    home: &Path,
    unit: Unit,
    exe: &str,
    interval_secs: u64,
) -> Result<InstallReport> {
    let label = unit.label();
    let path = launchd_path(home, unit);
    let log = launchd_log_path(home, unit);
    let dir = path.parent().context("LaunchAgents directory")?;
    std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    if let Some(parent) = log.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }
    let log_s = log.to_string_lossy();
    std::fs::write(&path, launchd_plist(unit, exe, interval_secs, &log_s))
        .with_context(|| format!("writing {}", path.display()))?;

    // Prefer modern bootstrap/bootout; fall back to load/unload.
    //
    // Every call here is quiet, because the failures are expected and printing
    // them is worse than useless: on a first install there is nothing to boot out
    // or unload, and `bootstrap` returns "Input/output error" on some macOS
    // versions even as `load -w` goes on to work. A successful install was
    // printing three lines of launchctl alarm at the user for no reason. Only our
    // own verdict below is worth showing.
    let quiet = |cmd: &mut Command| -> bool {
        cmd.stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    };

    let domain = format!("gui/{}", current_uid());
    quiet(Command::new("launchctl").args(["bootout", &domain, label]));
    quiet(Command::new("launchctl").args(["unload", "-w"]).arg(&path));

    let loaded = quiet(
        Command::new("launchctl")
            .args(["bootstrap", &domain])
            .arg(&path),
    ) || quiet(Command::new("launchctl").args(["load", "-w"]).arg(&path));
    if !loaded {
        bail!(
            "wrote {} but could not load it with launchctl",
            path.display()
        );
    }

    Ok(InstallReport {
        paths: vec![path],
        hint: Some(format!(
            "logs: {log_s}; remove with: launchctl bootout {domain} {label} && rm ~/Library/LaunchAgents/{label}.plist"
        )),
    })
}

/// Write systemd user units and enable the timer.
pub fn install_systemd_user(
    home: &Path,
    unit: Unit,
    exe: &str,
    interval_secs: u64,
) -> Result<InstallReport> {
    let label = unit.label();
    let dir = systemd_unit_dir(home);
    std::fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    let service_path = dir.join(format!("{label}.service"));
    let timer_path = dir.join(format!("{label}.timer"));
    let (service, timer) = systemd_units(unit, exe, interval_secs);
    std::fs::write(&service_path, service)
        .with_context(|| format!("writing {}", service_path.display()))?;
    std::fs::write(&timer_path, timer)
        .with_context(|| format!("writing {}", timer_path.display()))?;

    let reload = Command::new("systemctl")
        .args(["--user", "daemon-reload"])
        .status()
        .with_context(|| "running systemctl --user daemon-reload")?;
    if !reload.success() {
        bail!("systemctl --user daemon-reload failed");
    }
    let enable = Command::new("systemctl")
        .args(["--user", "enable", "--now", &format!("{label}.timer")])
        .status()
        .with_context(|| format!("enabling {label}.timer"))?;
    if !enable.success() {
        bail!("systemctl --user enable --now {label}.timer failed");
    }

    Ok(InstallReport {
        paths: vec![service_path, timer_path],
        hint: Some("if timers stop after logout, run: loginctl enable-linger $USER".into()),
    })
}

/// Register a Windows Task Scheduler entry that runs one unit on an interval.
pub fn install_windows_task(unit: Unit, exe: &str, interval_secs: u64) -> Result<InstallReport> {
    let label = unit.label();
    let minutes = (interval_secs / 60).max(1).to_string();
    // /TR wants the command as one string: "path\to\exe" scan
    let tr = format!("\"{exe}\" {}", unit.args().join(" "));
    let status = Command::new("schtasks")
        .args([
            "/Create", "/TN", label, "/TR", &tr, "/SC", "MINUTE", "/MO", &minutes, "/F",
        ])
        .status()
        .with_context(|| "running schtasks")?;
    if !status.success() {
        bail!("schtasks /Create failed for task {label}");
    }
    Ok(InstallReport {
        paths: Vec::new(),
        hint: Some(format!("remove with: schtasks /Delete /TN \"{label}\" /F")),
    })
}

/// Install one unit for the current platform.
pub fn install(home: &Path, unit: Unit, exe: &str, interval_secs: u64) -> Result<InstallReport> {
    match Platform::detect() {
        Platform::Launchd => install_launchd(home, unit, exe, interval_secs),
        Platform::SystemdUser => install_systemd_user(home, unit, exe, interval_secs),
        Platform::WindowsTaskScheduler => install_windows_task(unit, exe, interval_secs),
    }
}

/// What `install_linked_units` put on the scheduler after an account link.
#[derive(Debug, Default)]
pub struct LinkedInstall {
    pub sync: Option<InstallReport>,
    pub sync_interval_secs: Option<u64>,
    pub update: Option<InstallReport>,
}

/// Install the sync unit (and update, when auto-apply is on) for a linked host.
///
/// Call after login or setup connect. Scan is separate: it is worth having
/// without an account. Sync is not.
pub fn install_linked_units(
    home: &Path,
    exe: &str,
    host_flag: Option<&str>,
) -> Result<LinkedInstall> {
    let info = tokenstat_sync::scheduling_info(host_flag).map_err(|e| anyhow::anyhow!("{e}"))?;
    if !info.logged_in {
        return Ok(LinkedInstall::default());
    }
    let sync_interval = info
        .min_interval
        .unwrap_or_else(|| Unit::Sync.default_interval());
    let sync = install(home, Unit::Sync, exe, sync_interval)?;

    let update = if tokenstat_sync::auto_apply_enabled() {
        let persisted = tokenstat_sync::config::load()
            .ok()
            .and_then(|c| c.update.auto)
            .unwrap_or(false);
        if !persisted {
            let _ = tokenstat_sync::config::set_update_auto(true);
        }
        Some(install(
            home,
            Unit::Update,
            exe,
            Unit::Update.default_interval(),
        )?)
    } else {
        None
    };

    Ok(LinkedInstall {
        sync: Some(sync),
        sync_interval_secs: Some(sync_interval),
        update,
    })
}

fn current_uid() -> String {
    Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "501".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_plist_runs_a_scan_at_the_requested_interval() {
        let p = launchd_plist(Unit::Scan, "/usr/local/bin/tokenstat", 3600, "/tmp/t.log");
        assert!(p.contains("<string>/usr/local/bin/tokenstat</string>"));
        assert!(p.contains("<string>scan</string>"));
        assert!(p.contains("<integer>3600</integer>"));
        assert!(p.contains(LABEL));
        assert!(p.contains("/tmp/t.log"));
    }

    #[test]
    fn the_scan_plist_catches_up_at_load() {
        // Without this, a machine that was asleep waits a full interval before
        // recording anything, which is exactly when a catch-up matters most.
        assert!(launchd_plist(Unit::Scan, "t", 60, "/tmp/t.log").contains("<key>RunAtLoad</key>"));
    }

    #[test]
    fn the_sync_plist_does_not_fire_at_load() {
        // A fleet that boots together must not sync together, and nothing is lost
        // by waiting one interval.
        let p = launchd_plist(Unit::Sync, "t", 600, "/tmp/t.log");
        assert!(!p.contains("RunAtLoad"));
        assert!(p.contains("<string>sync</string>"));
        assert!(p.contains("<string>--scheduled</string>"));
        assert!(p.contains("ai.tokenstat.sync"));
    }

    #[test]
    fn the_two_units_never_collide() {
        assert_ne!(Unit::Scan.label(), Unit::Sync.label());
        let home = Path::new("/home/u");
        assert_ne!(
            launchd_path(home, Unit::Scan),
            launchd_path(home, Unit::Sync)
        );
        assert_ne!(
            launchd_log_path(home, Unit::Scan),
            launchd_log_path(home, Unit::Sync)
        );
    }

    #[test]
    fn every_plist_is_well_formed_xml() {
        for unit in [Unit::Scan, Unit::Sync] {
            let p = launchd_plist(unit, "t", 60, "/tmp/t.log");
            assert!(p.starts_with("<?xml"));
            assert_eq!(p.matches("<dict>").count(), p.matches("</dict>").count());
            assert_eq!(p.matches("<array>").count(), p.matches("</array>").count());
            assert!(p.trim_end().ends_with("</plist>"));
        }
    }

    #[test]
    fn the_scan_timer_catches_up_after_downtime() {
        let (service, timer) = systemd_units(Unit::Scan, "/usr/bin/tokenstat", 900);
        assert!(service.contains("ExecStart=/usr/bin/tokenstat scan"));
        assert!(timer.contains("OnUnitActiveSec=900s"));
        // Persistent replays a missed run rather than skipping it.
        assert!(timer.contains("Persistent=true"));
    }

    #[test]
    fn the_sync_timer_spreads_the_load_instead_of_replaying() {
        let (service, timer) = systemd_units(Unit::Sync, "/usr/bin/tokenstat", 600);
        assert!(service.contains("ExecStart=/usr/bin/tokenstat sync --scheduled"));
        assert!(timer.contains("OnUnitActiveSec=600s"));
        assert!(timer.contains("RandomizedDelaySec=180"));
        // A replayed sync at boot is exactly the burst we are avoiding.
        assert!(!timer.contains("Persistent=true"));
    }

    #[test]
    fn the_windows_command_quotes_a_path_with_spaces() {
        let c = windows_command(Unit::Scan, r"C:\Program Files\tokenstat.exe", 1800);
        assert!(c.contains("/MO 30"));
        assert!(c.contains(r#"\"C:\Program Files\tokenstat.exe\" scan"#));
        let s = windows_command(Unit::Sync, r"C:\tokenstat.exe", 600);
        assert!(s.contains(r#"\"C:\tokenstat.exe\" sync --scheduled"#));
        assert!(s.contains("ai.tokenstat.sync"));
    }

    #[test]
    fn a_sub_minute_interval_still_produces_a_valid_windows_task() {
        // schtasks rejects /MO 0, so short intervals clamp to one minute.
        assert!(windows_command(Unit::Scan, "t.exe", 30).contains("/MO 1"));
    }

    #[test]
    fn writing_launchd_plist_overwrites_on_reinstall() {
        let dir = std::env::temp_dir().join(format!("tokenstat-sched-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let home = &dir;
        std::fs::create_dir_all(home.join("Library/LaunchAgents")).unwrap();
        std::fs::create_dir_all(home.join("Library/Logs")).unwrap();

        let path = launchd_path(home, Unit::Scan);
        std::fs::write(&path, launchd_plist(Unit::Scan, "t", 60, "/tmp/t.log")).unwrap();
        std::fs::write(&path, launchd_plist(Unit::Scan, "t2", 120, "/tmp/t.log")).unwrap();
        let body = std::fs::read_to_string(&path).unwrap();
        assert!(body.contains("<string>t2</string>"));
        assert!(body.contains("<integer>120</integer>"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn systemd_unit_dir_is_under_xdg_config() {
        let p = systemd_unit_dir(Path::new("/home/u"));
        assert_eq!(p, PathBuf::from("/home/u/.config/systemd/user"));
    }
}
