// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Titles are decrypted only for the visible batch and are never persisted in
/// preferences. Removal and pin changes use the cache's index invalidation path.
struct WorkCacheManagementSheet: View {
    let scope: WorkReference.Scope
    @Environment(\.dismiss) private var dismiss
    @State private var records: [CacheRecordMeta] = []
    @State private var titles: [String: String] = [:]
    @State private var limit = 30
    @State private var busy = false
    @State private var failure: String?
    @State private var loaded = false

    private var current: Bool { WorkSessionContext.shared.readingScope == scope }

    var body: some View {
        ThemedSheet(title: "Manage saved work", subtitle: "Copies on this device", icon: .archive,
                    scrolls: true, onClose: { dismiss() }) {
            if current {
                let availableRecords = records.filter(allowed)
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text("Keep offline protects a copy from automatic expiry, within your storage limit. Removing a copy leaves source work and drafts intact.")
                        .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                    if let failure { Text(failure).font(Theme.caption).foregroundStyle(Theme.controlGlyph) }
                    if busy { ProgressView().controlSize(.small) }
                    if loaded && availableRecords.isEmpty {
                        Text("No saved work is available to open").font(Theme.callout)
                    }
                    ForEach(Array(availableRecords.prefix(limit)), id: \.id) { record in
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(titles[record.id] ?? label(record)).font(Theme.body.weight(.semibold))
                                .lineLimit(3)
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: record.bytes), countStyle: .file)) · Saved \(Date(timeIntervalSince1970: Double(record.updatedMs) / 1000).formatted(date: .abbreviated, time: .shortened))")
                                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                            ViewThatFits(in: .horizontal) {
                                HStack { actions(record) }
                                VStack(alignment: .leading) { actions(record) }
                            }
                        }
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if availableRecords.count > limit {
                        Button("Show more saved work", .more) {
                            limit += 30
                            Task { await loadTitles() }
                        }
                        .buttonStyle(SecondaryButtonStyle()).disabled(busy)
                    }
                    Button("Refresh", .refresh) { Task { await load() } }
                        .buttonStyle(SecondaryButtonStyle()).disabled(busy)
                }
            }
        }
        .modalFrame(width: 620, height: 680)
        .presentationBackground(Theme.background)
        .presentationDetents([.large])
        .task { await load() }
        .onChange(of: current) { _, value in if !value { titles = [:]; dismiss() } }
    }

    @ViewBuilder private func actions(_ record: CacheRecordMeta) -> some View {
        if record.kind != "searchHistory" {
            Button(record.pinned ? "Kept offline" : "Keep offline", record.pinned ? ActionIcon.pinned : .pin) {
                Task { await change(record, remove: false) }
            }
            .buttonStyle(SecondaryButtonStyle(small: true)).disabled(busy)
            .accessibilityHint(record.pinned ? "Allow this copy to expire automatically" : "Protect this copy from automatic expiry")
        }
        Button("Remove copy", .delete) { Task { await change(record, remove: true) } }
            .buttonStyle(SecondaryButtonStyle(small: true)).disabled(busy)
    }

    private func allowed(_ record: CacheRecordMeta) -> Bool {
        guard let reference = WorkCache.reference(recordID: record.id, scope: scope)
            ?? WorkSavedPreview.reference(recordID: record.id, scope: scope) else { return record.kind == "searchHistory" }
        return WorkCacheAccess.canRead(reference)
    }

    private func label(_ record: CacheRecordMeta) -> String {
        switch record.kind {
        case "searchHistory": "Search history"
        case "diff": "Saved change"
        case "attachment": "Saved attachment"
        default: "Saved conversation"
        }
    }

    private func load() async {
        guard current, !busy else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            let listing = try await Bridge.cacheList(scope: WorkCache.scope(for: scope))
            guard current, !Task.isCancelled else { return }
            records = listing.records.filter { $0.scope == WorkCache.scope(for: scope) }.sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                return $0.updatedMs > $1.updatedMs
            }
            titles = titles.filter { key, _ in records.contains { $0.id == key } }
            loaded = true
            await loadTitles()
        } catch { if current { failure = "Saved work could not be read. Try again." } }
    }

    private func loadTitles() async {
        let wireScope = WorkCache.scope(for: scope)
        guard let key = WorkCacheKey.existingKey(for: wireScope) else { return }
        for record in records.filter(allowed).prefix(limit) where titles[record.id] == nil {
            guard current, !Task.isCancelled else { return }
            guard allowed(record) else { continue }
            let title: String?
            if record.kind == "conversation" {
                title = try? await Bridge.cacheGet(key: WorkCacheKey.encoded(key), scope: wireScope, id: record.id).payload.title
            } else if record.kind == "diff" {
                title = try? await Bridge.cachedChange(key: WorkCacheKey.encoded(key), scope: wireScope, id: record.id).payload.title
            } else if record.kind == "attachment" {
                title = try? await Bridge.savedPreview(key: WorkCacheKey.encoded(key), scope: wireScope, id: record.id).payload.title
            } else { title = label(record) }
            guard current, !Task.isCancelled else { return }
            if allowed(record), let title { titles[record.id] = title }
        }
    }

    private func change(_ record: CacheRecordMeta, remove: Bool) async {
        guard current, allowed(record), !busy else { return }
        busy = true
        failure = nil
        do {
            if remove, record.kind == "searchHistory" {
                // Clear the shared in-memory history and drain pending saves,
                // so an open search cannot write the removed entries back.
                let history = WorkSearchHistory.shared(for: scope)
                await history.clear()
                if let message = history.failure {
                    busy = false
                    if current { failure = message }
                    return
                }
            } else if remove { _ = try await Bridge.cacheRemove(scope: record.scope, id: record.id) }
            else { _ = try await Bridge.cachePin(scope: record.scope, id: record.id, pinned: !record.pinned) }
            busy = false
            await load()
        } catch {
            busy = false
            if current {
                failure = remove ? "This copy could not be removed. Try again."
                    : "This copy could not be kept offline. It needs \(ByteCountFormatter.string(fromByteCount: Int64(clamping: record.bytes), countStyle: .file)) within the offline storage limit. Remove another copy or increase the limit in Settings, then try again."
            }
        }
    }
}
