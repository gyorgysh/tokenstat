// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Encrypted copies of opened chats, shared by both Apple settings surfaces.
///
/// What stays on this device and what never leaves it: opened conversations
/// are sealed with a key the system keychain holds and can be read back in
/// airplane mode. Nothing here is sent anywhere; opening a chat fetches it
/// live, and the copy is only the fallback. Clearing removes the copies and
/// leaves drafts and downloads alone.
struct SavedWorkSettings: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var enabled = WorkCacheSettings.shared.enabled
    @State private var bytes: UInt64?
    @State private var records: UInt64?
    @State private var pinned: UInt64?
    @State private var clearing = false
    @State private var cleared = false
    @State private var message: String?
    @State private var showManagement = false
    @State private var showOlderDrafts = false
    @State private var showOriginals = false
    @State private var retentionDays = WorkCacheSettings.shared.retentionDays
    @State private var budgetMB = WorkCacheSettings.shared.budgetMB
    @State private var offlineBudgetMB = WorkCacheSettings.shared.offlineBudgetMB
    @State private var refreshGeneration = UUID()

    var body: some View {
        card
            .disabled(clearing)
            .sheet(isPresented: $showOriginals) {
                if let scope = WorkSessionContext.shared.readingScope { WorkOriginalFilesSheet(scope: scope).id(scope) }
            }
            .sheet(isPresented: $showOlderDrafts) { WorkLegacyDraftsSheet() }
            .task(id: scope) {
                bytes = nil; records = nil; pinned = nil; cleared = false; message = nil
                await refresh()
            }
            .sheet(isPresented: $showManagement, onDismiss: { Task { await refresh() } }) {
                if let scope { WorkCacheManagementSheet(scope: scope) }
            }
            .onChange(of: enabled) { _, _ in
                WorkCacheSettings.shared.enabled = enabled
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
    }

    private var scope: WorkReference.Scope? {
        WorkSessionContext.shared.scope
    }

    @ViewBuilder
    private var card: some View {
        #if os(macOS)
        Card(
            title: "Saved work",
            subtitle: usageLabel,
            mark: "mark_cache",
            accessory: statusAccessory
        ) {
            rows
        }
        #else
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                ClientSectionTitle(title: "Saved work", mark: "mark_cache")
                Spacer(minLength: 0)
                if let statusAccessory { statusAccessory }
            }
            Text(usageLabel)
                .font(ClientType.body)
                .foregroundStyle(.secondary)
            rows
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        #endif
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            keepRow
            ThemeRule()
            Text("Opened conversations and viewed changes are encrypted on this device. Saved changes are read-only snapshots. Copies never leave the device; clearing them leaves source work and unsent drafts alone. Downloaded copies remain readable offline until removed or until access changes are learned on reconnection.")
                #if os(macOS)
                .font(Theme.caption)
                #else
                .font(ClientType.body)
                #endif
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            storagePolicy
            Button("Manage saved work", .archive) { showManagement = true }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(scope == nil)
            Button("Manage original draft files", .attach) { showOriginals = true }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(WorkSessionContext.shared.readingScope == nil)
            Button("Recover older pending drafts", .history) { showOlderDrafts = true }
                .buttonStyle(SecondaryButtonStyle())
            clearButton
            if let message {
                Text(message)
                    #if os(macOS)
                    .font(Theme.caption)
                    #else
                    .font(ClientType.caption)
                    #endif
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var keepRow: some View {
        Toggle("Save recent work on this device", isOn: $enabled)
            .toggleStyle(.brandCheckbox)
            #if os(macOS)
            .font(Theme.callout)
            #else
            .font(ClientType.label)
            .frame(minHeight: 44)
            .contentShape(.rect)
            #endif
            .tint(Theme.accent)
    }

    private var storagePolicy: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Menu {
                ForEach(WorkCacheSettings.retentionChoices, id: \.self) { days in
                    Button("\(days) days", days == retentionDays ? ActionIcon.done : .history) {
                        retentionDays = days
                        WorkCacheSettings.shared.retentionDays = days
                    }
                }
            } label: { ActionIcon.history.label("Keep recent copies for \(retentionDays) days") }
            Menu {
                ForEach(WorkCacheSettings.budgetChoices, id: \.self) { mb in
                    Button("\(mb) MB", mb == budgetMB ? ActionIcon.done : .archive) {
                        budgetMB = mb
                        WorkCacheSettings.shared.budgetMB = mb
                    }
                }
            } label: { ActionIcon.archive.label("Recent copies · \(budgetMB) MB") }
            Menu {
                ForEach(WorkCacheSettings.offlineBudgetChoices, id: \.self) { mb in
                    Button("\(mb) MB", mb == offlineBudgetMB ? ActionIcon.done : .pin) {
                        offlineBudgetMB = mb
                        WorkCacheSettings.shared.offlineBudgetMB = mb
                    }
                }
            } label: { ActionIcon.pin.label("Offline storage limit · \(offlineBudgetMB) MB") }
            Text("Limits apply when saving new work. Copies kept offline do not expire automatically. Lowering a limit never deletes them; remove copies in Manage saved work to make room.")
                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
        }
        .font(Theme.callout)
    }

    @ViewBuilder
    private var clearButton: some View {
        #if os(macOS)
        Button("Clear saved work", .delete) {
            Task { await clear() }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(clearing || bytes == nil || bytes == 0)
        #else
        Button {
            Task { await clear() }
        } label: {
            ActionIcon.delete.label(clearing ? "Clearing…" : "Clear saved work")
                .labelStyle(ActionLabelStyle())
                .font(ClientType.label.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(clearing || bytes == nil || bytes == 0)
        .accessibilityHint("Removes saved copies from this device. Drafts stay, and nothing is deleted on any computer.")
        #endif
    }

    private var statusAccessory: AnyView? {
        if clearing {
            return AnyView(ProgressView().controlSize(.small))
        }
        if cleared {
            return AnyView(
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Saved work cleared")
            )
        }
        return nil
    }

    private var usageLabel: String {
        if cleared { return "Saved work cleared" }
        guard let bytes, let records else { return "Saved work on this device" }
        if records == 0 { return "Nothing saved on this device" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let kept = pinned.map { $0 > 0 ? ", \($0) kept" : "" } ?? ""
        return records == 1
            ? "1 saved item (\(size)\(kept)) on this device"
            : "\(records) saved items (\(size)\(kept)) on this device"
    }

    private func refresh(afterFailedClear: Bool = false) async {
        guard !clearing || afterFailedClear else { return }
        let generation = UUID()
        refreshGeneration = generation
        guard let scope else { bytes = nil; records = nil; pinned = nil; return }
        do {
            let stats = try await Bridge.cacheStats(scope: WorkCache.scope(for: scope))
            guard refreshGeneration == generation, self.scope == scope, !Task.isCancelled else { return }
            bytes = stats.bytes
            records = stats.records
            pinned = stats.pinned
            cleared = false
            message = enabled && WorkCacheKey.key(for: WorkCache.scope(for: scope)) == nil
                ? "Secure storage is unavailable. Unlock this device and try again. Work cannot be saved until its encryption key is available." : nil
        } catch {
            guard refreshGeneration == generation, self.scope == scope, !Task.isCancelled else { return }
            if !WorkCacheStore.isUnavailable(error) {
                message = "Saved work could not be measured. Try again."
            }
            bytes = nil
            records = nil
            pinned = nil
        }
    }

    private func clear() async {
        guard let scope, !clearing else { return }
        refreshGeneration = UUID()
        clearing = true
        cleared = false
        message = nil
        defer {
            clearing = false
            if self.scope != scope { Task { await refresh() } }
        }
        do {
            _ = try await Bridge.cacheClearScope(scope: WorkCache.scope(for: scope))
            guard self.scope == scope, !Task.isCancelled else { return }
            bytes = 0
            records = 0
            cleared = true
        } catch {
            await refresh(afterFailedClear: true)
            if self.scope == scope { message = "Some saved work could not be removed. Try again." }
        }
    }
}
