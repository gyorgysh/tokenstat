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
        ThemedSheet(title: places == nil ? L10n.text("apple.worksearchsheet.search_work.cc46cedc") : L10n.text("common.search"),
                    subtitle: dynamicTypeSize.isAccessibilitySize ? "" : subtitle,
                    icon: dynamicTypeSize.isAccessibilitySize ? nil : .searchAll,
                    scrolls: dynamicTypeSize.isAccessibilitySize, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: ActionIcon.search.symbol).foregroundStyle(Theme.controlGlyph)
                    TextField(places == nil ? L10n.text("apple.worksearchsheet.search_work.cc46cedc") : L10n.text("apple.worksearchsheet.search_the_app_and_your_work.deb3629b"), text: $model.query)
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
                if openingChange { ProgressView(L10n.text("apple.worksearchsheet.opening_saved_change.a31530ab")).font(Theme.caption) }
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
                        Button(L10n.text("apple.worksearchsheet.try_again.d8b8392e"), .refresh) {
                            Task {
                                if model.queryFailure != nil { await model.search() }
                                else { await model.refresh() }
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                if let coverage = model.coverage, coverage.unreadable > 0 {
                    Text(L10n.text("apple.worksearchsheet.0_saved_items_could_not_be_read_results_co.3a212847", "\(coverage.unreadable)"))
                        .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                }
                if model.savedWorkChanged {
                    Button(L10n.text("apple.worksearchsheet.refresh_saved_work.dbb0ddec"), .refresh) { Task { await model.refresh() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if model.hasUpdatedResults {
                    Button(L10n.text("apple.worksearchsheet.show_updated_results.b4a3e278"), .refresh) { Task { await model.acceptUpdatedResults() } }
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
            ? L10n.text("apple.worksearchsheet.find_a_conversation_folder_or_change.c6ecae64")
            : L10n.text("apple.worksearchsheet.find_a_screen_a_setting_or_your_work.e15aaac3")
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
            Text(L10n.text("apple.worksearchsheet.in_the_app.dac837e8")).font(Theme.callout).foregroundStyle(Theme.controlGlyph)
            ForEach(hits) { place in
                Button { openPlace(place) } label: { WorkSearchPlaceRow(place: place) }
                    .buttonStyle(.plain)
            }
            if !model.results.isEmpty {
                Text(L10n.text("apple.worksearchsheet.your_work.ef14cf0d")).font(Theme.callout).foregroundStyle(Theme.controlGlyph)
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
                            Button(L10n.text("apple.worksearchsheet.show_more_results.b27dc424"), .more) { Task { await model.search(more: true) } }
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
                    Text(L10n.text("apple.worksearchsheet.recent_searches.228c84b5")).font(Theme.callout)
                    Spacer()
                    Button(L10n.text("apple.worksearchsheet.clear.83b12c22"), .delete) { Task { await model.history.clear() } }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .disabled(model.history.busy)
                }
                ForEach(model.history.payload.queries, id: \.self) { query in
                    Button(query, .search) { model.query = query; fieldFocused = true }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if !model.recentDestinations.isEmpty {
                    Text(L10n.text("apple.worksearchsheet.recently_opened.07d9b609")).font(Theme.callout)
                    ForEach(model.recentDestinations) { destination in
                        Button(destination.title, .history) { openResult(destination.reference) }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            } else {
                EmptyState(
                    symbol: ActionIcon.search.symbol,
                    title: places == nil ? L10n.text("apple.worksearchsheet.search_your_work.25aa8c29") : L10n.text("apple.worksearchsheet.search_the_app_and_your_work.deb3629b"),
                    message: openingMessage
                )
            }
            if model.history.enabled {
                Button(L10n.text("apple.worksearchsheet.turn_off_search_history.10132c4b"), .history) { Task { await model.history.setEnabled(false) } }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .disabled(model.history.busy)
            } else {
                Text(L10n.text("apple.worksearchsheet.search_history_is_off_turn_it_on_to_keep_r.6847b71e"))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("apple.worksearchsheet.turn_on_search_history.d3147981"), .history) { Task { await model.history.setEnabled(true) } }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .disabled(model.history.busy)
            }
            if let failure = model.history.failure {
                Text(failure).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                if !model.history.enabled {
                    Button(L10n.text("apple.worksearchsheet.clear_saved_history.186756c8"), .delete) { Task { await model.history.clear() } }
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
                            Button(model.liveMachines[identity] ?? L10n.text("apple.worksearchsheet.computer.76ed42d2"), .done) {
                                model.selectLiveHosts(model.liveHosts.subtracting([identity]))
                            }
                        } else {
                            Button(model.liveMachines[identity] ?? L10n.text("apple.worksearchsheet.computer.76ed42d2"), .device) {
                                model.selectLiveHosts(model.liveHosts.union([identity]))
                            }
                        }
                    }
                    if !model.liveHosts.isEmpty {
                        Button(L10n.text("apple.worksearchsheet.stop_searching_connected_machines.6f7d631e"), .stop) { model.selectLiveHosts([]) }
                    }
                } label: {
                    ActionIcon.search.label(model.liveHosts.isEmpty ? L10n.text("apple.worksearchsheet.search_connected_machines.67d82a82") : L10n.text("apple.worksearchsheet.computers_0.098e9f1f", "\(model.liveHosts.count)"))
                        .font(Theme.callout)
                }
            }
            if let coverage = model.liveCoverageText {
                Text(coverage).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.canLoadMoreLive {
                Button(L10n.text("apple.worksearchsheet.more_live_results.b30b9ba6"), .search) { model.loadMoreLive() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if !model.liveFailures.intersection(model.activeLiveHosts).isEmpty {
                Button(L10n.text("apple.worksearchsheet.retry_live_search.fef46d4a"), .refresh) { model.selectLiveHosts(model.liveHosts) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var coverageHeader: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.s))
            : AnyLayout(HStackLayout())
        return layout {
            Text(L10n.text("apple.worksearchsheet.saved_work_on_this_device.6942a15d")).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
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
                    Button(L10n.enumLabel(filter), .filter) { model.filter = filter }
                        .buttonStyle(SecondaryButtonStyle())
                        .foregroundStyle(model.filter == filter ? Theme.accent : Theme.controlGlyph)
                        .accessibilityAddTraits(model.filter == filter ? .isSelected : [])
                }

            }
        }
    }

    private var machineFilter: some View {
                Menu {
                    Button(L10n.text("apple.worksearchsheet.all_machines.47841756"), .device) { model.host = nil }
                    ForEach(model.machines.keys.sorted(), id: \.self) { identity in
                        Button(model.machines[identity] ?? L10n.text("apple.worksearchsheet.machine.8f1cc42d"), .device) { model.host = identity }
                    }
                } label: {
                    ActionIcon.device.label(model.host.flatMap { model.machines[$0] } ?? L10n.text("apple.worksearchsheet.all_machines.47841756"))
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
        return L10n.enumLabel(hit.source) + dated + (hit.partial ? L10n.text("apple.worksearchsheet.partial_conversation.26d41f9c") : "")
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
            : L10n.text("apple.worksearchsheet.pick_a_connected_machine_above_to_search_i.e252311d")
        return places == nil
            ? L10n.text("apple.worksearchsheet.type_to_find_a_conversation_a_folder_or_a.579dec50", "\(live)")
            : L10n.text("apple.worksearchsheet.type_to_find_a_screen_a_setting_or_work_yo.14600f0e", "\(live)")
    }

    /// A query with no work behind it. Full width when it is the only answer,
    /// and one quiet line when screens above it already answered.
    @ViewBuilder
    private var noWorkMatches: some View {
        if placeHits.isEmpty {
            EmptyState(
                symbol: ActionIcon.search.symbol,
                title: L10n.text("apple.worksearchsheet.no_matches_in_your_work.a6f76389"),
                message: noMatchesMessage
            )
        } else {
            Text(L10n.text("apple.worksearchsheet.nothing_in_your_work_matches_this.30cda127"))
                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                .padding(.vertical, Theme.Space.s)
        }
    }

    private var noMatchesMessage: String {
        if !model.liveMachines.isEmpty, model.activeLiveHosts.isEmpty {
            return L10n.text("apple.worksearchsheet.nothing_saved_on_this_device_matches_pick.c5307040")
        }
        if !model.includesSavedText {
            return L10n.text("apple.worksearchsheet.saved_conversation_text_is_off_so_this_cov.bca810dc")
        }
        return L10n.text("apple.worksearchsheet.nothing_here_matches_try_fewer_words_or_an.7daab500")
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
                    openFailure = L10n.text("apple.worksearchsheet.this_saved_change_is_no_longer_available_r.75cc6c73")
                }
            }
        } else if open(reference) { model.rememberOpen(reference); dismiss() }
        else { openFailure = L10n.text("apple.worksearchsheet.this_work_is_not_available_to_open_check_i.21b25b9d") }
    }
}
