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
            case .byHand: ClientSetupByHand(model: model, path: $path)
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
private struct StepScaffold<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    var number: Int
    var error: String?
    var onDismissError: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Step \(number) of 6")
                            .font(ClientType.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        Text(title).font(Theme.title.weight(.semibold))
                        Text(subtitle)
                            .font(ClientType.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error {
                        InlineBanner(text: error, kind: .danger) { onDismissError?() }
                    }
                    content()
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: Theme.Space.s) { footer() }
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, Theme.Space.m)
                .padding(.top, Theme.Space.s)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A titled block of rows, the shape the rest of the client uses for a form.
private struct StepSection<Content: View>: View {
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

    private var ready: Bool {
        model.pickedHostID != nil
            || (!model.host.hostname.trimmingCharacters(in: .whitespaces).isEmpty
                && !model.host.username.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        StepScaffold(
            title: "Which server",
            subtitle: "A machine you can already reach over SSH. tokenstat connects as you, "
                + "with your own key, and nothing about it goes through our servers.",
            number: 1,
            error: model.error,
            onDismissError: { model.error = nil }
        ) {
            if !library.hosts.isEmpty {
                StepSection(title: "Saved servers") {
                    ForEach(library.hosts) { host in
                        Button {
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
                        }
                        .buttonStyle(.plain)
                        if host.id != library.hosts.last?.id { ThemeRule() }
                    }
                }
            }
            StepSection(title: library.hosts.isEmpty
                ? "The server"
                : (model.pickedHostID == nil ? "Or type one" : "Type another")) {
                LabeledField(title: "Address", text: $model.host.hostname, placeholder: "203.0.113.10")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                LabeledField(title: "User", text: $model.host.username, placeholder: "root")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                LabeledField(title: "Name", text: $model.host.label, placeholder: "cloud one")
            }
        } footer: {
            Button("Continue", .next) {
                if model.pickedHostID == nil {
                    if model.host.label.trimmingCharacters(in: .whitespaces).isEmpty {
                        model.host.label = model.host.hostname
                    }
                }
                path.append(.credential)
            }
            .clientProminentStyle()
            .disabled(!ready)
            Button("I would rather run the command myself", .docs) {
                path.append(.byHand)
            }
            .font(ClientType.label)
        }
        .navigationTitle("Where")
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
            title: "How to sign in",
            subtitle: "A key from your vault, or a password used once for this connection "
                + "and never written down.",
            number: 2,
            error: model.error,
            onDismissError: { model.error = nil }
        ) {
            if library.keys.isEmpty {
                Text(
                    "There are no keys in your vault yet. Add one under Machines, SSH, or "
                    + "use a password this time."
                )
                .font(ClientType.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                StepSection(title: "Keys in your vault") {
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
                        }
                        .buttonStyle(.plain)
                        if key.id != library.keys.last?.id { ThemeRule() }
                    }
                }
            }
            StepSection(title: library.keys.isEmpty
                ? "A password, this time only"
                : "Or a password, this time only") {
                SecureField("Password", text: $model.password)
                    .textFieldStyle(.themed)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: model.password) { _, value in
                        if !value.isEmpty { model.credential = .password }
                    }
                Text(
                    "Used for this connection and dropped when the wizard closes. It is "
                    + "never saved to the vault or to this phone."
                )
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Button("Continue", .next) { path.append(.fingerprint) }
                .clientProminentStyle()
                .disabled(!ready)
        }
        .navigationTitle("Sign in")
    }
}

// MARK: - 3. The host key

private struct FingerprintStep: View {
    @Bindable var model: ClientSetupModel
    @Bindable var library: SSHLibraryModel
    @Binding var path: [SetupStep]

