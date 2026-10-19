// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SimulatorDevice.swift using swiftc -parse-as-library, then run.
import Foundation
import CoreGraphics

@main struct SimulatorDeviceTests {
    static func main() throws {
        let first = "00000000-0000-0000-0000-000000000001"
        let second = "00000000-0000-0000-0000-000000000002"
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
          {"udid":"\(first)","name":"QA phone; $(command)","state":"Shutdown","isAvailable":true,"deviceTypeIdentifier":"iPhone-Duo"},
          {"udid":"\(second)","name":"QA tablet","state":"Booted","isAvailable":true,"deviceTypeIdentifier":"iPad"},
          {"udid":"invalid","name":"Invalid","state":"Booted","isAvailable":true},
          {"udid":"00000000-0000-0000-0000-000000000003","name":"Unavailable","state":"Shutdown","isAvailable":false}],
          "com.apple.CoreSimulator.SimRuntime.watchOS-27-0":[
          {"udid":"00000000-0000-0000-0000-000000000004","name":"Watch","state":"Booted","isAvailable":true}]}}
        """
        let devices = try SimulatorDevice.appleInventory(Data(json.utf8))
        precondition(devices.count == 2 && devices.first?.id == second)
        precondition(devices[0].isTablet && devices[1].isFoldable)
        precondition(SimulatorDevice.preferred(in: devices, saved: first)?.id == first)
        precondition(SimulatorDevice.preferred(in: devices, saved: "deleted")?.id == second)
        precondition(devices[0].runtime == "iOS 27.0")
        precondition(SimulatorDevice.preferred(in: [], saved: first) == nil)
        let empty = try SimulatorDevice.appleInventory(Data("{\"devices\":{}}".utf8))
        precondition(empty.isEmpty)
        let starting = try SimulatorDevice.appleInventory(Data("{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-27-0\":[{\"udid\":\"\(first)\",\"name\":\"Starting phone\",\"state\":\"Booting\",\"isAvailable\":true}]}}".utf8))
        precondition(starting.first?.isBooting == true && starting.first?.isBooted == false && starting.first?.isRunning == true,
                     "An agent-started device must be attachable while it finishes booting")
        do { _ = try SimulatorDevice.appleInventory(Data("garbage".utf8)); preconditionFailure("Malformed inventory was accepted") } catch { }
        let valid = URL(string: "tokenstat://simulator/attach?device=\(first)&workspace=project")!
        precondition(SimulatorAttachRequest(url: valid)?.deviceID == first)
        precondition(SimulatorAttachRequest(url: valid)?.workspaceID == "project")
        let spaced = URL(string: "tokenstat://simulator/attach?device=\(first)&workspace=%2Fworkspace%2Fproject+app")!
        precondition(SimulatorAttachRequest(url: spaced)?.workspaceID == "/workspace/project app")
        let plus = URL(string: "tokenstat://simulator/attach?device=\(first)&workspace=%2Fworkspace%2Fproject%2Bapp")!
        precondition(SimulatorAttachRequest(url: plus)?.workspaceID == "/workspace/project+app")
        for value in ["tokenstat://simulator/erase?device=\(first)",
                      "https://simulator/attach?device=\(first)",
                      "tokenstat://simulator/attach?device=booted",
                      "tokenstat://simulator/attach?device=\(first)&device=\(second)",
                      "tokenstat://simulator/attach?device=\(first)&command=erase",
                      "tokenstat://simulator/attach?device=\(first)&workspace=x&workspace=y",
                      "tokenstat://user@simulator/attach?device=\(first)",
                      "tokenstat://simulator:80/attach?device=\(first)",
                      "tokenstat://simulator/attach?device=\(first)#fragment"] {
            precondition(SimulatorAttachRequest(url: URL(string: value)!) == nil, "Unsafe request accepted: \(value)")
        }
        let pixels = CGSize(width: 100, height: 200), bounds = CGSize(width: 300, height: 200)
        precondition(SimulatorGeometry.normalized(point: CGPoint(x: 150, y: 100), bounds: bounds, pixels: pixels) == CGPoint(x: 0.5, y: 0.5))
        precondition(SimulatorGeometry.normalized(point: CGPoint(x: 50, y: 100), bounds: bounds, pixels: pixels) == nil)
        precondition(SimulatorGeometry.normalized(point: .zero, bounds: .zero, pixels: pixels) == nil)
        precondition(SimulatorGeometry.normalized(point: CGPoint(x: 100, y: 0), bounds: bounds, pixels: pixels) == .zero)
        precondition(SimulatorGeometry.normalized(point: CGPoint(x: 200, y: 200), bounds: bounds, pixels: pixels) == CGPoint(x: 1, y: 1))
        let position = CGPoint(x: 0.2, y: 0.3)
        precondition(SimulatorGeometry.devicePoint(position, orientation: 1) == position)
        precondition(SimulatorGeometry.devicePoint(position, orientation: 2) == CGPoint(x: 0.8, y: 0.7))
        precondition(SimulatorGeometry.devicePoint(position, orientation: 3) == CGPoint(x: 0.3, y: 0.8))
        precondition(SimulatorGeometry.devicePoint(position, orientation: 4) == CGPoint(x: 0.7, y: 0.2))
        precondition(SimulatorGeometry.displaySize(pixels: pixels, orientation: 3) == CGSize(width: 200, height: 100))
        var tracker = SimulatorBootTracker()
        precondition(tracker.observe(devices, follows: true) == nil, "Initial discovery cannot steal the inspector")
        precondition(tracker.observe(devices, follows: true) == nil)
        precondition(tracker.observe([], follows: true) == nil)
        precondition(tracker.observe(devices, follows: true) == second, "An external boot must be discoverable")
        _ = tracker.observe([], follows: false)
        precondition(tracker.observe(devices, follows: false) == nil, "Disabled follow must not attach")
        precondition(tracker.observe(devices, follows: true) == nil, "Enabling follow cannot replay an older boot")
        precondition(SimulatorAttachmentIntent(deviceID: first) != SimulatorAttachmentIntent(deviceID: first), "Repeat attachment must remain an actionable request")
        print("PASS: simulator inventory, exact attach requests, device preference and letterbox input geometry")
    }
}
