// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#[path = "build_support/swift_contract.rs"]
mod swift_contract;

fn main() {
    let manifest = std::path::PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let sources = manifest.join("../mac/Sources");
    for file in swift_contract::SOURCE_FILES {
        println!("cargo:rerun-if-changed={}", sources.join(file).display());
    }
    println!("cargo:rerun-if-changed=build_support/swift_contract.rs");
    for file in ["Manrope-Variable.ttf", "JetBrainsMono-Variable.ttf"] {
        println!(
            "cargo:rerun-if-changed={}",
            manifest.join("../mac/Resources/Fonts").join(file).display()
        );
    }
    let generated = swift_contract::generate(&sources)
        .unwrap_or_else(|error| panic!("SwiftUI desktop contract changed: {error}"));
    let output = std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    std::fs::write(output.join("swiftui_contract.rs"), generated).unwrap();
    if std::env::var_os("CARGO_FEATURE_GUI").is_some() {
        let root = manifest.join("../..");
        let mut assets = String::from(
            "// Generated from the shared native SVG assets.\nfn embedded_asset(path: &str) -> Option<&'static [u8]> { match path {\n",
        );
        for catalog in ["Brands.xcassets", "FeatureMarks.xcassets"] {
            let directory = root.join("apps/mac/Resources").join(catalog);
            println!("cargo:rerun-if-changed={}", directory.display());
            let mut entries: Vec<_> = std::fs::read_dir(&directory)
                .unwrap()
                .map(|e| e.unwrap().path())
                .collect();
            entries.sort();
            for entry in entries {
                if entry.extension().and_then(|s| s.to_str()) != Some("imageset") {
                    continue;
                }
                let name = entry.file_stem().unwrap().to_string_lossy();
                let mut files: Vec<_> = std::fs::read_dir(&entry)
                    .unwrap()
                    .map(|e| e.unwrap().path())
                    .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("svg"))
                    .collect();
                files.sort();
                if let Some(file) = files.first() {
                    println!("cargo:rerun-if-changed={}", file.display());
                    assets.push_str(&format!(
                        "{:?} => Some(include_bytes!({:?})),\n",
                        format!("assets/{name}"),
                        file.canonicalize().unwrap().to_string_lossy()
                    ));
                }
            }
        }
        assets.push_str("_ => None, } }\n");
        std::fs::write(output.join("embedded_assets.rs"), assets).unwrap();
        let script = root.join("scripts/prepare-linux-fonts.py");
        let python = root.join("target/linux-fonttools-4.68.0/bin/python");
        println!("cargo:rerun-if-changed={}", script.display());
        let result = std::process::Command::new(python).arg(script).arg("--output").arg(output.join("fonts")).output()
            .unwrap_or_else(|e| panic!("Prepare the GPUI font build tool with: bash scripts/prepare-linux-fonts.sh ({e})"));
        assert!(
            result.status.success(),
            "Font preparation failed: {}",
            String::from_utf8_lossy(&result.stderr)
        );
    }
}
