// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Register the native scroll viewport as well as the outer chat pane.
/// An ancestor's drop modifier alone misses the AppKit scroll view's bounds.
/// This adds no view above the content, so text selection and controls keep
/// their ordinary mouse, keyboard and scrolling behavior.
extension View {
    func chatDropSurface(enabled: Bool, isTargeted: Binding<Bool>, receive: @escaping ([NSItemProvider]) -> Bool) -> some View {
        contentShape(Rectangle())
            .onDrop(of: ChatInbox.dropTypes, delegate: ChatPaneDropDelegate(enabled: enabled, isTargeted: isTargeted, receive: receive))
            .onChange(of: enabled) { _, enabled in if !enabled { isTargeted.wrappedValue = false } }
    }
}

private struct ChatPaneDropDelegate: DropDelegate {
    let enabled: Bool
    @Binding var isTargeted: Bool
    let receive: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool { enabled }
    func dropEntered(info: DropInfo) { isTargeted = enabled }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: enabled ? .copy : .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard enabled else { return false }
        return receive(info.itemProviders(for: ChatInbox.dropTypes))
    }
}
