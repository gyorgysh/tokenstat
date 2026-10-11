// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CryptoKit

struct ChatFileCapabilities: Codable, Sendable {
    let chunkBytes: Int
    let maxFileBytes: UInt64
    let relay: Bool
    let relayRemainingBytes: UInt64?
}
private struct ChatUploadStatus: Codable, Sendable {
    let transferId: String
    let offset: UInt64
    var finished: Bool?
    var attachment: ChatAttachment?
}
private struct ChatChunk: Codable, Sendable {
    var offset: UInt64
    var nextOffset: UInt64?
    var data: String?
    var done: Bool?
}
private struct ChatDownloadInfo: Codable, Sendable {
    let attachment: ChatAttachment
    let sha256: String
    let chunkBytes: Int
}

private func chatFileRelayRefusal(_ error: Error) -> Bool {
        if case let BridgeError.core(code, _) = error { return code == "relay_consent_required" }
        return false
    }


private actor ChatUploadJournal {
    static let shared = ChatUploadJournal()
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tokenstat-drafts/upload-receipts.json")
    private struct Entry: Codable { let transfer: String; let date: Date }
    private var entries: [String: Entry]?
    private func load() {
        guard entries == nil else { return }
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? 0) <= 64 * 1024,
            let data = try? Data(contentsOf: url) { entries = (try? JSONDecoder().decode([String:Entry].self, from: data)) ?? [:] }
        else { entries = [:] }
        entries = entries?.filter { Date().timeIntervalSince($0.value.date) < 24 * 60 * 60 }
    }
    func get(_ key: String) -> String? { load(); return entries?[key]?.transfer }
    func set(_ key: String, transfer: String?) throws {
        load()
        if let transfer { entries?[key] = Entry(transfer: transfer, date: Date()) } else { entries?[key] = nil }
        if (entries?.count ?? 0) > 128, let oldest = entries?.min(by: { $0.value.date < $1.value.date })?.key { entries?[oldest] = nil }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        try JSONEncoder().encode(entries ?? [:]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: url.path)
    }
}

private actor ChatFileTransferClaims {
    static let shared = ChatFileTransferClaims()
    private var active: Set<String> = []
    func acquire(_ key: String) throws {
        guard active.insert(key).inserted else { throw BridgeError.core(code:"file_transfer_busy",message:L10n.text("common.chat_files_busy")) }
    }
    func release(_ key: String) { active.remove(key) }
}

