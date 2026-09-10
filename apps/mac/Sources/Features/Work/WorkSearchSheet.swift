// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct WorkSearchSheet: View {
    @Bindable var model: WorkSearchModel
    let open: (WorkReference) -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var fieldFocused: Bool
    @State private var openFailure: String?
    @State private var openedChange: WorkViewedChange?
    @State private var openingChange = false
    @State private var keyboardSelection: WorkReference?

    var body: some View {
        ScrollViewReader { scroll in
        ThemedSheet(title: "Search work", subtitle: dynamicTypeSize.isAccessibilitySize ? "" : "Find a conversation, folder, or change",
                    icon: dynamicTypeSize.isAccessibilitySize ? nil : .search,
                    scrolls: dynamicTypeSize.isAccessibilitySize, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: ActionIcon.search.symbol).foregroundStyle(Theme.controlGlyph)
                    TextField("Search work", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(Theme.body)
                        .focused($fieldFocused)
                        .onSubmit {
                            if model.selected != nil || !model.results.isEmpty { openSelection() }
                            else { Task { await model.history.remember(query: model.query) } }
                        }
                }
                .padding(Theme.Space.m)
                .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(fieldFocused ? 0.6 : 0.15)))
                filters
                if openingChange { ProgressView("Opening saved change…").font(Theme.caption) }
                if let openFailure {
                    Text(openFailure).font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                }
                if let notice = model.coverageNotice {
                    Text(notice).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                }
                coverageHeader
                liveControls

                if let error = model.queryFailure ?? model.failure {
                    Text(error).font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                    if (try? WorkSearchQuery(model.query)) != nil {
                        Button("Try again", .refresh) {
                            Task {
                                if model.queryFailure != nil { await model.search() }
                                else { await model.refresh() }
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                if let coverage = model.coverage, coverage.unreadable > 0 {
                    Text("\(coverage.unreadable) saved items could not be read. Results cover the copies available now.")
                        .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                }
                if model.savedWorkChanged {
                    Button("Refresh saved work", .refresh) { Task { await model.refresh() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if model.hasUpdatedResults {
                    Button("Show updated results", .refresh) { Task { await model.acceptUpdatedResults() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.searching)
                }
                if dynamicTypeSize.isAccessibilitySize {
                    resultsList
                } else {
                    ScrollView { resultsList }
                }
            }
        }
        .onKeyPress(.downArrow) { model.moveSelection(1); keyboardSelection = model.selected; return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(-1); keyboardSelection = model.selected; return .handled }
        .modalFrame(width: 680, height: 720)
        .presentationBackground(Theme.background)
        .presentationDetents([.large])
        .task { fieldFocused = true; await model.start() }
        .task(id: model.query) { await model.search() }
        .task(id: model.filter) { await model.search() }
        .task(id: model.host) { await model.search() }
        .sheet(item: $openedChange) { WorkViewedChangeSheet(change: $0, ownsSession: { model.ownsSavedPresentation }) }
        .onDisappear { model.close() }
        .onChange(of: keyboardSelection) { _, selected in
            if let selected { scroll.scrollTo(selected, anchor: .center) }
        }
        }
    }

    private var resultsList: some View {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                        if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            recentWork
                                .padding(.vertical, Theme.Space.l)
                        } else if model.results.isEmpty, !model.loading, !model.searching,
                                  model.failure == nil, model.queryFailure == nil {
                            Text("No matches in saved work")
                                .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                                .padding(.vertical, Theme.Space.l)
                        }
                        ForEach(model.results, id: \.reference) { hit in
                            Button {
                                model.selected = hit.reference
                                openResult(hit.reference)
                            } label: {
                                row(hit)
                            }
                            .buttonStyle(.plain)
                            .id(hit.reference)
                            .onHover { hovering in if hovering { model.selected = hit.reference } }
                            .accessibilityAddTraits(model.selected == hit.reference ? .isSelected : [])
                        }
                        if model.canLoadMore {
                            Button("Show more results", .more) { Task { await model.search(more: true) } }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(model.searching)
                        }
                    }
    }

    private var recentWork: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Find conversations, folders, and changes you have opened or saved.")
                .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
            if model.history.enabled {
                HStack {
                    Text("Recent searches").font(Theme.callout)
                    Spacer()
                    Button("Clear", .delete) { Task { await model.history.clear() } }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .disabled(model.history.busy)
                }
                if model.history.payload.queries.isEmpty {
                    Text("Searches you submit will appear here.").font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                }
                ForEach(model.history.payload.queries, id: \.self) { query in
                    Button(query, .search) { model.query = query; fieldFocused = true }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if !model.recentDestinations.isEmpty {
                    Text("Recently opened").font(Theme.callout)
                    ForEach(model.recentDestinations) { destination in
                        Button(destination.title, .history) { openResult(destination.reference) }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                Button("Turn off search history", .history) { Task { await model.history.setEnabled(false) } }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .disabled(model.history.busy)
            } else {
                Text("Search history is off. Turn it on to keep recent searches and destinations, encrypted on this device.")
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                Button("Turn on search history", .history) { Task { await model.history.setEnabled(true) } }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.history.busy)
            }
            if let failure = model.history.failure {
                Text(failure).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                if !model.history.enabled {
                    Button("Clear saved history", .delete) { Task { await model.history.clear() } }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .disabled(model.history.busy)
                }
            }
        }
    }

    private var liveControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !model.liveMachines.isEmpty {
                Menu {
                    ForEach(model.liveMachines.keys.sorted(), id: \.self) { identity in
                        if model.liveHosts.contains(identity) {
                            Button(model.liveMachines[identity] ?? "Computer", .done) {
                                model.selectLiveHosts(model.liveHosts.subtracting([identity]))
                            }
                        } else {
                            Button(model.liveMachines[identity] ?? "Computer", .device) {
                                model.selectLiveHosts(model.liveHosts.union([identity]))
                            }
                        }
                    }
                    if !model.liveHosts.isEmpty {
                        Button("Stop searching connected machines", .stop) { model.selectLiveHosts([]) }
                    }
                } label: {
                    ActionIcon.search.label(model.liveHosts.isEmpty ? "Search connected machines" : "Computers (\(model.liveHosts.count))")
                        .font(Theme.callout)
                }
            }
            if let coverage = model.liveCoverageText {
                Text(coverage).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.canLoadMoreLive {
                Button("More live results", .search) { model.loadMoreLive() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if !model.liveFailures.intersection(model.activeLiveHosts).isEmpty {
                Button("Retry live search", .refresh) { model.selectLiveHosts(model.liveHosts) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var coverageHeader: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.s))
            : AnyLayout(HStackLayout())
        return layout {
            Text("Saved work on this device").font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            machineFilter
            if model.loading || model.searching { ProgressView().controlSize(.small) }
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(WorkSearchModel.Filter.allCases) { filter in
                    Button(filter.rawValue, .filter) { model.filter = filter }
                        .buttonStyle(SecondaryButtonStyle())
                        .foregroundStyle(model.filter == filter ? Theme.accent : Theme.controlGlyph)
                        .accessibilityAddTraits(model.filter == filter ? .isSelected : [])
                }

            }
        }
    }

    private var machineFilter: some View {
                Menu {
                    Button("All machines", .device) { model.host = nil }
                    ForEach(model.machines.keys.sorted(), id: \.self) { identity in
                        Button(model.machines[identity] ?? "Machine", .device) { model.host = identity }
                    }
                } label: {
                    ActionIcon.device.label(model.host.flatMap { model.machines[$0] } ?? "All machines")
                        .font(Theme.callout)
                }
    }

    private func resultIcon(_ kind: WorkReference.Kind) -> ActionIcon {
        switch kind {
        case .conversation: .comment
        case .workspace: .reveal
        case .commit: .commit
        case .savedDiff: .source
        case .terminal: .archive
        }
    }

    private func row(_ hit: WorkSearchIndex.Hit) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: resultIcon(hit.reference.kind).symbol)
                    .foregroundStyle(Theme.accent).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                highlighted(hit.title).font(Theme.body.weight(.semibold)).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if !hit.excerpt.text.isEmpty { highlighted(hit.excerpt).font(Theme.callout).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3) }
                Text("\(hit.folderName) · \(hit.machineName)")
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                Text("\(hit.source.rawValue) \(RelativeClock.phrase(for: hit.updatedAt, style: .full))\(hit.partial ? " · Partial conversation" : "")")
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.selected == hit.reference ? Theme.rowHighlight : Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    private func highlighted(_ excerpt: WorkSearchText.Excerpt) -> Text {
        var text = AttributedString(excerpt.text)
        for range in excerpt.highlights {
            guard let original = Range(range, in: excerpt.text),
                  let attributed = Range(original, in: text) else { continue }
            text[attributed].foregroundColor = Theme.accent
            text[attributed].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(text)
    }

    private func openSelection() {
        guard let reference = model.selected ?? model.results.first?.reference else { return }
        openResult(reference)
    }

    private func openResult(_ reference: WorkReference) {
        openFailure = nil
        if reference.kind == .commit || reference.kind == .savedDiff {
            guard !openingChange else { return }
            openingChange = true
            Task {
                defer { openingChange = false }
                if let change = await model.savedChange(reference) {
                    model.rememberOpen(reference)
                    openedChange = change
                } else {
                    openFailure = "This saved change is no longer available. Refresh saved work, or open its folder to view current changes."
                }
            }
        } else if open(reference) { model.rememberOpen(reference); dismiss() }
        else { openFailure = "This work is not available to open. Check its folder and machine in Workspaces, then try again." }
    }
}
