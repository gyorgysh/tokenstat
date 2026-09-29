// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with PersonaSoftBody.swift.
import Foundation

@main enum PersonaSoftBodyTests {
    static func main() {
        for variant in 0..<12 {
            var body = PersonaSoftBody()
            var drive = PersonaDrive()
            drive.morphAmount = 0.24
            drive.shapeStiffness *= 0.7 + CGFloat(variant) * 0.05
            for frame in 0..<7200 {
                let t = CGFloat(frame) / 120
                drive.morphPhase = t * 0.22 + CGFloat(variant)
                drive.roll = t * 1.25
                if frame % 360 == 0 { body.impulse(CGVector(dx: 0.1, dy: -0.5)) }
                body.step(dt: 1 / 120, drive: drive)
                for node in body.nodes {
                    precondition(node.p.x.isFinite && node.p.y.isFinite)
                    precondition(node.v.dx.isFinite && node.v.dy.isFinite)
                    precondition(node.p.x >= PersonaStage.leftRail && node.p.x <= PersonaStage.rightRail)
                    precondition(node.p.y >= PersonaStage.ceiling && node.p.y <= drive.floor)
                }
                precondition(body.bounds.width > 0.1 && body.bounds.height > 0.1)
            }
        }
        print("Persona soft body: 12 stiffness/phase variants, 60 seconds each, bounded while morphing and rolling")
    }
}
