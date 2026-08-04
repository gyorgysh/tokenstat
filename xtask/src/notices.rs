// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Third party attribution for a shipped binary.
//!
//! tokenstat itself is source-available and not redistributable, but almost
//! every crate it links is MIT, Apache-2.0 or BSD, and each of those asks that
//! its notice travels with the binary. Credit is owed and is cheap to give.
//!
//! The file is generated rather than committed, because a tracked generated
//! file is exactly what `scripts/check-no-artifacts.sh` exists to reject. The
//! release workflow runs this and drops the result next to the binary.
//!
//! Licence texts are deduplicated. Two hundred crates share about a dozen
//! texts, so printing each one per crate would produce a megabyte nobody
//! reads.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};
use serde_json::Value;

/// One dependency, as it will appear in the notice file.
struct Crate {
    name: String,
    version: String,
    licence: String,
    repository: Option<String>,
    /// Full text of whatever LICENSE / COPYING / NOTICE files ship with it.
    texts: Vec<String>,
}

pub fn generate(root_crate: &str, out: &Path) -> Result<()> {
    let metadata = metadata()?;
    let crates = collect(&metadata, root_crate)?;
    let rendered = render(root_crate, &crates);

    if let Some(parent) = out.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }
    std::fs::write(out, rendered).with_context(|| format!("writing {}", out.display()))?;
    println!("{}: {} dependencies", out.display(), crates.len());
    Ok(())
}

fn metadata() -> Result<Value> {
    let output = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()))
        .args(["metadata", "--format-version", "1", "--all-features"])
        .output()
        .context("running cargo metadata")?;
    if !output.status.success() {
        bail!(
            "cargo metadata failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    serde_json::from_slice(&output.stdout).context("parsing cargo metadata")
}

/// Walk the resolved graph from `root_crate`, so the notice covers what is
/// actually linked rather than every crate the workspace mentions.
fn collect(metadata: &Value, root_crate: &str) -> Result<Vec<Crate>> {
    let packages = metadata["packages"]
        .as_array()
        .context("metadata has no packages")?;
    let nodes = metadata["resolve"]["nodes"]
        .as_array()
        .context("metadata has no resolve graph")?;

    let by_id: BTreeMap<&str, &Value> = packages
        .iter()
        .filter_map(|p| Some((p["id"].as_str()?, p)))
        .collect();
    let deps_of: BTreeMap<&str, Vec<&str>> = nodes
        .iter()
        .filter_map(|n| {
            let id = n["id"].as_str()?;
            let deps = n["deps"]
                .as_array()?
                .iter()
                .filter_map(|d| d["pkg"].as_str())
                .collect();
            Some((id, deps))
        })
        .collect();

    let root = packages
        .iter()
        .find(|p| p["name"].as_str() == Some(root_crate))
        .and_then(|p| p["id"].as_str())
        .with_context(|| format!("no crate named {root_crate} in this workspace"))?;

    let mut seen = BTreeSet::new();
    let mut stack = vec![root];
    while let Some(id) = stack.pop() {
        if !seen.insert(id) {
            continue;
        }
        for dep in deps_of.get(id).into_iter().flatten() {
            stack.push(dep);
        }
    }

    let mut crates = Vec::new();
    for id in seen {
        let p = by_id[id];
        let name = p["name"].as_str().unwrap_or_default().to_string();
        // pueev's own code is covered by LICENSE, which ships beside this file.
        if name.starts_with("tokenstat") || name == "xtask" {
            continue;
        }
        let manifest = PathBuf::from(p["manifest_path"].as_str().unwrap_or_default());
        crates.push(Crate {
            licence: p["license"]
                .as_str()
                .unwrap_or("see the text below")
                .to_string(),
            repository: p["repository"].as_str().map(str::to_string),
            texts: licence_texts(manifest.parent().unwrap_or(Path::new("."))),
            name,
            version: p["version"].as_str().unwrap_or_default().to_string(),
        });
    }
    crates.sort_by(|a, b| (&a.name, &a.version).cmp(&(&b.name, &b.version)));
    Ok(crates)
}

/// Read the licence files a crate ships, if its sources are unpacked locally.
///
/// A vendored or path dependency may have none, and a missing text is not a
/// reason to fail the build: the SPDX identifier is still recorded, and the
/// gap is visible in the output.
fn licence_texts(dir: &Path) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut names: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| {
            let Some(name) = p.file_name().and_then(|n| n.to_str()) else {
                return false;
            };
            let upper = name.to_uppercase();
            p.is_file()
                && (upper.starts_with("LICENSE")
                    || upper.starts_with("LICENCE")
                    || upper.starts_with("COPYING")
                    || upper.starts_with("NOTICE"))
        })
        .collect();
    names.sort();
    names
        .iter()
        .filter_map(|p| std::fs::read_to_string(p).ok())
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
        .collect()
}

fn render(root_crate: &str, crates: &[Crate]) -> String {
    let mut out = String::new();
    out.push_str("# Third party notices\n\n");
    out.push_str(&format!(
        "This build of `{root_crate}` links the {} packages listed below. Each is \
         the work of its own authors and is used under its own licence. tokenstat \
         itself is licensed separately, see LICENSE.\n\n",
        crates.len()
    ));
    out.push_str("Licence texts are printed once each, at the end, with the packages that\n");
    out.push_str("share them. Generated by `cargo xtask notices`, do not edit by hand.\n\n");

    out.push_str("## Packages\n\n");
    out.push_str("| Package | Version | Licence |\n| --- | --- | --- |\n");
    for c in crates {
        let name = match &c.repository {
            Some(url) => format!("[{}]({})", c.name, url),
            None => c.name.clone(),
        };
        out.push_str(&format!("| {} | {} | {} |\n", name, c.version, c.licence));
    }

    // Text to the packages that ship it, so one MIT text serves two hundred.
    let mut texts: BTreeMap<&str, Vec<String>> = BTreeMap::new();
    for c in crates {
        for t in &c.texts {
            texts
                .entry(t.as_str())
                .or_default()
                .push(format!("{} {}", c.name, c.version));
        }
    }

    out.push_str("\n## Licence texts\n\n");
    for (n, (text, users)) in texts.iter().enumerate() {
        out.push_str(&format!("### Text {}\n\nApplies to: ", n + 1));
        out.push_str(&users.join(", "));
        out.push_str("\n\n```\n");
        out.push_str(text);
        out.push_str("\n```\n\n");
    }

    let missing: Vec<&str> = crates
        .iter()
        .filter(|c| c.texts.is_empty())
        .map(|c| c.name.as_str())
        .collect();
    if !missing.is_empty() {
        out.push_str("## Packages shipping no licence file\n\n");
        out.push_str(
            "Their SPDX identifier is in the table above, and the text is with the \
             upstream project.\n\n",
        );
        for name in missing {
            out.push_str(&format!("- {name}\n"));
        }
    }
    out
}
