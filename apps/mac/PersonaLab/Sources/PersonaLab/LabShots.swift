// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import AppKit
import SwiftUI

/// Render filmstrips to a PNG instead of opening a window.
///
/// A motion problem is hard to argue about in prose and slow to check by
/// launching a window and watching. A strip of frames, one row per mood, is
/// something you can look at, diff against the last attempt, and point at.
///
///   swift run --package-path apps/mac/PersonaLab PersonaLab --shots out.png
@MainActor
enum LabShots {
    struct Plan {
        var size: CGFloat = 132
        /// How big the frame is drawn, when that is not how big the mark is.
        /// Rendering at 18 and drawing at 132 is the only honest way to check
        /// a size that is too small to look at.
        var cell: CGFloat?
        var columns = 8
        var span: Double = 2.0
        var dark = true
        var seed: UInt64 = 0x51ED_2764_A11C_0001
    }

    static func run(arguments: [String]) -> Bool {
        if let pair = value(after: "--shift", in: arguments) {
            let names = pair.split(separator: ",").map(String.init)
            let moods = names.compactMap { name in
                PersonaMood.allCases.first { String(describing: $0) == name }
            }
            guard moods.count == 2 else {
                print("--shift wants two mood names, e.g. reading,gaming")
                return true
            }
            var plan = Plan()
            if let value = value(after: "--size", in: arguments), let size = Double(value) {
                plan.size = size
            }
            if let value = value(after: "--cell", in: arguments), let cell = Double(value) {
                plan.cell = cell
            }
            if let value = value(after: "--span", in: arguments), let span = Double(value) {
                plan.span = span
            }
            if let value = value(after: "--columns", in: arguments), let columns = Int(value) {
                plan.columns = columns
            }
            let path = arguments.firstIndex(of: "--shots").map { index in
                index + 1 < arguments.count ? arguments[index + 1] : "persona-shift.png"
            } ?? "persona-shift.png"
            write(shift(plan: plan, from: moods[0], to: moods[1]), to: path)
            return true
        }
        if arguments.contains("--bench") {
            for mood in PersonaMood.allCases {
                let result = LabBench.run(bodies: 120, seconds: 10, mood: mood)
                print("\(String(describing: mood).padding(toLength: 10, withPad: " ", startingAt: 0))  \(result.summary)")
            }
            return true
        }
        if let mood = value(after: "--probe", in: arguments) {
            probe(mood: mood, arguments: arguments)
            return true
        }
        guard let index = arguments.firstIndex(of: "--shots") else { return false }
        var plan = Plan()
        let path = index + 1 < arguments.count ? arguments[index + 1] : "persona-shots.png"
        if let value = value(after: "--seed", in: arguments), let seed = UInt64(value) {
            plan.seed = seed
        }
        if let value = value(after: "--size", in: arguments), let size = Double(value) {
            plan.size = size
        }
        if let value = value(after: "--span", in: arguments), let span = Double(value) {
            plan.span = span
        }
        if let value = value(after: "--cell", in: arguments), let cell = Double(value) {
            plan.cell = cell
        }
        if arguments.contains("--light") {
            plan.dark = false
        }
        if arguments.contains("--cast"), let name = value(after: "--mood", in: arguments),
           let mood = PersonaMood.allCases.first(where: { String(describing: $0) == name }) {
            write(cast(plan: plan, mood: mood), to: path)
            return true
        }
        if let moods = value(after: "--mood", in: arguments) {
            let wanted = moods.split(separator: ",").map(String.init)
            write(strip(plan: plan, moods: PersonaMood.allCases.filter { wanted.contains(String(describing: $0)) }), to: path)
        } else {
            write(strip(plan: plan, moods: PersonaMood.allCases), to: path)
        }
        return true
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func strip(plan: Plan, moods: [PersonaMood]) -> NSImage {
        let cell = plan.cell ?? plan.size
        let label: CGFloat = 22
        let width = cell * CGFloat(plan.columns)
        let height = (cell + label) * CGFloat(moods.count)
        let image = NSImage(size: CGSize(width: width, height: height))

        let appearance = NSAppearance(named: plan.dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            let background = plan.dark
                ? NSColor(red: 0.09, green: 0.08, blue: 0.12, alpha: 1)
                : NSColor(red: 0.97, green: 0.96, blue: 0.99, alpha: 1)
            background.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()

            for (row, mood) in moods.enumerated() {
                let engine = PersonaEngine(seed: plan.seed, mood: mood)
                engine.advance(to: 0, mood: mood, moving: true)
                let top = CGFloat(row) * (cell + label)

                (plan.dark ? NSColor.white : NSColor.black).withAlphaComponent(0.55).set()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: (plan.dark ? NSColor.white : NSColor.black).withAlphaComponent(0.65)
                ]
                // AppKit's origin is bottom left; rows are laid out from the top.
                (String(describing: mood) as NSString).draw(
                    at: CGPoint(x: 8, y: height - top - label + 4),
                    withAttributes: attributes
                )

                for column in 0..<plan.columns {
                    let time = plan.span * Double(column) / Double(max(plan.columns - 1, 1))
                    advance(engine, to: time, mood: mood)
                    guard let frame = render(engine: engine, mood: mood, size: plan.size) else { continue }
                    frame.draw(
                        in: NSRect(
                            x: CGFloat(column) * cell,
                            y: height - top - label - cell,
                            width: cell,
                            height: cell
                        )
                    )
                }
            }
            image.unlockFocus()
        }
        return image
    }

