// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChromeFit.swift.
import Foundation

@main enum ChromeFitTests {
    static func main() {
        // The sidebar keeps its column only with room for comfortable
        // detail plus the browser at the user's own width.
        precondition(ChromeFit.sidebarRoomForBrowser(width: 1677, persistedBrowser: 611))
        precondition(!ChromeFit.sidebarRoomForBrowser(width: 1676, persistedBrowser: 611))
        precondition(ChromeFit.sidebarRoomForBrowser(width: 1386, persistedBrowser: 320))
        precondition(!ChromeFit.sidebarRoomForBrowser(width: 1385, persistedBrowser: 320))
        precondition(ChromeFit.sidebarRoomForBrowser(width: 1386, persistedBrowser: 100))
        // A narrow window floats the browser and peeks the sidebar; the
        // pair below is the 13:21:53 beside state and the 13:21:56 crushed
        // state, which must float instead.
        precondition(ChromeFit.browserBeside(width: 1437, sidebarShowing: false, persistedBrowser: 611))
        precondition(!ChromeFit.browserBeside(width: 1048, sidebarShowing: false, persistedBrowser: 611))
        precondition(ChromeFit.browserBeside(width: 1416, sidebarShowing: false, persistedBrowser: 611))
        precondition(!ChromeFit.browserBeside(width: 1415, sidebarShowing: false, persistedBrowser: 611))
        precondition(ChromeFit.browserBeside(width: 1676, sidebarShowing: true, persistedBrowser: 611))
        precondition(!ChromeFit.browserBeside(width: 1675, sidebarShowing: true, persistedBrowser: 611))
        precondition(!ChromeFit.browserBeside(width: 1200, sidebarShowing: true, persistedBrowser: 611))
        precondition(ChromeFit.browserBeside(width: 1125, sidebarShowing: false, persistedBrowser: 320))
        precondition(!ChromeFit.browserBeside(width: 1124, sidebarShowing: false, persistedBrowser: 320))
        // A browser dragged very wide floats on ordinary windows.
        precondition(!ChromeFit.browserBeside(width: 1804, sidebarShowing: false, persistedBrowser: 1000))
        precondition(ChromeFit.browserBeside(width: 1805, sidebarShowing: false, persistedBrowser: 1000))
        // The docked maximum leaves the detail minimum; the floating
        // maximum leaves a sliver of content visible.
        precondition(ChromeFit.besideMax(available: 1307) == 1307 - 486)
        precondition(ChromeFit.besideMax(available: 400) == 320)
        precondition(ChromeFit.overlayMax(width: 1048) == 1048 - 37)
        precondition(ChromeFit.overlayMax(width: 300) == 320)
        print("Chrome fit: comfort edges, float coupling, and mode maxima")
    }
}
