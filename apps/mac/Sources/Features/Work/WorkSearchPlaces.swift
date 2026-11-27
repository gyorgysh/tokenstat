// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct WorkSearchPlace: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let icon: ActionIcon
    var keywords: [String] = []
}

struct WorkSearchPlaceSource {
    let matches: @MainActor (String) -> [WorkSearchPlace]
    let open: @MainActor (WorkSearchPlace) -> Void
}

enum WorkSearchPlaceMatch {
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
