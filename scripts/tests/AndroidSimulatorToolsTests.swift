// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with AndroidSimulatorTools.swift, SimulatorDevice.swift, SimulatorCommand.swift.
import Foundation

@main struct AndroidSimulatorToolsTests {
    static func main() async throws {
        for name in ["Phone_API_36", "tablet.qa-1"] { precondition(AndroidSimulatorTools.validAVD(name)) }
        for name in ["", ".", "..", "../outside", "phone;command", "$(command)", "a b", "世界"] {
            precondition(!AndroidSimulatorTools.validAVD(name), "Invalid AVD name accepted")
        }
        let output = """
        List of devices attached
        emulator-5554 device
        emulator-5556 offline
        physical-device device
        emulator-5558 unauthorized
        emulator-5560 device product:generic
        """
        precondition(AndroidSimulatorTools.emulatorSerials(output) == ["emulator-5554", "emulator-5560"])
        precondition(AndroidSimulatorTools.naturalLandscape("Physical size: 1080x2424\n") == false)
        precondition(AndroidSimulatorTools.naturalLandscape("Physical size: 2560x1600\n") == true)
        precondition(AndroidSimulatorTools.naturalLandscape("Physical size: 2560x1600\nOverride size: 800x1280\n") == false)
        precondition(AndroidSimulatorTools.naturalLandscape("Physical size: 0x0") == nil)
        precondition(AndroidSimulatorTools.naturalLandscape("unknown") == nil)
        precondition((1...4).map { AndroidSimulatorTools.rotation($0, naturalLandscape: false) } == [0,2,1,3])
        precondition((1...4).map { AndroidSimulatorTools.rotation($0, naturalLandscape: true) } == [1,3,2,0],
                     "Landscape-native tablets must still offer real portrait orientation")
        for value in ["hello", "apostrophe's", "$(echo command); `echo more`", "a\nb", "Unicode 世界"] {
            let result = try await SimulatorCommand.run("/bin/sh", ["-c", "printf %s " + AndroidSimulatorTools.quote(value)])
            precondition(result.status == 0 && String(decoding: result.data, as: UTF8.self) == value,
                         "ADB remote shell quoting changed text or executed it")
        }
        let valid = URL(string: "tokenstat://simulator/attach?device=android%3APhone_API_36&workspace=project")!
        precondition(SimulatorAttachRequest(url: valid)?.deviceID == "android:Phone_API_36")
        for name in ["..%2Foutside", "a%20b", "%24%28command%29"] {
            precondition(SimulatorAttachRequest(url: URL(string: "tokenstat://simulator/attach?device=android%3A" + name)!) == nil)
        }
        print("PASS: Android emulator identities, AVD validation, scoped attach and remote shell quoting")
    }
}
