// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

enum ChromeFit {
    static let comfortDetail = 800.0
    static let sidebarWidth = 260.0
    static let detailMinimum = 480.0
    static let browserMinimum = 320.0
    static let sidebarDivider = 1.0
    static let browserDivider = 5.0
    static let overlaySliver = 32.0

    static func sidebarRoomForBrowser(width: Double, persistedBrowser: Double) -> Bool {
        width >= sidebarWidth + sidebarDivider + comfortDetail + browserDivider
            + max(persistedBrowser, browserMinimum)
    }

    static func browserBeside(width: Double, sidebarShowing: Bool, persistedBrowser: Double) -> Bool {
        let available = width - (sidebarShowing ? sidebarWidth : 0)
        let fitted = min(
            max(persistedBrowser, browserMinimum),
            max(browserMinimum, available - detailMinimum - browserDivider - sidebarDivider)
        )
        return available - browserDivider - fitted >= comfortDetail
    }

    static func besideMax(available: Double) -> Double {
        max(browserMinimum, available - detailMinimum - browserDivider - sidebarDivider)
    }

    static func overlayMax(width: Double) -> Double {
        max(browserMinimum, width - overlaySliver - browserDivider)
    }
}
