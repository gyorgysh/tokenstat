// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Device-local downloads, shared by both Apple settings surfaces.
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Image("cache_purge")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .foregroundStyle(Theme.accent)
                    .rotationEffect(.degrees(clearing && !reduceMotion ? -12 : 0))
                    .scaleEffect(clearing && !reduceMotion ? 0.85 : 1)
                    .animation(clearing && !reduceMotion ? .easeInOut(duration: 0.3).repeatForever(autoreverses: true) : .easeOut(duration: 0.2), value: clearing)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Chat file cache").font(Theme.headline)
                    Text(usageLabel)
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if clearing { ProgressView().controlSize(.small) }
                if cleared {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            Picker("Maximum size", selection: $maxGB) {
                ForEach(ChatCachePreferences.sizes, id: \.self) { value in
                    Text("\(value) GB").tag(value)
                }
            }
            Picker("Remove unused files after", selection: $days) {
                ForEach(ChatCachePreferences.days, id: \.self) { value in
                    Text(value == 1 ? "1 day" : "\(value) days").tag(value)
                }
            }
            Text("Oldest downloads are removed when the cache is full. This includes local preview copies. Originals stay on the computer that owns the chat.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Button("Purge cache", .delete) {
                Task { await purge() }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(clearing)
            if let message {
                Text(message).font(Theme.caption).foregroundStyle(Theme.danger)
            }
        }
        .pickerStyle(.menu)
        .disabled(clearing)
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1)
        }
        .task { await refresh() }
        .onChange(of: maxGB) { _, _ in Task { await refresh() } }
        .onChange(of: days) { _, _ in Task { await refresh() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
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
            // Briefly let the SVG settle into its success state, even for an
            // empty cache. Reduced Motion skips the decorative delay.
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(500)) }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { cleared = true }
        } catch {
            NotificationCenter.default.post(name: .chatAttachmentCachePurged, object: nil)
            bytes = await ChatAttachmentCache.shared.usedBytes()
            message = "Some cached files could not be removed. Try again."
        }
        clearing = false
    }
}
