// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
fn main() {
    println!("cargo:rerun-if-changed=src/windows_screen.cpp");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows")
        && std::env::var_os("CARGO_FEATURE_LOCAL_HOST").is_some()
    {
        cc::Build::new()
            .cpp(true)
            .file("src/windows_screen.cpp")
            .flag_if_supported("/std:c++17")
            .flag_if_supported("/EHsc")
            .define("NOMINMAX", None)
            .compile("tokenstat_screen");
        for library in [
            "mfplat",
            "mfuuid",
            "strmiids",
            "wmcodecdspuuid",
            "ole32",
            "oleaut32",
            "gdi32",
            "user32",
        ] {
            println!("cargo:rustc-link-lib={library}");
        }
    }
}
