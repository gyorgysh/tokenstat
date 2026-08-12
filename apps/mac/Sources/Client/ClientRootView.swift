// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI
#if !os(macOS)
import UIKit
#endif

// The client is iOS and iPadOS only. The Mac has `RootView`, and these
// screens lean on toolbar placements and a tab bar that macOS does not
// have, so compiling them there would only break the desktop build.
#if !os(macOS)

/// The root of the iPhone and iPad client.
///
/// Not a narrow `RootView`. The Mac app is a workbench with two sidebars, a
/// terminal stack and a git pane, and a phone-sized copy of it would be the
/// wrong app rather than a smaller one. This root answers the two questions
/// someone opens a phone for, which `docs/ios-client-ui.md` states as: what did
/// I spend, and how much of my plan is left.
///
/// The chrome is the system's own. A `TabView` on iOS 26 draws the floating
/// glass bar, a `.toolbar` draws the glass top bar, and both keep their
/// behaviour under Reduce Transparency and Reduce Motion without this file
/// knowing about either. Custom glass is for the places no system control
/// exists, and there are deliberately very few.
struct ClientRootView: View {
    @State private var launch = LaunchState()
    @State private var selection: ClientTab = .home
    /// One account model for the whole client. The avatar reads it, the sheet
    /// edits it, and every screen that needs a tier or a machine list reads the
    /// same copy rather than starting a second sign-in state.
    @State private var account = AccountModel()
    /// Whether this phone can reach the internet. Every screen in the client is
    /// account plane, which means every screen depends on the network, so the
    /// answer belongs at the root rather than in each of them.
    @State private var connectivity = ConnectivityModel()
    /// The account sheet, opened from the avatar rather than from a tab. See
    /// `AvatarButton`.
    @State private var showAccount = false

    /// Set once the intro has been seen or skipped. A signed-in phone never
    /// sees it, so a reinstall onto an account that already exists does not get
    /// pitched the product it is already using.
    @AppStorage("client.hasOnboarded") private var hasOnboarded = false

