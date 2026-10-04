// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation
import SwiftUI

struct PullCreateContext: Codable, Sendable, Equatable {
    let branch: String?
    let head: String
    let published: Bool
    let repository: String
    let defaultBase: String
    let files: [FileChange]
    let problem: String?
}

struct PullCreateDraft: Codable, Sendable, Equatable {
    var title = ""
    var body = ""
    var base = ""
    var isDraft = true
    var paths: Set<String>? = nil
}

struct CreatedPull: Codable, Sendable {
    let number: UInt32
    let url: String
    let existing: Bool
}

@MainActor @Observable
final class PullCreateModel {
    var draft = PullCreateDraft()
    private(set) var context: PullCreateContext?
    private(set) var result: CreatedPull?
    private(set) var working = false
    var error: String?
    private var storage: WorkbenchDraftFile<PullCreateDraft>?
    private var revision: String?
    private var loaded = false
    private var owner: WorkReference.Scope?
    private var persisting: Task<Void, Never>?

    var canCreate: Bool {
        !working && loaded && owner == WorkSessionContext.shared.scope && result == nil && context?.published == true && !(context?.head.isEmpty ?? true)
            && context?.branch != draft.base.trimmingCharacters(in: .whitespacesAndNewlines) && !draft.base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load(workspaceID: String, peer: String?, target: GitCommitTarget) async {
        if !loaded {
            let scope = WorkSessionContext.shared.scope
            if target.peer == nil { await WorkSessionContext.shared.resolveLocalHostIdentity() }
            guard scope == WorkSessionContext.shared.scope else { return }
            owner = scope
            if let scope,
               let host = target.peer ?? WorkSessionContext.shared.localHostIdentity {
                let key = WorkReferenceKey.folder(scope: scope, hostIdentity: host, workspaceID: target.workspaceID) + "pull-create"
                let store = WorkbenchDraftFile<PullCreateDraft>(key: key)
                do {
                    let record = try await store.load()
                    storage = store
                    revision = record?.revision
                    if let record { draft = record.value }
                } catch { self.error = error.localizedDescription }
            }
            loaded = true
        }
        await check(workspaceID: workspaceID, peer: peer)
    }

    func check(workspaceID: String, peer: String?) async {
        guard !working, loaded, owner == WorkSessionContext.shared.scope else { return }
        working = true
        defer { working = false }
        do {
            let answer = try await Bridge.preparePullCreation(workspaceID: workspaceID, peer: peer)
            guard owner == WorkSessionContext.shared.scope else { return }
            context = answer
            if draft.base.isEmpty { draft.base = context?.defaultBase ?? "" }
            error = nil
        } catch { context = nil; self.error = error.localizedDescription }
    }

    func create(workspaceID: String, peer: String?) async {
        guard canCreate, let context else { return }
        working = true
        defer { working = false }
        do {
            let answer = try await Bridge.createPull(workspaceID: workspaceID, peer: peer, context: context, draft: draft)
            guard owner == WorkSessionContext.shared.scope else { return }
            result = answer
            error = nil
            if !answer.existing {
                draft = PullCreateDraft()
                await persist()
            }
        } catch { self.error = error.localizedDescription }
    }

    func persist() async {
        if let persisting { await persisting.value; return }
        guard loaded, let storage else { return }
        let snapshot = draft
        let expected = revision
        let work = Task { @MainActor in
            do { revision = try await storage.save(snapshot, expectedRevision: expected).revision }
            catch { self.error = error.localizedDescription }
        }
        persisting = work
        await work.value
        persisting = nil
        if draft != snapshot { await persist() }
    }
}

/// Each irreversible step uses the existing reviewed operation. Closing the
/// wizard leaves branch, commits, published work and writing available.
struct PullCreateView: View {
    let workspaceID: String
    let peer: String?
    let folderName: String
    let hostName: String
    let onCreated: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var model = PullCreateModel()
    @State private var branchName = ""
    @State private var commitSession: GitCommitSession?
    @State private var creatingBranch = false

