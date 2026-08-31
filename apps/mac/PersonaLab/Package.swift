// swift-tools-version:5.9
// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import PackageDescription

// The persona motion lab. A separate executable on purpose: the engine it
// drives is the app's own, symlinked in under Sources/PersonaLab/Engine, but
// building it needs neither the FFI xcframework nor xcodegen, so a change to
// a spring constant is `swift run` and about two seconds rather than a full
// app build.
//
//   apps/mac/PersonaLab/link-engine.sh   # (re)make the symlinks
//   swift run --package-path apps/mac/PersonaLab
let package = Package(
    name: "PersonaLab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PersonaLab", path: "Sources/PersonaLab")
    ]
)
