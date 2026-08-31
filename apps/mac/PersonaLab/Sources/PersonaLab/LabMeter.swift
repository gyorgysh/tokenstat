// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Frames actually delivered, and how long the longest one took.
///
/// Drawn inside a `Canvas` rather than published to SwiftUI, for the same
/// reason the engine is: a meter that invalidates a view sixty times a second
/// is measuring itself.
struct LabFrameMeter: View {
    private final class Samples {
        var times: [TimeInterval] = []
        var worst: Double = 0
        var shown = (fps: 0.0, worst: 0.0)
        var lastReport: TimeInterval = 0

        func record(_ now: TimeInterval) {
            if let last = times.last {
                worst = max(worst, (now - last) * 1000)
            }
            times.append(now)
            times.removeAll { now - $0 > 1 }
            if now - lastReport > 0.4 {
                lastReport = now
                shown = (Double(times.count), worst)
                worst = 0
            }
        }
    }

    @State private var samples = Samples()

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, size in
                samples.record(context.date.timeIntervalSinceReferenceDate)
                let text = Text(
                    String(
                        format: "%.0f fps   worst frame %.1f ms",
                        samples.shown.fps,
                        samples.shown.worst
                    )
                )
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(samples.shown.worst > 20 ? Theme.danger : .secondary)
                canvas.draw(text, at: CGPoint(x: 0, y: size.height / 2), anchor: .leading)
            }
        }
        .frame(height: 18)
    }
}

/// A straight measurement of the simulation on its own, with no drawing in it.
///
/// The honest number for "is this resource heavy": how long it takes to step
/// N bodies for one second of animation. Drawing is measured by the frame
/// meter above, running against the stress grid.
enum LabBench {
    struct Result {
        var bodies: Int
        var seconds: Double
        var milliseconds: Double

        var perBodyFrame: Double {
            // One simulated second is 120 fixed steps, presented as 60 frames.
            milliseconds / Double(bodies) / 60
        }

        var summary: String {
            String(
                format: "%d bodies × %.0fs of motion: %.1f ms total, %.4f ms per body per frame",
                bodies,
                seconds,
                milliseconds,
                perBodyFrame
            )
        }
    }

    static func run(bodies: Int, seconds: Double, mood: PersonaMood) -> Result {
        var engines: [PersonaEngine] = []
        engines.reserveCapacity(bodies)
        for index in 0..<bodies {
            engines.append(PersonaEngine(seed: UInt64(index &* 2_654_435_761 &+ 7), mood: mood))
        }
        // Prime, so the first frame's settle is not in the measurement.
        for engine in engines {
            engine.advance(to: 0, mood: mood, moving: true)
        }

        let frames = Int(seconds * 60)
        let started = DispatchTime.now().uptimeNanoseconds
        for frame in 1...frames {
            let time = Double(frame) / 60
            for engine in engines {
                engine.advance(to: time, mood: mood, moving: true)
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return Result(bodies: bodies, seconds: seconds, milliseconds: elapsed)
    }
}

/// The mark as somebody with Reduce Motion on sees it.
///
/// `PersonaMark` reads the accessibility setting from the environment, which
/// the lab cannot write, so this drives the same engine and the same renderer
/// with motion off. It is the resting pose of the mood, which is what the app
/// shows in that case: a settled character, not a frozen frame.
struct LabStillMark: View {
    var seed: UInt64
    var size: CGFloat
    var state: PersonaMood

    var body: some View {
        Canvas { canvas, canvasSize in
            let engine = PersonaEngine(seed: seed, mood: state)
            engine.advance(to: 0, mood: state, moving: false)
            var canvas = canvas
            PersonaRenderer.draw(engine, in: &canvas, rect: CGRect(origin: .zero, size: canvasSize))
        }
        .frame(width: size, height: size)
    }
}