    private var target: GitCommitTarget {
        let route = Bridge.chatRoute(workspaceID: workspaceID, peer: peer)
        return GitCommitTarget(peer: route.peer, workspaceID: route.workspaceID)
    }

    var body: some View {
        RemoteHostFeatureGate(feature: .pullCreation, peer: target.peer, hostName: hostName) {
            ThemedSheet(title: L10n.text("apple.pullcreate.new"), subtitle: [folderName, hostName].filter { !$0.isEmpty }.joined(separator: " · "),
                        icon: .merge, scrolls: true, onClose: { dismiss() }) {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if let result = model.result {
                        Label(result.existing ? L10n.text("apple.pullcreate.existing", String(result.number))
                              : L10n.text("apple.pullcreate.created", String(result.number)), systemImage: "checkmark.circle")
                            .font(Theme.title3).foregroundStyle(Theme.success)
                        if let url = URL(string: result.url) { Link(L10n.text("apple.pullcreate.open"), destination: url) }
                        if result.existing {
                            Text(L10n.text("apple.pullcreate.existing_help")).font(Theme.callout).foregroundStyle(.secondary)
                            Text(model.draft.title).font(Theme.callout.weight(.semibold)).textSelection(.enabled)
                            Text(model.draft.body).font(Theme.callout).textSelection(.enabled)
                        }
                    } else {
                        branchStep
                        commitStep
                        publishStep
                        describeStep
                    }
                    if let error = model.error { Text(error).font(Theme.callout).foregroundStyle(Theme.warning).textSelection(.enabled) }
                    if model.working || creatingBranch { ProgressView().controlSize(.small) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } actions: {
                Button(L10n.text("common.close"), .dismiss) { dismiss() }.buttonStyle(SecondaryButtonStyle(comfortable: true))
                if model.result != nil {
                    Button(L10n.text("common.done"), .done) { dismiss() }.buttonStyle(AccentButtonStyle(comfortable: true))
                } else {
                    Button(model.draft.isDraft ? L10n.text("apple.pullcreate.create_draft") : L10n.text("apple.pullcreate.create"), .create) {
                        Task { await model.create(workspaceID: workspaceID, peer: peer); if model.result != nil { await onCreated() } }
                    }.buttonStyle(AccentButtonStyle(comfortable: true)).disabled(!model.canCreate || creatingBranch)
                }
            }
            .disabled(creatingBranch)
            .task { await model.load(workspaceID: workspaceID, peer: peer, target: target) }
        }
        .modalFrame(width: 760, height: 740)
        .interactiveDismissDisabled(model.working || creatingBranch)
        .sheet(item: $commitSession, onDismiss: commitDismissed) { session in
            GitCommitComposer(session: session, folderName: folderName, hostName: hostName) { await check() }
        }
        .onChange(of: model.draft) { _, _ in Task { await model.persist() } }
        .onChange(of: model.context?.files.map(\.path)) { _, paths in
            guard let paths else { return }
            if let selected = model.draft.paths { model.draft.paths = selected.intersection(paths) }
            else { model.draft.paths = Set(paths) }
        }
    }

    private var branchStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            step("1", L10n.text("apple.pullcreate.branch"))
            Text(L10n.text("apple.pullcreate.branch_help", model.context?.branch ?? "—"))
                .font(Theme.callout).foregroundStyle(.secondary)
            HStack {
                TextField(L10n.text("apple.pullcreate.branch_name"), text: $branchName).textFieldStyle(.themed)
                Button(L10n.text("apple.pullcreate.make_branch"), .create) { Task { await createBranch() } }
                    .buttonStyle(SecondaryButtonStyle(small: true)).disabled(branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.working)
            }
            if model.context?.branch == model.draft.base {
                Text(L10n.text("apple.pullcreate.same_branch")).font(Theme.caption).foregroundStyle(Theme.warning)
            }
        }
    }

