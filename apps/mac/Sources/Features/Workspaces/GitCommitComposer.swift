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
            ThemedSheet(title: "Review and commit", subtitle: context, icon: .commit,
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
                                Text("Select a file to review its changes.")
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
                    Button("Compare saved draft", .compare) { Task { await session.compareSavedVersion() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            if let alternative = session.savedAlternative {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Saved draft").font(Theme.callout.weight(.semibold))
                    Text(alternative.draft.title.isEmpty ? "No commit title" : alternative.draft.title)
                        .font(Theme.callout)
                    Text(alternative.draft.details).font(Theme.callout).foregroundStyle(.secondary)
                    if alternative.draft.submitted != nil {
                        Text("This saved draft includes a submitted commit.").font(Theme.caption).foregroundStyle(Theme.accent)
                    }
                    Button("Use saved draft", .restore) { session.useSavedVersion() }
                        .buttonStyle(SecondaryButtonStyle()).disabled(!session.canUseSavedVersion)
                    Button("Keep my current writing", .save) { Task { await session.keepCurrentVersion() } }
                        .buttonStyle(SecondaryButtonStyle()).disabled(!session.canKeepCurrentVersion)
                }.padding(Theme.Space.m).background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            }
            if let error = session.errorMessage { message(error, danger: true) }
            if let outcome = session.outcome { message(outcome.message, danger: !outcome.succeeded) }
            if session.draft.message.utf8.count > 128 * 1024 {
                message("Shorten the commit message to 128 KiB or less before committing.", danger: true)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Commit title").font(Theme.callout.weight(.semibold))
                TextField("Describe the change", text: $session.draft.title, axis: .vertical)
                    .textFieldStyle(.themed).lineLimit(1...3)
                    .accessibilityLabel("Commit title")
                Text("Description (optional)").font(Theme.caption).foregroundStyle(.secondary)
                TextEditor(text: $session.draft.details)
                    .font(Theme.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150)
                    .padding(Theme.Space.s)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
                    .accessibilityLabel("Commit description")
            }
            .disabled(!session.loaded || session.working || session.draft.submitted != nil)
            if let review = session.review {
                Text("\(review.paths.count) selected \(review.paths.count == 1 ? "file" : "files")")
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
                ProgressView("Preparing review").frame(maxWidth: .infinity)
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
            Button(session.canRetrySubmission ? "Retry same submission" : "Check outcome", .refresh) {
                Task {
                    if session.canRetrySubmission { await session.retrySubmission() }
                    else { await session.checkOutcome(recover: true) }
                    if session.outcome?.succeeded == true { await onCommitted() }
                }
            }
            .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(session.working)
        } else if session.outcome?.succeeded == true {
            Button("Done", .done) { dismiss() }.buttonStyle(AccentButtonStyle(comfortable: true))
        } else {
            if session.review == nil {
                Button("Review selected files", .compare) { Task { await session.prepareReview() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(session.working)
            } else {
                Button("Commit \(session.review?.paths.count ?? 0) \(session.review?.paths.count == 1 ? "file" : "files")", .commit) {
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
                    Button("Try again", .refresh) { Task { await load() } }.buttonStyle(SecondaryButtonStyle())
                }.padding(Theme.Space.m)
            } else if let diff {
                #if os(macOS)
                DiffView(diff: diff)
                #else
                if diff.binary {
                    Text("Binary file · included in this reviewed selection")
                        .font(ClientType.body).foregroundStyle(.secondary).padding(Theme.Space.m)
                } else if rows.isEmpty {
                    Text("No text changes in this file.").font(ClientType.body).foregroundStyle(.secondary)
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
            } else { ProgressView("Reading reviewed changes") }
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
