#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise Apple upload retries with production code and an isolated transport."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Bridge/ChatFileTransfers.swift').read_text()
def declaration(signature, body=None):
    start = source.index(signature)
    brace = source.index('{', source.index(body, start) if body else start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
models = source[source.index('struct ChatFileCapabilities:'):source.index('private actor ChatUploadJournal')]
claims = declaration('private actor ChatFileTransferClaims')
upload = declaration('    static func uploadChatFile(', 'async throws -> ChatAttachment')
code = r'''
import Foundation
import CryptoKit
struct ChatAttachment: Codable, Sendable { let id: String; let name: String; let size: UInt64?; let mediaType: String? }
enum BridgeError: Error { case core(code: String, message: String) }
enum L10n { static func text(_ key: String) -> String { key } }
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    let scope = UUID().uuidString
    let generation: UInt64 = 1
}
enum RemoteHostFeature { case chatRecovery; func isSupported(peer: String?) async -> Bool { await Replies.shared.supported } }
private actor ChatUploadJournal {
    static let shared = ChatUploadJournal()
    var entries: [String:String] = [:]
    func get(_ key: String) -> String? { entries[key] }
    func set(_ key: String, transfer: String?) throws { entries[key] = transfer }
    func reset() { entries.removeAll() }
}
actor Replies {
    static let shared = Replies()
    var relay = false, failFinish = true, completed = false, cancelStatus = false, fallback = false
    var supported = true
    var cancelCapabilities = false
    var limit: UInt64 = 256 * 1024 * 1024
    var offset: UInt64 = 1000
    var prompts = 0, starts = 0, finishes = 0, capabilities = 0, chunks = 0, cancellations = 0
    var attachment: [String:Any] = [:]
    func reset() {
        relay = false; failFinish = true; completed = false; cancelStatus = false; fallback = false
        supported = true; cancelCapabilities = false
        limit = 256 * 1024 * 1024; offset = 1000
        prompts = 0; starts = 0; finishes = 0; capabilities = 0; chunks = 0; cancellations = 0
    }
    func resume(completed: Bool = false, offset: UInt64 = 1000, limit: UInt64 = 500, cancel: Bool = false) {
        relay = true; failFinish = false; self.completed = completed; self.offset = offset
        self.limit = limit; cancelStatus = cancel
    }
    func legacy() { supported = false; relay = true }
    func cancelPreflight() { cancelCapabilities = true; relay = true; failFinish = false; offset = 0 }
    func fresh(fallback: Bool = false) { failFinish = false; offset = 0; self.fallback = fallback }
    func confirm(_ answer: Bool) -> Bool { prompts += 1; return answer }
    func counts() -> [Int] { [prompts, starts, finishes, capabilities, chunks, cancellations] }
    func reply(_ method: String, _ params: [String:Any]) throws -> Data {
        let value: [String:Any]
        switch method {
        case "chat.attach":
            if relay && params["allowRelay"] as? Bool != true {
                throw BridgeError.core(code:"relay_consent_required", message:"Relay")
            }
            let bytes = Data(base64Encoded: params["data"] as! String)!
            precondition(bytes.count == 1000 && bytes.allSatisfy { $0 == 42 })
            chunks += 1
            var result: [String:Any] = ["id":"legacy", "name":params["name"]!, "size":bytes.count]
            result["mediaType"] = params["mediaType"]
            value = result
        case "chat.fileCapabilities":
            capabilities += 1
            if cancelCapabilities { withUnsafeCurrentTask { $0?.cancel() } }
            value = ["chunkBytes":512 * 1024,"maxFileBytes":limit,"relay":relay,"relayRemainingBytes":9999]
        case "chat.fileUploadStart":
            starts += 1
            attachment = ["id":"file-\(starts)","name":params["name"]!,"size":params["size"]!]
            attachment["mediaType"] = params["mediaType"]
            value = ["transferId":"upload","offset":offset]
        case "chat.fileUploadStatus":
            if cancelStatus { throw CancellationError() }
            var status: [String:Any] = ["transferId":"upload","offset":offset,"finished":completed]
            if completed { status["attachment"] = attachment }
            value = status
        case "chat.fileUploadChunk":
            if (relay || fallback) && params["allowRelay"] as? Bool != true {
                throw BridgeError.core(code:"relay_consent_required", message:"Relay")
            }
            let bytes = Data(base64Encoded: params["data"] as! String)!
            precondition(bytes.allSatisfy { $0 == 42 })
            chunks += 1; offset += UInt64(bytes.count)
            value = ["offset":offset]
        case "chat.fileUploadFinish":
            finishes += 1
            if failFinish { throw BridgeError.core(code:"offline", message:"Disconnected") }
            value = attachment
        case "chat.fileUploadCancel": cancellations += 1; value = ["cancelled":true]
        default: fatalError("Unexpected request \(method)")
        }
        return try JSONSerialization.data(withJSONObject:value)
    }
}
enum Bridge {
    enum Patience { case long }
    static func chatInvoke<T: Decodable>(peer: String?, _ method: String, _ params: [String:Any], patience: Patience? = nil,
        expectedScope: String, expectedGeneration: UInt64, as type: T.Type) async throws -> T {
        try await JSONDecoder().decode(type, from: Replies.shared.reply(method, params))
    }
}
'''
checks = r'''
@main struct Checks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("file.zip")
        try Data(repeating:42, count:1000).write(to:file)
        func send(_ type: String = "application/zip", approve: Bool = false) async throws -> ChatAttachment {
            try await Bridge.uploadChatFile(id:"chat", file:file, mediaType:type, peer:"peer",
                confirmRelay:{ _ in await Replies.shared.confirm(approve) })
        }
        func seed() async throws {
            await Replies.shared.reset(); await ChatUploadJournal.shared.reset()
            do { _ = try await send(); preconditionFailure("Fixture did not retain a receipt") }
            catch BridgeError.core(let code, _) { precondition(code == "offline") }
        }
        for completed in [true, false] {
            try await seed()
            await Replies.shared.resume(completed:completed)
            let result = try await send()
            precondition(result.name == "file.zip")
            await Replies.shared.resume(completed:true)
            _ = try await send()
            let counts = await Replies.shared.counts()
            precondition(counts[0] == 0 && counts[1] == 1 && counts[3] == 1 && counts[4] == 0,
                "Completed bytes must skip consent, limits, channel discovery and retransmission: \(counts)")
        }
        try await seed()
        await Replies.shared.resume(cancel:true)
        do { _ = try await send(); preconditionFailure("Cancelled status read continued") }
        catch is CancellationError {}
        var counts = await Replies.shared.counts()
        precondition(counts[0] == 0 && counts[1] == 1 && counts[5] == 0)
        await Replies.shared.resume(completed:true)
        _ = try await send()
        counts = await Replies.shared.counts()
        precondition(counts[1] == 1)

        try await seed()
        await Replies.shared.resume(offset:500, limit:2000)
        do { _ = try await send(); preconditionFailure("Declined relay continued") }
        catch is CancellationError {}
        counts = await Replies.shared.counts()
        precondition(counts[0] == 1 && counts[1] == 1 && counts[4] == 0 && counts[5] == 0)
        _ = try await send(approve:true)
        counts = await Replies.shared.counts()
        precondition(counts[1] == 1 && counts[4] == 1, "A declined prompt preserves its resume receipt")

        try await seed()
        await Replies.shared.resume(completed:true, limit:2000)
        let changed = try await send("application/octet-stream", approve:true)
        precondition(changed.mediaType == "application/octet-stream")
        counts = await Replies.shared.counts()
        precondition(counts[1] == 2, "Different media types must not reuse another attachment")

        await Replies.shared.reset(); await ChatUploadJournal.shared.reset()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await send()
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancelled upload continued") }
        catch is CancellationError {}
        counts = await Replies.shared.counts()
        precondition(counts.allSatisfy { $0 == 0 }, "Cancelled hashing must not start remote work")

        await Replies.shared.reset(); await ChatUploadJournal.shared.reset()
        await Replies.shared.cancelPreflight()
        let preflight = Task { try await send(approve:true) }
        do { _ = try await preflight.value; preconditionFailure("Cancelled preflight continued") }
        catch is CancellationError {}
        counts = await Replies.shared.counts()
        precondition(counts[0] == 0 && counts[1] == 0, "Cancelled preflight must not display consent")

        await Replies.shared.reset(); await ChatUploadJournal.shared.reset()
        await Replies.shared.fresh(fallback:true)
        _ = try await send(approve:true)
        counts = await Replies.shared.counts()
        precondition(counts[0] == 1 && counts[4] == 1, "Direct-to-relay fallback still needs consent")
        await Replies.shared.reset(); await ChatUploadJournal.shared.reset()
        await Replies.shared.fresh()
        do {
            _ = try await Bridge.uploadChatFile(id:"chat", file:file, peer:"peer",
                progress:{ _ in throw CancellationError() })
            preconditionFailure("Cancelled chunk upload continued")
        } catch is CancellationError {}
        counts = await Replies.shared.counts()
        let entries = await ChatUploadJournal.shared.entries
        precondition(counts[2] == 0 && counts[4] == 1 && counts[5] == 1 && entries.isEmpty,
            "Cancellation after sending bytes must cancel the host upload and retire its receipt")
        await Replies.shared.reset(); await ChatUploadJournal.shared.reset()
        await Replies.shared.legacy()
        let legacy = try await send(approve:true)
        counts = await Replies.shared.counts()
        precondition(legacy.mediaType == "application/zip" && counts[0] == 1 && counts[3] == 0 && counts[4] == 1,
            "Old hosts retain byte-exact uploads, metadata and relay consent")
        print("Apple uploads: completed receipt, pending finish, route limits, cancellation, declined resume, media type, fallback and old hosts passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-upload-check-') as directory:
    work = Path(directory)
    (work / 'checks.swift').write_text(code + models + claims + '\nextension Bridge {\n' + upload + '\n}\n' + checks)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', str(work / 'checks.swift'),
                    str(root / 'apps/mac/Sources/Bridge/ChatFileIO.swift'), '-o', str(work / 'checks')], check=True)
    subprocess.run([str(work / 'checks')], check=True)
