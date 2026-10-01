// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// A focused phone composer and a spacious review beside writing on iPad/Mac.
/// Both presentations operate on the same frozen selection and saved draft.
struct GitCommitComposer: View {
    @Bindable var session: GitCommitSession
    let folderName: String
    let hostName: String
    var onCommitted: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedPath: String?

    var body: some View {
        NavigationStack {
            ThemedSheet(title: L10n.text("apple.gitcommitcomposer.review_and_commit.96f097b7"), subtitle: context, icon: .commit,
                        onClose: { dismiss() }) {
                GeometryReader { geometry in
                    let split = geometry.size.width >= 820 && !typeSize.isAccessibilitySize
                    HStack(spacing: Theme.Space.m) {
                        ScrollView {
                            fields(split: split)
                        }
                        .frame(maxWidth: split ? 340 : .infinity)
                        if split {
                            ThemeRule.vertical
                            if let review = session.review, let path = selectedPath ?? review.includedPaths.first {
                                GitReviewedFileView(service: session.service, review: review, path: path)
                                    .id(path + review.tree)
                            } else {
                                Text(L10n.text("apple.gitcommitcomposer.select_a_file_to_review_its_changes.4a928544"))
                                    .font(Theme.callout).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
            } actions: {
                actions
            }
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .modalFrame(width: 960, height: 700)
        .interactiveDismissDisabled(session.working)
        .task {
            await session.load()
            if session.review == nil && session.draft.submitted == nil { await session.prepareReview() }
        }
        .onChange(of: session.draft) { _, _ in Task { await session.persist() } }
    }

    private var context: String {
        [folderName, session.review?.branchName, hostName.isEmpty ? nil : hostName]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func fields(split: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let saveError = session.saveError {
                message(saveError, danger: true)
                if session.canCompareSavedVersion {
                    Button(L10n.text("apple.gitcommitcomposer.compare_saved_draft.8b57a4df"), .compare) { Task { await session.compareSavedVersion() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            if let alternative = session.savedAlternative {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(L10n.text("apple.gitcommitcomposer.saved_draft.41c82369")).font(Theme.callout.weight(.semibold))
                    Text(alternative.draft.title.isEmpty ? L10n.text("apple.gitcommitcomposer.no_commit_title.b59e212a") : alternative.draft.title)
                        .font(Theme.callout)
                    Text(alternative.draft.details).font(Theme.callout).foregroundStyle(.secondary)
                    if alternative.draft.submitted != nil {
                        Text(L10n.text("apple.gitcommitcomposer.this_saved_draft_includes_a_submitted_comm.2af74385")).font(Theme.caption).foregroundStyle(Theme.accent)
                    }
                    Button(L10n.text("apple.gitcommitcomposer.use_saved_draft.31f362c2"), .restore) { session.useSavedVersion() }
                        .buttonStyle(SecondaryButtonStyle()).disabled(!session.canUseSavedVersion)
                    Button(L10n.text("apple.gitcommitcomposer.keep_my_current_writing.e20b63c4"), .save) { Task { await session.keepCurrentVersion() } }
                        .buttonStyle(SecondaryButtonStyle()).disabled(!session.canKeepCurrentVersion)
                }.padding(Theme.Space.m).background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            }
            if let error = session.errorMessage { message(error, danger: true) }
            if let outcome = session.outcome { message(outcome.message, danger: !outcome.succeeded) }
            if session.draft.message.utf8.count > 128 * 1024 {
                message(L10n.text("apple.gitcommitcomposer.shorten_the_commit_message_to_128_kib_or_l.ffe20f8c"), danger: true)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(L10n.text("apple.gitcommitcomposer.commit_title.30459372")).font(Theme.callout.weight(.semibold))
                TextField(L10n.text("apple.gitcommitcomposer.describe_the_change.beaee364"), text: $session.draft.title, axis: .vertical)
                    .textFieldStyle(.themed).lineLimit(1...3)
                    .accessibilityLabel(L10n.text("apple.gitcommitcomposer.commit_title.30459372"))
                Text(L10n.text("apple.gitcommitcomposer.description_optional.f6cbe2f0")).font(Theme.caption).foregroundStyle(.secondary)
                TextEditor(text: $session.draft.details)
                    .font(Theme.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150)
                    .padding(Theme.Space.s)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
                    .accessibilityLabel(L10n.text("apple.gitcommitcomposer.commit_description.ddbdf616"))
            }
            .disabled(!session.loaded || session.working || session.draft.submitted != nil)
            if let review = session.review {
                Text(L10n.text("apple.gitcommitcomposer.0_selected_1.3a4c3bb6", "\(review.paths.count)", "\(review.paths.count == 1 ? L10n.text("apple.gitcommitcomposer.file.3b9c358f") : "files")"))
                    .font(Theme.callout.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(review.includedPaths, id: \.self) { path in
                        if split {
                            Button { selectedPath = path } label: {
                                ActionIcon.compare.label(path)
                                    .font(Theme.callout).lineLimit(2)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .padding(.horizontal, Theme.Space.s)
                                    .background((selectedPath ?? review.includedPaths.first) == path ? Theme.rowSelected : Theme.panel,
                                                in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                            }.buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                GitReviewedFileView(service: session.service, review: review, path: path)
                            } label: { fileRow(path, selected: false) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            } else if session.working {
                ProgressView(L10n.text("apple.gitcommitcomposer.preparing_review.6cafe23d")).frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileRow(_ path: String, selected: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: ActionIcon.compare.symbol).foregroundStyle(Theme.accent)
            Text(path).font(Theme.callout).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(Theme.caption).foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.s)
        .frame(minHeight: 44)
        .background(selected ? Theme.rowSelected : Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .contentShape(.rect)
    }

    private func message(_ text: String, danger: Bool) -> some View {
        Text(text).font(Theme.callout).foregroundStyle(danger ? Theme.danger : Theme.accent)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private var actions: some View {
        if session.draft.submitted != nil {
            Button(session.canRetrySubmission ? L10n.text("apple.gitcommitcomposer.retry_same_submission.3dbca561") : L10n.text("apple.gitcommitcomposer.check_outcome.9200a2fd"), .refresh) {
                Task {
                    if session.canRetrySubmission { await session.retrySubmission() }
                    else { await session.checkOutcome(recover: true) }
                    if session.outcome?.succeeded == true { await onCommitted() }
                }
            }
            .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(session.working)
        } else if session.outcome?.succeeded == true {
            Button(L10n.text("common.done"), .done) { dismiss() }.buttonStyle(AccentButtonStyle(comfortable: true))
        } else {
            if session.review == nil {
                Button(L10n.text("apple.gitcommitcomposer.review_selected_files.fb340554"), .compare) { Task { await session.prepareReview() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(session.working)
            } else {
                Button(L10n.text("apple.gitcommitcomposer.commit_0_1.ed71a626", "\(session.review?.paths.count ?? 0)", "\(session.review?.paths.count == 1 ? L10n.text("apple.gitcommitcomposer.file.3b9c358f") : "files")"), .commit) {
                    Task {
                        await session.submit()
                        if session.outcome?.succeeded == true { await onCommitted() }
                    }
                }
                .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(!session.canCommit)
            }
        }
    }
}

struct GitReviewedFileView: View {
    let service: any GitCommitService
    let review: GitCommitReview
    let path: String
    @State private var diff: FileDiff?
    @State private var rows: [DiffDocumentRow] = []
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                VStack(spacing: Theme.Space.m) {
                    Text(error).font(Theme.callout).foregroundStyle(Theme.danger)
                    Button(L10n.text("apple.gitcommitcomposer.try_again.d8b8392e"), .refresh) { Task { await load() } }.buttonStyle(SecondaryButtonStyle())
                }.padding(Theme.Space.m)
            } else if let diff {
                #if os(macOS)
                DiffView(diff: diff)
                #else
                if diff.binary {
                    Text(L10n.text("apple.gitcommitcomposer.binary_file_included_in_this_reviewed_sele.7b9e8582"))
                        .font(ClientType.body).foregroundStyle(.secondary).padding(Theme.Space.m)
                } else if rows.isEmpty {
                    Text(L10n.text("apple.gitcommitcomposer.no_text_changes_in_this_file.9c538f4a")).font(ClientType.body).foregroundStyle(.secondary)
                } else {
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(rows) { row in
                                    switch row.content {
                                    case let .line(line): DiffLineRow(line: line, minWidth: geometry.size.width)
                                    case let .hunk(header):
                                        Text(header).font(ClientType.code).foregroundStyle(.secondary)
                                            .padding(Theme.Space.s).frame(minWidth: geometry.size.width, alignment: .leading)
                                            .background(Theme.panel)
                                    case .file: EmptyView()
                                    case let .note(note): Text(note).font(ClientType.body).padding(Theme.Space.m)
                                    }
                                }
                            }
                        }
                    }
                }
                #endif
            } else { ProgressView(L10n.text("apple.gitcommitcomposer.reading_reviewed_changes.9c829fac")) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .navigationTitle(path)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .task(id: path + review.tree) { await load() }
    }

    private func load() async {
        do {
            let fresh = try await service.diff(review, path: path)
            let lines = await Task.detached(priority: .userInitiated) { DiffDocumentRow.make([fresh], fileHeaders: false) }.value
            guard !Task.isCancelled else { return }
            diff = fresh; rows = lines; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
