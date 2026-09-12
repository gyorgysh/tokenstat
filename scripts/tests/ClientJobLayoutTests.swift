// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientJobLayout.swift ClientJobContext.swift.
import Foundation

@main struct ClientJobLayoutTests {
    static func main() {
        let compact = ClientJobLayout.resolve(width: 520, prefersStack: false)
        let medium = ClientJobLayout.resolve(width: 820, prefersStack: false)
        let wide = ClientJobLayout.resolve(width: 1_180, prefersStack: false)
        assert(compact.arrangement == .compact)
        assert(medium.arrangement == .twoColumns)
        assert(wide.arrangement == .threeColumns)
        for width in [CGFloat.nan, .infinity, -1, 0, 375, 759] {
            assert(ClientJobLayout.resolve(width: width, prefersStack: false).arrangement == .compact)
        }
        for width in stride(from: CGFloat(760), through: 1_079, by: 1) {
            let layout = ClientJobLayout.resolve(width: width, prefersStack: false)
            assert(layout.arrangement == .twoColumns)
            assert(width - layout.listWidth - 1 >= 519)
        }
        assert(ClientJobLayout.resolve(width: 1_080, prefersStack: false).arrangement == .threeColumns)
        assert(1_080 - wide.listWidth - wide.runWidth - 2 >= 518)
        // Phone landscape and large accessibility text retain focused screens.
        assert(ClientJobLayout.resolve(width: 1_400, prefersStack: true).arrangement == .compact)

        var navigation = ClientJobNavigation()
        assert(!navigation.presentsDetail(in: compact))
        navigation.openDetail()
        assert(navigation.presentsDetail(in: compact))
        assert(!navigation.presentsDetail(in: medium))
        navigation.presentedDetailChanged(false, in: medium)
        assert(navigation.presentsDetail(in: compact))
        navigation.presentedDetailChanged(false, in: wide)
        assert(navigation.presentsDetail(in: compact))
        navigation.presentedDetailChanged(false, in: compact)
        assert(!navigation.showsDetail)

        var inputs = ClientWorkflowInputs()
        inputs["review"] = "Review the keyboard changes"
        inputs["release"] = "Prepare the release notes"
        inputs[nil] = "No graph selected"
        assert(inputs[nil].isEmpty)
        assert(inputs["review"] == "Review the keyboard changes")
        assert(inputs["release"] == "Prepare the release notes")
        inputs["release"] = ""
        assert(inputs["release"].isEmpty && !inputs["review"].isEmpty)
        let otherSession = ClientWorkflowInputs()
        assert(otherSession["review"].isEmpty)
        assert(ClientJobWorkspaceID(peer: "a", workspace: "same") != ClientJobWorkspaceID(peer: "b", workspace: "same"))
        assert(ClientJobWorkspaceID(peer: "a-b", workspace: "c") != ClientJobWorkspaceID(peer: "a", workspace: "b-c"))
        print("Job layout: width boundaries, accessible stacking, navigation, scoped drafts and host identity passed")
    }
}
