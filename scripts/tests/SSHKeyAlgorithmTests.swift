// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SSHKeyAlgorithm.swift.
import CryptoKit
import Foundation

@main struct SSHKeyAlgorithmTests {
    static func main() throws {
        assert(SSHKeyAlgorithm.allCases.first == .ed25519)
        let first = try P256.Signing.PrivateKey(pemRepresentation: SSHKeyAlgorithm.makeP256PEM())
        let second = try P256.Signing.PrivateKey(pemRepresentation: SSHKeyAlgorithm.makeP256PEM())
        assert(first.publicKey.rawRepresentation != second.publicKey.rawRepresentation)
        let message = Data("SSH signing test".utf8)
        let signature = try first.signature(for: message)
        assert(first.publicKey.isValidSignature(signature, for: message))
        assert(!second.publicKey.isValidSignature(signature, for: message))
        #if os(macOS)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test-key")
        try first.pemRepresentation.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-y", "-f", path.path]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let publicData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        assert(process.terminationStatus == 0)
        assert(String(decoding: publicData, as: UTF8.self).hasPrefix("ecdsa-sha2-nistp256 "))
        #endif
        print("SSH algorithm generation tests passed")
    }
}
