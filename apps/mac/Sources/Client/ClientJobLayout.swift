// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Measures the space owned by a job workspace, after surrounding sidebars.
/// The selected job stays in its session when only this arrangement changes.
struct ClientJobLayout: Equatable {
    enum Arrangement: Equatable {
        case compact
        case twoColumns
        case threeColumns
    }

    let arrangement: Arrangement
    let listWidth: CGFloat
    let runWidth: CGFloat

    static func resolve(width: CGFloat, prefersStack: Bool) -> Self {
        guard !prefersStack, width.isFinite, width >= 760 else {
            return Self(arrangement: .compact, listWidth: 0, runWidth: 0)
        }
        if width < 1_080 {
            return Self(arrangement: .twoColumns, listWidth: 240, runWidth: 0)
        }
        return Self(arrangement: .threeColumns, listWidth: 260, runWidth: 300)
    }
}

/// Navigation intent belongs above the compact/split branch. Hiding a pushed
/// detail to make room for columns must not forget which job was open.
struct ClientJobNavigation: Equatable {
    private(set) var showsDetail = false

    mutating func openDetail() { showsDetail = true }

    func presentsDetail(in layout: ClientJobLayout) -> Bool {
        layout.arrangement == .compact && showsDetail
    }

    mutating func presentedDetailChanged(_ presented: Bool, in layout: ClientJobLayout) {
        guard layout.arrangement == .compact else { return }
        showsDetail = presented
    }
}
