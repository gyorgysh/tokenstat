// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import AppKit
import Observation
import AVFoundation
import IOSurface

@MainActor @Observable
final class SimulatorSession {
    var devices: [SimulatorDevice] = []
    var selectedID: String? { didSet { defaults.set(selectedID, forKey: key + ".selected") } }
    var favorites: Set<String> { didSet { defaults.set(Array(favorites), forKey: key + ".favorites") } }
    var defaultID: String? { didSet { defaults.set(defaultID, forKey: key + ".default") } }
    var followsAgents: Bool { didSet { defaults.set(followsAgents, forKey: key + ".follow") } }
    var attachedID: String?
    var busy = false
    var error: String?
    var message: String?
    var pixels = CGSize(width: 1206, height: 2622)
    var orientation = 1
    var hasFrame = false
    var perspective = false
    var yaw = 0.0
    var pitch = 0.0
    var zoom = 1.0
    @ObservationIgnored private(set) var connection: NativeSimulatorConnection?
    @ObservationIgnored var surface: Any?
    @ObservationIgnored private var videoBacking: CVPixelBuffer?
    @ObservationIgnored private var androidStream: AndroidSimulatorStream?
    @ObservationIgnored private var androidTools: AndroidSimulatorTools?
    @ObservationIgnored private var androidSerial: String?
    @ObservationIgnored private var androidTransportID: UInt64?
    @ObservationIgnored private var androidPixels = CGSize(width: 1080, height: 1920)
    @ObservationIgnored private var androidNaturalLandscape = false
    @ObservationIgnored private var androidWindowRotation = false
    @ObservationIgnored private var androidFixedRotation = false
    @ObservationIgnored private var androidTouch: (CGPoint, Date)?
    @ObservationIgnored private var displays = NSHashTable<SimulatorScreenNSView>.weakObjects()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var inputEpoch = UUID()
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var developerDirectory: String?
    @ObservationIgnored private var discoveryError: String?
    private let defaults: UserDefaults
    private let key: String
    private let inventory: SimulatorInventory

    init(preferenceKey: String, defaults: UserDefaults = .standard, inventory: SimulatorInventory = .shared) {
        key = "simulator." + preferenceKey
        self.defaults = defaults
        self.inventory = inventory
        let savedDefault = defaults.string(forKey: key + ".default")
        defaultID = savedDefault
        selectedID = savedDefault ?? defaults.string(forKey: key + ".selected")
        favorites = Set(defaults.stringArray(forKey: key + ".favorites") ?? [])
        followsAgents = defaults.object(forKey: key + ".follow") as? Bool ?? true
    }
    var selected: SimulatorDevice? { devices.first { $0.id == selectedID } }
    var attached: SimulatorDevice? { devices.first { $0.id == attachedID } }
    var previewPixels: CGSize {
        if selected?.isTablet == true { return CGSize(width: 2048, height: 2732) }
        if selected?.isFoldable == true { return CGSize(width: 1398, height: 2034) }
        return CGSize(width: 1206, height: 2622)
    }
    var orderedDevices: [SimulatorDevice] {
        devices.sorted { a, b in
            if favorites.contains(a.id) != favorites.contains(b.id) { return favorites.contains(a.id) }
            if a.isBooted != b.isBooted { return a.isBooted }
            if a.platform != b.platform { return a.platform == .ios }
            return (a.name + a.runtime + a.id).localizedStandardCompare(b.name + b.runtime + b.id) == .orderedAscending
        }
    }

