// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import Foundation

/// Keeps App Nap off while a terminal session is running.
///
/// macOS naps an app whose windows are all hidden or covered by something
/// else: timers are coalesced towards a second, and the process drops to
/// background CPU and I/O priority. The read loop then drains the host's
/// output buffer far slower than a printing agent fills it, and that buffer is
/// bounded at 512 KB, so a build log that runs while the window is behind
/// another one loses its middle and the terminal spends the first seconds
/// after the user comes back catching up on what survived. That is the "leave
/// it, come back, everything crawls" report: the app was not slow when the
/// user returned, it was asleep while they were away.
///
/// `.userInitiatedAllowingIdleSystemSleep` is the narrow option on purpose. It
/// lifts the nap and leaves the Mac free to sleep when nobody is at it: a
/// terminal must not be the reason a laptop stays awake in a bag.
///
/// Reference counted, because the assertion belongs to "some session is
/// running" rather than to whichever session started first.
@MainActor
enum TerminalActivity {
    private static var holders = 0
    private static var token: NSObjectProtocol?

    static func retain() {
        holders += 1
        guard holders == 1, token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "draining terminal session output"
        )
    }

    static func release() {
        holders = max(0, holders - 1)
        guard holders == 0, let held = token else { return }
        ProcessInfo.processInfo.endActivity(held)
        token = nil
    }
}
#endif
