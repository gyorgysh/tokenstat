// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import Darwin

/// A plain text record on disk of what the app was doing, for a freeze or a
/// crash that leaves nothing else behind.
///
/// The unified log keeps nothing across a forced power-off, and a crash report
/// names Apple's frames rather than the screen that was open. So this writes to
/// `~/Library/Logs/tokenstat/app-<day>.log`, one line at a time, and forces
/// every batch to the disk. The last lines before a freeze are the point.
///
/// Lines carry method names, control roles, timings,
/// and memory figures. Never call parameters, typed text, keystrokes, chat
/// content or file paths. The file stays on this Mac.
///
/// On by default. `defaults write ai.tokenstat.tokenstat DiagnosticsLogDisabled
/// -bool YES` turns it off.
enum DiagnosticsLog {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/tokenstat", isDirectory: true)

    /// Days of files kept. A freeze is looked at the same day or the next.
    private static let keepDays = 5
    /// One day's file stops growing here. A busy day is a few megabytes.
    private static let maxFileBytes: off_t = 64 * 1024 * 1024
    /// The main thread is stalled once a ping has waited this long.
    private static let stallMs: UInt64 = 500

    private static let queue = DispatchQueue(label: "ai.tokenstat.diagnostics", qos: .utility)
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var buffer = ""
    nonisolated(unsafe) private static var day = ""
    nonisolated(unsafe) private static var timers: [DispatchSourceTimer] = []
    nonisolated(unsafe) private static var pressure: DispatchSourceMemoryPressure?
    nonisolated(unsafe) private static var lastCPU: (wall: UInt64, cpu: UInt64)?
    nonisolated(unsafe) private static var hostdPID: pid_t = 0
    nonisolated(unsafe) private static var hostdLookup: UInt64 = 0
    nonisolated(unsafe) private static var inputMonitor: Any?

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    static var enabled: Bool {
        !UserDefaults.standard.bool(forKey: "DiagnosticsLogDisabled")
    }

    /// Open today's file, then start the sampler, the stall watch and the
    /// crash hooks. Called once, before any window exists.
    static func start() {
        guard enabled else { return }
        queue.sync {
            guard !started else { return }
            started = true
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            prune()
            openToday()
            let info = Bundle.main.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String ?? "?"
            let build = info?["CFBundleVersion"] as? String ?? "?"
            #if DEBUG
            let flavor = "debug"
            #else
            let flavor = "release"
            #endif
            append(
                "launch version=\(version) build=\(build) \(flavor) pid=\(getpid())"
                    + " os=\(ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: " ", with: "_"))"
                    + " model=\(sysctlString("hw.model")) cpus=\(ProcessInfo.processInfo.activeProcessorCount)"
                    + " ram_mb=\(ProcessInfo.processInfo.physicalMemory / 1_048_576)"
            )
            flush()
        }
        installFatalHandlers()
        startSampler()
        startStallWatch()
        startPressureWatch()
    }

    /// Clicks on a control, app activation, sleep and screen changes. Needs a
    /// running NSApplication, so it waits for launch to finish.
    @MainActor
    static func watchInput() {
        guard enabled, inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { event in
            noteInput(event)
            return event
        }
        let center = NotificationCenter.default
        let names: [(Notification.Name, String)] = [
            (NSApplication.didBecomeActiveNotification, "app active"),
            (NSApplication.didResignActiveNotification, "app inactive"),
            (NSApplication.didChangeScreenParametersNotification, "screens changed"),
            (NSApplication.willTerminateNotification, "terminate"),
        ]
        for (name, line) in names {
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                note(line, force: name == NSApplication.willTerminateNotification)
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
            note("sleep", force: true)
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            note("wake")
        }
    }

    /// One line. Forced lines reach the disk before this returns.
    static func note(_ line: String, force: Bool = false) {
        guard started else { return }
        if force {
            queue.sync {
                append(line)
                flush()
            }
        } else {
            queue.async { append(line) }
        }
    }

    // MARK: Bridge calls

    private static let inflightLock = NSLock()
    nonisolated(unsafe) private static var inflight: [UInt64: (method: String, at: UInt64)] = [:]
    nonisolated(unsafe) private static var nextCall: UInt64 = 0

    /// Remember a call until it ends, so a freeze names what was still waiting.
    static func callStarted(_ method: String) -> UInt64 {
        guard started else { return 0 }
        inflightLock.lock()
        defer { inflightLock.unlock() }
        nextCall &+= 1
        inflight[nextCall] = (method, DispatchTime.now().uptimeNanoseconds)
        return nextCall
    }

