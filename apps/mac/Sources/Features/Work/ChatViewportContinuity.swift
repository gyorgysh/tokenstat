// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CoreGraphics
import Observation

/// The live viewport belongs to a model selection, rather than a layout.
/// A new selection still opens at the latest turn. A replacement presentation
/// of that same selection resumes its last measured row.
@MainActor
@Observable
final class ChatViewportContinuity {
    @ObservationIgnored private var generation: UInt64?
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var place: ChatReadingMark?
    @ObservationIgnored private var placed = false
    private(set) var vacancy: UInt64 = 0

    @discardableResult
    func claim(generation: UInt64, owner: UUID) -> ChatReadingMark? {
        if self.generation != generation || self.owner != owner { placed = false }
        if self.generation != generation { place = nil }
        self.generation = generation
        self.owner = owner
        return place
    }

    @discardableResult
    func beginPlacement(generation: UInt64, owner: UUID) -> ChatReadingMark? {
        let mark = claim(generation: generation, owner: owner)
        placed = false
        return mark
    }

    @discardableResult
    func beginPlacement(generation: UInt64, owner: UUID, eligible: Bool) -> Bool {
        guard eligible else { return false }
        _ = beginPlacement(generation: generation, owner: owner)
        return true
    }

    @discardableResult
    func completePlacement(generation: UInt64, owner: UUID) -> Bool {
        guard self.generation == generation, self.owner == owner else { return false }
        placed = true
        return true
    }

    func isPlaced(generation: UInt64, owner: UUID) -> Bool {
        placed && owns(generation: generation, owner: owner)
    }

    func owns(generation: UInt64, owner: UUID) -> Bool {
        self.generation == generation && self.owner == owner
    }

    /// Wake a displaced visible reader only when its current lease is free.
    /// Teardown never changes the measured place or another owner's lease.
    @discardableResult
    func release(generation: UInt64, owner: UUID) -> Bool {
        guard owns(generation: generation, owner: owner) else { return false }
        self.owner = nil
        placed = false
        vacancy &+= 1
        return true
    }

    /// Explicit Latest may arrive while a replacement waits for attachment.
    /// It retires the place without letting that unattached view claim a lease.
    func chooseLatest(generation: UInt64) {
        guard self.generation == generation else { return }
        place = nil
    }

    func canPlace(generation: UInt64, currentGeneration: UInt64, owner: UUID, ticket: UUID, currentTicket: UUID) -> Bool {
        generation == currentGeneration && ticket == currentTicket && owns(generation: generation, owner: owner)
    }

    /// Only a settled reading action can replace a measured place. Resizing
    /// and programmatic placement can report usable-looking, temporary rows.
    func recordMeasurement(_ position: ChatReadingPosition, generation: UInt64,
                           owner: UUID, readerInitiated: Bool) {
        guard readerInitiated, isPlaced(generation: generation, owner: owner) else { return }
        record(position, generation: generation, owner: owner)
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

/// Lazy row heights can resolve after the initial placement. Keep that
/// correction bounded: unchanged geometry never earns another proxy walk.
@MainActor
final class ChatReadingHold {
    private var mark: ChatReadingMark?
    private var viewport: CGRect?
    private var moves = 0
    private var revealed = false

    func prepare(mark: ChatReadingMark, viewport: CGRect) {
        let sameViewport = self.viewport.map {
            abs($0.minX - viewport.minX) <= 0.5 && abs($0.minY - viewport.minY) <= 0.5
                && abs($0.width - viewport.width) <= 0.5 && abs($0.height - viewport.height) <= 0.5
        } ?? false
        guard self.mark != mark || !sameViewport else { return }
        self.mark = mark
        self.viewport = viewport
        moves = 0
        revealed = false
    }

    var canCorrect: Bool { mark != nil && moves < 6 }
    func corrected() { moves += 1 }
    func takeReveal() -> Bool {
        guard canCorrect, !revealed else { return false }
        revealed = true
        return true
    }
    func reset() {
        mark = nil
        viewport = nil
        moves = 0
        revealed = false
    }
}
