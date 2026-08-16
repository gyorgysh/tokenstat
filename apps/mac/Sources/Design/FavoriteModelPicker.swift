// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Per-backend model favorites, local to this Mac.
///
/// Stars pin models to the top of the picker. Nothing here leaves the machine.
@MainActor
@Observable
final class ModelFavoritesStore {
    static let shared = ModelFavoritesStore()

    private static let key = "models.favorites"

    private(set) var byBackend: [String: [String]] = [:]

    private init() {
        byBackend = Self.load()
    }

    func ids(for backend: String) -> [String] {
        byBackend[backend] ?? []
    }

    func contains(backend: String, model: String) -> Bool {
        guard !model.isEmpty else { return false }
        return ids(for: backend).contains(model)
    }

    func toggle(backend: String, model: String) {
        let cleaned = TodoCard.cleanModelID(model)
        guard !backend.isEmpty, !cleaned.isEmpty else { return }
        var list = ids(for: backend)
        if let idx = list.firstIndex(of: cleaned) {
            list.remove(at: idx)
        } else {
            list.insert(cleaned, at: 0)
        }
        if list.isEmpty {
            byBackend.removeValue(forKey: backend)
        } else {
            byBackend[backend] = list
        }
        Self.save(byBackend)
    }

    private static func load() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ value: [String: [String]]) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Model picker with a brand star. Favorites pin to the top of the list.
///
/// Same capsule language as `AppMenuPicker`. The star is a toggle chip, not
/// a system control.
struct FavoriteModelPicker: View {
    var backendID: String
    var models: [String]
    var extra: String = ""
    @Binding var selection: String
    @State private var favorites = ModelFavoritesStore.shared

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.s) {
            AppMenuPicker(
                title: "Model",
                options: options,
                selection: $selection
            )
            .id(backendID)
            starButton
        }
        .onAppear { clampSelection() }
        .onChange(of: backendID) { _, _ in clampSelection() }
        .onChange(of: models) { _, _ in clampSelection() }
    }

    private var options: [(value: String, label: String)] {
        var ids = models
        let extraID = TodoCard.cleanModelID(extra)
        // Keep a stored alias this backend no longer lists. Do not carry a
        // leftover from the previous agent into the new list.
        if !extraID.isEmpty, !ids.contains(extraID), extraID == selection {
            ids.insert(extraID, at: 0)
        }
        let favs = favorites.ids(for: backendID).filter { ids.contains($0) }
        let rest = ids.filter { !favs.contains($0) }
        return [(value: "", label: "Default")]
            + favs.map { (value: $0, label: $0) }
            + rest.map { (value: $0, label: $0) }
    }

    private func clampSelection() {
        let extraID = TodoCard.cleanModelID(extra)
        if selection.isEmpty { return }
        if models.contains(selection) { return }
        if selection == extraID { return }
        selection = ""
    }

    private var isFavorite: Bool {
        favorites.contains(backend: backendID, model: selection)
    }

    private var starButton: some View {
        Button {
            favorites.toggle(backend: backendID, model: selection)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isFavorite ? Theme.accent : Theme.controlGlyph)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isFavorite ? Theme.accentSoft : Theme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isFavorite ? Theme.accent.opacity(0.35) : Theme.border,
                            lineWidth: 1
                        )
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(selection.isEmpty)
        .help(isFavorite ? "Remove from favorites" : "Pin this model to the top")
        .accessibilityLabel(isFavorite ? "Remove favorite" : "Add favorite")
    }
}

/// Where a task run goes: hidden automation, or an interactive terminal.
enum TaskRunPlacement: String, Hashable {
    case background
    case front
}

/// Run type, then a single Run button. Same control in the inspector and
/// the run sheet, so the two surfaces cannot drift apart.
struct TaskRunBar: View {
    var canRun: Bool
    var running: Bool
    var action: (TaskRunPlacement) -> Void

    @AppStorage("tasks.runPlacement") private var placementRaw = TaskRunPlacement.background.rawValue

    private var placement: Binding<TaskRunPlacement> {
        Binding(
            get: { TaskRunPlacement(rawValue: placementRaw) ?? .background },
            set: { placementRaw = $0.rawValue }
        )
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Space.s) { content }
            VStack(alignment: .leading, spacing: Theme.Space.s) { content }
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        SegmentedCapsulePicker(
            options: [
                (TaskRunPlacement.background, "Background", "bolt.fill"),
                (TaskRunPlacement.front, "In front", "terminal"),
            ],
            selection: placement
        )
        #endif
        Button(running ? "Starting…" : "Run") {
            #if os(macOS)
            action(placement.wrappedValue)
            #else
            action(.background)
            #endif
        }
        .buttonStyle(AccentButtonStyle())
        .disabled(!canRun || running)
        .help(
            placement.wrappedValue == .front
                ? "Open an interactive terminal. Not tracked as an automation."
                : "Start as an automation. The transcript shows on Automations."
        )
        .accessibilityLabel("Run")
    }
}
