// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

extension AsciiScene {
    var title: String {
        switch id {
        case "dot-waves": L10n.text("common.chat_backdrop.dot_waves")
        case "dot-code": L10n.text("common.chat_backdrop.dot_code")
        default: id
        }
    }
}

struct ChatBackdropPicker: View {
    var comfortable = false
    private let appearance = AppAppearance.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("common.chat_backdrop.title")).font(Theme.headline)
            Text(L10n.text("common.chat_backdrop.detail"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: comfortable ? 132 : 112), spacing: Theme.Space.s)],
                      spacing: Theme.Space.s) {
                tile(nil)
                ForEach(AsciiScene.all) { scene in tile(scene) }
            }
        }
    }

    private func tile(_ scene: AsciiScene?) -> some View {
        let selected = appearance.chatBackdrop == scene?.id
        return Button {
            appearance.selectBackdrop(scene?.id)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Group {
                    if let scene {
                        AsciiBackdropView(scene: scene, palette: .current(scheme), paused: !selected, cellSize: 7, veil: 0, start: 24)
                    } else {
                        Theme.background
                            .overlay {
                                Image(systemName: "circle.slash")
                                    .font(Theme.font(16, weight: .regular))
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(height: comfortable ? 64 : 54)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
                HStack(spacing: Theme.Space.xs) {
                    Text(scene?.title ?? L10n.text("common.chat_backdrop.none"))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Theme.accent)
                            .accessibilityHidden(true)
                    }
                }
                .font(Theme.callout)
            }
            .padding(Theme.Space.s)
            .background(selected ? Theme.accentSoft : Theme.panel,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ChatBackdropMenu: View {
    private let appearance = AppAppearance.shared

    var body: some View {
        Menu {
            Picker(L10n.text("common.chat_backdrop.menu"), selection: Binding(
                get: { appearance.chatBackdrop ?? "" },
                set: { appearance.selectBackdrop($0.isEmpty ? nil : $0) }
            )) {
                Text(L10n.text("common.chat_backdrop.none")).tag("")
                ForEach(AsciiScene.all) { scene in
                    Text(scene.title).tag(scene.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            ActionIcon.theme.label(L10n.text("common.chat_backdrop.menu"))
        }
    }
}

struct ChatBackdropLayer: ViewModifier {
    var active: Bool
    var working: Bool
    var lane: CGFloat
    private let appearance = AppAppearance.shared
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if let scene = appearance.backdropScene {
            content
                .background {
                    AsciiBackdropView(scene: scene, palette: .current(scheme), working: working, paused: !active,
                                      lane: lane)
                        .ignoresSafeArea()
                }
        } else {
            content
        }
    }
}

extension View {
    func chatBackdrop(active: Bool, working: Bool, lane: CGFloat) -> some View {
        modifier(ChatBackdropLayer(active: active, working: working, lane: lane))
    }
}
