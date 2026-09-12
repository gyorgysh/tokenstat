// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// A host-local folder ID is only unique on its owning computer.
struct ClientJobWorkspaceID: Hashable {
    let peer: String
    let workspace: String
}

/// Unsent starting prompts belong to a graph, not to the currently visible
/// text field. Changing selection must not carry a prompt to another graph.
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
