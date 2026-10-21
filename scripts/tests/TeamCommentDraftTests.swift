// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TeamCommentDraftStore.swift TeamModels.swift WorkReference.swift JSONValue.swift.
import Foundation

@main struct TeamCommentDraftTests {
    static func expect(_ value: Bool) { precondition(value) }
    static func target(person: String = "member_fixture", share: String = "share_fixture") -> TeamCommentTarget {
        .init(origin: "https://accounts.example.test", person: person, organization: "org_fixture", repository: "repo_fixture", checkout: "checkout_fixture", share: share, host: String(repeating: "ab", count: 32))
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("team-comment-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TeamCommentDraftStore(directory: root), key = target()
        expect(try await store.load(key) == nil)
        let draft = try await store.save(key, text: "A fictional comment", expected: nil)!
        let reopened = TeamCommentDraftStore(directory: root)
        expect(try await reopened.load(key) == draft)
        expect(try await reopened.load(target(person: "another_person")) == nil)
        expect(try await reopened.load(target(share: "another_share")) == nil)
        let changed = try await store.save(key, text: "A revised comment", expected: draft)!
        do { _ = try await reopened.save(key, text: "Stale window", expected: draft); preconditionFailure("Stale writing overwrote another window") } catch TeamCommentDraftFailure.changed {}
        let reserved = try await store.reserve(key, expected: changed)
        expect(reserved.attempt != nil && reserved.text == changed.text)
        expect(try await reopened.load(key) == reserved)
        expect(try await reopened.reserve(key, expected: reserved) == reserved)
        do { _ = try await store.save(key, text: "Changed uncertain attempt", expected: reserved); preconditionFailure("Uncertain text was retargeted") } catch TeamCommentDraftFailure.pending {}
        expect(try await store.resolve(key, expected: reserved, state: .unknown) == reserved)
        expect(try await store.resolve(key, expected: reserved, state: .pending) == reserved)
        let retry = try await store.resolve(key, expected: reserved, state: .notAccepted)!
        expect(retry.text == reserved.text && retry.attempt == nil)
        let fresh = try await store.reserve(key, expected: retry)
        expect(fresh.attempt?.id != reserved.attempt?.id)
        expect(try await store.resolve(key, expected: fresh, state: .accepted) == nil)
        let later = try await reopened.save(key, text: "A later draft", expected: nil)!
        do { _ = try await store.resolve(key, expected: fresh, state: .accepted); preconditionFailure("Late acknowledgement removed newer writing") } catch TeamCommentDraftFailure.changed {}
        expect(try await store.load(key) == later)
        let holder = Process(), ready = Pipe()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-c", "import fcntl,sys,time\nf=open(sys.argv[1],'a')\nfcntl.lockf(f,fcntl.LOCK_EX)\nprint('ready',flush=True)\ntime.sleep(30)", root.appendingPathComponent("drafts.lock").path]
        holder.standardOutput = ready; holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer { if holder.isRunning { holder.terminate() }; holder.waitUntilExit() }
        var line = Data()
        while !line.contains(10) {
            let chunk = try ready.fileHandleForReading.read(upToCount: 1) ?? Data()
            expect(!chunk.isEmpty); line.append(chunk)
        }
        expect(String(data: line, encoding: .utf8) == "ready\n")
        do { _ = try await store.load(key); preconditionFailure("A busy file was waited on rather than reported") } catch TeamCommentDraftFailure.unavailable {}
        expect(holder.isRunning)
        holder.terminate(); holder.waitUntilExit()
        expect(try await store.load(key) == later)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let file = files.first { $0.pathExtension == "json" }!
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let original = try Data(contentsOf: file)
        try Data("{broken fixture".utf8).write(to: file)
        do { _ = try await reopened.save(key, text: "Do not overwrite damaged writing", expected: nil); preconditionFailure("Damaged storage became empty") } catch {}
        expect(try Data(contentsOf: file) == Data("{broken fixture".utf8))
        try original.write(to: file)
        let tooLong = try await store.save(key, text: String(repeating: "字", count: 4000), expected: later)!
        expect(!tooLong.canSend)
        do { _ = try await store.reserve(key, expected: tooLong); preconditionFailure("Oversized comment was reserved") } catch TeamCommentDraftFailure.tooLong {}
        expect(try await store.load(key) == tooLong)
        let outside = root.appendingPathComponent("outside.fixture")
        try Data("Keep this private fixture".utf8).write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        do { _ = try await store.load(key); preconditionFailure("Linked draft was read") } catch TeamCommentDraftFailure.unavailable {}
        expect(try String(contentsOf: outside, encoding: .utf8) == "Keep this private fixture")
        print("Team comment drafts preserve exact attempts, account/share isolation, concurrent edits and damaged files")
    }
}
