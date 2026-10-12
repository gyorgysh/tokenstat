// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(iOS)
import Observation
import SwiftUI
import UIKit

@Observable @MainActor
final class ClientKeyboardPresence {
    static let shared = ClientKeyboardPresence()
    private(set) var isVisible = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
        ) { [weak self] note in
            let visible = ((note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue.height ?? 0) > 0
            Task { @MainActor [weak self] in self?.isVisible = visible }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isVisible = false }
        })
    }
}

/// Hide input without clearing a query, submitting a form or closing its sheet.
struct ClientKeyboardDismissButton: View {
    var body: some View {
        if ClientKeyboardPresence.shared.isVisible {
            Button(L10n.text("apple.clientchatcomposer.hide_keyboard.f6b0718e"), .hideKeyboard) {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .environment(\.compactActions, true)
            .buttonStyle(.plain)
            .font(Theme.fixed(18, weight: .medium))
            .foregroundStyle(Theme.accent)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .accessibilityIdentifier("keyboard.hide")
        }
    }
}
#endif
