// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Bound peer-supplied input before converting it to native event integers.
enum ScreenInputValues {
    static func isText(_ value: String) -> Bool {
        guard let scalar = value.unicodeScalars.first else { return false }
        // AppKit reports navigation/function keys in its private-use block.
        return scalar.value >= 32 && scalar.value != 127 && !(0xF700...0xF8FF).contains(scalar.value)
    }

    static func coordinate(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    static func button(_ value: Int?) -> UInt32 {
        guard let value, (0...31).contains(value) else { return 0 }
        return UInt32(value)
    }

    static func wheel(_ value: Double?) -> Int32 {
        guard let value, value.isFinite else { return 0 }
        return Int32(min(Double(Int32.max), max(Double(Int32.min), value)))
    }
}