    /// Step in real 60fps increments up to the sample instant, so what is
    /// drawn is what the app would have drawn at that moment rather than one
    /// enormous jump the fixed-step cap would have thrown away.
    private static func advance(_ engine: PersonaEngine, to time: Double, mood: PersonaMood) {
        var now = engine.sampledTime
        while now < time - 1e-9 {
            now = min(now + 1.0 / 60, time)
            engine.advance(to: now, mood: mood, moving: true)
        }
    }

    private static func render(engine: PersonaEngine, mood: PersonaMood, size: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(
            content: LabShotFrame(engine: engine, size: size)
        )
        renderer.scale = 2
        return renderer.nsImage
    }

    private static func write(_ image: NSImage, to path: String) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("could not encode the strip\n".utf8))
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        } catch {
            FileHandle.standardError.write(Data("could not write \(path): \(error)\n".utf8))
        }
    }
}

/// One frame of one character, with no time in it: the engine has already
/// been advanced, and this only paints what it is holding.
private struct LabShotFrame: View {
    let engine: PersonaEngine
    let size: CGFloat

    var body: some View {
        Canvas { canvas, canvasSize in
            var canvas = canvas
            PersonaRenderer.draw(engine, in: &canvas, rect: CGRect(origin: .zero, size: canvasSize))
        }
        .frame(width: size, height: size)
    }
}


extension LabShots {
    /// One row per seed, so the cast can be compared doing the same thing.
    static func cast(plan: Plan, mood: PersonaMood) -> NSImage {
        var seeds: [UInt64] = []
        var bits = plan.seed
        for _ in 0..<8 {
            bits = bits &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            seeds.append(bits | 1)
        }
        let cell = plan.cell ?? plan.size
        let width = cell * CGFloat(plan.columns)
        let height = cell * CGFloat(seeds.count)
        let image = NSImage(size: CGSize(width: width, height: height))
        let appearance = NSAppearance(named: plan.dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            (plan.dark
                ? NSColor(red: 0.09, green: 0.08, blue: 0.12, alpha: 1)
                : NSColor(red: 0.97, green: 0.96, blue: 0.99, alpha: 1)).setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            for (row, seed) in seeds.enumerated() {
                let engine = PersonaEngine(seed: seed, mood: mood)
                engine.advance(to: 0, mood: mood, moving: true)
                for column in 0..<plan.columns {
                    let time = plan.span * Double(column) / Double(max(plan.columns - 1, 1))
                    advance(engine, to: time, mood: mood)
                    guard let frame = render(engine: engine, mood: mood, size: plan.size) else { continue }
                    frame.draw(in: NSRect(
                        x: CGFloat(column) * cell,
                        y: height - CGFloat(row + 1) * cell,
                        width: cell,
                        height: cell
                    ))
                }
            }
            image.unlockFocus()
        }
        return image
    }

    /// Numbers, for when a shape is wrong and the picture cannot say why.
    static func probe(mood name: String, arguments: [String]) {
        guard let mood = PersonaMood.allCases.first(where: { String(describing: $0) == name }) else {
            print("no mood called \(name)")
            return
        }
        let span = value(after: "--span", in: arguments).flatMap(Double.init) ?? 3.0
        let engine = PersonaEngine(seed: 0x51ED_2764_A11C_0001, mood: mood)
        engine.advance(to: 0, mood: mood, moving: true)
        print("t      x      y      w      h      energy")
        var now = 0.0
        var nextReport = 0.0
        while now < span {
            now += 1.0 / 60
            engine.advance(to: now, mood: mood, moving: true)
            guard now >= nextReport else { continue }
            nextReport += 0.1
            let bounds = engine.body.bounds
            print(String(
                format: "%5.2f  %.3f  %.3f  %.3f  %.3f  %.4f",
                now, bounds.midX, bounds.midY, bounds.width, bounds.height, engine.energy
            ))
        }
    }
}


extension LabShots {
    /// One mood turning into another, frame by frame.
    ///
    /// The change is the thing being looked at here, so the strip runs at the
    /// frame rate rather than at reading speed: half a second across the whole
    /// row, which is exactly the length of a shift.
    static func shift(plan: Plan, from: PersonaMood, to: PersonaMood) -> NSImage {
        let cell = plan.cell ?? plan.size
        let width = cell * CGFloat(plan.columns)
        let image = NSImage(size: CGSize(width: width, height: cell))
        let appearance = NSAppearance(named: plan.dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            (plan.dark
                ? NSColor(red: 0.09, green: 0.08, blue: 0.12, alpha: 1)
                : NSColor(red: 0.97, green: 0.96, blue: 0.99, alpha: 1)).setFill()
            NSRect(x: 0, y: 0, width: width, height: cell).fill()

            let engine = PersonaEngine(seed: plan.seed, mood: from)
            engine.advance(to: 0, mood: from, moving: true)
            // Settle into the outgoing mood first, so what the strip shows is
            // a change and not a start.
            advance(engine, to: 3.0, mood: from)
            let began = engine.sampledTime

            for column in 0..<plan.columns {
                let time = began + plan.span * Double(column) / Double(max(plan.columns - 1, 1))
                var now = engine.sampledTime
                while now < time - 1e-9 {
                    now = min(now + 1.0 / 60, time)
                    engine.advance(to: now, mood: to, moving: true)
                }
                guard let frame = render(engine: engine, mood: to, size: plan.size) else { continue }
                frame.draw(in: NSRect(x: CGFloat(column) * cell, y: 0, width: cell, height: cell))
            }
            image.unlockFocus()
        }
        return image
    }
}
