// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#[cfg(all(feature = "gui", any(target_os = "linux", target_os = "macos")))]
mod ui;

#[cfg(unix)]
fn main() -> anyhow::Result<()> {
    use anyhow::{Context, bail};
    use std::path::PathBuf;
    use tokenstat_linux::client::{Client, OwnerLock};

    let mut socket = None;
    let mut no_spawn = false;
    let mut doctor = false;
    let mut probe_ui = false;
    let mut desktop_preview = false;
    let mut shell_fixture = false;
    let mut day_fixture = None;
    let mut home_fixture = None;
    let mut stage = None;
    let mut installed_bin = PathBuf::from("/usr/bin");
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--socket" => {
                socket = Some(PathBuf::from(args.next().context("--socket needs a path")?))
            }
            "--no-spawn" => no_spawn = true,
            "--doctor" => doctor = true,
            "--probe-ui" => probe_ui = true,
            "--desktop-preview" => desktop_preview = true,
            "--shell-fixture" => shell_fixture = true,
            "--day-fixture" => {
                day_fixture = Some(args.next().context("--day-fixture needs a fixture name")?);
            }
            "--home-fixture" => {
                home_fixture = Some(args.next().context("--home-fixture needs a fixture name")?);
            }
            "--stage-integration" => {
                stage = Some(PathBuf::from(
                    args.next()
                        .context("--stage-integration needs a directory")?,
                ))
            }
            "--installed-bin" => {
                installed_bin = PathBuf::from(args.next().context("--installed-bin needs a path")?)
            }
            "--version" | "-V" => {
                println!(
                    "tokenstat desktop {} (GPUI feasibility build)",
                    tokenstat_core::VERSION
                );
                return Ok(());
            }
            "--help" | "-h" => {
                println!(
                    "tokenstat desktop feasibility build\n\n  --desktop-preview      Open the partial SwiftUI shell port\n  --shell-fixture         Preview synthetic data, without host/archive access\n  --day-fixture NAME     Open a fixed-size offline day parity fixture\n  --home-fixture NAME    Open a fixed-size offline Home parity fixture\n  --probe-ui             Open the transport/rendering experiment\n  --socket PATH          Connect to an isolated host\n  --no-spawn             Only connect, never launch a host\n  --doctor               Read host protocol and snapshot, without a window\n  --stage-integration DIR Write desktop and user-unit files for review\n  --installed-bin PATH   Installed executable directory for staged files\n  --version              Print the shared core version\n\nThe production UI requires full SwiftUI parity. Both previews are incomplete.\nOn macOS, specify --socket and --no-spawn for a connected preview."
                );
                return Ok(());
            }
            _ => bail!("Unknown option: {arg}. Use --help."),
        }
    }
    if usize::from(probe_ui)
        + usize::from(desktop_preview)
        + usize::from(shell_fixture)
        + usize::from(day_fixture.is_some())
        + usize::from(home_fixture.is_some())
        + usize::from(doctor)
        + usize::from(stage.is_some())
        > 1
    {
        bail!(
            "Choose one mode: --probe-ui, --desktop-preview, --shell-fixture, --day-fixture, --home-fixture, --doctor or --stage-integration."
        );
    }
    if let Some(root) = stage {
        tokenstat_linux::integration::stage(&root, &installed_bin)?;
        println!(
            "Staged desktop integration in {}. No service was enabled.",
            root.display()
        );
        return Ok(());
    }
    if let Some(name) = day_fixture {
        #[cfg(all(feature = "gui", any(target_os = "linux", target_os = "macos")))]
        return tokenstat_linux::desktop::run_day_fixture(&name);
        #[cfg(not(all(feature = "gui", any(target_os = "linux", target_os = "macos"))))]
        bail!("This build has no GUI. Build with the gui feature to render day fixture {name}.");
    }
    if let Some(name) = home_fixture {
        #[cfg(all(feature = "gui", any(target_os = "linux", target_os = "macos")))]
        return tokenstat_linux::desktop::run_home_fixture(&name);
        #[cfg(not(all(feature = "gui", any(target_os = "linux", target_os = "macos"))))]
        bail!("This build has no GUI. Build with the gui feature to render Home fixture {name}.");
    }
    if shell_fixture {
        #[cfg(all(feature = "gui", any(target_os = "linux", target_os = "macos")))]
        {
            tokenstat_linux::desktop::run(None);
            return Ok(());
        }
        #[cfg(not(all(feature = "gui", any(target_os = "linux", target_os = "macos"))))]
        bail!("This build has no GUI. Build with the gui feature.");
    }
    if cfg!(target_os = "macos") && (socket.is_none() || !no_spawn) {
        bail!("For a macOS preview, specify --socket PATH --no-spawn with an isolated host.");
    }
    if cfg!(target_os = "linux") && unsafe { libc::geteuid() } == 0 {
        bail!("Run the desktop as your normal user. Use the CLI for a deliberate system host.");
    }
    let data = tokenstat_paths::data_dir().context("No data directory is available")?;
    let allow_spawn = !no_spawn && !doctor && socket.is_none();
    let client = Client {
        socket: socket.unwrap_or_else(|| data.join("host.sock")),
        allow_spawn,
    };
    if doctor {
        let snapshot = client.snapshot(false)?;
        println!(
            "host: {}\nversion: {}\ntimezone: {}\nevents: {}\nopen files: {:?} / {:?}",
            client.socket.display(),
            snapshot.info.core_version,
            snapshot.info.timezone,
            snapshot.totals.events,
            snapshot.info.open_files,
            snapshot.info.open_file_limit
        );
        return Ok(());
    }
    if !probe_ui && !desktop_preview {
        bail!(
            "The Linux desktop requires full SwiftUI parity. Use --probe-ui only for the transport/rendering experiment."
        );
    }
    let _owner = OwnerLock::acquire(&data)?;
    #[cfg(all(feature = "gui", any(target_os = "linux", target_os = "macos")))]
    {
        if desktop_preview {
            tokenstat_linux::desktop::run(Some(client));
        } else {
            ui::run(client);
        }
        Ok(())
    }
    #[cfg(not(all(feature = "gui", any(target_os = "linux", target_os = "macos"))))]
    bail!("This build has no GUI. Build with the gui feature.");
}

#[cfg(not(unix))]
fn main() {
    eprintln!("Build the Linux desktop on Linux, or preview it on macOS.");
    std::process::exit(1);
}
