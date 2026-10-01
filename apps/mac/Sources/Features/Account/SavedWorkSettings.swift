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
            .sheet(isPresented: $showManagement, onDismiss: refreshAfterDismiss) {
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
            title: L10n.text("apple.savedworksettings.saved_work.9204cce7"),
            subtitle: usageLabel,
            mark: "mark_cache",
            accessory: statusAccessory
        ) {
            rows
        }
        #else
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                ClientSectionTitle(title: L10n.text("apple.savedworksettings.saved_work.9204cce7"), mark: "mark_cache")
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
            Text(L10n.text("apple.savedworksettings.opened_conversations_and_viewed_changes_ar.6ef58718"))
                #if os(macOS)
                .font(Theme.caption)
                #else
                .font(ClientType.body)
                #endif
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            storagePolicy
            Button(L10n.text("apple.savedworksettings.manage_saved_work.4802a957"), .archive) { showManagement = true }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(scope == nil)
            Button(L10n.text("apple.savedworksettings.manage_original_draft_files.dd83a362"), .attach) { showOriginals = true }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(WorkSessionContext.shared.readingScope == nil)
            Button(L10n.text("apple.savedworksettings.recover_older_pending_drafts.f85e1cbc"), .history) { showOlderDrafts = true }
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
        Toggle(L10n.text("apple.savedworksettings.save_recent_work_on_this_device.e5e4effd"), isOn: $enabled)
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
                    Button(L10n.text("apple.savedworksettings.0_days.af78beb0", "\(days)"), days == retentionDays ? ActionIcon.done : .history) {
                        retentionDays = days
                        WorkCacheSettings.shared.retentionDays = days
                    }
                }
            } label: { ActionIcon.history.label(L10n.text("apple.savedworksettings.keep_recent_copies_for_0_days.6ae1227d", "\(retentionDays)")) }
            Menu {
                ForEach(WorkCacheSettings.budgetChoices, id: \.self) { mb in
                    Button(L10n.text("apple.savedworksettings.0_mb.a698208f", "\(mb)"), mb == budgetMB ? ActionIcon.done : .archive) {
                        budgetMB = mb
                        WorkCacheSettings.shared.budgetMB = mb
                    }
                }
            } label: { ActionIcon.archive.label(L10n.text("apple.savedworksettings.recent_copies_0_mb.139b8ff8", "\(budgetMB)")) }
            Menu {
                ForEach(WorkCacheSettings.offlineBudgetChoices, id: \.self) { mb in
                    Button(L10n.text("apple.savedworksettings.0_mb.a698208f", "\(mb)"), mb == offlineBudgetMB ? ActionIcon.done : .pin) {
                        offlineBudgetMB = mb
                        WorkCacheSettings.shared.offlineBudgetMB = mb
                    }
                }
            } label: { ActionIcon.pin.label(L10n.text("apple.savedworksettings.offline_storage_limit_0_mb.46a5934c", "\(offlineBudgetMB)")) }
            Text(L10n.text("apple.savedworksettings.limits_apply_when_saving_new_work_copies_k.6bcfd49d"))
                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
        }
        .font(Theme.callout)
    }

    @ViewBuilder
    private var clearButton: some View {
        #if os(macOS)
        Button(L10n.text("apple.savedworksettings.clear_saved_work.d362e82a"), .delete) {
            Task { await clear() }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(clearing || bytes == nil || bytes == 0)
        #else
        Button {
            Task { await clear() }
        } label: {
            ActionIcon.delete.label(clearing ? L10n.text("apple.savedworksettings.clearing.9a81378b") : L10n.text("apple.savedworksettings.clear_saved_work.d362e82a"))
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
        .accessibilityHint(L10n.text("apple.savedworksettings.removes_saved_copies_from_this_device_draf.85fe0c9a"))
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
                    .accessibilityLabel(L10n.text("apple.savedworksettings.saved_work_cleared.b146d276"))
            )
        }
        return nil
    }

    private var usageLabel: String {
        if cleared { return L10n.text("apple.savedworksettings.saved_work_cleared.b146d276") }
        guard let bytes, let records else { return L10n.text("apple.savedworksettings.saved_work_on_this_device.6942a15d") }
        if records == 0 { return L10n.text("apple.savedworksettings.nothing_saved_on_this_device.30328043") }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let kept = pinned.map { $0 > 0 ? L10n.text("apple.savedworksettings.0_kept.74c0ae6a", "\($0)") : "" } ?? ""
        return records == 1
            ? L10n.text("apple.savedworksettings.1_saved_item_0_1_on_this_device.2656032d", "\(size)", "\(kept)")
            : L10n.text("apple.savedworksettings.0_saved_items_1_2_on_this_device.7c9fd44c", "\(records)", "\(size)", "\(kept)")
    }

    /// Re-read totals when the management sheet goes away. A named function
    /// rather than an inline closure: `onDismiss` takes no view, and an inline
    /// `Task` would read as the sheet's content to the surface gate.
    private func refreshAfterDismiss() {
        Task { await refresh() }
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
            if enabled {
                let key = await WorkCacheKey.keyForSaving(for: WorkCache.scope(for: scope)) {
                    refreshGeneration == generation && self.scope == scope && enabled
                        && WorkSessionContext.shared.scope == scope
                }
                guard refreshGeneration == generation, self.scope == scope, !Task.isCancelled else { return }
                message = key == nil
                    ? L10n.text("apple.savedworksettings.secure_storage_is_unavailable_unlock_this.e9f2fab6") : nil
            } else { message = nil }
        } catch {
            guard refreshGeneration == generation, self.scope == scope, !Task.isCancelled else { return }
            if !WorkCacheStore.isUnavailable(error) {
                message = L10n.text("apple.savedworksettings.saved_work_could_not_be_measured_try_again.c5966f63")
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
            if self.scope == scope { message = L10n.text("apple.savedworksettings.some_saved_work_could_not_be_removed_try_a.fc8393cf") }
        }
    }
}
