#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Check new and older host payloads against the production Swift detail model."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'apps/mac/Sources/Bridge/Models.swift').read_text()
model = source[source.index('struct PullDetail: Codable'):source.index('\nstruct PullTimelineEvent:', source.index('struct PullDetail: Codable'))]
harness = r'''
import Foundation
struct PullActor: Codable, Sendable, Hashable {}
struct PullReview: Codable, Sendable, Hashable {}
struct PullFile: Codable, Sendable, Hashable {}
struct PullCheck: Codable, Sendable, Hashable {}
func parseServerDate(_ date: String) -> Date? { nil }
'''
checks = r'''
@main struct Check {
    static func main() throws {
        var payload: [String: Any] = [
            "number": 1, "title": "", "body": "", "url": "", "author": [:],
            "createdAt": "", "updatedAt": "", "headRef": "", "baseRef": "",
            "additions": 0, "deletions": 0, "changedFiles": 0, "state": "open",
            "draft": false, "mergeable": "", "mergeState": "", "labels": [],
            "assignees": [], "reviewRequests": [], "reviews": [], "files": [], "checks": []
        ]
        func detail() throws -> PullDetail {
            try JSONDecoder().decode(PullDetail.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        var decoded = try detail()
        precondition(!decoded.hasIncompleteChecks)
        payload["checks"] = Array(repeating: [String: String](), count: 50)
        decoded = try detail()
        precondition(decoded.hasIncompleteChecks) // older host, limit reached
        payload["checksTruncated"] = false
        decoded = try detail()
        precondition(!decoded.hasIncompleteChecks) // exactly 50, complete
        payload["checksTruncated"] = true
        decoded = try detail()
        precondition(decoded.hasIncompleteChecks)
        print("Pull checks: older hosts and explicit page coverage passed")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(harness + model + checks)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
