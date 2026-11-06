#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the shipping chat-list deletion callback with scene-owned caches."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "apps/mac/Sources/Client/ClientChatView.swift").read_text()
start = source.index("    private func didDeleteChat(")
end = source.index("\n    private func row(", start)
callback = source[start:end]
recent = (root / "apps/mac/Sources/Client/ClientRecentChats.swift").read_text()
start = recent.index("    private func didDeleteChat(")
end = recent.index("\n    private var chatSwitcher:", start)
recent_callback = recent[start:end]
swift = r'''
import Foundation
struct ChatConversation: Equatable { let id: String }
struct Reference: Equatable { let peer, workspace, id: String }
struct Presented {
    let peer, workspaceID, chatID: String
    var reference: Reference { .init(peer: peer, workspace: workspaceID, id: chatID) }
}
enum WorkDestinationResolver {
    static func sameConversation(_ a: Reference?, _ b: Reference) -> Bool { a == b }
}
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: String? = "alice"
}
@MainActor final class Model { var peer: String? = "mac"; var workspaceID: String? = "project" }
@MainActor final class Entry {
    var ids = ["deleted", "kept"]
    func remove(_ id: String) { ids.removeAll { $0 == id } }
}
@MainActor final class Projects {
    let value = Entry()
    func entry(peer: String, workspace: String) -> Entry {
        precondition(peer == "mac" && workspace == "project")
        return value
    }
}
@MainActor final class Readers {
    var removed: [String] = []
    func removed(_ id: String, peer: String, workspace: String) async {
        precondition(peer == "mac" && workspace == "project")
        removed.append(id)
    }
}
@MainActor final class Navigation {
    var requestedChat: Reference? = .init(peer: "mac", workspace: "project", id: "deleted")
    var presentedChat: Presented? = .init(peer: "mac", workspaceID: "project", chatID: "deleted")
    var visibleChat: Reference? = .init(peer: "mac", workspace: "project", id: "deleted")
    func reference(peer: String, workspaceID: String, chatID: String) -> Reference {
        Reference(peer: peer, workspace: workspaceID, id: chatID)
    }
}
@MainActor final class Screen {
    let peer = "mac", workspaceID = "project"
    let model = Model(), projects = Projects(), readers = Readers(), navigation = Navigation()
    var opened: ChatConversation? = .init(id: "deleted")
    var retainedThread: ChatConversation? = .init(id: "deleted")
    func delete() { didDeleteChat(.init(id: "deleted")) }
''' + callback + r'''
}
@MainActor final class RecentScreen {
    let peer = "mac", workspaceID = "project", chatID = "deleted"
    let model = Model(), projects = Projects(), readers = Readers(), navigation = Navigation()
    var presentationScope: String? = "alice"
    var visible = true
    var dismissals = 0
    func dismiss() { dismissals += 1 }
    func delete() { didDeleteChat(.init(id: "deleted")) }
''' + recent_callback + r'''
}
@main enum Run {
    @MainActor static func main() async {
        let screen = Screen()
        screen.delete()
        for _ in 0..<100 { await Task.yield() }
        precondition(screen.opened == nil && screen.retainedThread == nil)
        precondition(screen.projects.value.ids == ["kept"], "The project cache must lose the deleted row")
        precondition(screen.readers.removed == ["deleted"], "Every retained reader must learn the deletion")
        precondition(screen.navigation.requestedChat == nil && screen.navigation.presentedChat == nil,
            "A pending destination must not reopen the deleted chat")

        let foreign = Screen()
        foreign.model.peer = "other"
        foreign.delete()
        for _ in 0..<100 { await Task.yield() }
        precondition(foreign.projects.value.ids.count == 2 && foreign.readers.removed.isEmpty)

        let moved = Screen()
        moved.navigation.requestedChat = .init(peer: "mac", workspace: "project", id: "kept")
        moved.navigation.presentedChat = .init(peer: "mac", workspaceID: "project", chatID: "kept")
        moved.delete()
        WorkSessionContext.shared.scope = "bob"
        for _ in 0..<100 { await Task.yield() }
        precondition(moved.readers.removed.isEmpty, "Queued work must not cross an account change")
        precondition(moved.navigation.requestedChat?.id == "kept" && moved.navigation.presentedChat?.chatID == "kept")
        WorkSessionContext.shared.scope = "alice"
        let hidden = RecentScreen()
        hidden.visible = false
        hidden.delete()
        for _ in 0..<100 { await Task.yield() }
        precondition(hidden.projects.value.ids == ["kept"] && hidden.readers.removed == ["deleted"],
            "A completed Recent-chat deletion must clear caches even after the reader disappears")
        precondition(hidden.navigation.requestedChat == nil && hidden.navigation.presentedChat == nil)
        let other = RecentScreen()
        other.navigation.presentedChat = .init(peer: "mac", workspaceID: "project", chatID: "kept")
        other.navigation.requestedChat = .init(peer: "mac", workspace: "project", id: "kept")
        other.delete()
        precondition(other.navigation.presentedChat?.chatID == "kept" && other.navigation.requestedChat?.id == "kept")
        precondition(other.dismissals == 0, "Deleting one chat must not dismiss a different cover")
        let shown = RecentScreen()
        shown.navigation.presentedChat = nil
        shown.delete()
        precondition(shown.dismissals == 1, "The deleted visible Recent chat must close")
        let stale = RecentScreen()
        WorkSessionContext.shared.scope = "bob"
        stale.delete()
        for _ in 0..<100 { await Task.yield() }
        precondition(stale.projects.value.ids.count == 2 && stale.readers.removed.isEmpty,
            "An old Recent reader must not remove the new account's cache")
        print("Chat deletion retires cached rows, readers and matching destinations")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="tokenstat-chat-deletion-") as directory:
    path = Path(directory)
    (path / "test.swift").write_text(swift)
    subprocess.run(["swiftc", "-parse-as-library", str(path / "test.swift"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
