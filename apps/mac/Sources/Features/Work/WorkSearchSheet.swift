// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct WorkSearchSheet: View {
    @Bindable var model: WorkSearchModel
    let open: (WorkReference) -> Bool
    /// Screens and settings this front end can be sent to, searched beside the
    /// work. Left out on the Mac, where search is about work alone.
    var places: WorkSearchPlaceSource? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var fieldFocused: Bool
    @State private var openFailure: String?
    @State private var openedChange: WorkViewedChange?
    @State private var openingChange = false
    @State private var keyboardSelection: WorkReference?

    var body: some View {
        ScrollViewReader { scroll in
        ThemedSheet(title: places == nil ? "Search work" : "Search",
                    subtitle: dynamicTypeSize.isAccessibilitySize ? "" : subtitle,
                    icon: dynamicTypeSize.isAccessibilitySize ? nil : .search,
                    scrolls: dynamicTypeSize.isAccessibilitySize, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: ActionIcon.search.symbol).foregroundStyle(Theme.controlGlyph)
                    TextField(places == nil ? "Search work" : "Search the app and your work", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(Theme.body)
                        .focused($fieldFocused)
                        // A query is a name, a word from a thread or a screen,
                        // never a sentence: an autocorrected first word finds
                        // nothing and a capital hides nothing.
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit {
                            if model.selected != nil || !model.results.isEmpty { openSelection() }
                            else if let place = placeHits.first { openPlace(place) }
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

    private var subtitle: String {
        places == nil
            ? "Find a conversation, folder, or change"
            : "Find a screen, a setting, or your work"
    }

    /// Screens and settings matching what has been typed. Only for a query:
    /// an empty field is for what somebody was doing, not a map of the app.
    private var placeHits: [WorkSearchPlace] {
        guard let places, !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return places.matches(model.query)
    }

    /// Above the work, because a screen is an exact answer and a conversation
    /// is a likely one. Few enough that the work is still on the first screen.
    @ViewBuilder
    private var placeList: some View {
        let hits = placeHits
        if !hits.isEmpty {
            Text("In the app").font(Theme.callout).foregroundStyle(Theme.controlGlyph)
            ForEach(hits) { place in
                Button { openPlace(place) } label: { WorkSearchPlaceRow(place: place) }
                    .buttonStyle(.plain)
            }
            if !model.results.isEmpty {
                Text("Your work").font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                    .padding(.top, Theme.Space.s)
            }
        }
    }

    private var resultsList: some View {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                        if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            recentWork
                                .padding(.vertical, Theme.Space.l)
                        } else {
                            placeList
                        }
                        if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           model.results.isEmpty, !model.loading, !model.searching,
                           model.failure == nil, model.queryFailure == nil {
                            noWorkMatches
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

    /// Nothing typed yet.
    ///
    /// What is here is what somebody was doing: recent searches and the places
    /// they opened. With none of that, the screen says what this field can find
    /// rather than leaving a blank page under a cursor.
    private var recentWork: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if hasRecentWork {
                HStack {
                    Text("Recent searches").font(Theme.callout)
                    Spacer()
                    Button("Clear", .delete) { Task { await model.history.clear() } }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .disabled(model.history.busy)
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
            } else {
                EmptyState(
                    symbol: ActionIcon.search.symbol,
                    title: places == nil ? "Search your work" : "Search the app and your work",
                    message: openingMessage
                )
            }
            if model.history.enabled {
                Button("Turn off search history", .history) { Task { await model.history.setEnabled(false) } }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .disabled(model.history.busy)
            } else {
                Text("Search history is off. Turn it on to keep recent searches and destinations, encrypted on this device.")
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Turn on search history", .history) { Task { await model.history.setEnabled(true) } }
                    .buttonStyle(SecondaryButtonStyle(small: true))
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
                // A folder's row is its own name three times over otherwise:
                // the title, the excerpt the host echoes back, and the trail.
                if !hit.excerpt.text.isEmpty, hit.excerpt.text != hit.title.text {
                    highlighted(hit.excerpt).font(Theme.callout).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                }
                Text(place(hit))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                Text(timing(hit))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.selected == hit.reference ? Theme.rowHighlight : Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    /// Where the hit lives: the folder and the machine, or the machine alone
    /// when the hit *is* that folder.
    private func place(_ hit: WorkSearchIndex.Hit) -> String {
        hit.folderName == hit.title.text || hit.folderName.isEmpty
            ? hit.machineName
            : "\(hit.folderName) · \(hit.machineName)"
    }

    /// Where it came from, and when it last changed when that is known.
    ///
    /// A folder carries no time of its own: a host answers zero for it, which
    /// printed as "56 years ago" under every folder in the list. Saying
    /// "Live" and stopping is the honest version.
    private func timing(_ hit: WorkSearchIndex.Hit) -> String {
        let dated = hit.updatedAt.timeIntervalSince1970 > 0
            ? " " + RelativeClock.phrase(for: hit.updatedAt, style: .full)
            : ""
        return hit.source.rawValue + dated + (hit.partial ? " · Partial conversation" : "")
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

    private var hasRecentWork: Bool {
        model.history.enabled
            && !(model.history.payload.queries.isEmpty && model.recentDestinations.isEmpty)
    }

    /// What the field can find, before anything has been typed into it.
    private var openingMessage: String {
        let live = model.liveMachines.isEmpty
            ? ""
            : " Pick a connected machine above to search it as it is now."
        return places == nil
            ? "Type to find a conversation, a folder, or a change you have opened or saved.\(live)"
            : "Type to find a screen, a setting, or work you have opened or saved.\(live)"
    }

    /// A query with no work behind it. Full width when it is the only answer,
    /// and one quiet line when screens above it already answered.
    @ViewBuilder
    private var noWorkMatches: some View {
        if placeHits.isEmpty {
            EmptyState(
                symbol: ActionIcon.search.symbol,
                title: "No matches in your work",
                message: noMatchesMessage
            )
        } else {
            Text("Nothing in your work matches this.")
                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                .padding(.vertical, Theme.Space.s)
        }
    }

    private var noMatchesMessage: String {
        if !model.liveMachines.isEmpty, model.activeLiveHosts.isEmpty {
            return "Nothing saved on this device matches. Pick a connected machine above to search what is on it."
        }
        if !model.includesSavedText {
            return "Saved conversation text is off, so this covers folder names only. Turn it on in Saved work, or search a connected machine."
        }
        return "Nothing here matches. Try fewer words, or another machine."
    }

    private func openPlace(_ place: WorkSearchPlace) {
        places?.open(place)
        dismiss()
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
