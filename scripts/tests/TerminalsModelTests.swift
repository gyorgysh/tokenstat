// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TerminalsModel.swift TerminalPaneSelection.swift.
import AppKit
import Foundation
struct WorkspaceFolder { var id: String; var path = "/tmp" }
struct PtySessionInfo { var id: String; var workspaceID: String? = "workspace"; var command = "sh"; var hidden: Bool? }
enum TerminalWheelForwarder { static func install() {} }
enum TerminalMouseForwarder { static func install() {} }
enum TerminalPreferences { static let disablesColor = false }
enum TerminalSplitLayout: String { case single, side, stacked; var isSplit: Bool { self != .single } }
enum WorkspacePreference {
    static func splitLayout(for id: String) -> TerminalSplitLayout { .single }
    static func setSplitLayout(_ value: TerminalSplitLayout, for id: String) {}
    static func splitFraction(for id: String) -> Double { 0.5 }
    static func setSplitFraction(_ value: Double, for id: String) {}
    static func inspectorShellHostID(for id: String) -> String? { nil }
    static func setInspectorShellHostID(_ value: String?, for id: String) {}
}
@MainActor final class SSHLiveTerminal { let id = UUID().uuidString }
@MainActor final class SSHSessionsModel { var sessions: [SSHLiveTerminal] = []; func select(_ value: SSHLiveTerminal) {}; func close(_ value: SSHLiveTerminal) async {} }
@MainActor final class TerminalSession {
    let id = UUID().uuidString
    var hostID: String; var workspaceID: String; var command: String
    var isPending = false; var isInspectorShell = false; var isFocused = false; var stopped = false
    init(info: PtySessionInfo) { hostID = info.id; workspaceID = info.workspaceID ?? ""; command = info.command }
    init(pendingCommand: String, workspace: WorkspaceFolder, rows: Int, cols: Int) {
        hostID = "pending"; workspaceID = workspace.id; command = pendingCommand; isPending = true
    }
    func attach(info: PtySessionInfo) { guard isPending else { return }; hostID = info.id; isPending = false }
    func start() {}; func stop() { stopped = true }; func acknowledgeAttention() {}
}
@MainActor final class WorkspaceTerminal {
    let id: String; let local: TerminalSession?; let ssh: SSHLiveTerminal?
    init(_ value: TerminalSession) { id = value.id; local = value; ssh = nil }
    init(_ value: SSHLiveTerminal) { id = "ssh:" + value.id; ssh = value; local = nil }
}
@MainActor enum Bridge {
    static var list: [PtySessionInfo] = []
    static var holdList = false
    static var listWaiter: CheckedContinuation<[PtySessionInfo], Never>?
    static var spawnWaiters: [CheckedContinuation<PtySessionInfo, Never>] = []
    static var closed: [String] = []
    static func ptyList() async throws -> [PtySessionInfo] {
        if holdList { return await withCheckedContinuation { listWaiter = $0 } }
        return list
    }
    static func ptySpawn(workspaceID: String, command: String, args: [String], rows: Int, cols: Int, noColor: Bool, dark: Bool, modelProvider: String?, modelID: String?, hidden: Bool) async throws -> PtySessionInfo {
        await withCheckedContinuation { spawnWaiters.append($0) }
    }
    static func ptyClose(id: String) async throws { closed.append(id) }
    static func isHostRecoveryError(_ error: Error) -> Bool { false }
}
@main struct TerminalsModelTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let model = TerminalsModel()
        let workspace = WorkspaceFolder(id: "workspace")
        let first = model.begin(workspace: workspace, command: "sh")
        let second = model.begin(workspace: workspace, command: "sh")
        Bridge.list = [PtySessionInfo(id: "second"), PtySessionInfo(id: "unrelated")]
        await model.load()
        assert(first.isPending && second.isPending && model.sessions.count == 2,
               "list rows cannot claim pending requests by command/workspace")
        let launch = Task { await model.complete(first, args: [], rows: 24, cols: 80) }
        while Bridge.spawnWaiters.isEmpty { await Task.yield() }
        Bridge.holdList = true
        let stale = Task { await model.load() }
        while Bridge.listWaiter == nil { await Task.yield() }
        Bridge.spawnWaiters.removeFirst().resume(returning: PtySessionInfo(id: "first"))
        _ = await launch.value
        Bridge.listWaiter?.resume(returning: []); Bridge.listWaiter = nil
        await stale.value
        assert(model.sessions.contains { $0 === first } && first.hostID == "first" && !first.stopped,
               "old list must not remove a newly confirmed spawn")
        let lateLaunch = Task { await model.complete(second, args: [], rows: 24, cols: 80) }
        while Bridge.spawnWaiters.isEmpty { await Task.yield() }
        await model.close(second)
        Bridge.spawnWaiters.removeFirst().resume(returning: PtySessionInfo(id: "second"))
        _ = await lateLaunch.value
        assert(Bridge.closed == ["second"], "closing pending tab kills only its confirmed process")
        print("Terminal reconciliation identity and late-spawn races passed")
    }
}
