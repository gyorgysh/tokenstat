// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Observation
import SwiftUI

@MainActor
@Observable
final class SSHConnectionsModel {
    var hosts: [SSHHost] = []
    var keys: [SSHKeyRecord] = []
    var snippets: [SSHSnippet] = []
    var error: String?

    func load() async {
        do {
            async let hosts = Bridge.sshHosts()
            async let keys = Bridge.sshKeys()
            async let snippets = Bridge.sshSnippets()
            self.hosts = try await hosts
            self.keys = try await keys
            self.snippets = try await snippets
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct SSHConnectionsView: View {
    private enum Section: String, CaseIterable { case hosts = "Hosts", keys = "Keys", snippets = "Snippets" }
    @State private var model = SSHConnectionsModel()
    @State private var section = Section.hosts
    @State private var addingHost = false
    @State private var addingKey = false
    @State private var addingSnippet = false
    @State private var connecting: SSHHost?
    @State private var terminal: SSHLiveTerminal?

    var body: some View {
        VStack(spacing: 0) {
            Picker("SSH library", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            if let error = model.error { Text(error).foregroundStyle(Theme.danger).padding(.horizontal) }
            List {
                switch section {
                case .hosts:
                    ForEach(model.hosts) { host in
                        Button { connecting = host } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(host.label)
                                    Text("\(host.username)@\(host.hostname):\(host.port)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "server.rack") }
                        }.buttonStyle(.plain)
                    }.onDelete { offsets in deleteHosts(offsets) }
                case .keys:
                    ForEach(model.keys) { key in
                        Label {
                            VStack(alignment: .leading) { Text(key.label); Text(key.publicKey).font(.caption).lineLimit(1) }
                        } icon: { Image(systemName: key.hardwareBacked ? "key.radiowaves.forward" : "key.fill") }
                    }.onDelete { offsets in deleteKeys(offsets) }
                case .snippets:
                    ForEach(model.snippets) { snippet in
                        VStack(alignment: .leading) { Text(snippet.title); Text(snippet.command).font(.system(.caption, design: .monospaced)) }
                    }.onDelete { offsets in deleteSnippets(offsets) }
                }
            }
        }
        .navigationTitle("SSH")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ToolbarIconButton(systemImage: "plus", help: "Add \(section.rawValue.lowercased())") {
                    switch section { case .hosts: addingHost = true; case .keys: addingKey = true; case .snippets: addingSnippet = true }
                }
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $addingHost) { SSHHostForm(model: model) }
        .sheet(isPresented: $addingKey) { SSHKeyForm(model: model) }
        .sheet(isPresented: $addingSnippet) { SSHSnippetForm(model: model) }
        .sheet(item: $connecting) { host in SSHConnectForm(host: host, model: model) { terminal = $0 } }
        #if os(macOS)
        .sheet(item: $terminal) { SSHLiveTerminalScreen(session: $0).frame(minWidth: 720, minHeight: 480) }
        #else
        .fullScreenCover(item: $terminal) { SSHLiveTerminalScreen(session: $0) }
        #endif
    }

    private func deleteHosts(_ offsets: IndexSet) { for i in offsets { let id = model.hosts[i].id; Task { try? await Bridge.deleteSSHHost(id: id); await model.load() } } }
    private func deleteKeys(_ offsets: IndexSet) { for i in offsets { let key = model.keys[i]; SSHSecretStore.delete(reference: key.secretRef); Task { try? await Bridge.deleteSSHKey(id: key.id); await model.load() } } }
    private func deleteSnippets(_ offsets: IndexSet) { for i in offsets { let id = model.snippets[i].id; Task { try? await Bridge.deleteSSHSnippet(id: id); await model.load() } } }
}

private struct SSHHostForm: View {
    @Environment(\.dismiss) private var dismiss
    let model: SSHConnectionsModel
    @State private var label = ""
    @State private var hostname = ""
    @State private var username = "root"
    @State private var port = 22
    var body: some View { NavigationStack { Form { TextField("Name", text: $label); TextField("Address", text: $hostname); TextField("Username", text: $username); TextField("Port", value: $port, format: .number) }.navigationTitle("Add SSH host").toolbar { Button("Save", .save) { Task { _ = try? await Bridge.saveSSHHost(SSHHost(id: "", label: label, hostname: hostname, port: port, username: username, credentialID: nil, jumpHostID: nil, tags: [], provider: nil, hostKeys: [])); await model.load(); dismiss() } }.disabled(label.isEmpty || hostname.isEmpty || username.isEmpty) } }.frame(minWidth: 420, minHeight: 260) }
}

private struct SSHKeyForm: View {
    @Environment(\.dismiss) private var dismiss
    let model: SSHConnectionsModel
    @State private var label = "My SSH key"
    @State private var pem = ""
    @State private var error: String?
    var body: some View { NavigationStack { Form { TextField("Name", text: $label); TextEditor(text: $pem).font(.system(.caption, design: .monospaced)); if let error { Text(error).foregroundStyle(Theme.danger) } }.navigationTitle("Add key").toolbar { Button("Generate", .create) { Task { await keep(try await Bridge.generateSSHKey()) } }; Button("Import", .upload) { Task { do { await keep(try await Bridge.inspectSSHKey(pem: pem, passphrase: nil)) } catch { self.error = error.localizedDescription } } }.disabled(pem.isEmpty) } }.frame(minWidth: 480, minHeight: 360) }
    private func keep(_ material: SSHKeyMaterial) async { do { let id = UUID().uuidString; let ref = try SSHSecretStore.store(material.privateKey, id: id); _ = try await Bridge.saveSSHKey(SSHKeyRecord(id: "key_\(id)", label: label, algorithm: material.algorithm, publicKey: material.publicKey, secretRef: ref, hardwareBacked: false)); await model.load(); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct SSHSnippetForm: View {
    @Environment(\.dismiss) private var dismiss
    let model: SSHConnectionsModel
    @State private var title = ""
    @State private var command = ""
    var body: some View { NavigationStack { Form { TextField("Name", text: $title); TextEditor(text: $command).font(.system(.body, design: .monospaced)) }.navigationTitle("Add snippet").toolbar { Button("Save", .save) { Task { _ = try? await Bridge.saveSSHSnippet(SSHSnippet(id: "", title: title, command: command, tags: [], hostIDs: [])); await model.load(); dismiss() } }.disabled(title.isEmpty || command.isEmpty) } }.frame(minWidth: 440, minHeight: 300) }
}

private struct SSHConnectForm: View {
    @Environment(\.dismiss) private var dismiss
    @State var host: SSHHost
    let model: SSHConnectionsModel
    let connected: (SSHLiveTerminal) -> Void
    @State private var password = ""
    @State private var selectedKeyID = ""
    @State private var offeredFingerprint: String?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                if host.hostKeys.isEmpty {
                    Text("Verify the server identity before sending credentials.")
                    Button("Show fingerprint", .security) { Task { await probe() } }
                    if let offeredFingerprint {
                        Text(offeredFingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Trust this fingerprint", .approve) { Task { await trust(offeredFingerprint) } }
                    }
                } else {
                    Picker("Authentication", selection: $selectedKeyID) {
                        Text("Password").tag("")
                        ForEach(model.keys) { Text($0.label).tag($0.id) }
                    }
                    if selectedKeyID.isEmpty { SecureField("Password", text: $password) }
                    Button("Connect", .connect) { Task { await connect() } }
                        .disabled(selectedKeyID.isEmpty && password.isEmpty)
                }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .navigationTitle(host.label)
        }
        .frame(minWidth: 420, minHeight: 280)
    }
    private func probe() async {
        do { offeredFingerprint = try await Bridge.probeSSHHost(host).fingerprint }
        catch { self.error = error.localizedDescription }
    }
    private func trust(_ fingerprint: String) async {
        do {
            host.hostKeys = [fingerprint]
            _ = try await Bridge.saveSSHHost(host)
            offeredFingerprint = nil
            await model.load()
        } catch { self.error = error.localizedDescription }
    }
    private func connect() async {
        do {
            let handle: SSHSessionHandle
            if let key = model.keys.first(where: { $0.id == selectedKeyID }) {
                if key.secretRef.hasPrefix("agent:") {
                    handle = try await Bridge.openSSHWithAgent(host, fingerprint: String(key.secretRef.dropFirst("agent:".count)), rows: 24, cols: 80)
                } else {
                    let pem = try SSHSecretStore.load(reference: key.secretRef)
                    handle = try await Bridge.openSSHWithKey(host, pem: pem, passphrase: nil, rows: 24, cols: 80)
                }
            } else {
                handle = try await Bridge.openSSHWithPassword(host, password: password, rows: 24, cols: 80)
            }
            connected(SSHLiveTerminal(handle: handle, title: host.label))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
