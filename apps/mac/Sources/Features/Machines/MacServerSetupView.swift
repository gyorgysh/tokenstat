// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

#if os(macOS)
/// The desktop entry to the same SSH provisioning model used by iOS.
/// The model owns fingerprints, secrets, checkpoints and the install session;
/// this view only advances after the host has confirmed each step.
struct MacServerSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountModel.self) private var account
    @State private var setup = ClientSetupModel()
    @State private var library = SSHLibraryModel(ownerScope: WorkSessionContext.shared.scope)
    @State private var step: Step = .address

    private enum Step: Int {
        case address, fingerprint, check, install, verify

        var title: String {
            switch self {
            case .address: "Server and sign in"
            case .fingerprint: "Verify identity"
            case .check: "Check server"
            case .install: "Install tokenstat"
            case .verify: "Verify connection"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: "server.rack")
                    .font(Theme.title)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up a Linux host").font(Theme.title.weight(.semibold))
                    Text("\(step.rawValue + 1) of 5 · \(step.title)")
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Close setup")
            }
            .padding(Theme.Space.l)
            ThemeRule()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if let failure = setup.failure {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text(failure.explanation).font(Theme.callout.weight(.semibold))
                            if let changed = failure.changed { Text(changed).font(Theme.caption) }
                            if let details = failure.details { Text(details).font(Theme.caption).textSelection(.enabled) }
                        }
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    stepContent
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ThemeRule()
            HStack(spacing: Theme.Space.m) {
                if step != .address {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .address }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(setup.working)
                }
                Spacer()
                if setup.working {
                    ProgressView().controlSize(.small)
                    Button("Stop") { setup.cancelWork() }
                        .buttonStyle(SecondaryButtonStyle())
                } else {
                    primaryAction
                }
            }
            .padding(Theme.Space.l)
        }
        .frame(width: 680, height: 640)
        .background(Theme.background)
        .task {
            await account.load()
            _ = await setup.prepare(library: library)
            if let resume = setup.resume(library: library) {
                step = resume == .finish ? .verify : .address
            }
        }
        .onDisappear {
            setup.retire()
            library.deactivate()
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .address: addressStep
        case .fingerprint: fingerprintStep
        case .check: checkStep
        case .install: installStep
        case .verify: verifyStep
        }
    }

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Connect over SSH to a Linux server you control. Nothing is installed until you approve its identity and review the server check.")
                .foregroundStyle(.secondary)
            if !library.hosts.isEmpty {
                Picker("Saved SSH host", selection: Binding(
                    get: { setup.pickedHostID ?? "" },
                    set: { id in
                        setup.resetServer()
                        setup.pickedHostID = id.isEmpty ? nil : id
                        if let host = library.hosts.first(where: { $0.id == id }) {
                            setup.host = host
                            if let key = host.credentialID { setup.credential = .key(key) }
                        }
                    }
                )) {
                    Text("New server").tag("")
                    ForEach(library.hosts) { host in Text(host.label).tag(host.id) }
                }
            }
            TextField("Server address", text: field(\.hostname))
                .textContentType(.URL)
            HStack {
                TextField("SSH user", text: field(\.username))
                TextField("Name", text: field(\.label))
            }
            HStack {
                Text("SSH port")
                TextField("22", value: Binding(
                    get: { setup.host.port }, set: { setup.host.port = $0 }
                ), format: .number)
                .frame(width: 90)
            }
            Picker("Sign in with", selection: credentialChoice) {
                Text("Choose a credential").tag("")
                Text("Password for this setup").tag("password")
                ForEach(library.keys) { key in Text(key.label).tag(key.id) }
            }
            if setup.credential == .password {
                SecureField("SSH password", text: Binding(
                    get: { setup.password }, set: { setup.password = $0 }
                ))
                Text("The password is used for this connection and is not saved.")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var fingerprintStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Compare this fingerprint with the one your server or provider shows before trusting it.")
                .foregroundStyle(.secondary)
            if let fingerprint = setup.fingerprint {
                Text(fingerprint)
                    .font(Theme.monoText(14))
                    .textSelection(.enabled)
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.border))
            }
            Text("No credential is sent until you confirm this key.")
                .font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    private var checkStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("The server check reads its operating system, architecture and available disk space before installation.")
                .foregroundStyle(.secondary)
            if let check = setup.check {
                LabeledContent("System", value: check.distro ?? check.os ?? "Unknown")
                LabeledContent("Architecture", value: check.arch ?? "Unknown")
                LabeledContent("Service manager", value: check.systemd == true ? "systemd" : "Unavailable")
                LabeledContent("Free disk", value: check.diskFreeMb.map { "\($0 / 1024) GB" } ?? "Unknown")
                if check.root == true {
                    Text("Agents on this server will run with root access.")
                        .foregroundStyle(Theme.warning)
                }
                ForEach(check.blockers, id: \.self) { Text($0).foregroundStyle(Theme.danger) }
                TextField("Name on your account", text: Binding(
                    get: { setup.machineName }, set: { setup.machineName = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var installStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Install the CLI and background host. The server signs in with a one-time code and grants this Mac access to its work.")
                .foregroundStyle(.secondary)
            if let terminal = setup.terminal {
                SSHNativeTerminal(session: terminal)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text("When the installer finishes, verify that the host answers over the encrypted connection.")
                    .font(Theme.caption).foregroundStyle(.secondary)
            } else {
                agentChoice("claude_code", title: "Claude Code")
                agentChoice("codex", title: "Codex")
                Text("You can install or sign in to agents later.")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var verifyStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Confirm the new host is on your account and answers with the same machine identity through the tunnel.")
                .foregroundStyle(.secondary)
            if let finished = setup.finished {
                Label("Host ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                Text(finished.machineKey)
                    .font(Theme.monoText(12)).textSelection(.enabled)
            } else {
                Text("The installer can still be finishing. Checking again will not reinstall it.")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch step {
        case .address:
            Button("Probe SSH identity") {
                Task {
                    await setup.probe(library: library)
                    if setup.fingerprint != nil { step = .fingerprint }
                }
            }
            .disabled(!setup.prepared || setup.host.hostname.trimmingCharacters(in: .whitespaces).isEmpty)
        case .fingerprint:
            Button("Trust this server") {
                Task {
                    await setup.trust(library: library)
                    if setup.trusted {
                        step = .check
                        await setup.inspect(library: library)
                    }
                }
            }
            .disabled(setup.fingerprint == nil)
        case .check:
            if setup.check?.ready == true {
                Button("Continue to install") { step = .install }
                    .disabled(setup.machineName.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button("Check again") { Task { await setup.inspect(library: library) } }
            }
        case .install:
            if setup.terminal != nil {
                Button("Verify host") { step = .verify }
            } else {
                Button("Start installation") { Task { await setup.install(library: library) } }
            }
        case .verify:
            if setup.finished != nil {
                Button("Done") {
                    if setup.completeSetup() { dismiss() }
                }
            } else {
                Button("Check connection") {
                    Task { await setup.waitForMachine(library: library, account: account) }
                }
            }
        }
    }

    private func field(_ key: WritableKeyPath<SSHHost, String>) -> Binding<String> {
        Binding(get: { setup.host[keyPath: key] },
                set: { setup.editServer(key, value: $0) })
    }

    private var credentialChoice: Binding<String> {
        Binding(get: {
            switch setup.credential {
            case .none: ""
            case .password: "password"
            case let .key(id): id
            }
        }, set: { value in
            if value == "password" { setup.credential = .password }
            else if value.isEmpty { setup.credential = .none }
            else { setup.credential = .key(value) }
        })
    }

    private func agentChoice(_ id: String, title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { setup.agents.contains(id) },
            set: { on in
                setup.agents.removeAll { $0 == id }
                if on { setup.agents.append(id) }
            }
        ))
    }
}
#endif
