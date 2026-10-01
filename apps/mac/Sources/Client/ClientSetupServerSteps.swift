// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// Door two: a server, over the SSH session this phone opens itself.
///
/// One screen per step. Each of them can fail on its own, each failure has its
/// own sentence, and the one place where a mistake is permanent (trusting a
/// host key) is a screen rather than a row inside another one.
struct ClientSetupServerStep: View {
    let step: SetupStep
    @Bindable var model: ClientSetupModel
    @Bindable var library: SSHLibraryModel
    @Binding var path: [SetupStep]
    var onFinish: () -> Void

    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch step {
            case .where: WhereStep(model: model, library: library, path: $path)
            case .credential: CredentialStep(model: model, library: library, path: $path)
            case .fingerprint: FingerprintStep(model: model, library: library, path: $path)
            case .check: CheckStep(model: model, library: library, path: $path)
            case .install: InstallStep(model: model, library: library, path: $path)
            case .finish: FinishStep(model: model, library: library, path: $path)
            case .project: ClientSetupProjectStep(model: model, onFinish: onFinish)
            case .byHand: ClientSetupByHand(model: model, path: $path)
            case .cloud: ClientSetupCloudDoor(model: model, library: library, path: $path)
            case .mac: ClientSetupMacDoor()
            case .needServer: ClientSetupServerGuide(path: $path)
            }
        }
        .background(Theme.background)
        .environment(account)
    }
}

// MARK: - Shared shape

/// Every step looks the same: what this is, the thing to do, and one button.
///
/// A container rather than six copies, so the wizard reads as one flow and a
/// change to the rhythm happens once.
struct StepScaffold<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    var number: Int
    var total = 7
    /// The step's own picture. Nil on the two steps that draw their own: the
    /// install shows a terminal, and the last one shows the machine.
    var art: SetupArtKind?
    var error: String?
    /// The typed form, when the screen has somewhere for its action to go.
    /// `error` stays for the places that only print a sentence.
    var failure: ClientSetupFailure?
    var onDismissError: (() -> Void)?
    var onRecover: ((ClientSetupFailure.Action) -> Void)?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    /// The last thing announced, so a redraw does not say it again.
    ///
    /// SwiftUI rebuilds a step's body whenever anything on it moves, and an
    /// announcement posted from that path is read out on every keystroke.
    @State private var announced: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let art {
                        ClientSetupArt(kind: art)
                            .frame(maxWidth: .infinity)
                            .padding(.top, Theme.Space.xs)
                    }
                    VStack(spacing: Theme.Space.s) {
                        SetupRail(number: number, total: total)
                        Text(title).font(Theme.title.weight(.semibold))
                        Text(subtitle)
                            .font(ClientType.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    if let failure {
                        SetupFailureBanner(
                            failure: failure,
                            onDismiss: { onDismissError?() },
                            onRecover: onRecover
                        )
                    } else if let error {
                        InlineBanner(text: error, kind: .danger) { onDismissError?() }
                    }
                    content()
                    SetupActions { footer() }
                }
                .padding(Theme.Space.m)
                .setupColumn()
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)

        }
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("setup.step.\(number)")
        // A failure is the one state change worth interrupting for: somebody
        // is waiting on a step that has stopped, and the next action is in the
        // banner they cannot see.
        .onChange(of: failure?.explanation) { _, now in
            guard let now, now != announced else { return }
            announced = now
            AccessibilityNotification.Announcement(now).post()
        }
    }
}

/// Actions stay in the scroll layout, above the home indicator and keyboard.
struct SetupActions<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: Theme.Space.m) { content() }
            .buttonStyle(SetupSecondaryButtonStyle())
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.m)
    }
}

private struct SetupSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ClientType.label)
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
    }
}

