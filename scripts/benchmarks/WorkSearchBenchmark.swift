// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Manual release-mode benchmark of the production local index. Synthetic data only.
import Foundation

@main struct WorkSearchBenchmark {
    static func main() async throws {
        let bytesPerMessage = max(128, min(10_000, Int(CommandLine.arguments.dropFirst().first ?? "1024") ?? 1024))
        let iterations = max(5, min(100, Int(CommandLine.arguments.dropFirst(2).first ?? "20") ?? 20))
        let varied = CommandLine.arguments.dropFirst(3).first == "varied"
        var random: UInt64 = 42
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz \n".utf8)
        let scope = WorkReference.Scope.local(installationID: "benchmark")
        let folder = WorkSearchIndex.Folder(hostIdentity: "fixture-host", workspaceID: "fixture-folder")
        let index = WorkSearchIndex(scope: scope, folders: [folder])
        let clock = ContinuousClock()
        func milliseconds(_ elapsed: Duration) -> Double {
            Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        }
        let started = clock.now
        var sourceBytes = 0
        var indexBuildMS = 0.0
        let prose = String(repeating: "Planning local work. ", count: bytesPerMessage / 21 + 1)
        for conversation in 0..<100 {
            let reference = WorkReference(scope: scope, hostIdentity: folder.hostIdentity,
                workspaceID: folder.workspaceID, kind: .conversation, itemID: "conversation-\(conversation)")
            var documents: [WorkSearchIndex.Document] = []
            for message in 0..<100 {
                let number = conversation * 100 + message
                var anchored = reference
                anchored.anchor = "user-s\(message + 1)"
                let body: String
                if varied {
                    var bytes: [UInt8] = []
                    bytes.reserveCapacity(bytesPerMessage)
                    for _ in 0..<bytesPerMessage {
                        random = random &* 6364136223846793005 &+ 1442695040888963407
                        bytes.append(alphabet[Int((random >> 32) % UInt64(alphabet.count))])
                    }
                    body = String(decoding: bytes, as: UTF8.self)
                } else { body = String(prose.prefix(bytesPerMessage)) }
                let text = body + " Café quartz row \(number)."
                sourceBytes += text.utf8.count
                documents.append(.init(reference: anchored, revision: "r1", title: "Conversation \(conversation)",
                    text: text, folderName: "Project", machineName: "Fixture", updatedAt: Date(timeIntervalSince1970: Double(number)), partial: false))
            }
            let indexing = clock.now
            guard let load = await index.beginLoad(reference), await index.replace(load, documents: documents) else { fatalError("Fixture refused") }
            indexBuildMS += milliseconds(indexing.duration(to: clock.now))
        }
        let buildMS = milliseconds(started.duration(to: clock.now))
        var results: [[String: Any]] = []
        for queryText in ["quartz", "café", "row 9987", "absent-needle"] {
            let query = try WorkSearchQuery(queryText)
            var elapsed: [Double] = []
            var total = 0
            for _ in 0..<iterations {
                let began = clock.now
                let result = try await index.search(query)
                elapsed.append(milliseconds(began.duration(to: clock.now)))
                total = result.total
                precondition(result.hits.count <= 50)
            }
            elapsed.sort()
            results.append(["query": queryText, "total": total, "median_ms": elapsed[elapsed.count / 2],
                            "p95_ms": elapsed[min(elapsed.count - 1, Int(ceil(Double(elapsed.count) * 0.95)) - 1)]])
        }
        let output: [String: Any] = ["messages": 10_000, "conversations": 100, "source_bytes": sourceBytes,
            "iterations": iterations, "build_ms": buildMS, "index_build_ms": indexBuildMS,
            "corpus": varied ? "varied" : "repeated", "queries": results, "optimized": true,
            "os": ProcessInfo.processInfo.operatingSystemVersionString]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
