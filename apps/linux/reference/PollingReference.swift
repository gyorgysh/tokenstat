// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// The complete unchanged original ChatPolling.swift is compiled beside this.
import Foundation

@main enum PollingReference {
    static func main() throws {
        let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
        let traces = (input["traces"] as! [[[String: Any]]]).map { actions -> [Any] in
            var cadence = ChatPollCadence()
            return actions.map { action -> Any in
                let now = Double(action["now"] as! String)!
                let value: Any
                switch action["op"] as! String {
                case "note":
                    cadence.note(success: action["success"] as! Bool, changed: action["changed"] as! Bool, now: now)
                    value = NSNull()
                case "interval":
                    let duration = cadence.interval(busy: action["busy"] as! Bool,
                                                    attachments: action["attachments"] as! Bool, now: now).components
                    value = ["ms": duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000]
                case "status": value = ["claim": cadence.claimStatus(now: now, force: action["force"] as! Bool)]
                case "approvals": value = ["claim": cadence.claimApprovals(now: now, force: action["force"] as! Bool)]
                default: preconditionFailure("Unknown fixture action")
                }
                return ["nowBits": String(now.bitPattern), "value": value]
            }
        }
        let output = try JSONSerialization.data(withJSONObject: ["traces": traces], options: [.sortedKeys])
        FileHandle.standardOutput.write(output)
    }
}
