// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// This machine in the middle, everything linked to it around the outside.
///
/// The Devices screen is entirely about what can reach what, and it answered
/// that with three stacked lists of identifiers. A person setting up their
/// second computer wants to see the pair, so here is the pair: one tile each,
/// a line between them, and the line says whether it is live.
///
/// Deliberately fixed: positions come from the index, nothing is dragged, and
/// nothing animates into place. It is a diagram, not a canvas.
struct DeviceHub: View {
    struct Node: Identifiable {
        var id: String
        var name: String
        /// SF Symbol, chosen by the caller because only it knows a phone from
        /// a desktop.
        var symbol: String
        /// nil where presence was never established, which draws the same as
        /// offline but says so differently.
        var online: Bool?
        /// Dialled from here, so its workspaces are in the sidebar.
        var connected: Bool = false
    }

    var centre: Node
    var others: [Node]
    /// Tiles drawn before the rest collapses into a count.
    var maxOthers: Int = 7
    var tile: CGFloat = 44

    private var shown: [Node] {
        others.count > maxOthers ? Array(others.prefix(maxOthers - 1)) : others
    }

    private var hidden: Int {
        max(0, others.count - shown.count)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let middle = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - tile / 2 - 10
            ZStack {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, node in
                    let point = position(index: index, count: shown.count + (hidden > 0 ? 1 : 0), middle: middle, radius: radius)
                    line(from: middle, to: point, node: node)
                }
                tileView(centre, emphasis: true)
                    .position(middle)
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, node in
                    tileView(node, emphasis: false)
                        .position(position(index: index, count: shown.count + (hidden > 0 ? 1 : 0), middle: middle, radius: radius))
                }
                if hidden > 0 {
                    overflow
                        .position(position(index: shown.count, count: shown.count + 1, middle: middle, radius: radius))
                }
            }
        }
        .frame(height: others.isEmpty ? tile + 34 : 190)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    /// Even spacing around the circle, first tile at the top.
    private func position(index: Int, count: Int, middle: CGPoint, radius: CGFloat) -> CGPoint {
        guard count > 0, radius > 0 else { return middle }
        let angle = Double(index) / Double(count) * 2 * .pi - .pi / 2
        return CGPoint(x: middle.x + radius * cos(angle), y: middle.y + radius * sin(angle))
    }

    /// A live link is drawn, a dead one is dashed. The line carries the state
    /// that a row of grey words used to.
    private func line(from: CGPoint, to: CGPoint, node: Node) -> some View {
        Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
        .stroke(
            node.connected ? Theme.accent.opacity(0.8) : Theme.border,
            style: StrokeStyle(
                lineWidth: node.connected ? 2 : 1,
                dash: node.online == true ? [] : [3, 3]
            )
        )
    }

    private func tileView(_ node: Node, emphasis: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(emphasis ? Theme.accent.opacity(0.16) : Theme.panel)
                Circle()
                    .strokeBorder(emphasis ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: 1)
                Image(systemName: node.symbol)
                    .font(.system(size: tile * 0.42))
                    .foregroundStyle(emphasis ? Theme.accent : .secondary)
            }
            .frame(width: tile, height: tile)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(dot(for: node))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 1.5))
            }
            Text(node.name)
                .font(.caption2)
                .foregroundStyle(emphasis ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: tile * 1.9)
        }
        .opacity(node.online == false && !emphasis ? 0.6 : 1)
        .help(node.name)
    }

    private var overflow: some View {
        Text("+\(hidden)")
            .font(Theme.numeric(12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: tile, height: tile)
            .background(Circle().fill(Theme.panel))
            .overlay(Circle().strokeBorder(Theme.border))
    }

    private func dot(for node: Node) -> Color {
        switch node.online {
        case .some(true): return node.connected ? Theme.accent : Theme.success
        case .some(false): return Theme.stateIdle
        case .none: return Theme.warning
        }
    }

    private var summary: String {
        let online = others.filter { $0.online == true }.count
        let linked = others.filter(\.connected).count
        if others.isEmpty { return "\(centre.name). No other devices linked yet." }
        return "\(centre.name), linked to \(others.count) devices. \(online) reachable, \(linked) connected now."
    }
}
