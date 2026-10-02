// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientWebPages.swift.
import Foundation

@main enum ClientWebPagesTests {
    static func main() {
        for host in ["https://tokenstat.ai", "https://account.example.test"] {
            precondition(ClientWebPages.privacy(host: host).absoluteString == "\(host)/privacy?mobile=1")
            precondition(ClientWebPages.terms(host: host).absoluteString == "\(host)/terms?mobile=1")
            let deletion = ClientWebPages.accountDeletion(host: host)
            precondition(deletion.absoluteString == "\(host)/settings/data?mobile=1&focus=delete#delete")
            precondition(ClientWebPages.withMobileFlag(deletion) == deletion)
        }
        let profile = ClientWebPages.publicProfile(host: "https://tokenstat.ai", handle: "someone")
        precondition(profile.absoluteString == "https://tokenstat.ai/someone?mobile=1")
        let existing = URL(string: "https://tokenstat.ai/privacy?source=app&mobile=1#details")!
        precondition(ClientWebPages.withMobileFlag(existing) == existing)
        print("Client web pages: stable service routes, account hosts, mobile flags and fragments passed")
    }
}
