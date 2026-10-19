// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SimulatorDevice.swift, SimulatorHardware.swift and SimulatorDeviceMesh.swift.
import Foundation
import simd

@main struct SimulatorHardwareTests {
    static func main() {
        func resolve(_ type: String, platform: SimulatorDevice.Platform = .ios, name: String = "Renamed QA device") -> SimulatorHardware {
            SimulatorHardware(device: SimulatorDevice(id: "00000000-0000-0000-0000-000000000001", name: name,
                runtime: "Test runtime", platform: platform, deviceType: type, isBooted: false))
        }
        let families: [(SimulatorHardware, [String])] = [
            (.iPhoneProPlateau, ["iPhone-17-Pro", "iPhone-17-Pro-Max", "iPhone-18-Pro", "iPhone-18-Pro-Max"]),
            (.iPhonePro, ["iPhone-11-Pro", "iPhone-12-Pro-Max", "iPhone-13-Pro", "iPhone-14-Pro-Max", "iPhone-15-Pro", "iPhone-16-Pro-Max"]),
            (.iPhoneDualVertical, ["iPhone-16", "iPhone-16-Plus", "iPhone-17", "iPhone-X", "iPhone-XS-Max"]),
            (.iPhoneDualSquare, ["iPhone-11", "iPhone-12-mini"]),
            (.iPhoneDualDiagonal, ["iPhone-13-mini", "iPhone-14-Plus", "iPhone-15"]),
            (.iPhoneSingle, ["iPhone-16e", "iPhone-17e", "iPhone-XR"]),
            (.iPhoneHome, ["iPhone-SE", "iPhone-SE--2nd-generation-", "iPhone-SE-3rd-generation", "iPhone-6s-Plus", "iPhone-8"]),
            (.iPhoneHomeDual, ["iPhone-7-Plus", "iPhone-8-Plus"]),
            (.iPhoneAir, ["iPhone-Air"]), (.iPhoneDuo, ["iPhone-Duo"]),
            (.iPadProThin, ["iPad-Pro-11-inch-M4-8GB", "iPad-Pro-13-inch-M4-16GB", "iPad-Pro-11-inch-M5-12GB"]),
            (.iPadProDual, ["iPad-Pro--11-inch---2nd-generation-", "iPad-Pro-11-inch-3rd-generation", "iPad-Pro-11-inch-4th-generation-16GB", "iPad-Pro--12-9-inch---4th-generation-", "iPad-Pro-12-9-inch-6th-generation-8GB"]),
            (.iPadPro, ["iPad-Pro--11-inch-", "iPad-Pro--12-9-inch---3rd-generation-"]),
            (.iPad, ["iPad-A16", "iPad-10th-generation", "iPad-Air--4th-generation-", "iPad-Air-5th-generation", "iPad-Air-13-inch-M2", "iPad-Air-11-inch-M4", "iPad-mini-6th-generation", "iPad-mini-A17-Pro"]),
            (.iPadHome, ["iPad--8th-generation-", "iPad-9th-generation", "iPad-Air-2", "iPad-Air--3rd-generation-", "iPad-mini-4", "iPad-mini--5th-generation-", "iPad-Pro--10-5-inch-"])
        ]
        for (family, types) in families {
            for type in types {
                for value in [type, "com.apple.CoreSimulator.SimDeviceType." + type] {
                    precondition(resolve(value) == family, "Wrong hardware family for \(value)")
                }
            }
        }
        precondition(resolve("iPhone-17-Pro", platform: .android) == .phone, "Android names must not select Apple hardware")
        precondition(resolve("Android-tablet", platform: .android) == .tablet)
        precondition(resolve("unknown", name: "iPhone 17 Pro Max") == .phone, "A user rename must not select hardware")
        precondition(resolve("iPhone-17", name: "iPad Pro") == .iPhoneDualVertical)
        precondition(resolve("iPad-Pro-13-inch-M5-16GB", name: "iPhone 17") == .iPadProThin)
        precondition(resolve("iPhone-Future") == .phone && resolve("iPad-Future") == .iPad)

        let counts: [(SimulatorHardware, Int)] = [(.iPhoneProPlateau, 3), (.iPhonePro, 3), (.iPhoneDualVertical, 2),
            (.iPhoneDualDiagonal, 2), (.iPhoneDualSquare, 2), (.iPhoneSingle, 1), (.iPhoneAir, 1), (.iPhoneDuo, 2),
            (.iPad, 1), (.iPadPro, 1), (.iPadProDual, 2), (.iPadProThin, 1)]
        for (hardware, count) in counts {
            let mesh = SimulatorDeviceMesh(aspect: hardware.isTablet ? 0.75 : 0.46, hardware: hardware)
            precondition(mesh.rearCameraCenters.count == count, "Wrong lens count for \(hardware)")
            precondition(mesh.rearCameraCenters.allSatisfy { $0.x > 0 && $0.z < -mesh.depth / 2 },
                         "Apple cameras must be raised on the left when viewed from behind")
        }
        let diagonal = SimulatorDeviceMesh(aspect: 0.46, hardware: .iPhoneDualDiagonal).rearCameraCenters
        let vertical = SimulatorDeviceMesh(aspect: 0.46, hardware: .iPhoneDualVertical).rearCameraCenters
        precondition(abs(diagonal[0].x - diagonal[1].x) > 0.15 && abs(vertical[0].x - vertical[1].x) < 0.001)
        precondition(SimulatorHardware.iPhoneAir.depth < SimulatorHardware.iPhoneProPlateau.depth * 0.7)
        precondition(SimulatorHardware.iPadProThin.depth < SimulatorHardware.iPad.depth * 0.8)
        for hardware in SimulatorHardware.allCases {
            for aspect: Float in [0.46, 0.75, 1.42] {
                for inner in hardware == .iPhoneDuo ? [false, true] : [false] {
                    let mesh = SimulatorDeviceMesh(aspect: aspect, hardware: hardware, innerDisplay: inner)
                    precondition(mesh.vertices.count % 3 == 0 && mesh.vertices.count < 100_000)
                    let bound = mesh.boundingRadius
                    precondition(mesh.vertices.allSatisfy { vertex in
                        let p = vertex.position, n = vertex.normal
                        return [p.x, p.y, p.z, n.x, n.y, n.z].allSatisfy(\.isFinite)
                            && abs(simd_length(SIMD3(n.x, n.y, n.z)) - 1) < 0.0001
                            && simd_length(SIMD3(p.x, p.y, p.z)) <= bound + 0.0001
                    }, "Invalid geometry or clipping at an orbit angle for \(hardware)")
                    let screen = mesh.vertices.filter { $0.texture.z == 1 }
                    precondition(!screen.isEmpty && screen.allSatisfy { (-0.0001...1.0001).contains($0.texture.x) && (-0.0001...1.0001).contains($0.texture.y) }, "Invalid live UVs for \(hardware), aspect \(aspect), inner \(inner)")
                    precondition(screen.contains { $0.texture.x < 0.001 } && screen.contains { $0.texture.x > 0.999 })
                    precondition(screen.contains { $0.texture.y < 0.001 } && screen.contains { $0.texture.y > 0.999 },
                                 "A hardware profile cropped the live framebuffer")
                }
            }
        }
        print("PASS: Apple hardware families, stable type selection, rear camera counts/layouts, full live UVs and solid orbit bounds")
    }
}