    var body: some View {
        StepScaffold(
            title: "Is this your server?",
            subtitle: "Every server has a fingerprint. Trusting the wrong one is the one "
                + "mistake here that cannot be taken back, so it gets its own screen.",
            number: 3,
            error: model.error,
            onDismissError: { model.error = nil }
        ) {
            StepSection(title: "Fingerprint") {
                if let fingerprint = model.fingerprint {
                    Text(fingerprint)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Compare it with what the server itself reports. On the machine, "
                        + "`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` prints it."
                    )
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else if model.working {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Asking the server…").font(ClientType.label)
                    }
                    Text(
                        "An address that is wrong takes about a minute to give up, because "
                        + "nothing answers to say so."
                    )
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Nothing asked yet.").font(ClientType.label).foregroundStyle(.secondary)
                }
            }
        } footer: {
            if model.fingerprint == nil {
                if model.working {
                    Button("Stop", .stop) { model.cancelWork() }
                        .clientProminentStyle()
                } else {
                    Button("Ask the server", .connect) {
                        Task { await model.probe(library: library) }
                    }
                    .clientProminentStyle()
                }
            } else {
                Button("This is my server", .approve) {
                    Task {
                        await model.trust(library: library)
                        if model.trusted { path.append(.check) }
                    }
                }
                .clientProminentStyle()
                .disabled(model.working)
                Button("Ask again", .refresh) {
                    model.fingerprint = nil
                    Task { await model.probe(library: library) }
                }
                .font(ClientType.label)
            }
        }
        .navigationTitle("Fingerprint")
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
            title: "What is on it",
            subtitle: "Read before anything is written. Nothing on the server changes on "
                + "this screen.",
            number: 4,
            error: model.error,
            onDismissError: { model.error = nil }
        ) {
            if let check = model.check {
                StepSection(title: "The machine") {
                    fact("Operating system", check.distro ?? check.os ?? "unknown")
                    fact("Architecture", check.arch ?? "unknown")
                    fact("Signs in as", check.user ?? "unknown")
                    fact("Service manager", (check.systemd ?? false) ? "systemd" : "not systemd")
                    fact("Free space", check.diskFreeMb.map { "\($0 / 1024) GB" } ?? "unknown")
                    if check.installed == true {
                        fact("Already installed", "tokenstat is on this machine")
                    }
                }
                if check.root == true {
                    // A fact next to the operating system version, not a
                    // warning triangle. It is the trade being made, and it is
                    // the right one for a machine that exists to do this work.
                    StepSection(title: "Who agents run as") {
                        Text("Agents on this machine will run as root.")
                            .font(ClientType.body)
                        Text(
                            "That is the same authority as the SSH session you just opened, "
                            + "so it grants nothing you did not already have. It does mean an "
                            + "agent here is never blocked by a permission."
                        )
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !check.blockers.isEmpty {
                    StepSection(title: "In the way") {
                        ForEach(check.blockers, id: \.self) { blocker in
                            Text(blocker)
                                .font(ClientType.label)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                StepSection(title: "What to call it") {
                    LabeledField(title: "Name", text: $model.machineName, placeholder: "cloud one")
                    Text("This is the name on your account, and what you tap to reach it.")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
            } else if model.working {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Looking at the machine…").font(ClientType.label)
                }
            }
        } footer: {
            if model.working {
                Button("Stop", .stop) { model.cancelWork() }
                    .clientProminentStyle()
            } else if model.check?.ready == true {
                Button("Install", .download) { path.append(.install) }
                    .clientProminentStyle()
                    .disabled(model.working || model.machineName.trimmingCharacters(in: .whitespaces).isEmpty)
            } else if model.check != nil {
                Button("Check again", .refresh) {
                    Task { await model.inspect(library: library) }
                }
                .clientProminentStyle()
                .disabled(model.working)
            }
            Button("Show me the command instead", .docs) { path.append(.byHand) }
                .font(ClientType.label)
        }
        .navigationTitle("Check")
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
                    Text("Installing on \(model.machineName)")
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
                    Button("It finished, check the machine", .next) { path.append(.finish) }
                        .clientProminentStyle()
                    Button("It failed, show me the command", .docs) { path.append(.byHand) }
                        .font(ClientType.label)
                }
                .padding(Theme.Space.m)
            } else {
                StepScaffold(
                    title: "Install",
                    subtitle: "tokenstat mints a one-time pairing code, writes it to a private "
                        + "file on the server, and runs the installer. You watch the whole thing.",
                    number: 5,
                    error: model.error,
                    onDismissError: { model.error = nil }
                ) {
                    StepSection(title: "What will happen") {
                        bullet("The CLI and the always-on host are installed.")
                        bullet("The machine signs in to your account with a code that "
                            + "expires in fifteen minutes and works once.")
                        bullet("This phone is allowed to open the work here, granted over "
                            + "this SSH session rather than through our servers.")
                        bullet("It stays on and keeps counting, which costs whatever the "
                            + "server costs.")
                    }
                    StepSection(title: "Agents") {
                        Toggle("Install Claude Code", isOn: Binding(
                            get: { model.agents.contains("claude_code") },
                            set: { on in
                                model.agents = on ? ["claude_code"] : []
                            }
                        ))
                        .tint(Theme.accent)
                        Text(
                            "A fresh machine has no agent signed in. You can do that in a "
                            + "terminal once it is up."
                        )
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } footer: {
                    Button("Start the install", .download) {
                        Task { await model.install(library: library) }
                    }
                    .clientProminentStyle()
                    .disabled(model.working)
                    Button("I would rather run it myself", .docs) { path.append(.byHand) }
                        .font(ClientType.label)
                }
            }
        }
        .navigationTitle("Install")
        .navigationBarTitleDisplayMode(.inline)
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
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StepScaffold(
            title: model.finished == nil ? "Waiting for the machine" : "It is up",
            subtitle: model.finished == nil
                ? "The server signs in, joins the tunnel and answers. This takes a few seconds."
                : "\(model.machineName) is on your account and this phone can reach it.",
            number: 6,
            error: model.error,
            onDismissError: { model.error = nil }
        ) {
            ClientEmptyArt(kind: model.finished == nil ? .provisioning : .serverReady)
                .frame(maxWidth: .infinity)
            if let status = model.finished {
                StepSection(title: "This machine") {
                    fact("Signed in", status.account.handle ?? "yes")
                    fact("Always on", (status.alwaysOn ?? false) ? "on" : "off")
                    fact("Reachable", (status.tunnel.online ?? false) ? "yes" : "connecting")
                    fact("Runs as", status.runsAs?.name ?? "unknown")
                    fact("This phone", status.allowedDevices > 0 ? "allowed" : "not allowed yet")
                }
                StepSection(title: "What is next") {
                    Text(
                        status.agents.contains(where: \.installed)
                        ? "An agent is installed. It still needs its own sign-in, which is a "
                        + "terminal on this machine, and then a folder to work in."
                        : "No agent is installed yet. Open this machine and install one from "
                        + "the launcher, then give it a folder."
                    )
                    .font(ClientType.label)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            if model.finished == nil {
                Button("Check again", .refresh) {
                    Task { await model.waitForMachine(library: library, account: account) }
                }
                .clientProminentStyle()
                .disabled(model.working)
            } else {
                Button("Open this machine", .next) {
                    navigation.destination = .workspaces
                    dismiss()
                }
                .clientProminentStyle()
            }
        }
        .navigationTitle("Finish")
        .task {
            guard model.finished == nil, !model.working else { return }
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
