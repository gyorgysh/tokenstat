// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! A native fixture executable, suitable for an isolated test bundle without
//! a shell wrapper. It never receives a host client or opens a live archive.

fn main() -> anyhow::Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [] => tokenstat_linux::desktop::run_home_fixture("machines-ready-dark"),
        [mode, name] if mode == "home" => tokenstat_linux::desktop::run_home_fixture(name),
        [mode, name] if mode == "day" => tokenstat_linux::desktop::run_day_fixture(name),
        [mode, name] if mode == "project" => tokenstat_linux::desktop::run_project_fixture(name),
        _ => anyhow::bail!(
            "Use component-preview [home|day|project FIXTURE]; the default is machines-ready-dark"
        ),
    }
}