    func refresh(force: Bool = false) async {
        do {
            let found = try await inventory.load(force: force)
            try Task.checkCancellation()
            if error == discoveryError { error = nil }
            discoveryError = nil
            devices = found
            if selected == nil { selectedID = SimulatorDevice.preferred(in: found, saved: defaultID ?? selectedID, favorites: favorites)?.id }
            let booted = Set(found.filter(\.isRunning).map(\.id))
            if let id = attachedID, !booted.contains(id), !busy { detach(suppressFollow: false); error = nil; message = L10n.text("apple.simulator.stopped") }
            else if let id = attachedID, active, !busy, connection?.needsReconnect == true { attach(id, bootIfNeeded: false) }
            else if let id = attachedID, active, !busy, attached?.platform == .android,
                    let device = found.first(where: { $0.id == id }),
                    androidSerial == nil || device.serial != androidSerial || device.transportID != androidTransportID { attach(id, bootIfNeeded: false) }
        } catch is CancellationError { }
        catch {
            if devices.isEmpty { discoveryError = error.localizedDescription; self.error = discoveryError }
        }
    }

    func setActive(_ value: Bool) {
        active = value
        if !value {
            inputEpoch = UUID(); androidTouch = nil
            displays.allObjects.forEach { $0.cancelGestures() }
            connection?.stop(); androidStream?.stop()
        }
        else if let connection { do { try startDisplay(connection) } catch { self.error = error.localizedDescription } }
        else if androidSerial != nil { startAndroidDisplay() }
    }

    func attach(_ id: String? = nil, bootIfNeeded: Bool = true) {
        guard let id = id ?? selectedID, let device = devices.first(where: { $0.id == id }) else { return }
        if busy, selectedID == id { return }
        operation?.cancel()
        generation = UUID()
        inputEpoch = UUID()
        let lease = generation
        connection?.stop(); connection = nil; surface = nil; hasFrame = false
        androidStream?.stop(); androidStream = nil; androidSerial = nil; androidTransportID = nil; videoBacking = nil
        attachedID = nil; selectedID = id; busy = true; error = nil; message = nil
        displays.allObjects.forEach { $0.clear() }
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == lease { self.busy = false } }
            do {
                if device.platform == .android {
                    try await self.attachAndroid(device, lease: lease, bootIfNeeded: bootIfNeeded)
                    return
                }
                if !device.isRunning {
                    guard bootIfNeeded else { throw SimulatorCommand.Failure(message: L10n.text("apple.simulator.stopped")) }
                    do { _ = try await SimulatorCommand.simctl(["boot", id], timeout: 30) }
                    catch {
                        // An agent can boot the device after our last inventory.
                        // Accept that race only after verifying this exact device.
                        let fresh = try? await SimulatorDevice.appleInventory(SimulatorCommand.simctl(["list", "devices", "available", "--json"]))
                        guard fresh?.contains(where: { $0.id == id && $0.isRunning }) == true else { throw error }
                    }
                }
                try Task.checkCancellation()
                self.developerDirectory = try await SimulatorCommand.developerDirectory()
                guard self.generation == lease, let directory = self.developerDirectory else { return }
                let deadline = Date().addingTimeInterval(180)
                while true {
                    try Task.checkCancellation()
                    guard self.generation == lease else { return }
                    do {
                        let connection = try NativeSimulatorConnection(developerDirectory: directory, deviceID: id)
                        connection.controlFailureHandler = { [weak self] error in
                            if self?.generation == lease { self?.error = error.localizedDescription }
                        }
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            connection.prepareInput { error in
                                if let error { continuation.resume(throwing: error) }
                                else { continuation.resume() }
                            }
                        }
                        try Task.checkCancellation()
                        guard self.generation == lease else { return }
                        self.connection = connection; self.attachedID = id
                        try self.startDisplay(connection)
                        let firstFrameDeadline = Date().addingTimeInterval(15)
                        while !self.hasFrame && self.active && Date() < firstFrameDeadline {
                            try Task.checkCancellation()
                            guard self.generation == lease else { return }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        if self.active && !self.hasFrame {
                            throw NSError(domain: "ai.tokenstat.simulator", code: 10,
                                userInfo: [NSLocalizedDescriptionKey: L10n.text("apple.simulator.timeout")])
                        }
                        if !self.active { connection.stop() }
                        break
                    } catch {
                        guard self.generation == lease else { return }
                        self.connection?.stop(); self.connection = nil; self.attachedID = nil
                        let failure = error as NSError
                        guard failure.domain == "ai.tokenstat.simulator", [10,11].contains(failure.code), Date() < deadline else { throw error }
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                await self.refresh()
            } catch is CancellationError { }
            catch { if self.generation == lease { self.error = error.localizedDescription } }
        }
    }

