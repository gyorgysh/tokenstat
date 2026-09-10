// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// A screen or setting inside the app, offered by search beside saved work.
///
/// Search is the field somebody types into when they do not know where a thing
/// lives, so it answers for the app as well as for the work in it. Nobody
/// should have to know that the notification switch is behind the avatar, on
/// the second pane of a sheet, to be able to find it.
///
/// The identifier says where the place goes, in a form the front end parses
/// (`"tab:home"`, `"account:thisDevice:tabs"`). This layer stays ignorant of
/// destinations so one sheet can serve a client that has tabs and a Mac that
/// has windows.
struct WorkSearchPlace: Identifiable, Hashable {
    let id: String
    let title: String
    /// Where it lives, said the way a person would: "Account · This device".
    let detail: String
    let icon: ActionIcon
    /// Words somebody might type for this that the title does not contain.
    var keywords: [String] = []
}

/// The places search offers and what opening one does. The client fills this
/// in; the Mac leaves it out and search stays about work alone.
struct WorkSearchPlaceSource {
    let matches: @MainActor (String) -> [WorkSearchPlace]
    let open: @MainActor (WorkSearchPlace) -> Void
}

enum WorkSearchPlaceMatch {
    /// Every word typed has to start a word in the place, so "not" finds
    /// Notifications and "tab bar" finds Tabs, while a word from nowhere in it
    /// removes the place rather than ranking it last.
    ///
    /// Ranked by where the match landed: the title first, then the words kept
    /// for searching, then the trail that says where it lives. A person typing
    /// "plan" means the Plan card, not every setting that mentions a plan.
    static func rank(_ query: String, in places: [WorkSearchPlace], limit: Int = 6) -> [WorkSearchPlace] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return [] }
        let scored = places.compactMap { place -> (WorkSearchPlace, Int)? in
            var total = 0
            for word in words {
                guard let score = score(word, in: place) else { return nil }
                total += score
            }
            return (place, total)
        }
        return scored.sorted {
            $0.1 == $1.1 ? $0.0.title < $1.0.title : $0.1 > $1.1
        }.prefix(limit).map(\.0)
    }

    private static func score(_ word: String, in place: WorkSearchPlace) -> Int? {
        if starts(place.title, with: word) { return place.title.lowercased() == word ? 6 : 4 }
        if place.keywords.contains(where: { starts($0, with: word) }) { return 2 }
        if starts(place.detail, with: word) { return 1 }
        return nil
    }

    private static func starts(_ text: String, with word: String) -> Bool {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.contains { $0.hasPrefix(word) }
    }
}

/// One place, drawn like a search result rather than like a settings row: this
/// list is read by somebody scanning for a word they typed.
struct WorkSearchPlaceRow: View {
    let place: WorkSearchPlace
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: place.icon.symbol)
                    .foregroundStyle(Theme.accent).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(place.title).font(Theme.body.weight(.semibold))
                Text(place.detail).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.controlGlyph)
                .accessibilityHidden(true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}
