// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import Foundation
import CoreGraphics

struct SimulatorDevice: Identifiable, Equatable, Sendable {
    enum Platform: String, Codable, Sendable { case ios, android }
    let id: String
    let name: String
    let runtime: String
    let platform: Platform
    let deviceType: String
    let isBooted: Bool
    let isBooting: Bool
    let serial: String?
    let transportID: UInt64?
    init(id: String, name: String, runtime: String, platform: Platform, deviceType: String, isBooted: Bool, isBooting: Bool = false, serial: String? = nil, transportID: UInt64? = nil) {
        self.id = id; self.name = name; self.runtime = runtime; self.platform = platform
        self.deviceType = deviceType; self.isBooted = isBooted; self.isBooting = isBooting; self.serial = serial; self.transportID = transportID
    }
    var isRunning: Bool { isBooted || isBooting }
    var isTablet: Bool { deviceType.localizedCaseInsensitiveContains("ipad") || deviceType.localizedCaseInsensitiveContains("tablet") }
    var isFoldable: Bool { deviceType.localizedCaseInsensitiveContains("duo") || deviceType.localizedCaseInsensitiveContains("fold") }
    static func validAndroidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && name != "." && name != ".."
            && name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }
    }

    static func appleInventory(_ data: Data) throws -> [Self] {
        struct Inventory: Decodable { let devices: [String: [Entry]] }
        struct Entry: Decodable {
            let udid: String; let name: String; let state: String
            let isAvailable: Bool?; let deviceTypeIdentifier: String?
        }
        let inventory = try JSONDecoder().decode(Inventory.self, from: data)
        return inventory.devices.flatMap { runtime, entries in
            guard runtime.contains(".iOS-") else { return [Self]() }
            return entries.compactMap { entry in
                guard entry.isAvailable == true, UUID(uuidString: entry.udid) != nil else { return nil }
                return Self(id: entry.udid.uppercased(), name: entry.name,
                    runtime: "iOS " + (runtime.components(separatedBy: ".iOS-").last ?? runtime).replacingOccurrences(of: "-", with: "."),
                    platform: .ios, deviceType: entry.deviceTypeIdentifier ?? entry.name,
                    isBooted: entry.state == "Booted", isBooting: entry.state == "Booting")
            }
        }.sorted { a, b in
            if a.isBooted != b.isBooted { return a.isBooted }
            return (a.name + a.runtime + a.id).localizedStandardCompare(b.name + b.runtime + b.id) == .orderedAscending
        }
    }

    static func preferred(in devices: [Self], saved: String?, favorites: Set<String> = []) -> Self? {
        if let saved, let device = devices.first(where: { $0.id == saved }) { return device }
        return devices.first(where: { $0.isBooted })
            ?? devices.first(where: { favorites.contains($0.id) })
            ?? devices.first(where: { $0.platform == .ios && !$0.isTablet }) ?? devices.first
    }
}

struct SimulatorBootTracker {
    private var previous: Set<String>?
    mutating func observe(_ devices: [SimulatorDevice], follows: Bool) -> String? {
        let booted = Set(devices.filter(\.isBooted).map(\.id))
        defer { previous = booted }
        guard follows, let previous else { return nil }
        return devices.first { $0.isBooted && !previous.contains($0.id) }?.id
    }
}

/// A repeated link is a new request even when it names the same device.
struct SimulatorAttachmentIntent: Equatable {
    let id = UUID()
    let deviceID: String
}

/// Attach links carry a concrete device identity; they never execute a command.
struct SimulatorAttachRequest: Equatable {
    let deviceID: String
    let workspaceID: String?
    init?(url: URL) {
        guard url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              url.scheme?.lowercased() == "tokenstat", url.host == "simulator", url.path == "/attach",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        guard let values = parts.queryItems,
              values.filter({ $0.name == "device" }).count == 1,
              let id = values.first(where: { $0.name == "device" })?.value,
              UUID(uuidString: id) != nil || (id.hasPrefix("android:") && SimulatorDevice.validAndroidName(String(id.dropFirst(8)))) else { return nil }
        let workspaces = values.filter { $0.name == "workspace" }
        guard workspaces.count <= 1, values.allSatisfy({ ["device", "workspace"].contains($0.name) }) else { return nil }
        deviceID = id.hasPrefix("android:") ? id : id.uppercased()
        workspaceID = workspaces.first?.value
    }
}

enum SimulatorGeometry {
    static func displaySize(pixels: CGSize, orientation: Int) -> CGSize {
        [3, 4].contains(orientation) ? CGSize(width: pixels.height, height: pixels.width) : pixels
    }
    static func devicePoint(_ point: CGPoint, orientation: Int) -> CGPoint {
        switch orientation {
        case 2: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 3: CGPoint(x: point.y, y: 1 - point.x)
        case 4: CGPoint(x: 1 - point.y, y: point.x)
        default: point
        }
    }
    /// All input uses top-left device coordinates. Letterboxing never sends touches.
    static func normalized(point: CGPoint, bounds: CGSize, pixels: CGSize) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0, pixels.width > 0, pixels.height > 0 else { return nil }
        let scale = min(bounds.width / pixels.width, bounds.height / pixels.height)
        let size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        let x = (point.x - (bounds.width - size.width) / 2) / size.width
        let y = (point.y - (bounds.height - size.height) / 2) / size.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }
}
#endif