    private func attachAndroid(_ device: SimulatorDevice, lease: UUID, bootIfNeeded: Bool) async throws {
        guard let tools = AndroidSimulatorTools.installed() else { throw SimulatorCommand.Failure(message: L10n.text("apple.simulator.android_missing")) }
        androidTools = tools
        // Resolve again at attachment time: the cached emulator port may now
        // belong to another AVD, even when that device is already fully booted.
        let current = try await tools.inventory().first { $0.id == device.id }
        try Task.checkCancellation()
        guard generation == lease else { return }
        if current?.isBooted != true {
            guard bootIfNeeded else { throw SimulatorCommand.Failure(message: L10n.text("apple.simulator.stopped")) }
            try await AndroidSimulatorLauncher.shared.boot(String(device.id.dropFirst(8)), tools: tools)
        }
        let deadline = Date().addingTimeInterval(180)
        var target = current
        while Date() < deadline {
            try Task.checkCancellation()
            guard generation == lease else { return }
            if let target, let serial = target.serial,
               let value = try? await tools.command(serial, ["shell", "getprop", "sys.boot_completed"], timeout: 4, transportID: target.transportID),
               String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1" { break }
            try await Task.sleep(for: .seconds(1))
            target = try await tools.inventory().first { $0.id == device.id }
        }
        try Task.checkCancellation()
        guard generation == lease else { return }
        guard let target, let serial = target.serial, Date() < deadline else { throw SimulatorCommand.Failure(message: L10n.text("apple.simulator.timeout")) }
        let transportID = target.transportID
        let image = try await tools.command(serial, ["exec-out", "screencap", "-p"], transportID: transportID)
        try Task.checkCancellation()
        guard generation == lease else { return }
        if let bitmap = NSBitmapImageRep(data: image) { androidPixels = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh) }
        let dimensions = try await tools.command(serial, ["shell", "wm", "size"], transportID: transportID)
        try Task.checkCancellation()
        guard generation == lease else { return }
        androidNaturalLandscape = AndroidSimulatorTools.naturalLandscape(String(decoding: dimensions, as: UTF8.self)) ?? (androidPixels.width > androidPixels.height)
        let windowHelp = (try? await tools.command(serial, ["shell", "wm", "help"], transportID: transportID)) ?? Data()
        try Task.checkCancellation()
        guard generation == lease else { return }
        let capabilities = String(decoding: windowHelp, as: UTF8.self)
        androidWindowRotation = capabilities.contains("user-rotation")
        androidFixedRotation = capabilities.contains("fixed-to-user-rotation")
        pixels = androidPixels; orientation = 1; androidSerial = serial; androidTransportID = transportID; attachedID = device.id
        if active { startAndroidDisplay() }
        await refresh()
    }

    private func startAndroidDisplay() {
        guard let androidTools, let androidSerial else { return }
        let stream = AndroidSimulatorStream()
        let lease = generation
        stream.onFrame = { [weak self, weak stream] buffer in
            guard let self, let stream, self.androidStream === stream, self.generation == lease, self.active,
                  let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
            self.videoBacking = buffer; self.surface = surface
            let pixels = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            if self.pixels != pixels { self.pixels = pixels }
            if !self.hasFrame { self.hasFrame = true }
            for view in self.displays.allObjects { view.present(surface, pixels: pixels, orientation: 1, backing: buffer) }
        }
        stream.onError = { [weak self, weak stream] text in
            guard let self, let stream, self.androidStream === stream, self.generation == lease else { return }
            self.inputEpoch = UUID(); self.androidTouch = nil
            self.androidInputFlight?.cancel(); self.androidInputFlight = nil
            stream.stop(); self.androidStream = nil; self.androidSerial = nil; self.androidTransportID = nil
            self.surface = nil; self.videoBacking = nil; self.hasFrame = false
            self.displays.allObjects.forEach { $0.clear() }
            self.error = text
        }
        androidStream?.stop(); androidStream = stream
        stream.start(tools: androidTools, serial: androidSerial, pixels: androidPixels, transportID: androidTransportID)
    }

    private func startDisplay(_ connection: NativeSimulatorConnection) throws {
            try connection.start { [weak self, weak connection] surface, pixels, orientation in
                guard let self, self.active, self.connection === connection else { return }
                self.surface = surface
                let size = SimulatorGeometry.displaySize(pixels: pixels, orientation: orientation)
                if self.pixels != size { self.pixels = size }
                if self.orientation != orientation { self.orientation = orientation }
                if !self.hasFrame { self.hasFrame = true }
                for view in self.displays.allObjects { view.present(surface, pixels: pixels, orientation: orientation) }
            }
    }

    func register(_ view: SimulatorScreenNSView) {
        displays.add(view)
        if let surface { view.present(surface, pixels: SimulatorGeometry.displaySize(pixels: pixels, orientation: orientation), orientation: orientation, backing: videoBacking) }
    }

    func detach(suppressFollow: Bool = true) {
        if suppressFollow { defaults.set(Date().addingTimeInterval(12).timeIntervalSince1970, forKey: key + ".followAfter") }
        generation = UUID(); operation?.cancel(); operation = nil
        inputEpoch = UUID()
        androidInputFlight?.cancel(); androidInputFlight = nil; androidTouch = nil
        connection?.stop(); connection = nil; attachedID = nil; busy = false
        androidStream?.stop(); androidStream = nil; androidSerial = nil; androidTransportID = nil; videoBacking = nil
        surface = nil; hasFrame = false
        displays.allObjects.forEach { $0.clear() }
    }

    func shutdown() {
        guard let id = attachedID ?? selectedID, !busy else { return }
        let serial = androidSerial, transportID = androidTransportID
        detach(); busy = true; error = nil
        let lease = generation
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == lease { self.busy = false } }
            do {
                if id.hasPrefix("android:") {
                    guard let tools = self.androidTools ?? AndroidSimulatorTools.installed() else {
                        throw SimulatorCommand.Failure(message: L10n.text("apple.simulator.android_missing"))
                    }
                    // A stream can disconnect while the device menu is open.
                    // Resolve the exact AVD if that input lease was cleared.
                    let target = serial == nil ? try await tools.inventory().first(where: { $0.id == id }) : nil
                    if let serial = serial ?? target?.serial {
                        _ = try await tools.command(serial, ["emu", "kill"], transportID: transportID ?? target?.transportID)
                    }
                } else { _ = try await SimulatorCommand.simctl(["shutdown", id]) }
                await self.refresh()
            }
            catch is CancellationError { }
            catch { if self.generation == lease { self.error = error.localizedDescription } }
        }
    }

    func rotate(_ value: Int) {
        guard (1...4).contains(value) else { return }
        if androidSerial != nil {
            let rotation = String(AndroidSimulatorTools.rotation(value, naturalLandscape: androidNaturalLandscape))
            // A physical device rotation must also work when a tablet app
            // requests a fixed orientation; the guest handles letterboxing.
            if androidFixedRotation { androidCommand(["shell", "wm", "fixed-to-user-rotation", "enabled"]) }
            if androidWindowRotation {
                androidCommand(["shell", "wm", "user-rotation", "lock", rotation], refreshDisplay: true, expectedLandscape: [3,4].contains(value))
            } else {
                androidCommand(["shell", "settings", "put", "system", "accelerometer_rotation", "0"])
                androidCommand(["shell", "settings", "put", "system", "user_rotation", rotation], refreshDisplay: true, expectedLandscape: [3,4].contains(value))
            }
            return
        }
        let delivered = attached?.isFoldable == true ? connection?.setFoldableOrientation(value) : connection?.setOrientation(value)
        if delivered != true { error = L10n.text("apple.simulator.control_unavailable") }
    }
    func fold(_ angle: Double) {
        guard attached?.platform == .ios, attached?.isFoldable == true else { return }
        if connection?.setHingeAngle(angle) != true { error = L10n.text("apple.simulator.control_unavailable") }
    }
    func button(_ usage: UInt) {
        if androidSerial != nil { androidCommand(["shell", "input", "keyevent", usage == 0 ? "3" : "26"]); return }
        if connection?.pressButton(usage) != true { error = L10n.text("apple.simulator.control_unavailable") }
    }
    func command(_ arguments: [String], input: Data? = nil) {
        guard let id = attachedID, !busy else { return }
        if androidSerial != nil {
            if arguments.first == "ui", let mode = arguments.last { androidCommand(["shell", "cmd", "uimode", "night", mode == "dark" ? "yes" : "no"]) }
            else if arguments.first == "launch" { androidCommand(["shell", "am", "start", "-a", "android.settings.SETTINGS"]) }
            else if let input { androidCommand(["shell", "input", "text", AndroidSimulatorTools.quote(String(decoding: input, as: UTF8.self).replacingOccurrences(of: " ", with: "%s"))]) }
            return
        }
        let lease = generation
        Task { [weak self] in
            do { _ = try await SimulatorCommand.simctl(arguments.map { $0 == "{device}" ? id : $0 }, input: input) }
            catch { if self?.generation == lease { self?.error = error.localizedDescription } }
        }
    }
    func screenshot() {
        guard let id = attachedID else { return }
        let tools = androidTools, serial = androidSerial, transportID = androidTransportID
        let displayID = connection?.displayID ?? 1
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Simulator.png"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let pixels: Data
                    if let tools, let serial { pixels = try await tools.command(serial, ["exec-out", "screencap", "-p"], transportID: transportID) }
                    else { pixels = try await SimulatorCommand.screenshot(deviceID: id, displayID: displayID) }
                    try pixels.write(to: url, options: .atomic)
                    self?.message = L10n.text("apple.simulator.screenshot_saved")
                } catch { self?.error = error.localizedDescription }
            }
        }
    }

    func pasteClipboard(isCurrent: @escaping () -> Bool = { true }) {
        guard let text = NSPasteboard.general.string(forType: .string), let id = attachedID else { return }
        if androidSerial != nil { command(["pbcopy", "{device}"], input: Data(text.utf8)); return }
        let lease = generation, input = inputEpoch
        Task { [weak self] in
            do {
                _ = try await SimulatorCommand.simctl(["pbcopy", id], input: Data(text.utf8))
                guard let self, self.generation == lease, self.inputEpoch == input, self.active, isCurrent() else { return }
                self.keyboardChord(25, keepCommand: NSEvent.modifierFlags.contains(.command))
            } catch { if self?.generation == lease { self?.error = error.localizedDescription } }
        }
    }
    func copyDeviceClipboard(cut: Bool = false) {
        guard let id = attachedID, androidSerial == nil else { return }
        let lease = generation, clipboardRevision = NSPasteboard.general.changeCount
        keyboardChord(cut ? 27 : 6, keepCommand: NSEvent.modifierFlags.contains(.command))
        Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                let text = try await SimulatorCommand.simctl(["pbpaste", id])
                guard self?.generation == lease, NSPasteboard.general.changeCount == clipboardRevision,
                      let string = String(data: text, encoding: .utf8) else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string, forType: .string)
            } catch { if self?.generation == lease { self?.error = error.localizedDescription } }
        }
    }
    func keyboardChord(_ usage: UInt, keepCommand: Bool = false) {
        guard let connection else { return }
        _ = connection.sendKeyUsage(0xe3, pressed: true)
        _ = connection.sendKeyUsage(usage, pressed: true)
        _ = connection.sendKeyUsage(usage, pressed: false)
        if !keepCommand { _ = connection.sendKeyUsage(0xe3, pressed: false) }
    }

    func touch(_ point: CGPoint, phase: Int) -> Bool {
        guard active || phase == 2 else { return false }
        guard androidSerial != nil else { return connection?.touch(at: point, phase: phase) == true }
        if phase == 0 { androidTouch = (point, Date()); return true }
        guard phase == 2, let (start, began) = androidTouch else { return true }
        androidTouch = nil
        let from = CGPoint(x: start.x * androidPixels.width, y: start.y * androidPixels.height)
        let to = CGPoint(x: point.x * androidPixels.width, y: point.y * androidPixels.height)
        androidCommand(AndroidSimulatorTools.gestureArguments(from: from, to: to, duration: Date().timeIntervalSince(began)))
        return true
    }
    func key(_ event: NSEvent, pressed: Bool) -> Bool {
        guard active || !pressed else { return false }
        guard androidSerial != nil else { return connection?.keyEvent(event, pressed: pressed) == true }
        guard !event.modifierFlags.contains(.command) else { return false }
        guard pressed else { return true }
        let special: [UInt16: String] = [36:"66",51:"67",53:"111",48:"61",123:"21",124:"22",125:"20",126:"19"]
        if let code = special[event.keyCode] { androidCommand(["shell", "input", "keyevent", code]) }
        else if let text = event.characters { androidCommand(["shell", "input", "text", AndroidSimulatorTools.quote(text.replacingOccurrences(of: " ", with: "%s"))]) }
        return true
    }
    @ObservationIgnored private var androidInputFlight: Task<Void, Never>?
    private func androidCommand(_ arguments: [String], refreshDisplay: Bool = false, expectedLandscape: Bool? = nil) {
        guard let tools = androidTools, let serial = androidSerial else { return }
        let lease = generation, input = inputEpoch, previous = androidInputFlight, transportID = androidTransportID
        androidInputFlight = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == lease, self.inputEpoch == input, self.active else { return }
            do {
                _ = try await tools.command(serial, arguments, transportID: transportID)
                if refreshDisplay {
                    try await Task.sleep(for: .milliseconds(400))
                    for attempt in 0..<5 {
                        let image = try await tools.command(serial, ["exec-out", "screencap", "-p"], transportID: transportID)
                        guard self.generation == lease, self.inputEpoch == input else { return }
                        guard let bitmap = NSBitmapImageRep(data: image) else { throw SimulatorCommand.Failure(message: L10n.text("apple.simulator.control_unavailable")) }
                        self.androidPixels = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
                        if expectedLandscape == nil || expectedLandscape == (bitmap.pixelsWide > bitmap.pixelsHigh) { break }
                        guard attempt < 4 else { throw SimulatorCommand.Failure(message: L10n.text("apple.simulator.control_unavailable")) }
                        try await Task.sleep(for: .milliseconds(400))
                    }
                    if self.active { self.startAndroidDisplay() }
                }
            } catch { if self.generation == lease { self.error = error.localizedDescription } }
        }
    }
    func openExternally() {
        if selected?.platform == .android {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.android.studio") else {
                error = L10n.text("apple.simulator.android_studio_missing"); return
            }
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            return
        }
        let selectedID = attachedID ?? selectedID
        Task { [weak self] in
            guard let self else { return }
            do {
                let directory = try await SimulatorCommand.developerDirectory()
                self.developerDirectory = directory
                self.openAppleSimulator(directory: directory, deviceID: selectedID)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func openAppleSimulator(directory: String, deviceID: String?) {
        let contents = URL(fileURLWithPath: directory).deletingLastPathComponent()
        for path in ["Applications/DeviceHub.app", "Developer/Applications/Simulator.app"] {
            let url = contents.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = deviceID.map { ["-CurrentDeviceUDID", $0] } ?? []
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
                    if let error { Task { @MainActor in self?.error = error.localizedDescription } }
                }
                return
            }
        }
        error = L10n.text("apple.simulator.external_unavailable")
    }
    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
    }
}
#endif