    private var commitStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            step("2", L10n.text("apple.pullcreate.commit"))
            if let files = model.context?.files, !files.isEmpty {
                Text(L10n.text("apple.pullcreate.files_help", String(files.count))).font(Theme.callout).foregroundStyle(.secondary)
                DisclosureGroup(L10n.text("apple.pullcreate.choose_files")) {
                    ForEach(files, id: \.path) { file in
                        Toggle(file.path, isOn: Binding(
                            get: { model.draft.paths?.contains(file.path) == true },
                            set: { selected in
                                var paths = model.draft.paths ?? []
                                if selected { paths.insert(file.path) } else { paths.remove(file.path) }
                                model.draft.paths = paths
                            }
                        )).toggleStyle(.brandCheckbox).font(Theme.caption)
                    }
                }
                Button(L10n.text("apple.pullcreate.review_commit"), .commit) {
                    Task {
                        let session = GitCommitSessions.session(target: target)
                        await session.load()
                        if session.draft.submitted == nil { session.setSelection(model.draft.paths ?? []) }
                        commitSession = session
                    }
                }.buttonStyle(SecondaryButtonStyle(small: true)).disabled(model.working || model.context?.branch == model.draft.base || model.draft.paths?.isEmpty != false)
            } else {
                if model.context != nil { Text(L10n.text("apple.pullcreate.clean")).font(Theme.callout).foregroundStyle(.secondary) }
            }
        }
    }

    private var publishStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            step("3", L10n.text("apple.pullcreate.publish"))
            Text(model.context?.published == true ? L10n.text("apple.pullcreate.published") : L10n.text("apple.pullcreate.publish_help"))
                .font(Theme.callout).foregroundStyle(.secondary)
            HStack {
                GitPushControl(target: target, folderName: folderName, hostName: hostName, outgoing: 0) { await check() }
                    .disabled(model.working || model.context?.branch == model.draft.base)
                Button(L10n.text("apple.pullcreate.check"), .refresh) { Task { await check() } }
                    .buttonStyle(SecondaryButtonStyle(small: true)).disabled(model.working)
            }
            if let problem = model.context?.problem { Text(problem).font(Theme.caption).foregroundStyle(Theme.warning) }
        }
    }

    private var describeStep: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            step("4", L10n.text("apple.pullcreate.describe"))
            TextField(L10n.text("apple.pullcreate.base"), text: $model.draft.base).textFieldStyle(.themed)
            TextField(L10n.text("apple.pullcreate.title"), text: $model.draft.title).textFieldStyle(.themed)
            Text(L10n.text("apple.pullcreate.description")).font(Theme.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.draft.body).font(Theme.callout).frame(minHeight: 120)
                .padding(6).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            Toggle(L10n.text("apple.pullcreate.draft"), isOn: $model.draft.isDraft).toggleStyle(.brandCheckbox)
            Text(L10n.text("apple.pullcreate.final_help")).font(Theme.caption).foregroundStyle(.secondary)
        }.disabled(model.working)
    }

    private func step(_ number: String, _ title: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(number).font(Theme.caption.weight(.bold)).frame(width: 24, height: 24)
                .background(Theme.accentSoft, in: Circle()).foregroundStyle(Theme.accent)
            Text(title).font(Theme.callout.weight(.semibold))
        }
    }

    private func check() async { await model.check(workspaceID: workspaceID, peer: peer) }
    private func commitDismissed() { Task { await check() } }

    private func createBranch() async {
        creatingBranch = true
        defer { creatingBranch = false }
        do {
            let outcome = try await target.call("workspace.createBranch", ["branch": branchName.trimmingCharacters(in: .whitespacesAndNewlines)], as: GitOutcome.self)
            guard outcome.ok else { model.error = outcome.message; return }
            branchName = ""
            target.notifyChanged()
            await check()
        } catch { model.error = error.localizedDescription }
    }
}
