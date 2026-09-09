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

    var body: some View {
        card
            .disabled(clearing)
            .task { await refresh() }
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
            Text("Opened chats are sealed on this device and reopened when the machine cannot be reached. Copies never leave the device; clearing them deletes nothing on any computer and leaves drafts alone.")
                #if os(macOS)
                .font(Theme.caption)
                #else
                .font(ClientType.body)
                #endif
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        Toggle("Keep copies of opened chats", isOn: $enabled)
            #if os(macOS)
            .font(Theme.callout)
            #else
            .font(ClientType.label)
            .frame(minHeight: 44)
            .contentShape(.rect)
            #endif
            .tint(Theme.accent)
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
        .accessibilityHint("Removes saved chat copies from this device. Drafts stay, and nothing is deleted on any computer.")
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
        guard let bytes, let records else { return "Saved conversations on this device" }
        if records == 0 { return "Nothing saved on this device" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let kept = pinned.map { $0 > 0 ? ", \($0) kept" : "" } ?? ""
        return records == 1
            ? "1 saved conversation (\(size)\(kept)) on this device"
            : "\(records) saved conversations (\(size)\(kept)) on this device"
    }

    private func refresh() async {
        guard let scope else { bytes = nil; records = nil; pinned = nil; return }
        do {
            let stats = try await Bridge.cacheStats(scope: WorkCache.scope(for: scope))
            bytes = stats.bytes
            records = stats.records
            pinned = stats.pinned
            cleared = false
            message = nil
        } catch {
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
        clearing = true
        cleared = false
        message = nil
        defer { clearing = false }
        do {
            _ = try await Bridge.cacheClearScope(scope: WorkCache.scope(for: scope))
            bytes = 0
            records = 0
            cleared = true
        } catch {
            message = "Some saved work could not be removed. Try again."
            await refresh()
        }
    }
}