    /// `failure` is an error code or a type name, never a message: a message
    /// can quote a path or the text of a call.
    static func callFinished(_ token: UInt64, method: String, remote: Bool, failure: String?) {
        guard started, token != 0 else { return }
        inflightLock.lock()
        let begun = inflight.removeValue(forKey: token)?.at
        inflightLock.unlock()
        guard let begun else { return }
        let ms = (DispatchTime.now().uptimeNanoseconds - begun) / 1_000_000
        note("call \(method) ms=\(ms)\(remote ? " remote" : "")\(failure.map { " failed=\($0)" } ?? "")")
    }

    private static func inflightSummary() -> String {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        guard let oldest = inflight.values.min(by: { $0.at < $1.at }) else { return "inflight=0" }
        let age = (DispatchTime.now().uptimeNanoseconds - oldest.at) / 1_000_000
        return "inflight=\(inflight.count) oldest=\(oldest.method):\(age)ms"
    }

    // MARK: Input

    /// A click names the control under it by role. A key is
    /// logged only as a shortcut, and only by its modifiers, never its letter.
    @MainActor
    private static func noteInput(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            guard !flags.isEmpty else { return }
            var names: [String] = []
            if flags.contains(.command) { names.append("cmd") }
            if flags.contains(.control) { names.append("ctrl") }
            if flags.contains(.option) { names.append("opt") }
            note("shortcut \(names.joined(separator: "+"))")
        default:
            let kind = event.type == .rightMouseDown ? "right-click" : "click"
            guard let window = event.window else {
                note("\(kind) role=none")
                return
            }
            let screen = window.convertPoint(toScreen: event.locationInWindow)
            let size = window.frame.size
            // After the click is handled, not before it. The hit test walks
            // the accessibility tree, and the click should not wait on a log.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let target = describe(window.accessibilityHitTest(screen))
                    note("\(kind) \(target) window=\(Int(size.width))x\(Int(size.height))")
                }
            }
        }
    }

    @MainActor
    static func describe(_ element: Any?) -> String {
        guard let element = element as? NSAccessibilityProtocol else { return "role=none" }
        // Row and menu labels can contain chat titles, file names or text
        // typed into a note. Even a short prefix must stay out of this log.
        return "role=\(element.accessibilityRole()?.rawValue ?? "none")"
    }

    static func exceptionSummary(_ exception: NSException) -> String {
        // AppKit reasons can quote document contents and local paths.
        "exception \(exception.name.rawValue)"
    }

    // MARK: Sampler

    /// Once a second: this app's memory and CPU, the helper's memory, the
    /// machine's free memory, and what calls are still waiting.
    private static func startSampler() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler {
            append(sample())
            flush()
        }
        timer.resume()
        timers.append(timer)
    }

    private static func sample() -> String {
        var fields = ["sample"]
        fields.append("mem_mb=\(footprint(pid: getpid()) / 1_048_576)")
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        if proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, size) == size {
            fields.append("threads=\(task.pti_threadnum)")
        }
        fields.append("cpu=\(cpuPercent())%")
        if let hostd = hostdFootprint() {
            fields.append("hostd_mb=\(hostd / 1_048_576)")
        }
        fields.append(systemMemory())
        fields.append(inflightSummary())
        return fields.joined(separator: " ")
    }

    /// The figure Activity Monitor calls Memory.
    private static func footprint(pid: pid_t) -> UInt64 {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return result == 0 ? usage.ri_phys_footprint : 0
    }

    private static func cpuPercent() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = UInt64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000
            + UInt64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)
        let wall = DispatchTime.now().uptimeNanoseconds / 1_000
        defer { lastCPU = (wall, cpu) }
        guard let last = lastCPU, wall > last.wall, cpu >= last.cpu else { return 0 }
        return Int((cpu - last.cpu) * 100 / (wall - last.wall))
    }

    /// The helper runs as its own process, so its memory is read by pid. The
    /// pid is looked up again every ten seconds, since the helper can restart.
    private static func hostdFootprint() -> UInt64? {
        let now = DispatchTime.now().uptimeNanoseconds
        if hostdPID == 0 || now - hostdLookup > 10_000_000_000 {
            hostdLookup = now
            hostdPID = findProcess(named: "tokenstat-hostd")
        }
        guard hostdPID != 0 else { return nil }
        let bytes = footprint(pid: hostdPID)
        if bytes == 0 { hostdPID = 0 }
        return bytes == 0 ? nil : bytes
    }

    private static func findProcess(named target: String) -> pid_t {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return 0 }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let found = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard found > 0 else { return 0 }
        var name = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(found)) where pid > 0 {
            name.withUnsafeMutableBufferPointer { buffer in
                _ = proc_name(pid, buffer.baseAddress, UInt32(buffer.count))
            }
            if String(cString: name) == target { return pid }
        }
        return 0
    }

    /// The kernel's free memory level, the figure `memory_pressure` prints,
    /// plus what the compressor holds. A freeze from memory shows as the level
    /// falling toward zero.
    private static func systemMemory() -> String {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "sys=unknown" }
        let page = UInt64(vm_kernel_page_size)
        let compressed = UInt64(stats.compressor_page_count) * page
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let free = sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 ? "\(level)%" : "unknown"
        return "sys_free=\(free) compressed_mb=\(compressed / 1_048_576) swapouts=\(stats.swapouts)"
    }

    // MARK: Stall watch

    nonisolated(unsafe) private static var pingSentAt: UInt64 = 0
    nonisolated(unsafe) private static var stalled = false
    nonisolated(unsafe) private static var lastStallLine: UInt64 = 0

    /// A background timer asks the main thread to answer every 200ms. A ping
    /// left waiting past half a second is a stall, logged when it starts,
    /// every second while it lasts, and once more when it ends.
    private static func startStallWatch() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .milliseconds(200), leeway: .milliseconds(20))
        timer.setEventHandler {
            let now = DispatchTime.now().uptimeNanoseconds
            if pingSentAt == 0 {
                pingSentAt = now
                DispatchQueue.main.async {
                    queue.async { answered() }
                }
                return
            }
            let waited = (now - pingSentAt) / 1_000_000
            guard waited >= stallMs else { return }
            if !stalled {
                stalled = true
                lastStallLine = now
                append("stall main thread blocked \(waited)ms \(inflightSummary())")
                flush()
            } else if now - lastStallLine >= 1_000_000_000 {
                lastStallLine = now
                append("stall still blocked \(waited)ms \(sample())")
                flush()
            }
        }
        timer.resume()
        timers.append(timer)
    }

    private static func answered() {
        let waited = (DispatchTime.now().uptimeNanoseconds - pingSentAt) / 1_000_000
        pingSentAt = 0
        if stalled {
            stalled = false
            append("stall ended after \(waited)ms")
            flush()
        }
    }

    private static func startPressureWatch() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: queue)
        source.setEventHandler {
            let event = source.data
            let level = event.contains(.critical) ? "critical" : event.contains(.warning) ? "warning" : "normal"
            append("memory pressure \(level) \(sample())")
            flush()
        }
        source.resume()
        pressure = source
    }

    // MARK: Crashes

    /// Written from a signal handler, so built ahead of time and written with
    /// nothing but `write`.
    nonisolated(unsafe) private static var fatalLines: [Int32: [UInt8]] = [:]
    nonisolated(unsafe) fileprivate static var fatalFD: Int32 = -1

    private static func installFatalHandlers() {
        let signals: [(Int32, String)] = [
            (SIGTRAP, "SIGTRAP"), (SIGABRT, "SIGABRT"), (SIGSEGV, "SIGSEGV"),
            (SIGBUS, "SIGBUS"), (SIGILL, "SIGILL"), (SIGFPE, "SIGFPE"),
        ]
        for (number, name) in signals {
            fatalLines[number] = Array("fatal signal \(name), see the crash report for the stack\n".utf8)
            signal(number) { number in
                if DiagnosticsLog.fatalFD >= 0, let line = DiagnosticsLog.fatalLines[number] {
                    line.withUnsafeBytes { _ = Darwin.write(DiagnosticsLog.fatalFD, $0.baseAddress, $0.count) }
                    fsync(DiagnosticsLog.fatalFD)
                }
                signal(number, SIG_DFL)
                raise(number)
            }
        }
        NSSetUncaughtExceptionHandler { exception in
            DiagnosticsLog.note(DiagnosticsLog.exceptionSummary(exception), force: true)
        }
    }

    // MARK: File

    /// Runs on `queue`.
    private static func append(_ line: String) {
        let now = Date()
        let today = String(stamp.string(from: now).prefix(10))
        if today != day {
            flush()
            openToday()
        }
        let uptime = Double(DispatchTime.now().uptimeNanoseconds / 1_000_000) / 1000
        buffer += "\(stamp.string(from: now)) up=\(String(format: "%.1f", uptime)) \(line)\n"
        if buffer.utf8.count > 64 * 1024 { flush() }
    }

    /// Runs on `queue`. Write what is buffered and make the disk hold it.
    private static func flush() {
        guard !buffer.isEmpty, fatalFD >= 0 else {
            buffer = ""
            return
        }
        var info = stat()
        if fstat(fatalFD, &info) == 0, info.st_size > maxFileBytes {
            buffer = ""
            return
        }
        let bytes = Array(buffer.utf8)
        buffer = ""
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let wrote = Darwin.write(fatalFD, base + offset, raw.count - offset)
                if wrote <= 0 { break }
                offset += wrote
            }
        }
        fsync(fatalFD)
    }

    private static func openToday() {
        day = String(stamp.string(from: Date()).prefix(10))
        let path = directory.appendingPathComponent("app-\(day).log").path
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        let previous = fatalFD
        fatalFD = fd
        if previous >= 0 { close(previous) }
    }

    private static func prune() {
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files where file.lastPathComponent.hasPrefix("app-") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "?" }
        return String(cString: value)
    }
}
#endif
