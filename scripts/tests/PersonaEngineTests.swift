// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with PersonaEngine.swift, PersonaSoftBody.swift, PersonaMood.swift, PersonaTraits.swift.
import SwiftUI

// The engine uses theme colours only to derive identity and status ink.
enum Theme {
    static let accent = Color(red: 0.54, green: 0.36, blue: 0.96)
    static let secondary = Color(red: 0.91, green: 0.47, blue: 0.98)
    static let warning = Color(red: 0.88, green: 0.66, blue: 0.23)
    static let danger = Color(red: 0.84, green: 0.27, blue: 0.25)
}

@main enum PersonaEngineTests {
    static func main() {
        for seed: UInt64 in [0, 1, 3, 5, 7, 997, UInt64.max] {
            let engine = PersonaEngine(seed: seed)
            precondition(engine.traits.eyeCount == 2 && !engine.traits.hasAntenna)
            let identity = engine.traits.bodyShape
            let silhouette = engine.traits.lumps
            // No external force: the character must retain its own outline
            // without the asymmetric heart/tortilla manufacturing momentum.
            var restBody = PersonaSoftBody(lumps: silhouette)
            restBody.reset(centre: CGPoint(x: 0.5, y: 0.48), radius: 0.28)
            let restPose = restBody.nodes.map(\.p)
            var restDrive = PersonaDrive()
            restDrive.gravity = 0
            restDrive.radius = 0.28
            for _ in 0..<2400 { restBody.step(dt: 1 / 120, drive: restDrive) }
            for (node, original) in zip(restBody.nodes, restPose) {
                precondition(hypot(node.p.x - original.x, node.p.y - original.y) < 1e-5,
                             "Fixed silhouettes must not drift or round into another shape")
            }
            var time = 0.0
            engine.advance(to: time, mood: .idle, moving: true)
            for from in PersonaMood.allCases {
                for to in PersonaMood.allCases {
                    engine.advance(to: time, mood: from, moving: true)
                    for _ in 0..<45 {
                        let before = engine.body.nodes.map(\.p)
                        time += 1.0 / 60
                        engine.advance(to: time, mood: to, moving: true)
                        precondition(engine.traits.bodyShape == identity && engine.traits.lumps == silhouette)
                        precondition(engine.roll.isFinite && engine.yaw.isFinite)
                        for (node, previous) in zip(engine.body.nodes, before) {
                            precondition(node.p.x.isFinite && node.p.y.isFinite)
                            precondition(node.p.x >= PersonaStage.leftRail && node.p.x <= PersonaStage.rightRail)
                            precondition(node.p.y >= PersonaStage.ceiling && node.p.y <= PersonaStage.floor)
                            precondition(hypot(node.p.x - previous.x, node.p.y - previous.y) < 0.3,
                                "Mood transition must carry position continuously")
                        }
                    }
                }
            }
            let frozen = engine.body.nodes.map(\.p)
            engine.suspendClock()
            time += 3600
            engine.advance(to: time, mood: engine.mood, moving: true)
            precondition(engine.body.nodes.map(\.p) == frozen, "Resume must not catch up through a long suspension")
            engine.advance(to: time, mood: .idle, moving: false)
            precondition(engine.roll == 0 && engine.yaw == 0)
            let settled = engine.body.nodes.map(\.p)
            engine.advance(to: time + 1, mood: .idle, moving: false)
            precondition(engine.body.nodes.map(\.p) == settled, "Reduce Motion must remain still")
        }
        print("Persona engine: every mood pair across all four plush shapes, suspension and Reduce Motion pass")
    }
}
