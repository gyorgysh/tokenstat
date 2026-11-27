// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Observation
import SwiftUI

@MainActor @Observable
final class HandlePicker {
    enum State: Equatable {
        case empty
        case checking
        case available
        case refused(String)
        case unknown(String)
    }

    var text = "" {
        didSet { if text != oldValue { changed() } }
    }
    private(set) var state = State.empty
    private(set) var handle = ""

    @ObservationIgnored private let current: String?
    @ObservationIgnored private let check: @MainActor (String) async throws -> HandleCheck
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private let pause: Duration

    init(current: String? = nil,
         pause: Duration = .milliseconds(400),
         check: @escaping @MainActor (String) async throws -> HandleCheck) {
        self.current = current
        self.pause = pause
        self.check = check
    }

    var canClaim: Bool {
        switch state {
        case .available, .unknown: return !handle.isEmpty
        case .empty, .checking, .refused: return false
        }
    }

    func refuse(_ message: String) {
        pending?.cancel()
        state = .refused(message)
    }

    private func changed() {
        pending?.cancel()
        let next = HandleRules.normalized(text)
        handle = next
        guard !next.isEmpty else { state = .empty; return }
        if next == current { state = .refused(L10n.text("common.handle.current")); return }
        if let reason = HandleRules.localReason(next) {
            state = .refused(HandleRules.message(reason))
            return
        }
        state = .checking
        pending = Task { [weak self, pause, check] in
            do { try await Task.sleep(for: pause) } catch { return }
            do {
                let answer = try await check(next)
                guard !Task.isCancelled, let self, self.handle == next else { return }
                self.state = answer.available ? .available
                    : .refused(HandleRules.message(answer.reason, fallback: answer.message))
            } catch {
                guard !Task.isCancelled, let self, self.handle == next else { return }
                self.state = .unknown(L10n.text("common.handle.check_failed"))
            }
        }
    }
}

struct HandleField: View {
    @Bindable var picker: HandlePicker
    let host: String
    let disabled: Bool
    let onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 0) {
                Text(HandleRules.prefix(host: host))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityHidden(true)
                TextField(L10n.text("common.handle.placeholder"), text: $picker.text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    #endif
                    .onSubmit(onSubmit)
                    .disabled(disabled)
                    .accessibilityLabel(L10n.text("common.handle.field_label"))
                    .accessibilityIdentifier("handle.field")
            }
            .font(Theme.monoText(15, relativeTo: .body))
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: 44)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(border, lineWidth: focused ? 1.5 : 1)
            )
            .contentShape(.rect)
            .onTapGesture { focused = true }

            status
                .font(Theme.caption)
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("handle.status")
        }
        .onAppear { focused = true }
        .onChange(of: picker.state) { _, state in announce(state) }
    }

    private var border: Color {
        if case .refused = picker.state { return Theme.danger.opacity(0.6) }
        return focused ? Theme.accent : Theme.border
    }

    @ViewBuilder
    private var status: some View {
        switch picker.state {
        case .empty:
            Text(L10n.text("common.handle.hint", "\(HandleRules.minimum)"))
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                BusySpinner(size: .mini)
                Text(L10n.text("common.handle.checking")).foregroundStyle(.secondary)
            }
        case .available:
            line(L10n.text("common.handle.available"), "checkmark.circle.fill", Theme.diffAdded)
        case .refused(let message):
            line(message, "xmark.circle.fill", Theme.danger)
        case .unknown(let message):
            line(message, "exclamationmark.triangle.fill", Theme.warning)
        }
    }

    private func line(_ text: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
    }

    private func announce(_ state: HandlePicker.State) {
        let words: String
        switch state {
        case .available: words = L10n.text("common.handle.available")
        case .refused(let message), .unknown(let message): words = message
        case .empty, .checking: return
        }
        AccessibilityNotification.Announcement(words).post()
    }
}