/// Where a recovery action goes.
///
/// One table for the whole wizard rather than a closure per screen: the answer
/// to "the fingerprint changed" is the fingerprint screen wherever somebody was
/// standing when it happened, and six copies of that would drift.
///
/// Actions that are not a place stay where they are. Retrying is the screen's
/// own button, and updating a machine is something that happens on the machine,
/// so both leave the failure on screen with its explanation.
@MainActor
func recover(
    _ action: ClientSetupFailure.Action,
    model: ClientSetupModel,
    path: Binding<[SetupStep]>
) {
    guard let destination = action.destination else { return }
    // A changed key is re-established from scratch: it has to be looked at,
    // not carried forward from a record that no longer fits the server.
    if action == .reviewFingerprint { model.resetServer() }
    model.failure = nil
    // Already here. Rebuilding the stack onto the screen somebody is standing
    // on would animate a journey to where they already are.
    guard path.wrappedValue.last != destination else { return }
    // Every destination is reached through the address, so the stack is built
    // rather than pushed onto: arriving at the credential screen with no way
    // back to the address would be a dead end of its own.
    switch destination {
    case .where: path.wrappedValue = [.where]
    case .credential: path.wrappedValue = [.where, .credential]
    case .install: path.wrappedValue = [.where, .credential, .check, .install]
    case .finish: path.wrappedValue = [.where, .credential, .check, .install, .finish]
    default: path.wrappedValue = [destination]
    }
}

