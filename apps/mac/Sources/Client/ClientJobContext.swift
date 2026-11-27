// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

struct ClientJobWorkspaceID: Hashable {
    let peer: String
    let workspace: String
}

struct ClientWorkflowInputs {
    private var values: [String: String] = [:]

    subscript(graphID: String?) -> String {
        get { graphID.flatMap { values[$0] } ?? "" }
        set {
            guard let graphID else { return }
            if newValue.isEmpty {
                values.removeValue(forKey: graphID)
            } else {
                values[graphID] = newValue
            }
        }
    }
}
