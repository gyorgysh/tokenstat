// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with DesktopOpenRequest.swift and DesktopWorkbenchState.swift.
import Foundation

@main struct DesktopOpenRequestTests {
    struct Example: Decodable {
        let name: String
        let url: String
        let tool: String?
        let workspace: String?
        let tab: String?
        let browser: String?
        let session: String?
        let commit: String?
        let new: Bool?
    }
    static func main() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("desktop-actions.json")
        let examples = try JSONDecoder().decode([Example].self, from: Data(contentsOf: file))
        for example in examples {
            let request = URL(string: example.url).flatMap(DesktopOpenRequest.init(url:))
            guard let tool = example.tool else { precondition(request == nil, example.name); continue }
            guard let request else { preconditionFailure(example.name) }
            precondition(request.tool.rawValue == tool && request.workspaceID == example.workspace, example.name)
            precondition(request.inspectorTab?.rawValue == example.tab && request.browserURL?.absoluteString == example.browser, example.name)
            precondition(request.sessionID == example.session && request.newTerminal == (example.new ?? false), example.name)
            precondition(request.commitID == example.commit, example.name)
        }
        let oversized = URL(string: "tokenstat://workbench/open?workspace=" + String(repeating: "a", count: 513) + "&tool=changes")!
        precondition(DesktopOpenRequest(url: oversized) == nil)
        let one = DesktopTerminalIntent(sessionID: nil, newTerminal: true)
        let two = DesktopTerminalIntent(sessionID: nil, newTerminal: true)
        precondition(one.id != two.id, "An explicit repeated action needs its own consumable identity")
        print("Desktop action contract: \(examples.count) shared Mac/Windows cases passed")
    }
}
