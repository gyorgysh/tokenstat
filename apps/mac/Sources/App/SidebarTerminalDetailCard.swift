// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import SwiftUI

/// Read the observable session inside the popover's own view graph. Passing
/// preformatted fields from the row left an open card holding a snapshot.
struct SidebarTerminalDetailCard: View {
    let session: TerminalSession
    let folder: WorkspaceFolder
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshedGit: GitStatus?
    private struct Owner: Hashable {
        let reference: WorkReference?
        let generation: UInt64
    }
    private var owner: Owner {
        Owner(reference: session.workReference, generation: WorkSessionContext.shared.generation)
    }
    private var title: String {
        session.customName ?? session.harnessID.map(harnessName) ?? (session.command as NSString).lastPathComponent
    }
    private var subtitle: String {
        guard let reported = session.title?.trimmingCharacters(in: .whitespaces), !reported.isEmpty,
              !reported.localizedCaseInsensitiveContains(title), !title.localizedCaseInsensitiveContains(reported) else {
            return L10n.text("apple.rootview.terminal.e0926fda")
        }
        return L10n.text("apple.rootview.terminal_0.f851d42b", reported)
    }

    var body: some View {
        SidebarDetailCard(title: title, subtitle: subtitle,
                          symbol: "terminal", path: session.reportedCwd ?? session.cwd,
                          fields: fields, git: refreshedGit ?? folder.git) {
            if session.meter?.contextUsed == nil {
                Text(L10n.text("apple.chatcontext.context_unknown"))
                    .font(Theme.caption).foregroundStyle(.secondary)
                if let window = session.meter?.contextWindow {
                    Text(L10n.text("apple.chatcontext.window_tokens", window.formatted()))
                        .font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if session.meter?.contextEstimated == true {
                Text(L10n.text("apple.rootview.context_window_estimated_from_related_mode.9d7879e3"))
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
            Text(L10n.text("common.session_identity.title")).font(Theme.callout.weight(.semibold))
            SessionIdentityRows(entries: session.identityEntries,
                                truncated: session.sessionIdentities?.truncated ?? false,
                                reportedTotal: session.sessionIdentities?.total)
        }
        .task(id: owner) {
            let requested = owner
            refreshedGit = nil
            guard let reference = requested.reference else { return }
            while !Task.isCancelled, requested == owner, WorkCacheAccess.canRead(reference) {
                if scenePhase == .active {
                    await session.refreshDetails()
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .task(id: owner) {
            let requested = owner
            guard let reference = requested.reference else { return }
            while !Task.isCancelled, requested == owner, WorkCacheAccess.canRead(reference) {
                if scenePhase == .active, let fresh = try? await SidebarDetailRefresh.folder(folder.id) {
                    guard !Task.isCancelled, requested == owner, WorkCacheAccess.canRead(reference) else { return }
                    refreshedGit = fresh.git
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private var fields: [SidebarDetailField] {
        var fields = [
            SidebarDetailField(title: L10n.text("apple.rootview.project.98595978"), value: folder.name, symbol: "folder"),
            SidebarDetailField(title: L10n.text("apple.rootview.computer.76ed42d2"), value: folder.sidebarComputer, symbol: "laptopcomputer"),
            SidebarDetailField(title: L10n.text("apple.rootview.status.920e413c"), value: session.statusLabel, symbol: "circle.dotted",
                               tint: session.state == .needsAttention ? Theme.warning : session.state == .failed ? Theme.danger : session.state == .working || session.state == .starting ? Theme.stateWorking : Theme.controlGlyph),
            SidebarDetailField(title: L10n.text("apple.rootview.command.71316697"), value: session.command, symbol: "terminal", monospaced: true),
        ]
        if let meter = session.meter {
            fields.append(.init(title: L10n.text("apple.rootview.tokens.a039dfb9"), value: meter.tokens.formatted(), symbol: "number", numeric: true))
            let context: String
            if let used = meter.contextUsed {
                let amount = meter.contextWindow.map { "\(used.formatted()) / \($0.formatted())" } ?? used.formatted()
                context = (meter.contextEstimated ? "~" : "") + amount
            } else {
                context = L10n.text("apple.sidebarhovercard.usage_not_reported")
            }
            fields.append(.init(title: L10n.text("apple.rootview.context.a6e600a1"), value: context, symbol: "gauge.with.dots.needle.50percent", numeric: true))
            if let model = meter.model { fields.append(.init(title: L10n.text("apple.rootview.model.5e2c614c"), value: model, symbol: "sparkles")) }
            if let cost = meter.costMicros {
                fields.append(.init(title: L10n.text("apple.rootview.list_price.5d5835fd"),
                                    value: Money(micros: cost, estimated: meter.estimated, complete: meter.complete).formatted, symbol: "dollarsign.circle"))
            }
        } else {
            fields.append(.init(title: L10n.text("apple.rootview.tokens.a039dfb9"), value: L10n.text("apple.sidebarhovercard.usage_not_reported"), symbol: "number"))
        }
        var resources = [String]()
        if let cpu = session.cpuPercent { resources.append(L10n.text("apple.rootview.cpu_0.bc621b54", "\(Int(cpu.rounded()))")) }
        if let memory = session.memoryMb, memory >= 1 {
            resources.append(memory >= 1000 ? String(format: "%.1f GB", memory / 1024) : "\(Int(memory.rounded())) MB")
        }
        if !resources.isEmpty {
            fields.append(.init(title: L10n.text("apple.rootview.resources.e89b30aa"), value: resources.joined(separator: " · "), symbol: "cpu"))
        }
        return fields
    }
}
#endif