/// What failed, what it changed, and the one thing to do next.
///
/// The three parts are the contract. "What changed" is the half people ask for
/// first and the half an error message never has: knowing that a failed
/// connection touched nothing is what makes it safe to try again.
///
/// The technical detail is there and closed. It is selectable, because the
/// person who wants it wants to paste it somewhere.
struct SetupFailureBanner: View {
    let failure: ClientSetupFailure
    var onDismiss: (() -> Void)?
    var onRecover: ((ClientSetupFailure.Action) -> Void)?

    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(failure.explanation)
                        .font(Theme.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let changed = failure.changed {
                        Text(changed)
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if let onDismiss {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark").font(Theme.font(10))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("apple.clientsetupserversteps.dismiss.48845bff"))
                }
            }
            HStack(spacing: Theme.Space.s) {
                // Only an action that leads somewhere gets a button. Signing
                // in to the account and updating the machine both happen
                // outside this wizard, and the explanation says so; retrying
                // is the screen's own primary button, already on screen.
                if let onRecover, failure.action.isActionable {
                    Button(failure.action.title, failure.action.icon) {
                        onRecover(failure.action)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("setup.recover")
                }
                if failure.details != nil {
                    Button(showingDetails ? L10n.text("apple.clientsetupserversteps.hide_details.c9722a7a") : L10n.text("apple.clientsetupserversteps.details.45989de4"), .more) {
                        showingDetails.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(ClientType.caption)
                }
                Spacer(minLength: 0)
            }
            if showingDetails, let details = failure.details {
                Text(details)
                    .font(Theme.monoText(11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.failure")
    }
}

/// One readable column, wherever the window happens to be.
///
/// An iPad in landscape gives this sheet a thousand points of width, and a
/// paragraph that wide is measured in head movements rather than in words. The
/// column stops growing and centres instead. On a phone the limit is never
/// reached, so nothing there changes.
extension View {
    func setupColumn() -> some View {
        frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Where somebody is, in four words rather than eight numbers.
///
/// "Step 3 of 7" says how much is left and nothing about what any of it is
/// for. The five connection screens are one thing happening, so they are one
/// milestone, and the two that follow are the two real decisions: the
/// machine, the project.
///
/// It is deliberately not a progress bar. Nothing here knows how long an
/// install takes, and a bar that fills at a made-up rate is a claim.
struct SetupRail: View {
    let number: Int
    let total: Int

    private static let milestones: [(name: String, last: Int)] = [
        (L10n.text("common.connect"), 5), (L10n.text("apple.clientsetupserversteps.machine.8f1cc42d"), 6), (L10n.text("apple.clientsetupserversteps.project.98595978"), 7),
    ]

    private var index: Int {
        Self.milestones.firstIndex { number <= $0.last } ?? Self.milestones.count - 1
    }

    var body: some View {
        // Four words fit on a phone at the usual text size and stop fitting
        // some way up the Dynamic Type scale. Rather than truncate the names,
        // which would leave somebody reading "Conn…", the rail falls back to
        // the milestone they are on and how far along it is.
        ViewThatFits(in: .horizontal) {
            full.fixedSize(horizontal: true, vertical: false)
            short
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.text("apple.clientsetupserversteps.step_0_of_1_2.69f669d8", "\(number)", "\(total)", "\(Self.milestones[index].name)")
        )
        .accessibilityIdentifier("setup.rail.\(Self.milestones[index].name.lowercased())")
    }

    private var full: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(Array(Self.milestones.enumerated()), id: \.offset) { position, milestone in
                if position > 0 {
                    Rectangle()
                        .fill(position <= index ? Theme.accent : Theme.border)
                        .frame(width: 14, height: 1)
                        .accessibilityHidden(true)
                }
                chip(milestone.name, at: position)
            }
        }
        .lineLimit(1)
    }

    private var short: some View {
        HStack(spacing: Theme.Space.xs) {
            chip(Self.milestones[index].name, at: index)
            Text(L10n.text("apple.clientsetupserversteps.0_of_1.9fea8201", "\(number)", "\(total)"))
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chip(_ name: String, at position: Int) -> some View {
        Text(name)
            .font(ClientType.caption.weight(position == index ? .semibold : .regular))
            .foregroundStyle(tint(for: position))
            .padding(.horizontal, position == index ? Theme.Space.s : 0)
            .padding(.vertical, position == index ? 3 : 0)
            .background {
                if position == index {
                    Capsule().fill(Theme.accent.opacity(0.12))
                }
            }
    }

    private func tint(for position: Int) -> Color {
        if position == index { return Theme.accent }
        return Color.secondary
    }
}

/// A titled block of rows, the shape the rest of the client uses for a form.
struct StepSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(ClientType.label.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: Theme.Space.s) { content() }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
        }
    }
}

// MARK: - 1. Where

private struct WhereStep: View {
    @Bindable var model: ClientSetupModel
    @Bindable var library: SSHLibraryModel
    @Binding var path: [SetupStep]

    private func serverField(_ field: WritableKeyPath<SSHHost, String>) -> Binding<String> {
        Binding(get: { model.host[keyPath: field] }, set: { model.editServer(field, value: $0) })
    }

    private var ready: Bool {
        model.pickedHostID != nil
            || (!model.host.hostname.trimmingCharacters(in: .whitespaces).isEmpty
                && !model.host.username.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        StepScaffold(
            title: L10n.text("apple.clientsetupserversteps.which_server.f723b68c"),
            subtitle: L10n.text("apple.clientsetupserversteps.choose_a_saved_server_or_enter_its_address.a9fb6642"),
            number: 1,
            art: .find,
            failure: model.failure,
            onDismissError: { model.failure = nil },
            onRecover: { recover($0, model: model, path: $path) }
        ) {
            if !library.hosts.isEmpty {
                StepSection(title: L10n.text("apple.clientsetupserversteps.saved_servers.4bf08480")) {
                    ForEach(library.hosts) { host in
                        Button {
                            model.password = ""
                            model.credential = .none
                            model.pickedHostID = model.pickedHostID == host.id ? nil : host.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.label).font(ClientType.body)
                                    Text(host.address)
                                        .font(ClientType.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.pickedHostID == host.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.pickedHostID == host.id ? .isSelected : [])
                        if host.id != library.hosts.last?.id { ThemeRule() }
                    }
                }
            }
            StepSection(title: library.hosts.isEmpty
                ? L10n.text("apple.clientsetupserversteps.the_server.442b5366")
                : (model.pickedHostID == nil ? L10n.text("apple.clientsetupserversteps.or_type_one.3c8afc53") : L10n.text("apple.clientsetupserversteps.type_another.0993d6bc"))) {
                LabeledField(title: L10n.text("apple.clientsetupserversteps.address.56ef8f20"), text: serverField(\.hostname), placeholder: "203.0.113.10")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                LabeledField(title: L10n.text("apple.clientsetupserversteps.user.b512d97e"), text: serverField(\.username), placeholder: L10n.text("apple.clientsetupserversteps.root.4813494d"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                LabeledField(title: L10n.text("apple.clientsetupserversteps.name.dcd1d522"), text: serverField(\.label), placeholder: L10n.text("apple.clientsetupserversteps.cloud_one.ab0123af"))
            }
        } footer: {
            Button(L10n.text("apple.clientsetupserversteps.continue.31fbef16"), .next) {
                if model.pickedHostID == nil {
                    if model.host.label.trimmingCharacters(in: .whitespaces).isEmpty {
                        model.host.label = model.host.hostname
                    }
                }
                path.append(.credential)
            }
            .setupPrimaryStyle()
            .disabled(!ready)
            Button(L10n.text("apple.clientsetupserversteps.set_up_with_a_terminal.c6e8442d"), .docs) {
                path.append(.byHand)
            }
            .font(ClientType.label)
        }
        .navigationTitle(L10n.text("apple.clientsetupserversteps.connect_a_server.a438d2cf"))
        .onAppear { model.resetServer() }
        .onChange(of: model.pickedHostID) { _, picked in
            guard let picked, let host = library.hosts.first(where: { $0.id == picked }) else {
                return
            }
            // Carry the saved record's own credential over, so somebody who has
            // connected to this server before does not choose a key twice.
            if let credential = host.credentialID { model.credential = .key(credential) }
            if model.machineName == "server" { model.machineName = host.label }
        }
    }
}

// MARK: - 2. How to sign in

private struct CredentialStep: View {
    @Bindable var model: ClientSetupModel
    @Bindable var library: SSHLibraryModel
    @Binding var path: [SetupStep]

    private var ready: Bool {
        switch model.credential {
        case .none: false
        case .password: !model.password.isEmpty
        case .key: true
        }
    }

    var body: some View {
        StepScaffold(
            title: L10n.text("apple.clientsetupserversteps.how_to_sign_in.6730dada"),
            subtitle: L10n.text("apple.clientsetupserversteps.a_key_from_your_vault_or_a_password_used_o.75f6b9b8"),
            number: 2,
            art: .unlock,
            failure: model.failure,
            onDismissError: { model.failure = nil },
            onRecover: { recover($0, model: model, path: $path) }
        ) {
            if library.keys.isEmpty {
                Text(
                    L10n.text("apple.clientsetupserversteps.there_are_no_keys_in_your_vault_yet_add_on.ca0f75f6")
                )
                .font(ClientType.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                StepSection(title: L10n.text("apple.clientsetupserversteps.keys_in_your_vault.32d8b1ef")) {
                    ForEach(library.keys) { key in
                        Button {
                            model.credential = .key(key.id)
                            model.password = ""
                        } label: {
                            HStack {
                                Text(key.label).font(ClientType.body)
                                Spacer()
                                if model.credential == .key(key.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.credential == .key(key.id) ? .isSelected : [])
                        if key.id != library.keys.last?.id { ThemeRule() }
                    }
                }
            }
            StepSection(title: library.keys.isEmpty
                ? L10n.text("apple.clientsetupserversteps.a_password_this_time_only.0283f848")
                : L10n.text("apple.clientsetupserversteps.or_a_password_this_time_only.44e1c7da")) {
                SecureField(L10n.text("apple.clientsetupserversteps.password.e7cf3ef4"), text: $model.password)
                    .textFieldStyle(.themed)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: model.password) { _, value in
                        if !value.isEmpty { model.credential = .password }
                    }
                Text(
                    L10n.text("apple.clientsetupserversteps.used_for_this_connection_and_dropped_when.43398559")
                )
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Button(L10n.text("apple.clientsetupserversteps.continue.31fbef16"), .next) {
                path.append(model.resumingInstallation ? .finish : .fingerprint)
            }
                .setupPrimaryStyle()
                .disabled(!ready)
        }
        .navigationTitle(L10n.text("common.sign_in"))
    }
}

// MARK: - 3. The host key

private struct FingerprintStep: View {
    @Bindable var model: ClientSetupModel
    @Bindable var library: SSHLibraryModel
    @Binding var path: [SetupStep]

    var body: some View {
        StepScaffold(
            title: L10n.text("apple.clientsetupserversteps.is_this_your_server.1d76f188"),
            subtitle: L10n.text("apple.clientsetupserversteps.compare_this_fingerprint_with_your_server.f06f2526"),
            number: 3,
            art: .identify,
            failure: model.failure,
            onDismissError: { model.failure = nil },
            onRecover: { recover($0, model: model, path: $path) }
        ) {
            StepSection(title: L10n.text("apple.clientsetupserversteps.fingerprint.ba7af0b7")) {
                if let fingerprint = model.fingerprint {
                    Text(fingerprint)
                        .font(Theme.monoText(13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(
                        LocalizedStringKey(L10n.text("apple.clientsetupserversteps.compare_it_with_what_the_server_itself_rep.0f5fff76"))
                    )
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else if model.working {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("apple.clientsetupserversteps.asking_the_server.fb689559")).font(ClientType.label)
                    }
                    Text(
                        L10n.text("apple.clientsetupserversteps.an_address_that_is_wrong_takes_about_a_min.c355da67")
                    )
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L10n.text("apple.clientsetupserversteps.nothing_asked_yet.3f88b8bf")).font(ClientType.label).foregroundStyle(.secondary)
                }
            }
        } footer: {
            if model.fingerprint == nil {
                if model.working {
                    Button(L10n.text("common.stop"), .stop) { model.cancelWork() }
                        .setupPrimaryStyle()
                } else {
                    Button(L10n.text("apple.clientsetupserversteps.ask_the_server.5d186479"), .connect) {
                        Task { await model.probe(library: library) }
                    }
                    .setupPrimaryStyle()
                }
            } else {
                Button(L10n.text("apple.clientsetupserversteps.this_is_my_server.22acffe8"), .approve) {
                    Task {
                        await model.trust(library: library)
                        if model.trusted { path.append(.check) }
                    }
                }
                .setupPrimaryStyle()
                .disabled(model.working)
                Button(L10n.text("apple.clientsetupserversteps.ask_again.0d9ad5ef"), .refresh) {
                    model.fingerprint = nil
                    Task { await model.probe(library: library) }
                }
                .font(ClientType.label)
            }
        }
        .navigationTitle(L10n.text("apple.clientsetupserversteps.fingerprint.ba7af0b7"))
        .task {
            guard model.fingerprint == nil, !model.working else { return }
            await model.probe(library: library)
        }
    }
}

// MARK: - 4. What is on the machine

private struct CheckStep: View {
    @Bindable var model: ClientSetupModel
    @Bindable var library: SSHLibraryModel
    @Binding var path: [SetupStep]

    var body: some View {
        StepScaffold(
            title: L10n.text("apple.clientsetupserversteps.what_is_on_it.047811ac"),
            subtitle: L10n.text("apple.clientsetupserversteps.read_before_anything_is_written_nothing_on.f53dc6d5"),
            number: 4,
            art: .inspect,
            failure: model.failure,
            onDismissError: { model.failure = nil },
            onRecover: { recover($0, model: model, path: $path) }
        ) {
            if let check = model.check {
                StepSection(title: L10n.text("apple.clientsetupserversteps.the_machine.0cccf589")) {
                    fact(L10n.text("apple.clientsetupserversteps.operating_system.0fcabfe6"), check.distro ?? check.os ?? "unknown")
                    fact(L10n.text("apple.clientsetupserversteps.architecture.cd74053c"), check.arch ?? "unknown")
                    fact(L10n.text("apple.clientsetupserversteps.signs_in_as.f6adc71c"), check.user ?? "unknown")
                    fact(L10n.text("apple.clientsetupserversteps.service_manager.ddd070d4"), (check.systemd ?? false) ? "systemd" : L10n.text("apple.clientsetupserversteps.not_systemd.050cd421"))
                    fact(L10n.text("apple.clientsetupserversteps.free_space.64cd989e"), check.diskFreeMb.map { "\($0 / 1024) GB" } ?? "unknown")
                    if check.installed == true {
                        fact(L10n.text("apple.clientsetupserversteps.already_installed.9616d808"), L10n.text("apple.clientsetupserversteps.tokenstat_is_on_this_machine.3fc55e14"))
                    }
                }
                if check.root == true {
                    // A fact next to the operating system version, not a
                    // warning triangle. It is the trade being made, and it is
                    // the right one for a machine that exists to do this work.
                    StepSection(title: L10n.text("apple.clientsetupserversteps.who_agents_run_as.fc7c9918")) {
                        Text(L10n.text("apple.clientsetupserversteps.agents_on_this_machine_will_run_as_root.d624b53a"))
                            .font(ClientType.body)
                        Text(
                            L10n.text("apple.clientsetupserversteps.that_is_the_same_authority_as_the_ssh_sess.27a3539a")
                        )
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !check.blockers.isEmpty {
                    StepSection(title: L10n.text("apple.clientsetupserversteps.in_the_way.ec946c03")) {
                        ForEach(check.blockers, id: \.self) { blocker in
                            Text(blocker)
                                .font(ClientType.label)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                StepSection(title: L10n.text("apple.clientsetupserversteps.what_to_call_it.55325bff")) {
                    LabeledField(title: L10n.text("apple.clientsetupserversteps.name.dcd1d522"), text: $model.machineName, placeholder: L10n.text("apple.clientsetupserversteps.cloud_one.ab0123af"))
                    Text(L10n.text("apple.clientsetupserversteps.this_is_the_name_on_your_account_and_what.4a9ec588"))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
            } else if model.working {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("apple.clientsetupserversteps.looking_at_the_machine.2b29e9e2")).font(ClientType.label)
                }
            }
        } footer: {
            if model.working {
                Button(L10n.text("common.stop"), .stop) { model.cancelWork() }
                    .setupPrimaryStyle()
            } else if model.check?.ready == true {
                Button(L10n.text("apple.clientsetupserversteps.install.569ca49f"), .download) { path.append(.install) }
                    .setupPrimaryStyle()
                    .disabled(model.working || model.machineName.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button(L10n.text("apple.clientsetupserversteps.check_again.fb7099ad"), .refresh) {
                    Task { await model.inspect(library: library) }
                }
                .setupPrimaryStyle()
                .disabled(model.working)
            }
            Button(L10n.text("apple.clientsetupserversteps.show_me_the_command_instead.1da2f134"), .docs) { path.append(.byHand) }
                .font(ClientType.label)
        }
        .navigationTitle(L10n.text("apple.clientsetupserversteps.check.9d60841e"))
        .task {
            guard model.check == nil, !model.working else { return }
            await model.inspect(library: library)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(ClientType.label).foregroundStyle(.secondary)
            Spacer(minLength: Theme.Space.m)
            Text(value)
                .font(ClientType.label)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 5. Install

private struct InstallStep: View {
    @Bindable var model: ClientSetupModel
    @Bindable var library: SSHLibraryModel
    @Binding var path: [SetupStep]

    var body: some View {
        VStack(spacing: 0) {
            if let terminal = model.terminal {
                // A real terminal, not a spinner. People trust an installer
                // they can watch, and every support conversation about a
                // failed install starts with this text.
                HStack {
                    Text(L10n.text("apple.clientsetupserversteps.installing_on_0.db18c0f3", "\(model.machineName)"))
                        .font(ClientType.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if terminal.alive {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                ThemeRule()
                SSHNativeTerminal(session: terminal)
                ThemeRule()
                VStack(spacing: Theme.Space.s) {
                    Button(L10n.text("apple.clientsetupserversteps.it_finished_check_the_machine.0c1b9b30"), .next) { path.append(.finish) }
                        .setupPrimaryStyle()
                    Button(L10n.text("apple.clientsetupserversteps.it_failed_show_me_the_command.df0a4f0d"), .docs) { path.append(.byHand) }
                        .font(ClientType.label)
                }
                .padding(Theme.Space.m)
            } else {
                StepScaffold(
                    title: L10n.text("apple.clientsetupserversteps.install.569ca49f"),
                    subtitle: L10n.text("apple.clientsetupserversteps.tokenstat_mints_a_one_time_pairing_code_wr.f10f332e"),
                    number: 5,
                    art: .install,
                    failure: model.failure,
                    onDismissError: { model.failure = nil },
                    onRecover: { recover($0, model: model, path: $path) }
                ) {
                    StepSection(title: L10n.text("apple.clientsetupserversteps.what_will_happen.d5b89826")) {
                        bullet(L10n.text("apple.clientsetupserversteps.the_cli_and_the_always_on_host_are_install.5c5da81f"))
                        bullet(L10n.text("apple.clientsetupserversteps.the_machine_signs_in_to_your_account_with.72be3ba6"))
                        bullet(L10n.text("apple.clientsetupserversteps.this_device_is_allowed_to_open_the_work_he.47d6f496"))
                        bullet(L10n.text("apple.clientsetupserversteps.it_stays_on_and_keeps_counting_which_costs.713e3511"))
                    }
                    StepSection(title: L10n.text("apple.clientsetupserversteps.agents.279b44d2")) {
                        agentChoice("claude_code", name: L10n.text("apple.clientsetupserversteps.claude_code.246ef8c1"),
                            detail: L10n.text("apple.clientsetupserversteps.anthropic_s_coding_agent_for_your_projects.2be1987f"))
                        ThemeRule()
                        agentChoice("codex", name: L10n.text("apple.clientsetupserversteps.codex.616efbe9"),
                            detail: L10n.text("apple.clientsetupserversteps.openai_s_coding_agent_for_your_projects.68a482b3"))
                        Text(L10n.text("apple.clientsetupserversteps.choose_either_both_or_neither_you_can_inst.36b5f4ed"))
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                        Text(L10n.text("apple.clientsetupserversteps.next_setup_helps_you_sign_in_to_your_agent.34acb358"))
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } footer: {
                    Button(L10n.text("apple.clientsetupserversteps.start_the_install.40fb0ff5"), .download) {
                        Task { await model.install(library: library) }
                    }
                    .setupPrimaryStyle()
                    .disabled(model.working)
                    Button(L10n.text("apple.clientsetupserversteps.i_would_rather_run_it_myself.73496e0e"), .docs) { path.append(.byHand) }
                        .font(ClientType.label)
                }
            }
        }
        .navigationTitle(L10n.text("apple.clientsetupserversteps.install.569ca49f"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func agentChoice(_ id: String, name: String, detail: String) -> some View {
        Toggle(isOn: Binding(
            get: { model.agents.contains(id) },
            set: { selected in
                model.agents.removeAll { $0 == id }
                if selected { model.agents.append(id) }
            }
        )) {
            HStack(spacing: Theme.Space.s) {
                HarnessMark(id: id, size: 40).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(ClientType.body)
                    Text(detail)
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Circle().fill(Theme.accent).frame(width: 5, height: 5).padding(.top, 6)
            Text(text)
                .font(ClientType.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 6. Finish

private struct FinishStep: View {
    @Bindable var model: ClientSetupModel
    @Bindable var library: SSHLibraryModel
    @Binding var path: [SetupStep]

    @Environment(AccountModel.self) private var account

    var body: some View {
        StepScaffold(
            title: model.finished == nil ? L10n.text("apple.clientsetupserversteps.waiting_for_the_machine.9a2264c1") : L10n.text("apple.clientsetupserversteps.it_is_up.3f950bb2"),
            subtitle: model.finished == nil
                ? L10n.text("apple.clientsetupserversteps.the_server_signs_in_joins_the_tunnel_and_a.2831dd5b")
                : L10n.text("apple.clientsetupserversteps.0_is_on_your_account_and_this_device_can_r.944d14db", "\(model.machineName)"),
            number: 6,
            failure: model.failure,
            onDismissError: { model.failure = nil },
            onRecover: { recover($0, model: model, path: $path) }
        ) {
            if model.manualInstall, model.finished == nil {
                StepSection(title: L10n.text("apple.clientsetupserversteps.confirm_the_installed_machine.835e82aa")) {
                    Text(L10n.text("apple.clientsetupserversteps.paste_the_full_machine_key_printed_at_the.11894974"))
                        .font(ClientType.label)
                        .foregroundStyle(.secondary)
                    TextField(L10n.text("apple.clientsetupserversteps.64_character_machine_key.90b955a9"), text: $model.manualMachineKey)
                        .font(Theme.monoText(13))
                        .textFieldStyle(.themed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.working || model.expectedPeer != nil)
                }
            }
            ClientEmptyArt(kind: model.finished == nil ? .provisioning : .serverReady)
                .frame(maxWidth: .infinity)
            if let status = model.finished {
                StepSection(title: L10n.text("apple.clientsetupserversteps.this_machine.1b8548de")) {
                    fact(L10n.text("apple.clientsetupserversteps.signed_in.ca566c89"), status.account.handle ?? "yes")
                    fact(L10n.text("apple.clientsetupserversteps.always_on.044ba8a9"), (status.alwaysOn ?? false) ? "on" : "off")
                    fact(L10n.text("apple.clientsetupserversteps.reachable.f94b5f3d"), (status.tunnel.online ?? false) ? "yes" : "connecting")
                    fact(L10n.text("apple.clientsetupserversteps.runs_as.dc98511e"), status.runsAs?.name ?? "unknown")
                    fact(L10n.text("apple.clientsetupserversteps.allowed_devices.748d1f2f"), "\(status.allowedDevices)")
                }
                StepSection(title: L10n.text("apple.clientsetupserversteps.what_is_next.8cfb34ce")) {
                    Text(
                        status.agents.contains(where: \.installed)
                        ? L10n.text("apple.clientsetupserversteps.the_agent_is_on_the_machine_it_still_needs.10e35681")
                        : L10n.text("apple.clientsetupserversteps.no_agent_is_on_the_machine_yet_the_next_st.51e14f92")
                        + L10n.text("apple.clientsetupserversteps.signs_it_in.f4f1faf5")
                    )
                    .font(ClientType.label)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            if model.finished == nil {
                Button(L10n.text("apple.clientsetupserversteps.check_again.fb7099ad"), .refresh) {
                    Task { await model.waitForMachine(library: library, account: account) }
                }
                .setupPrimaryStyle()
                .disabled(model.working || !model.canCheckMachine)
            } else {
                Button(L10n.text("apple.clientsetupserversteps.continue.31fbef16"), .next) { path.append(.project) }
                    .setupPrimaryStyle()
            }
        }
        .navigationTitle(L10n.text("apple.clientsetupserversteps.finish.a6c7a84b"))
        .task {
            guard model.finished == nil, !model.working, model.canCheckMachine else { return }
            await model.waitForMachine(library: library, account: account)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(ClientType.label).foregroundStyle(.secondary)
            Spacer(minLength: Theme.Space.m)
            Text(value).font(ClientType.label)
        }
    }
}

/// A field with its own label above it, which is what the rest of the client
/// uses instead of a placeholder that disappears the moment somebody types.
private struct LabeledField: View {
    let title: String
    @Binding var text: String
    var placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.themed)
        }
    }
}

#endif
