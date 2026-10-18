// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// The brand mark's ink bounds, shared by the ordinary logo and its glass
/// treatment. Three bars, one baseline, the same proportions and colours.
enum TokenstatLogoGeometry {
    static let inkSide: CGFloat = 42
    static let cornerRadius: CGFloat = 3.5
    struct Bar {
        let rect: CGRect
        let color: Color
    }
    static let bars: [Bar] = [
        .init(rect: CGRect(x: 0, y: 24, width: 12, height: 18),
              color: Color(red: 0xC3 / 255, green: 0xB0 / 255, blue: 0xFF / 255)),
        .init(rect: CGRect(x: 15, y: 12, width: 12, height: 30),
              color: Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255)),
        .init(rect: CGRect(x: 30, y: 0, width: 12, height: 42),
              color: Color(red: 0xE8 / 255, green: 0x79 / 255, blue: 0xF9 / 255)),
    ]
}
