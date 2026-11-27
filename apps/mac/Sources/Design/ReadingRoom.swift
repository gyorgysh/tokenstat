// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

enum ReadingRoom {
    #if os(macOS)
    static let laneWidth: CGFloat = 1040
    static let proseWidth: CGFloat = 820
    #else
    static let laneWidth: CGFloat = 780
    static let proseWidth: CGFloat = 780
    #endif

    static let listWidth: CGFloat = .infinity

    static let alignment: Alignment = .topLeading
}
