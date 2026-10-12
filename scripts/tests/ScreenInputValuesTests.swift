// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ScreenInputValues.swift.
import Foundation

@main struct ScreenInputValuesTests {
    static func main() {
        assert(ScreenInputValues.isText("é"))
        assert(!ScreenInputValues.isText("\u{F702}"), "left arrow is a key event, not private-use text")
        assert(!ScreenInputValues.isText("\r"))
        assert(ScreenInputValues.button(-1) == 0)
        assert(ScreenInputValues.button(Int.max) == 0)
        assert(ScreenInputValues.button(2) == 2)
        assert(ScreenInputValues.coordinate(1e300) == 1)
        assert(ScreenInputValues.coordinate(-1) == 0)
        assert(ScreenInputValues.coordinate(.nan) == 0)
        assert(ScreenInputValues.coordinate(0.75) == 0.75)
        assert(ScreenInputValues.wheel(1e300) == Int32.max)
        assert(ScreenInputValues.wheel(-1e300) == Int32.min)
        assert(ScreenInputValues.wheel(.infinity) == 0)
        assert(ScreenInputValues.wheel(-3.8) == -3)
        print("Screen input integer and coordinate bounds passed")
    }
}
