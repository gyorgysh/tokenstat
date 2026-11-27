// swift-tools-version:5.9
// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import PackageDescription

let package = Package(
    name: "PersonaLab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PersonaLab", path: "Sources/PersonaLab")
    ]
)