    var body: some View {
        Group {
            // Three doors after the host is up, not two: still checking,
            // could not check (usually offline), and a definitive answer.
            // Folding a failed check into "signed out" was the cold-start bug
            // that flashed Sign in for a phone that still had a token.
            if !launch.hostReady || account.authPending {
                LaunchSplashView()
                    .transition(.opacity)
            } else if account.authNeedsRetry {
                ClientAuthRetryView(
                    message: account.authCheckError,
                    isLoading: account.isLoading
                ) {
                    Task { await account.load() }
                }
                .transition(.opacity)
            } else if !account.signedIn {
                // **The app is behind the sign-in, not beside it.** Every
                // screen here answers a question about an account, so a signed
                // out phone that can reach the tabs is four empty screens and a
                // sign-in card repeated on each of them. One door instead: the
                // intro on a first run, the sign-in screen after that.
                if hasOnboarded {
                    ClientLoginView()
                        .transition(.opacity)
                } else {
                    ClientOnboarding()
                        .transition(.opacity)
                }
            } else {
                tabs
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: account.signedIn)
        .animation(.easeInOut(duration: 0.28), value: account.authChecked)
        .animation(.easeInOut(duration: 0.28), value: account.authNeedsRetry)
        .tint(Theme.accent)
        .environment(account)
        .environment(connectivity)
        .task {
            connectivity.start()
            // Sign-in presents over the app rather than handing the URL to
            // Safari and hoping somebody comes back. See `ClientWebAuth`.
            account.signInPresenter = { ClientWebAuth.shared.start($0) }
            // The app closes the window the app opened. Without this the sheet
            // sits there after a successful approval, on top of a screen that
            // has already signed in behind it.
            account.signInDismisser = { ClientWebAuth.shared.cancel() }
            await launch.prepare()
            // Name this phone before anything asks the account who is on it.
            // See `ClientDeviceName`.
            await ClientDeviceName.publish()
            await account.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            // Cold start offline leaves authNeedsRetry. Signed-in screens also
            // want a fresh me after the network returns, and the tunnel session
            // this phone holds should reconnect now, not after its backoff.
            Task { await account.load() }
            Task { await Bridge.nudgeTunnel() }
        }
        .sheet(isPresented: $showAccount) {
            ClientAccountSheet()
                .environment(account)
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            ForEach(ClientTab.allCases) { tab in
                Tab(tab.label, systemImage: tab.symbol, value: tab) {
                    NavigationStack {
                        tab.content
                            .clientChrome(showAccount: $showAccount)
                    }
                }
            }
        }
        // The bar shrinks out of the way while reading and returns on scroll
        // up. It never hides completely: a control that disappears is one
        // people stop trusting.
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

/// The four destinations the client has.
///
/// Account is not among them on purpose. It lives behind the avatar in the top
/// bar, which is where a thumb already goes looking for it, and that keeps a
/// tab for something a person actually opens the app to see.
///
/// **Limits used to have a tab and gave it up.** The phone exists to answer two
/// questions, spend and what is left, and both belong on the screen that opens.
/// A tab for the second one meant somebody had to know it was there. It is a
/// card on Home now, which is also what the original plan said before the tab
/// bar tempted it out.
///
/// What took the free slot is **Workspaces**, which is the machine plane's front
/// door: folders on a machine that is awake, and later the sessions running in
/// them. That is the thing this app cannot do yet and the thing people will open
/// it hoping to find, so it gets a place rather than being buried under
/// Machines. Machines stays: a device is not a folder, and the account's tier,
/// its reach and its last-seen times belong to devices.
enum ClientTab: String, CaseIterable, Identifiable {
    case home
    case workspaces
    case insights
    case machines

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .workspaces: return "Workspaces"
        case .insights: return "Insights"
        case .machines: return "Devices"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "square.grid.3x3.fill"
        case .workspaces: return "folder.fill"
        case .insights: return "chart.bar.xaxis"
        case .machines: return "laptopcomputer"
        }
    }

    @ViewBuilder
    var content: some View {
        switch self {
        case .home: ClientHomeView()
        case .workspaces: ClientWorkspacesView()
        case .insights: ClientInsightsView()
        case .machines: ClientDevicesView()
        }
    }
}

/// Could not finish the first account check (almost always offline).
///
/// Separate from the login door on purpose: Sign in is for "we know you are
/// out". This is for "we could not ask". A Retry is the honest control.
private struct ClientAuthRetryView: View {
    let message: String?
    let isLoading: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: Theme.Space.m) {
                LogoMark(size: 46)
                Text("Could not reach your account")
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(message ?? "Check the connection and try again.")
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            Spacer()
            VStack(spacing: Theme.Space.m) {
                Button {
                    onRetry()
                } label: {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Try again").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(isLoading)
            }
            .tint(Theme.accent)
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
    }
}

private extension View {
    /// The top bar every client screen shares: the avatar, the wordmark, and
    /// room for exactly one contextual control.
    ///
    /// A modifier rather than a wrapper view, so each screen keeps its own
    /// scroll view as the direct child of the navigation stack. That is what
    /// lets content scroll under the glass instead of stopping at its edge.
    func clientChrome(showAccount: Binding<Bool>) -> some View {
        toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AvatarButton { showAccount.wrappedValue = true }
                }
                // The wordmark, not the screen's name. The tab bar already
                // says which screen this is, and the middle of the top bar is
                // the one piece of pure brand the client gets.
                ToolbarItem(placement: .principal) {
                    // Larger than the Mac's sidebar lockup, and not filling:
                    // this is the one brand on the screen and it has a whole
                    // bar to itself, where the sidebar size read as a caption.
                    // `fills` off so it centres instead of pushing right.
                    Wordmark(size: 22, fills: false)
                        .accessibilityAddTraits(.isHeader)
                }
            }
    }
}

#endif
