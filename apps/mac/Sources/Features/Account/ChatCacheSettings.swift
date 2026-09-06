// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Device-local downloads, shared by both Apple settings surfaces.
///
/// Same card chrome as Terminal and Notifications: a 22pt feature mark, title
/// and subtitle in the header, then labelled rows. The large purge illustration
/// sat outside that vocabulary and made this block look like a different product.
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
            title: "Chat file cache",
            subtitle: usageLabel,
            mark: "mark_cache",
            accessory: statusAccessory
        ) {
            rows
        }
        #else
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                ClientSectionTitle(title: "Chat file cache", mark: "mark_cache")
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
            pickerRow(
                "Maximum size",
                selection: $maxGB,
                values: ChatCachePreferences.sizes
            ) { "\($0) GB" }
            ThemeRule()
            pickerRow(
                "Remove unused files after",
                selection: $days,
                values: ChatCachePreferences.days
            ) { $0 == 1 ? "1 day" : "\($0) days" }
            Text("Oldest downloads are removed when the cache is full. This includes local preview copies. Originals stay on the computer that owns the chat.")
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
        Button("Purge cache", .delete) {
            Task { await purge() }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(clearing)
        #else
        Button {
            Task { await purge() }
        } label: {
            ActionIcon.delete.label(clearing ? "Purging…" : "Purge cache")
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
        .accessibilityHint("Removes downloaded chat files from this device. Originals stay on the computer that owns the chat.")
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
                    .accessibilityLabel("Cache cleared")
            )
        }
        return nil
    }

    private var usageLabel: String {
        if cleared { return "Cache cleared" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " on this device"
    }

    private func refresh() async {
        do {
            bytes = try await ChatAttachmentCache.shared.configure(maxGB: maxGB, days: days)
            cleared = false
            message = nil
        } catch {
            message = "Some cached files could not be removed. Try again."
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
            message = "Some cached files could not be removed. Try again."
        }
        clearing = false
    }
}
