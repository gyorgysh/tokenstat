// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

final class AsciiClock {
    private(set) var time: Double
    private var last: Date?

    init(_ time: Double = 0) { self.time = time }

    func advance(to date: Date, rate: Double) -> Double {
        if let last {
            time += min(max(date.timeIntervalSince(last), 0), 0.25) * rate
        }
        last = date
        return time
    }

    func rest() { last = nil }
}

struct AsciiBackdropView: View {
    let scene: AsciiScene
    let palette: AsciiPalette
    var working = false
    var paused = false
    var lane: CGFloat?
    var cellSize: CGFloat = 14
    var speed: Double = 1
    var veil: Double = 0.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @State private var clock: AsciiClock

    init(scene: AsciiScene, palette: AsciiPalette, working: Bool = false, paused: Bool = false, lane: CGFloat? = nil,
         cellSize: CGFloat = 14, speed: Double = 1, veil: Double = 0.4, start: Double = 12) {
        self.scene = scene
        self.palette = palette
        self.working = working
        self.paused = paused
        self.lane = lane
        self.cellSize = cellSize
        self.speed = speed
        self.veil = veil
        _clock = State(initialValue: AsciiClock(start))
    }

    var body: some View {
        let still = paused || reduceMotion || phase != .active
        ZStack {
            AsciiColor.color(palette.bg)
            GeometryReader { geometry in
                RadialGradient(colors: [AsciiColor.color(palette.accent).opacity(palette.glowStrength), .clear],
                               center: UnitPoint(x: 0.5, y: 1.05), startRadius: 0,
                               endRadius: max(geometry.size.width, geometry.size.height) * 0.9)
            }
            TimelineView(.animation(minimumInterval: 1 / 15, paused: still)) { context in
                let t = still ? clock.time : clock.advance(to: context.date, rate: speed * (working ? 3 : 1))
                Canvas(rendersAsynchronously: true) { graphics, size in
                    var sink = AsciiGraphicsSink(context: graphics, cell: effectiveCell, light: palette.light)
                    AsciiRenderer.draw(scene, palette: palette, into: &sink, size: size, time: t, cell: effectiveCell,
                                       veil: veil, lane: lane)
                }
            }
        }
        .onChange(of: still) { _, now in if now { clock.rest() } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var effectiveCell: CGFloat { cellSize }
}

protocol AsciiSink {
    mutating func glow(center: CGPoint, radius: CGFloat, color: UInt32, alpha: Double)
    mutating func cell(x: CGFloat, y: CGFloat, value: AsciiCell)
    mutating func veil(left: CGFloat, right: CGFloat, height: CGFloat, color: UInt32, edge: CGFloat, alpha: Double)
}

struct AsciiGraphicsSink: AsciiSink {
    var context: GraphicsContext
    let cell: CGFloat
    let light: Bool
    private let disc: Path
    private let font: Font
    private var glyphs: [GlyphKey: GraphicsContext.ResolvedText] = [:]
    private var colors: [UInt32: Color] = [:]

    private struct GlyphKey: Hashable {
        let ch: Character
        let fg: UInt32
    }

    init(context: GraphicsContext, cell: CGFloat, light: Bool) {
        self.context = context
        self.cell = cell
        self.light = light
        let inset = cell * 0.12
        disc = Path(ellipseIn: CGRect(x: inset, y: inset, width: cell - inset * 2, height: cell - inset * 2))
        font = .system(size: (cell * 0.66).rounded(), weight: .semibold, design: .monospaced)
    }

    private mutating func color(_ value: UInt32) -> Color {
        if let cached = colors[value] { return cached }
        let made = AsciiColor.color(value)
        colors[value] = made
        return made
    }

    mutating func glow(center: CGPoint, radius: CGFloat, color value: UInt32, alpha: Double) {
        let base = color(value)
        var layer = context
        layer.opacity = min(1, alpha)
        layer.blendMode = light ? .normal : .screen
        layer.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                   with: .radialGradient(Gradient(colors: [base, base.opacity(0)]), center: center,
                                         startRadius: 0, endRadius: radius))
    }

    mutating func cell(x: CGFloat, y: CGFloat, value: AsciiCell) {
        context.opacity = value.a
        if let dot = value.dot {
            if value.size >= 1 {
                context.fill(disc.offsetBy(dx: x, dy: y), with: .color(color(dot)))
            } else {
                let d = (cell * 0.76) * value.size
                context.fill(Path(ellipseIn: CGRect(x: x + (cell - d) / 2, y: y + (cell - d) / 2, width: d, height: d)),
                             with: .color(color(dot)))
            }
        }
        guard value.ch != " " else { return }
        let key = GlyphKey(ch: value.ch, fg: value.fg)
        let text: GraphicsContext.ResolvedText
        if let cached = glyphs[key] {
            text = cached
        } else {
            text = context.resolve(Text(String(value.ch)).font(font).foregroundColor(color(value.fg)))
            glyphs[key] = text
        }
        context.draw(text, at: CGPoint(x: x + cell / 2, y: y + cell / 2), anchor: .center)
    }

    mutating func veil(left: CGFloat, right: CGFloat, height: CGFloat, color value: UInt32, edge: CGFloat, alpha: Double) {
        let base = color(value)
        context.opacity = alpha
        context.fill(Path(CGRect(x: left, y: 0, width: right - left, height: height)),
                     with: .linearGradient(Gradient(stops: [
                        .init(color: base.opacity(0), location: 0), .init(color: base, location: edge),
                        .init(color: base, location: 1 - edge), .init(color: base.opacity(0), location: 1),
                     ]), startPoint: CGPoint(x: left, y: 0), endPoint: CGPoint(x: right, y: 0)))
    }
}

enum AsciiRenderer {
    static func draw<Sink: AsciiSink>(_ scene: AsciiScene, palette: AsciiPalette, into sink: inout Sink, size: CGSize,
                                      time: Double, cell: CGFloat, veil: Double, lane: CGFloat?) {
        let w = size.width, h = size.height
        let cols = Int((w / cell).rounded(.up)), rows = Int((h / cell).rounded(.up))
        guard cols > 0, rows > 0 else { return }

        func put(_ px: CGFloat, _ py: CGFloat, _ c: AsciiCell) {
            guard c.a >= 0.02 else { return }
            var value = c
            value.a = min(1, c.a)
            sink.cell(x: px, y: py, value: value)
        }

        if let cellAt = scene.cell {
            for y in 0..<rows {
                for x in 0..<cols {
                    if let c = cellAt(x, y, cols, rows, time, palette) { put(CGFloat(x) * cell, CGFloat(y) * cell, c) }
                }
            }
        }

        for s in scene.sprites?(cols, rows, time, palette) ?? [] {
            let gx0 = s.x.rounded(), gy0 = s.y.rounded()
            if gx0 > Double(cols + 2) || gy0 > Double(rows + 2)
                || gx0 + Double(s.art.width) < -2 || gy0 + Double(s.art.height) < -2 { continue }
            if let g = s.glow {
                sink.glow(center: CGPoint(x: (gx0 + Double(s.art.width) / 2) * Double(cell),
                                          y: (gy0 + Double(s.art.height) / 2) * Double(cell)),
                          radius: g.r * cell, color: g.color, alpha: g.a)
            }
            for (gy, row) in s.art.rows.enumerated() {
                for (gx, key) in row.enumerated() {
                    guard let value = s.pal[key] else { continue }
                    put(CGFloat(gx0 + Double(gx)) * cell, CGFloat(gy0 + Double(gy)) * cell,
                        s.a == 1 ? value : value.faded(s.a))
                }
            }
        }

        if let lane, veil > 0 {
            let width = min(lane, w)
            let l = (w - width) / 2 - cell * 2, r = (w + width) / 2 + cell * 2
            sink.veil(left: l, right: r, height: h, color: palette.bg, edge: cell / (r - l), alpha: veil)
        }
    }
}
