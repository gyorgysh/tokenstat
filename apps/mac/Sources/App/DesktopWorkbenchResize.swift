// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import SwiftUI
import Observation

/// Live drag updates reach only the two layout leaves that need the width.
/// RootView and the stored chat/tool view values do not rebuild per pointer event.
@Observable final class DesktopWorkbenchResizeState {
    private(set) var liveWidth: Double?
    @ObservationIgnored private var origin: Double?
    var isDragging: Bool { liveWidth != nil }

    func width(preferred: Double, cap: Double) -> Double {
        min(max(DesktopWorkbenchLayout.toolMinimum, liveWidth ?? preferred), cap)
    }

    func drag(translation: Double, preferred: Double, cap: Double) {
        if origin == nil { origin = width(preferred: preferred, cap: cap) }
        let next = min(cap, max(DesktopWorkbenchLayout.toolMinimum, (origin ?? preferred) - translation))
        if liveWidth != next { liveWidth = next }
    }

    func finish() -> Double? {
        let result = liveWidth
        cancel()
        return result
    }

    func cancel() { origin = nil; liveWidth = nil }
}

struct DesktopWorkbenchSpace: View {
    let resize: DesktopWorkbenchResizeState
    let preferred: Double
    let cap: Double
    var body: some View {
        Color.clear.frame(width: resize.width(preferred: preferred, cap: cap) + DesktopWorkbenchLayout.divider)
    }
}

struct DesktopWorkbenchPanel<Content: View>: View {
    let resize: DesktopWorkbenchResizeState
    @Binding var preferred: Double
    let cap: Double
    let isVisible: Bool
    let content: Content

    init(resize: DesktopWorkbenchResizeState, preferred: Binding<Double>, cap: Double, isVisible: Bool,
         @ViewBuilder content: () -> Content) {
        self.resize = resize
        _preferred = preferred
        self.cap = cap
        self.isVisible = isVisible
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            DesktopWorkbenchDivider(resize: resize, preferred: $preferred, cap: cap, isVisible: isVisible)
            content.frame(width: resize.width(preferred: preferred, cap: cap))
        }
        .transaction { if resize.isDragging { $0.animation = nil; $0.disablesAnimations = true } }
        .onDisappear { resize.cancel() }
        .onChange(of: isVisible) { _, visible in if !visible { resize.cancel() } }
    }
}

private struct DesktopWorkbenchDivider: View {
    let resize: DesktopWorkbenchResizeState
    @Binding var preferred: Double
    let cap: Double
    let isVisible: Bool
    @State private var hovered = false

    var body: some View {
        Rectangle().fill(Theme.border).frame(width: 1)
            .frame(width: DesktopWorkbenchLayout.divider)
            .overlay {
                Color.clear.frame(width: 11)
                    .contentShape(.rect)
                    .background { ColumnResizeCursorArea(isActive: isVisible) }
                    .overlay {
                        Capsule().fill(Theme.accent.opacity(hovered || resize.isDragging ? 0.8 : 0))
                            .frame(width: 3, height: 36).allowsHitTesting(false)
                    }
                    .onHover { hovered = $0 }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { resize.drag(translation: $0.translation.width, preferred: preferred, cap: cap) }
                        .onEnded { _ in if let width = resize.finish() { preferred = width } })
                    .onTapGesture(count: 2) { resize.cancel(); preferred = min(520, cap) }
            }
            .help(L10n.text("apple.workbench.resize"))
            .accessibilityElement()
            .accessibilityLabel(L10n.text("apple.workbench.resize"))
            .accessibilityAdjustableAction { direction in
                preferred = min(cap, max(DesktopWorkbenchLayout.toolMinimum,
                    preferred + (direction == .increment ? 40 : -40)))
            }
    }
}
#endif
