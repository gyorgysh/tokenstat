// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// The live viewport belongs to a model selection, rather than a layout.
/// A new selection still opens at the latest turn. A replacement presentation
/// of that same selection resumes its last measured row.
@MainActor
final class ChatViewportContinuity {
    private var generation: UInt64?
    private var owner: UUID?
    private var place: ChatReadingMark?

    @discardableResult
    func claim(generation: UInt64, owner: UUID) -> ChatReadingMark? {
        if self.generation != generation { place = nil }
        self.generation = generation
        self.owner = owner
        return place
    }

    func mark(generation: UInt64) -> ChatReadingMark? {
        self.generation == generation ? place : nil
    }

    func record(_ position: ChatReadingPosition, generation: UInt64, owner: UUID) {
        guard self.generation == generation, self.owner == owner else { return }
        switch position {
        case .latest: place = nil
        case let .away(mark): place = mark
        case .unknown: break
        }
    }
}
