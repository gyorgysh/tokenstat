// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Device-local downloads, shared by both Apple settings surfaces.
///
/// Named for the product, not for the one kind of file that uses it today.
/// Chat files are the current contents. Other downloads join the same budget
/// as they land, so this card does not get renamed each time.
struct ChatCacheSettings: View {
    @AppStorage(ChatCachePreferences.sizeKey) private var maxGB = 5
    @AppStorage(ChatCachePreferences.daysKey) private var days = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var bytes = 0
    @State private var clearing = false
    @State private var cleared = false
    @State private var message: String?

    var body: some View {
        card
            .disabled(clearing)
            .task { await refresh() }
            .onChange(of: maxGB) { _, _ in Task { await refresh() } }
            .onChange(of: days) { _, _ in Task { await refresh() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
    }

    @ViewBuilder
    private var card: some View {
        #if os(macOS)
        Card(
            title: L10n.text("apple.chatcachesettings.tokenstat_cache.697429b6"),
            subtitle: usageLabel,
            mark: "mark_cache",
            accessory: statusAccessory
        ) {
            rows
        }
        #else
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                ClientSectionTitle(title: L10n.text("apple.chatcachesettings.tokenstat_cache.697429b6"), mark: "mark_cache")
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
            containsRow
            ThemeRule()
            pickerRow(
                L10n.text("apple.chatcachesettings.maximum_size.5a9f1ffe"),
                selection: $maxGB,
                values: ChatCachePreferences.sizes
            ) { "\($0) GB" }
            ThemeRule()
            pickerRow(
                L10n.text("apple.chatcachesettings.remove_unused_files_after.e5209ea0"),
                selection: $days,
                values: ChatCachePreferences.days
            ) { $0 == 1 ? "1 day" : L10n.text("apple.chatcachesettings.0_days.af78beb0", "\($0)") }
            Text(L10n.text("apple.chatcachesettings.oldest_downloads_are_removed_when_the_cach.d16a8169"))
                #if os(macOS)
                .font(Theme.caption)
                #else
                .font(ClientType.body)
                #endif
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            purgeButton
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

    private var containsRow: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Text(L10n.text("apple.chatcachesettings.currently_contains.dae0b1be"))
                #if os(macOS)
                .font(Theme.callout)
                #else
                .font(ClientType.label)
                #endif
            Spacer(minLength: Theme.Space.m)
            Text(L10n.text("apple.chatcachesettings.chat_files.c826719c"))
                #if os(macOS)
                .font(Theme.callout)
                #else
                .font(ClientType.label)
                #endif
                .foregroundStyle(.secondary)
        }
        #if !os(macOS)
        .frame(minHeight: 44)
        .contentShape(.rect)
        #endif
        .accessibilityElement(children: .combine)
    }

    private func pickerRow<Value: Hashable>(
        _ title: String,
        selection: Binding<Value>,
        values: [Value],
        label: @escaping (Value) -> String
    ) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Text(title)
                #if os(macOS)
                .font(Theme.callout)
                #else
                .font(ClientType.label)
                #endif
            Spacer(minLength: Theme.Space.m)
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { value in
                    Text(label(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        #if !os(macOS)
        .frame(minHeight: 44)
        .contentShape(.rect)
        #endif
    }

    @ViewBuilder
    private var purgeButton: some View {
        #if os(macOS)
        Button(L10n.text("apple.chatcachesettings.purge_cache.6d8332d5"), .delete) {
            Task { await purge() }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(clearing)
        #else
        Button {
            Task { await purge() }
        } label: {
            ActionIcon.delete.label(clearing ? L10n.text("apple.chatcachesettings.purging.347a864f") : L10n.text("apple.chatcachesettings.purge_cache.6d8332d5"))
                .labelStyle(ActionLabelStyle())
                .font(ClientType.label.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(clearing)
        .accessibilityHint(L10n.text("apple.chatcachesettings.removes_downloaded_chat_files_from_this_de.aa34a0e4"))
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
                    .transition(.opacity)
                    .accessibilityLabel(L10n.text("apple.chatcachesettings.cache_cleared.61a13722"))
            )
        }
        return nil
    }

    private var usageLabel: String {
        if cleared { return L10n.text("apple.chatcachesettings.cache_cleared.61a13722") }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + L10n.text("apple.chatcachesettings.on_this_device.f913ae1c")
    }

    private func refresh() async {
        do {
            bytes = try await ChatAttachmentCache.shared.configure(maxGB: maxGB, days: days)
            cleared = false
            message = nil
        } catch {
            message = L10n.text("apple.chatcachesettings.some_cached_files_could_not_be_removed_try.9111b244")
        }
    }

    private func purge() async {
        guard !clearing else { return }
        clearing = true
        cleared = false
        message = nil
        do {
            try await ChatAttachmentCache.shared.purge()
            NotificationCenter.default.post(name: .chatAttachmentCachePurged, object: nil)
            bytes = await ChatAttachmentCache.shared.usedBytes()
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(300)) }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { cleared = true }
        } catch {
            NotificationCenter.default.post(name: .chatAttachmentCachePurged, object: nil)
            bytes = await ChatAttachmentCache.shared.usedBytes()
            message = L10n.text("apple.chatcachesettings.some_cached_files_could_not_be_removed_try.9111b244")
        }
        clearing = false
    }
}
