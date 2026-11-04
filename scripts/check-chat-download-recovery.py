#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run the Apple download implementation against a local fake transport."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Bridge/ChatFileTransfers.swift').read_text()
def declaration(signature):
    start = source.index(signature)
    body = source.index('async throws -> URL', start) if 'downloadChatFile' in signature else start
    end = source.index('{', body) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
models = source[source.index('struct ChatFileCapabilities:'):source.index('private actor ChatUploadJournal')]
claims = declaration('private actor ChatFileTransferClaims')
download = declaration('    static func downloadChatFile(')
code = r'''
import Foundation
import CryptoKit
struct ChatAttachment: Codable, Sendable { let id: String; let name: String; let size: UInt64? }
enum BridgeError: Error { case core(code: String, message: String) }
enum L10n { static func text(_ key: String) -> String { key } }
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    let scope = UUID().uuidString
    let generation: UInt64 = 1
}
actor Replies {
    static let shared = Replies()
    var bytes = Data("verified bytes for a resumed attachment".utf8)
    var relay = true
    var fallback = false
    var confirmations = 0
    var chunks = 0
    var deniedChunks = 0
    func reset(relay: Bool = true, fallback: Bool = false) {
        self.relay = relay; self.fallback = fallback
        confirmations = 0; chunks = 0; deniedChunks = 0
    }
    func confirm(_ answer: Bool) -> Bool { confirmations += 1; return answer }
    func reply(_ method: String, _ params: [String: Any]) throws -> Data {
        let value: [String: Any]
        switch method {
        case "chat.fileCapabilities":
            value = ["chunkBytes": 512 * 1024, "maxFileBytes": 256 * 1024 * 1024, "relay": relay, "relayRemainingBytes": 9999]
        case "chat.fileDownloadInfo":
            value = ["attachment": ["id": params["attachmentId"]!, "name": "preview.png", "size": bytes.count], "sha256": Self.sha(bytes), "chunkBytes": 512 * 1024]
        case "chat.fileDownloadChunk":
            if (relay || fallback) && params["allowRelay"] as? Bool != true {
                deniedChunks += 1
                throw BridgeError.core(code: "relay_consent_required", message: "Relay consent required")
            }
            let offset = Int(params["offset"] as! UInt64)
            chunks += 1
            value = ["offset": offset, "nextOffset": bytes.count, "data": bytes.dropFirst(offset).base64EncodedString(), "done": true]
        default: fatalError("Unexpected call: \(method)")
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
    nonisolated static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
enum Bridge {
    enum Patience { case long }
    static func chatInvoke<T: Decodable>(peer: String?, _ method: String, _ params: [String: Any], patience: Patience? = nil,
        expectedScope: String, expectedGeneration: UInt64, as type: T.Type) async throws -> T {
        try await JSONDecoder().decode(type, from: Replies.shared.reply(method, params))
    }
}
'''
checks = r'''
@main struct Checks {
    @MainActor static func main() async throws {
        let bytes = await Replies.shared.bytes
        func cached(_ attachment: String, contents: Data) throws -> URL {
            let owner = try JSONEncoder().encode(WorkSessionContext.shared.scope).base64EncodedString()
            let key = Replies.sha(Data([owner, "peer", "chat", attachment, Replies.sha(bytes)].joined(separator: "|").utf8))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-chat-files/transfer-" + key)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("preview.png")
            try contents.write(to: file)
            return file
        }
        let complete = try cached("complete", contents: bytes)
        defer { try? FileManager.default.removeItem(at: complete.deletingLastPathComponent()) }
        let result = try await Bridge.downloadChatFile(id: "chat", attachmentID: "complete", peer: "peer",
            confirmRelay: { _ in await Replies.shared.confirm(false) })
        precondition(result == complete)
        let confirmations = await Replies.shared.confirmations
        let chunks = await Replies.shared.chunks
        precondition(confirmations == 0 && chunks == 0, "A completed local download must not ask to spend relay allowance")

        await Replies.shared.reset()
        let partial = try cached("partial", contents: bytes.prefix(5))
        defer { try? FileManager.default.removeItem(at: partial.deletingLastPathComponent()) }
        _ = try await Bridge.downloadChatFile(id: "chat", attachmentID: "partial", peer: "peer",
            confirmRelay: { _ in await Replies.shared.confirm(true) })
        let resumed = try Data(contentsOf: partial)
        let partialPrompts = await Replies.shared.confirmations
        precondition(resumed == bytes && partialPrompts == 1, "Partial downloads still require consent and preserve their prefix")

        await Replies.shared.reset()
        let denied = try cached("denied", contents: bytes.prefix(5))
        defer { try? FileManager.default.removeItem(at: denied.deletingLastPathComponent()) }
        do {
            _ = try await Bridge.downloadChatFile(id: "chat", attachmentID: "denied", peer: "peer", confirmRelay: { _ in await Replies.shared.confirm(false) })
            preconditionFailure("Declined relay continued")
        } catch is CancellationError {}
        let deniedBytes = try Data(contentsOf: denied)
        let deniedChunks = await Replies.shared.chunks
        precondition(deniedBytes == bytes.prefix(5) && deniedChunks == 0, "Declining the initial relay request keeps the partial download")

        await Replies.shared.reset()
        let corrupt = try cached("corrupt", contents: Data(repeating: 0, count: bytes.count))
        defer { try? FileManager.default.removeItem(at: corrupt.deletingLastPathComponent()) }
        do {
            _ = try await Bridge.downloadChatFile(id: "chat", attachmentID: "corrupt", peer: "peer", confirmRelay: { _ in await Replies.shared.confirm(false) })
            preconditionFailure("Corrupt completed cache was reused")
        } catch let error as NSError { precondition(error.domain == NSCocoaErrorDomain) }
        precondition(!FileManager.default.fileExists(atPath: corrupt.path))

        await Replies.shared.reset(relay: false, fallback: true)
        let fallback = try cached("fallback", contents: Data())
        defer { try? FileManager.default.removeItem(at: fallback.deletingLastPathComponent()) }
        _ = try await Bridge.downloadChatFile(id: "chat", attachmentID: "fallback", peer: "peer", confirmRelay: { _ in await Replies.shared.confirm(true) })
        let fallbackPrompts = await Replies.shared.confirmations
        let fallbacks = await Replies.shared.deniedChunks
        precondition(fallbackPrompts == 1 && fallbacks == 1, "A direct-to-relay fallback still requires explicit consent")
        print("Apple downloads: completed reuse, partial resume, declined relay, corrupt cache and route fallback passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-download-tests-') as directory:
    work = Path(directory)
    (work / 'checks.swift').write_text(code + models + claims + '\nextension Bridge {\n' + download + '\n}\n' + checks)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', str(work / 'checks.swift'),
                    str(root / 'apps/mac/Sources/Bridge/ChatFileIO.swift'),
                    str(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatFileStaging.swift'),
                    '-o', str(work / 'checks')], check=True)
    subprocess.run([str(work / 'checks')], check=True)