extension Bridge {
    static func uploadChatFile(id: String, file: URL, name: String? = nil, mediaType: String? = nil,
        peer: String?, confirmRelay: @escaping @Sendable (UInt64?) async -> Bool = { _ in false },
        progress: @escaping @Sendable (Double) async throws -> Void = { _ in }) async throws -> ChatAttachment {
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        let (scope, generation) = await MainActor.run { (WorkSessionContext.shared.scope, WorkSessionContext.shared.generation) }
        let (size, digest) = try await Task.detached { try ChatFileIO.hash(file) }.value
        guard await RemoteHostFeature.chatRecovery.isSupported(peer: peer) else {
            guard size <= 12 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            guard let bytes = try input.read(upToCount: Int(size) + 1), bytes.count == Int(size) else { throw CocoaError(.fileReadCorruptFile) }
            var legacy: [String:Any] = ["id":id,"name":name ?? file.lastPathComponent,"data":bytes.base64EncodedString(),"allowRelay":false]
            if let mediaType { legacy["mediaType"] = mediaType }
            do { return try await chatInvoke(peer:peer,"chat.attach",legacy,patience:Patience.long,expectedScope:scope,expectedGeneration:generation,as:ChatAttachment.self) }
            catch {
                guard chatFileRelayRefusal(error), await confirmRelay(nil) else { throw error }
                legacy["allowRelay"] = true
                return try await chatInvoke(peer:peer,"chat.attach",legacy,patience:Patience.long,expectedScope:scope,expectedGeneration:generation,as:ChatAttachment.self)
            }
        }
        let capabilities = try await chatInvoke(peer: peer, "chat.fileCapabilities", ["id": id], expectedScope: scope, expectedGeneration: generation, as: ChatFileCapabilities.self)
        guard size <= min(capabilities.maxFileBytes, ChatFileIO.maximumBytes) else { throw CocoaError(.fileReadTooLarge) }
        var allowRelay = false
        if capabilities.relay { guard await confirmRelay(capabilities.relayRemainingBytes) else { throw CancellationError() }; allowRelay = true }
        var params: [String: Any] = ["id": id, "name": name ?? file.lastPathComponent, "size": size, "sha256": digest]
        if let mediaType { params["mediaType"] = mediaType }
        let owner = try JSONEncoder().encode(scope).base64EncodedString()
        let journalKey = SHA256.hash(data: Data([owner, peer ?? "local", id, digest, name ?? file.lastPathComponent].joined(separator: "|").utf8)).map { String(format:"%02x",$0) }.joined()
        try await ChatFileTransferClaims.shared.acquire(journalKey)
        defer { Task { await ChatFileTransferClaims.shared.release(journalKey) } }
        let upload: ChatUploadStatus
        if let transfer = await ChatUploadJournal.shared.get(journalKey),
            let status = try? await chatInvoke(peer:peer,"chat.fileUploadStatus",["id":id,"transferId":transfer],expectedScope:scope,expectedGeneration:generation,as:ChatUploadStatus.self) {
            if status.finished == true, let attachment = status.attachment {
                try await ChatUploadJournal.shared.set(journalKey, transfer:nil)
                return attachment
            }
            upload = status
        } else {
            upload = try await chatInvoke(peer: peer, "chat.fileUploadStart", params, expectedScope: scope, expectedGeneration: generation, as: ChatUploadStatus.self)
            do { try await ChatUploadJournal.shared.set(journalKey, transfer:upload.transferId) }
            catch {
                struct Cancelled: Decodable, Sendable { let cancelled: Bool }
                _ = try? await chatInvoke(peer:peer,"chat.fileUploadCancel",["id":id,"transferId":upload.transferId],expectedScope:scope,expectedGeneration:generation,as:Cancelled.self)
                throw error
            }
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset = upload.offset
        guard offset <= size, capabilities.chunkBytes > 0 else { throw CocoaError(.fileReadCorruptFile) }
        do {
            while offset < size {
                try Task.checkCancellation()
                try handle.seek(toOffset: offset)
                guard let data = try handle.read(upToCount: min(Int(size - offset), min(capabilities.chunkBytes, ChatFileIO.chunkBytes))), !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                var request: [String: Any] = ["id":id,"transferId":upload.transferId,"offset":offset,"data":data.base64EncodedString(),"allowRelay":allowRelay]
                let chunk: ChatChunk
                do {
                    chunk = try await chatInvoke(peer: peer, "chat.fileUploadChunk", request, patience: Patience.long, expectedScope: scope, expectedGeneration: generation, as: ChatChunk.self)
                } catch {
                    guard !allowRelay, chatFileRelayRefusal(error), await confirmRelay(capabilities.relayRemainingBytes) else { throw error }
                    allowRelay = true; request["allowRelay"] = true
                    chunk = try await chatInvoke(peer: peer, "chat.fileUploadChunk", request, patience: Patience.long, expectedScope: scope, expectedGeneration: generation, as: ChatChunk.self)
                }
                guard chunk.offset == offset + UInt64(data.count) else { throw CocoaError(.fileReadCorruptFile) }
                offset = chunk.offset
                try await progress(Double(offset)/Double(size))
            }
            let attachment = try await chatInvoke(peer: peer, "chat.fileUploadFinish", ["id":id,"transferId":upload.transferId], patience: Patience.long, expectedScope: scope, expectedGeneration: generation, as: ChatAttachment.self)
            try await ChatUploadJournal.shared.set(journalKey, transfer:nil)
            return attachment
        } catch {
            struct Cancelled: Decodable, Sendable { let cancelled: Bool }
            if error is CancellationError {
                _ = try? await chatInvoke(peer: peer,"chat.fileUploadCancel",["id":id,"transferId":upload.transferId],expectedScope:scope,expectedGeneration:generation,as:Cancelled.self)
                try? await ChatUploadJournal.shared.set(journalKey, transfer:nil)
            }
            throw error
        }
    }
    static func downloadChatFile(id: String, attachmentID: String, peer: String?,
        confirmRelay: @escaping @Sendable (UInt64?) async -> Bool = { _ in false },
        progress: @escaping @Sendable (Double) async throws -> Void = { _ in }) async throws -> URL {
        let (scope, generation) = await MainActor.run { (WorkSessionContext.shared.scope, WorkSessionContext.shared.generation) }
        let capabilities = try await chatInvoke(peer:peer,"chat.fileCapabilities",["id":id],expectedScope:scope,expectedGeneration:generation,as:ChatFileCapabilities.self)
        let info = try await chatInvoke(peer:peer,"chat.fileDownloadInfo",["id":id,"attachmentId":attachmentID],patience:Patience.long,expectedScope:scope,expectedGeneration:generation,as:ChatDownloadInfo.self)
        guard let size = info.attachment.size, size > 0, size <= min(capabilities.maxFileBytes, ChatFileIO.maximumBytes) else { throw CocoaError(.fileReadTooLarge) }
        var allowRelay = false
        if capabilities.relay { guard await confirmRelay(capabilities.relayRemainingBytes) else { throw CancellationError() }; allowRelay = true }
        let owner = try JSONEncoder().encode(scope).base64EncodedString()
        let key = SHA256.hash(data: Data([owner, peer ?? "local", id, attachmentID, info.sha256].joined(separator:"|").utf8)).map { String(format:"%02x",$0) }.joined()
        try await ChatFileTransferClaims.shared.acquire(key)
        defer { Task { await ChatFileTransferClaims.shared.release(key) } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-chat-files/transfer-" + key, isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let name = ChatFileStaging.sanitized(info.attachment.name)
        let file = directory.appendingPathComponent(name == "." || name == ".." || name.isEmpty ? "attachment" : name)
        if !FileManager.default.fileExists(atPath:file.path) {
            guard FileManager.default.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forWritingTo:file)
        defer { try? handle.close() }
        do {
            var offset: UInt64 = 0
            var hash = SHA256()
            let existing = try FileHandle(forReadingFrom:file)
            defer { try? existing.close() }
            while let data = try existing.read(upToCount:ChatFileIO.chunkBytes), !data.isEmpty {
                offset += UInt64(data.count)
                guard offset <= size else { throw CocoaError(.fileReadCorruptFile) }
                hash.update(data:data)
            }
            try handle.seek(toOffset:offset)
            while offset < size {
                try Task.checkCancellation()
                var request: [String:Any] = ["id":id,"attachmentId":attachmentID,"offset":offset,"allowRelay":allowRelay]
                let chunk: ChatChunk
                do { chunk = try await chatInvoke(peer:peer,"chat.fileDownloadChunk",request,patience:Patience.long,expectedScope:scope,expectedGeneration:generation,as:ChatChunk.self) }
                catch {
                    guard !allowRelay, chatFileRelayRefusal(error), await confirmRelay(capabilities.relayRemainingBytes) else { throw error }
                    allowRelay = true; request["allowRelay"] = true
                    chunk = try await chatInvoke(peer:peer,"chat.fileDownloadChunk",request,patience:Patience.long,expectedScope:scope,expectedGeneration:generation,as:ChatChunk.self)
                }
                guard chunk.offset == offset, let encoded = chunk.data, encoded.utf8.count <= 699052,
                    let data = Data(base64Encoded:encoded), !data.isEmpty, data.count <= ChatFileIO.chunkBytes,
                    chunk.nextOffset == offset + UInt64(data.count), offset + UInt64(data.count) <= size else { throw CocoaError(.fileReadCorruptFile) }
                try handle.write(contentsOf:data); hash.update(data:data); offset += UInt64(data.count)
                try await progress(Double(offset)/Double(size))
            }
            guard hash.finalize().map({String(format:"%02x",$0)}).joined() == info.sha256 else { throw CocoaError(.fileReadCorruptFile) }
            try handle.synchronize()
            return file
        } catch {
            if error is CancellationError || (error as NSError).domain == NSCocoaErrorDomain { try? FileManager.default.removeItem(at:directory) }
            throw error
        }
    }
}
