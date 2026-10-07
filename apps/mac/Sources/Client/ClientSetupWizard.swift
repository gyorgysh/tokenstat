// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// How somebody gets a machine, asked once and answerable forever after.
///
/// Not a modal that traps anybody: every step can be left, and leaving lands
/// on the numbers, which is a real product rather than a failure state. Skip
/// sits below the three doors as a quiet button rather than a fourth card,
/// so it never reads as a fourth way to set up.
struct ClientSetupWizard: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation

    @Bindable var session: ClientSetupSession
    private var model: ClientSetupModel { session.model }
    private var library: SSHLibraryModel {
        get { session.library }
        nonmutating set { session.library = newValue }
    }
    private var path: [SetupStep] {
        get { session.path }
        nonmutating set { session.path = newValue }
    }
    /// Set when a picked door fails to start. The doors show no failure until
    /// then. prepare() runs on open and stays silent; the check reruns on
    /// entry instead.
    private var entryAttempted: Bool {
        get { session.entryAttempted }
        nonmutating set { session.entryAttempted = newValue }
    }

    var body: some View {
        NavigationStack(path: $session.path) {
            doors
                .navigationTitle(L10n.text("apple.clientsetupwizard.set_up_a_machine.43e10e13"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.text("common.close")) { dismiss() }
                            // Escape leaves, for somebody on a keyboard. The
                            // sheet is dismissible by gesture already, and a
                            // keyboard had no equivalent.
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("setup.close")
                    }
                }
                .navigationDestination(for: SetupStep.self) { step in
                    ClientSetupServerStep(step: step, model: model, library: library, path: $session.path, onFinish: { dismiss() })
                }
        }
        .tint(Theme.accent)
        .task {
            await session.prepare()
            await account.load()
        }
        .onChange(of: account.account) { _, now in accountDidChange(now) }
        .onChange(of: WorkSessionContext.shared.generation) { _, _ in accountDidChange(account.account) }
        .environment(account)
    }

    /// Both account callbacks use the library's immutable lifetime, so their
    /// delivery order cannot pair a new setup model with a retired library.
    private func accountDidChange(_ now: Account?) {
        let departed = library.ownership.captured.map {
            $0.scope != WorkSessionContext.shared.scope || $0.generation != WorkSessionContext.shared.generation
        } ?? false
        if departed {
            session.cancelPreparation()
            library.deactivate()
            library = SSHLibraryModel(ownerScope: WorkSessionContext.shared.scope)
        }
        guard model.shouldReprepare(for: now) || departed else { return }
        path = []; entryAttempted = false
        let currentLibrary = library
        Task { await model.prepare(library: currentLibrary) }
    }

    // MARK: - D0, the question

    private var doors: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                header
                // Failures show here only once setup is underway. Prepared and
                // failing answers a tap. Unprepared with an entry attempt
                // answers the picked door. A prepare that fails on open stays
                // silent and reruns on entry.
                if let failure = model.failure, model.prepared || entryAttempted {
                    // Genuinely signed out gets sign-in words; anything else,
                    // including a signed-in app whose account answered setup
                    // differently, gets a retry and never sign-in advice.
                    if !model.prepared,
                       failure.action == .signInToAccount || failure.action == .retry {
                        if failure.action == .signInToAccount, !account.signedIn {
                            SetupSignInCard(
                                onRetry: {
                                    Task { await model.prepare(library: library) }
                                },
                                onDismiss: clearEntryFailure
                            )
                        } else {
                            SetupRetryCard(
                                onRetry: {
                                    Task {
                                        await account.load()
                                        await model.prepare(library: library)
                                    }
                                },
                                onDismiss: clearEntryFailure
                            )
                        }
                    } else {
                        SetupFailureBanner(
                            failure: failure,
                            onDismiss: { model.failure = nil },
                            onRecover: { recover($0, model: model, path: $session.path) }
                        )
                    }
                }
                if let draft = model.savedDraft { resumeCard(draft) }
                // The computer first: no token, no rental, nothing to buy.
                // The doors below it both assume a server.
                door(
                    title: L10n.text("apple.clientsetupwizard.on_my_mac.8282732a"),
                    body: L10n.text("apple.clientsetupwizard.install_the_desktop_app_on_the_computer_yo.adea6dec"),
                    requirement: nil,
                    symbol: "laptopcomputer"
                ) {
                    enter([.mac])
                }
                door(
                    title: L10n.text("apple.clientsetupwizard.on_a_server_i_have.70b31f4d"),
                    body: L10n.text("apple.clientsetupwizard.connect_over_ssh_and_set_it_up_tokenstat_i.8fa4f9e0"),
                    requirement: paywalled ? L10n.text("apple.clientsetupwizard.reaching_it_needs_patron.c628ad97") : nil,
                    symbol: "server.rack"
                ) {
                    enter([.where])
                }
                door(
                    title: L10n.text("apple.clientsetupwizard.on_a_cloud_machine.304af746"),
                    body: L10n.text("apple.clientsetupwizard.a_vps_or_a_dedicated_server_import_the_one.0e3b5c2d"),
                    requirement: paywalled ? L10n.text("apple.clientsetupwizard.reaching_it_needs_patron.c628ad97") : nil,
                    symbol: "cloud.fill"
                ) {
                    enter([.cloud])
                }
                // Leaving, without pretending it is a setup choice. A fourth card
                // wore the same surface as the three doors and read as a fourth
                // way to set up. A quiet bordered button says what it is.
                VStack(spacing: Theme.Space.s) {
                    Button(L10n.text("apple.clientsetupwizard.skip_for_now.b58eb52c"), .next) { dismiss() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("setup.skip")
                    Text(L10n.text("apple.clientsetupwizard.go_to_your_account_and_your_numbers_usage.fb973c15"))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, Theme.Space.xs)
                Text(
                    L10n.text("apple.clientsetupwizard.nothing_here_is_permanent_every_door_can_b.7027fa6d")
                )
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Space.xs)
            }
            .padding(Theme.Space.m)
            .setupColumn()
        }
        .background(Theme.background)
    }

    /// A picked door setup could not walk through. prepare() runs on open so
    /// the resume card and the install line are warm. Its failure stays
    /// silent until a door is picked, and a success clears the attempt on
    /// the way in.
    private func enter(_ steps: [SetupStep]) {
        if model.prepared {
            path = steps
            return
        }
        let presentationID = session.presentation?.id
        let currentModel = model
        let currentLibrary = library
        Task { @MainActor in
            guard let ready = await currentModel.prepare(library: currentLibrary),
                  session.presentation?.id == presentationID,
                  session.model === currentModel else { return }
            if ready {
                entryAttempted = false
                path = steps
            } else {
                entryAttempted = true
            }
        }
    }

    /// Forget a failed entry. The doors go back to saying nothing, and the
    /// next picked door runs the check again.
    private func clearEntryFailure() {
        entryAttempted = false
        model.failure = nil
    }

    /// A picked door opened with no signed-in account. Not the failure's own
    /// wording about "the account that started this setup", which confused
    /// somebody who had started nothing. No art: the header above already
    /// carries the connection scene, and repeating it here made one picture
    /// do two jobs.
    private func SetupSignInCard(onRetry: @escaping () -> Void, onDismiss: @escaping () -> Void) -> some View {
        ClientEmptyState(
            kind: .needsAccount,
            title: L10n.text("apple.clientsetupwizard.sign_in_to_set_up_a_machine.d2117f15"),
            message: L10n.text("apple.clientsetupwizard.setup_needs_a_signed_in_account_if_you_jus.771114c7"),
            actionTitle: L10n.text("apple.clientsetupwizard.check_again.fb7099ad"),
            actionIcon: .refresh,
            action: onRetry,
            secondaryActionTitle: L10n.text("apple.clientsetupwizard.not_now.a0e63d7c"),
            secondaryActionIcon: .dismiss,
            secondaryAction: onDismiss
        )
    }

    /// Setup could not start, although the app itself may look signed in.
    /// Sign-in advice would send somebody in circles here, so this retries
    /// instead. Unreachable grey, not the sign-in tile and not the header
    /// scene, so the three states read apart.
    private func SetupRetryCard(onRetry: @escaping () -> Void, onDismiss: @escaping () -> Void) -> some View {
        ClientEmptyState(
            kind: .unreachable,
            title: L10n.text("apple.clientsetupwizard.setup_could_not_start.21614de3"),
            message: L10n.text("apple.clientsetupwizard.nothing_was_started_so_there_is_nothing_to.32225f88"),
            actionTitle: L10n.text("apple.clientsetupwizard.check_again.fb7099ad"),
            actionIcon: .refresh,
            action: onRetry,
            secondaryActionTitle: L10n.text("apple.clientsetupwizard.not_now.a0e63d7c"),
            secondaryActionIcon: .dismiss,
            secondaryAction: onDismiss
        )
    }

    /// Setup left half-finished is the normal case on a phone, not an error.
    ///
    /// Continuing never repeats a remote step: it reopens where the draft
    /// stopped and asks the server what is actually true. Starting over is
    /// offered beside it, and says plainly that it changes nothing on the
    /// server, because that is the fear that makes people leave this screen.
    private func resumeCard(_ draft: ClientSetupDraft) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "arrow.trianglehead.clockwise")
                    .font(Theme.fixed(15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(L10n.text("apple.clientsetupwizard.setup_in_progress.46d0a813"))
                    .font(ClientType.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .textCase(.uppercase)
                    .kerning(0.6)
            }
            Text(draft.machineName)
                .font(Theme.headline)
            Text(draft.milestone.summary)
                .font(ClientType.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Button(L10n.text("apple.clientsetupwizard.continue_setup.c5702c19"), .next) {
                    if let step = model.resume(library: library) { path = [step] }
                }
                .setupPrimaryStyle()
                .accessibilityIdentifier("setup.resume")
                Button(L10n.text("apple.clientsetupwizard.start_over.5eed7e9f"), .restore) {
                    if model.startNewSetup() { path = [.where] }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("setup.startOver")
            }
            .padding(.top, Theme.Space.xs)
            Text(L10n.text("apple.clientsetupwizard.starting_over_forgets_this_progress_on_thi.cf10cf66"))
                .font(ClientType.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: .rect(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1)
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Space.s) {
            ClientEmptyArt(kind: .connect)
                .frame(maxWidth: .infinity)
            Text(L10n.text("apple.clientsetupwizard.how_do_you_want_to_work.f00e4112"))
                .font(Theme.title.weight(.semibold))
            Text(
                L10n.text("apple.clientsetupwizard.tokenstat_runs_agents_on_a_machine_that_st.ba177299")
            )
            .font(ClientType.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.bottom, Theme.Space.xs)
    }

    /// The server and cloud doors need the tunnel, which is patron and up.
    /// Said on the door rather than after twenty minutes of SSH.
    private var paywalled: Bool {
        if let remote = account.account?.canRemote { return !remote }
        return !["patron", "legend"].contains(account.account?.tier?.lowercased())
    }

    private func door(
        title: String,
        body: String,
        requirement: String?,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: symbol)
                    .font(Theme.fixed(25, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 54, height: 54)
                    .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(title).font(Theme.headline)
                    Text(body)
                        .font(ClientType.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    if let requirement {
                        Text(requirement)
                            .font(ClientType.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Theme.fixed(13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

#endif
