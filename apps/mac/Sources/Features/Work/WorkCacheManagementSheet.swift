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
        ThemedSheet(title: L10n.text("apple.workcachemanagementsheet.manage_saved_work.4802a957"), subtitle: L10n.text("apple.workcachemanagementsheet.copies_on_this_device.06bf3713"), icon: .archive,
                    scrolls: true, onClose: { dismiss() }) {
            if current {
                let availableRecords = records.filter(allowed)
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text(L10n.text("apple.workcachemanagementsheet.keep_offline_protects_a_copy_from_automati.89008a1c"))
                        .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                    if let failure { Text(failure).font(Theme.caption).foregroundStyle(Theme.controlGlyph) }
                    if busy { ProgressView().controlSize(.small) }
                    if loaded && availableRecords.isEmpty {
                        Text(L10n.text("apple.workcachemanagementsheet.no_saved_work_is_available_to_open.8932e8e2")).font(Theme.callout)
                    }
                    ForEach(Array(availableRecords.prefix(limit)), id: \.id) { record in
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(titles[record.id] ?? label(record)).font(Theme.body.weight(.semibold))
                                .lineLimit(3)
                            Text(L10n.text("apple.workcachemanagementsheet.0_saved_1.ad0f121e", "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: record.bytes), countStyle: .file))", "\(Date(timeIntervalSince1970: Double(record.updatedMs) / 1000).formatted(date: .abbreviated, time: .shortened))"))
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
                        Button(L10n.text("apple.workcachemanagementsheet.show_more_saved_work.9074e8ae"), .more) {
                            limit += 30
                            Task { await loadTitles() }
                        }
                        .buttonStyle(SecondaryButtonStyle()).disabled(busy)
                    }
                    Button(L10n.text("common.refresh"), .refresh) { Task { await load() } }
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
            Button(record.pinned ? L10n.text("apple.workcachemanagementsheet.kept_offline.7d4c828c") : L10n.text("apple.workcachemanagementsheet.keep_offline.d500aec1"), record.pinned ? ActionIcon.pinned : .pin) {
                Task { await change(record, remove: false) }
            }
            .buttonStyle(SecondaryButtonStyle(small: true)).disabled(busy)
            .accessibilityHint(record.pinned ? L10n.text("apple.workcachemanagementsheet.allow_this_copy_to_expire_automatically.30674b2c") : L10n.text("apple.workcachemanagementsheet.protect_this_copy_from_automatic_expiry.bb1622fb"))
        }
        Button(L10n.text("apple.workcachemanagementsheet.remove_copy.63d1aef0"), .delete) { Task { await change(record, remove: true) } }
            .buttonStyle(SecondaryButtonStyle(small: true)).disabled(busy)
    }

    private func allowed(_ record: CacheRecordMeta) -> Bool {
        guard let reference = WorkCache.reference(recordID: record.id, scope: scope)
            ?? WorkSavedPreview.reference(recordID: record.id, scope: scope) else { return record.kind == "searchHistory" }
        return WorkCacheAccess.canRead(reference)
    }

    private func label(_ record: CacheRecordMeta) -> String {
        switch record.kind {
        case "searchHistory": L10n.text("apple.workcachemanagementsheet.search_history.df165949")
        case "diff": L10n.text("apple.workcachemanagementsheet.saved_change.c2f6fdb4")
        case "attachment": L10n.text("apple.workcachemanagementsheet.saved_attachment.39c14384")
        default: L10n.text("apple.workcachemanagementsheet.saved_conversation.20844222")
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
        } catch { if current { failure = L10n.text("apple.workcachemanagementsheet.saved_work_could_not_be_read_try_again.a77d3a43") } }
    }

    private func loadTitles() async {
        let wireScope = WorkCache.scope(for: scope)
        guard let key = await WorkCacheKey.existingKeyInBackground(for: wireScope) else { return }
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
                failure = remove ? L10n.text("apple.workcachemanagementsheet.this_copy_could_not_be_removed_try_again.b4a0a1c0")
                    : L10n.text("apple.workcachemanagementsheet.this_copy_could_not_be_kept_offline_it_nee.024f5397", "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: record.bytes), countStyle: .file))")
            }
        }
    }
}
