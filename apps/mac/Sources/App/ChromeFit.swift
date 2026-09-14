// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

/// When the desktop shell's columns fit beside the content, and when they
/// float over it instead.
///
/// One standard, taken from the inspector: the detail column keeps about 800
/// points, and a pane that would squeeze it below that stops being a column
/// and floats. The inspector's own edge (`widthForThreeColumns` in RootView)
/// is 1450 for exactly this reason: 260 sidebar plus 800 detail plus 400
/// inspector, near enough. The browser and the sidebar follow the same rule
/// here, so a narrowing window degrades the same way everywhere: the browser
/// floats, the sidebar peeks, and the content keeps the room.
///
/// The sizes are full-factor literals mirroring RootView's DisplayFit-scaled
/// values. On a scaled display the true edges sit a little lower, so these
/// float and peek slightly early there: the safe direction, and the windows
/// where the two answers differ do not exist on those screens.
///
/// Everything here is a pure function of the window width and the browser
/// width the user chose. The live drag width is deliberately not an input:
/// modes flip on drag end, never mid-gesture, so a drag cannot unmount its
/// own handle halfway through.
enum ChromeFit {
    /// Detail width below which a trailing pane floats instead of squeezing.
    static let comfortDetail = 800.0
    /// The sidebar column's footprint at full factor.
    static let sidebarWidth = 260.0
    /// The detail column's absolute minimum, below which nothing sits beside it.
    static let detailMinimum = 480.0
    /// The narrowest a floating or docked browser pane gets.
    static let browserMinimum = 320.0
    /// Divider widths: 1 beside the sidebar, 5 for the browser handle.
    static let sidebarDivider = 1.0
    static let browserDivider = 5.0
    /// How much content stays visible beside a floating browser.
    static let overlaySliver = 32.0

    /// Whether the sidebar keeps its column with the browser open.
    ///
    /// The window holds the sidebar, both dividers, comfortable detail, and
    /// the browser at the user's own width. A closed browser keeps the
    /// legacy sidebar edge, which lives in RootView, not here.
    static func sidebarRoomForBrowser(width: Double, persistedBrowser: Double) -> Bool {
        width >= sidebarWidth + sidebarDivider + comfortDetail + browserDivider
            + max(persistedBrowser, browserMinimum)
    }

    /// Whether the browser sits beside the content rather than floating.
    ///
    /// Even without the sidebar, the detail keeps its comfort width. Takes
    /// the persisted width, so a browser the user dragged very wide floats
    /// instead of crushing the detail to its minimum.
    static func browserBeside(width: Double, sidebarShowing: Bool, persistedBrowser: Double) -> Bool {
        let available = width - (sidebarShowing ? sidebarWidth : 0)
        let fitted = min(
            max(persistedBrowser, browserMinimum),
            max(browserMinimum, available - detailMinimum - browserDivider - sidebarDivider)
        )
        return available - browserDivider - fitted >= comfortDetail
    }

    /// The widest a docked browser gets: whatever leaves the detail minimum.
    static func besideMax(available: Double) -> Double {
        max(browserMinimum, available - detailMinimum - browserDivider - sidebarDivider)
    }

    /// The widest a floating browser gets: whatever leaves a sliver visible.
    static func overlayMax(width: Double) -> Double {
        max(browserMinimum, width - overlaySliver - browserDivider)
    }
}
