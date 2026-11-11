#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Render original project conversation children with inert, fixed-time owners.

These hidden-window source references are not GPUI captures or pixel approval.
No real ChatModel, draft store, host, transcript or account is instantiated.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import plistlib
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "apps/mac/Sources"
spec = importlib.util.spec_from_file_location("renderer", Path(__file__).with_name("linux-swiftui-render.py"))
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)
c = renderer.contract


def harness():
    chunks = [renderer.harness().split("@main struct Reference {")[0]]
    for path, marker in [
        ("Bridge/Models.swift", "struct ChatSharingMarker:"),
        ("Bridge/GitPullModels.swift", "struct BranchPull:"),
        ("Features/Workspaces/GitPullView.swift", "extension BranchPull {"),
        ("Bridge/Models.swift", "struct ChatConversation:"),
        ("App/SidebarPreferences.swift", "enum SidebarProjectsSort:"),
        ("App/SidebarProjectsLayout.swift", "struct SidebarChatEntry:"),
        ("App/SidebarProjectsLayout.swift", "enum SidebarChatDay:"),
        ("App/SidebarProjectsLayout.swift", "struct SidebarChatDayGroup:"),
        ("App/SidebarProjectsLayout.swift", "enum SidebarProjectsLayout {"),
        ("Features/Workspaces/Chat/ChatHistoryWindow.swift", "enum ChatHistoryWindow {"),
        ("Features/Workspaces/WorkspaceDirectoryPresentation.swift", "enum WorkspaceDirectoryPresentation:"),
        ("Design/CompactAge.swift", "enum CompactAge {"),
        ("Features/Workspaces/Chat/ChatTurnTiming.swift", "enum TurnElapsed {"),
        ("Design/NativeMenuTrigger.swift", "struct NativeMenuItem {"),
        ("Design/Skeleton.swift", "enum Skeleton {"),
        ("App/SidebarRowActions.swift", "struct SidebarRowActions:"),
        ("Features/Work/ChatDraftMark.swift", "struct ChatDraftMark:"),
        ("App/SidebarHoverCard.swift", "struct SidebarDetailButton<"),
        ("App/SidebarHoverCard.swift", "struct SidebarChatDetailButton:"),
    ]:
        value = c.declaration(path, marker)
        if marker == "enum Skeleton {":
            old = r"@Environment(\.accessibilityReduceMotion) private var reduceMotion"
            assert old in value
            value = value.replace(old, "private let reduceMotion = true")
        chunks.append(value)
    timing = c.declaration("Features/Workspaces/Chat/ChatTurnTiming.swift", "struct TurnElapsedText:")
    chunks.append(timing.replace("context.date", "ChatFixtureInput.now"))
    row = c.declaration("App/RootView.swift", "private struct ChatSidebarConversationRow:")
    assert "@State private var isHovering = false" in row
    row = row.replace("@State private var isHovering = false", "@State private var isHovering: Bool")
    assert "@State private var copying = false" in row
    row = row.replace("@State private var copying = false", "@State private var copying: Bool")
    initializer = r'''
    init(conversation: ChatConversation, folder: WorkspaceFolder,
         rename: @escaping (String) async throws -> Void, fork: @escaping () async throws -> Void,
         draft: WorkReference?, runningSince: Date?, isSelected: Bool,
         select: @escaping () -> Void, remove: @escaping () -> Void,
         warmPreview: @escaping () async -> Void) {
        self.conversation=conversation;self.folder=folder;self.rename=rename;self.fork=fork
        self.draft=draft;self.runningSince=runningSince;self.isSelected=isSelected
        self.select=select;self.remove=remove;self.warmPreview=warmPreview
        _isHovering=State(initialValue:ChatFixtureInput.value.hovered==conversation.id)
        _copying=State(initialValue:ChatFixtureInput.value.copying.contains(conversation.id))
    }
'''
    row = row.replace("    var body: some View {", initializer + "    var body: some View {", 1)
    chunks.append(row)
    trailing = c.declaration("App/RootView.swift", "extension ChatSidebarConversationRow {")
    old = "CompactAge.text(ms: conversation.lastMessageAtMs ?? conversation.updatedAtMs)"
    assert old in trailing
    chunks.append(trailing.replace(old, old[:-1] + ", now: ChatFixtureInput.now)"))
    chunks.append(r'''
struct ChatRoutingState: Codable, Hashable, Sendable {}
struct WorkspaceFolder: Hashable, Sendable {var id="/fixture/alpha";var name="alpha";var machineLabel: String? = nil}
struct ChatFixture: Decodable {
    var name: String;var rows: [ChatConversation];var presentation: String
    var expanded: Bool;var selected: String?;var hovered: String?;var shift: Bool
    var copying: [String]
    var drafts: [String:Bool];var held: [String]?;var now: Int64;var runningSince: Int64
}
@MainActor enum ChatFixtureInput {
    static var value: ChatFixture!
    static var now: Date {Date(timeIntervalSince1970:Double(value.now)/1000)}
}
@MainActor final class ChatDraftStore {
    static let shared=ChatDraftStore()
    func hasDraft(for reference: WorkReference) -> Bool {ChatFixtureInput.value.drafts[reference.itemID ?? ""] == true}
    func draft(for reference: WorkReference) -> Int? {hasDraft(for:reference) ? 1 : nil}
}
@MainActor final class SidebarModifierKeys {
    static let shared=SidebarModifierKeys()
    var shift: Bool {ChatFixtureInput.value.shift}
    func refresh() {}
}
@MainActor final class SidebarMenuTracking {static let shared=SidebarMenuTracking();var active=false}
struct NativeMenuTrigger: View {var items: () -> [NativeMenuItem];var accessibilityLabel: String;var body: some View {EmptyView()}}
extension View {func sidebarContextMenu(items: @escaping () -> [NativeMenuItem]) -> some View {self}}
@MainActor enum SidebarPinAction {static func items(reference: WorkReference?,name: String,folderName: String) -> [NativeMenuItem] {[]}}
struct SidebarChatDetailCard: View {var conversation: ChatConversation;var folder: WorkspaceFolder;var body: some View {EmptyView()}}
enum BridgeLaunch {static func wait() async {}}
@MainActor final class WorkSessionContext {static let shared=WorkSessionContext();var generation: UInt64=0}
@MainActor final class ChatModel {
    var folderID: String? {nil}
    var selected: ChatConversation? {ChatFixtureInput.value.rows.first {$0.id==ChatFixtureInput.value.selected}}
    func sidebarChats(in folder: String) -> [ChatConversation] {ChatFixtureInput.value.rows}
    func sidebarDirectoryPresentation(in folder: String) -> WorkspaceDirectoryPresentation {
        switch ChatFixtureInput.value.presentation {case "loading":return .loading;case "failed":return .failed;case "empty":return .empty;default:return .content}
    }
    func draftReference(for id: String,in folder: String) -> WorkReference? {
        WorkReference(scope:.local(installationID:"fixture-installation"),hostIdentity:"fixture-host",workspaceID:folder,kind:.conversation,itemID:id)
    }
    func turnStartedAt(for id: String) -> Date? {
        Date(timeIntervalSince1970:Double(ChatFixtureInput.value.runningSince)/1000)
    }
    func rename(_ chat: ChatConversation,in folder: String,to name: String) async throws {}
    func fork(_ chat: ChatConversation,in folder: String) async throws -> ChatConversation {chat}
    func reveal(id: String,in folder: String) {}
    func select(_ chat: ChatConversation) async {}
    func remove(_ chat: ChatConversation,in folder: String) async {}
    func warmConversationPreview(_ chat: ChatConversation,in folder: String) async {}
    func warmWorkspacePreviews(_ folder: String,includeMessages: Bool) async {}
    /* SOURCE_UNUSED */
    /* SOURCE_UNTOUCHED */
}
struct StubSession: Identifiable {var id="unused";var label="";var ssh: Bool?;var alive=false}
typealias TerminalSession = StubSession
final class Terminals {
    func workspaceTerminals(in folder: String) -> [StubSession] {[]}
    func activeTerminal(in folder: String) -> StubSession? {nil}
    func select(_ session: StubSession,in folder: String) {}
    func sendToOtherHalf(_ session: StubSession,in folder: String) {}
}
struct StubJob: Identifiable {var id="unused";var backend=""}
struct StubRun: Identifiable {var id="unused";var workflowID=""}
struct StubBackend {var id="unused";var label=""}
final class Automations {
    var selectedJobID: String?;var backends: [StubBackend]=[]
    func liveJobs(in folder: String) -> [StubJob] {[]}
    func lastRun(for job: StubJob) -> StubRun? {nil}
}
final class Workflows {var selectedRunID: String?;func liveRuns(in folder: String) -> [StubRun] {[]}}
struct ActiveAutomationRow: View {var job: StubJob;var backendLabel: String;var isSelected: Bool;var action: () -> Void;var body: some View {EmptyView()}}
struct ActiveWorkflowRow: View {var run: StubRun;var isSelected: Bool;var action: () -> Void;var body: some View {EmptyView()}}
struct SidebarRow: View {var label: String;var symbol: String;var isSelected: Bool;var indent: Int;var action: () -> Void;var body: some View {EmptyView()}}
private struct ProjectChildrenSurface: View {
    let chat=ChatModel();let terminals=Terminals();let automations=Automations();let workflows=Workflows()
    let chatOrderHold=ChatOrderHold()
    var route: Route {.workspace(id:"/fixture/alpha",section:.chat)}
    var projectsFilter=""
    var showingChatOverview=false
    var expandedChatHistories: Set<String> {ChatFixtureInput.value.expanded ? ["/fixture/alpha"] : []}
    init() {chatOrderHold.order["/fixture/alpha"]=ChatFixtureInput.value.held}
    func sessionRows(_ sessions: [StubSession],in folder: WorkspaceFolder,showingTerminal: Bool) -> some View {EmptyView()}
    func openSection(_ section: WorkspaceSection,in folder: String,then update: (() -> Void)? = nil) {update?()}
    func openAutomation(jobID: String,runID: String?,in folder: String) {}
    func openWorkflow(graphID: String,runID: String,in folder: String) {}
    func setProjectExpanded(_ id: String,_ expanded: Bool) {}
    func setHistoryExpanded(_ id: String,_ expanded: Bool) {}
    static func sidebarChatRowID(_ id: String) -> String {"fixture-chat-"+id}
    /* SOURCE_IDENTITY */
    /* SOURCE_HOLD */
    /* SOURCE_HOLDING */
    /* SOURCE_CHILDREN */
    @ViewBuilder /* SOURCE_ROWS */
    @ViewBuilder /* SOURCE_LIST */
    var body: some View {projectChildren(WorkspaceFolder(),sessions:[],showingTerminal:false).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)}
}
''')
    source = "\n\n".join(chunks)
    for name, file, marker in [
        ("UNUSED", "Features/Workspaces/Chat/ChatModel.swift", "func isUnused("),
        ("UNTOUCHED", "Features/Workspaces/Chat/ChatModel.swift", "func isUntouched("),
        ("IDENTITY", "App/RootView.swift", "private struct SidebarChatReadIdentity:"),
        ("HOLD", "App/RootView.swift", "final class ChatOrderHold {"),
        ("HOLDING", "App/RootView.swift", "static func holdingOrder("),
        ("CHILDREN", "App/RootView.swift", "private func projectChildren("),
        ("ROWS", "App/RootView.swift", "private func chatHistoryRows("),
        ("LIST", "App/RootView.swift", "private func chatHistoryList("),
    ]:
        source = source.replace(f"/* SOURCE_{name} */", c.declaration(file, marker))
    # A closed source overview is inert in this reference, including its callback.
    source = source.replace("var showingChatOverview=false", "@State var showingChatOverview=false")
    render = c.declaration_text(renderer.harness(), "@MainActor static func render<V: View>(")
    render = render.replace("window.isReleasedWhenClosed = false", "window.isReleasedWhenClosed = false\n        window.alphaValue=0")
    source += "\n@main struct ChatReference {\n" + render + r'''
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppFonts.register();guard AppFonts.registered else {throw NSError(domain:"Fonts",code:1)}
        let fixtures=try JSONDecoder().decode([ChatFixture].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        let output=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        for fixture in fixtures {
            ChatFixtureInput.value=fixture
            for dark in [false,true] {
                try render(ProjectChildrenSurface(),name:"children-"+fixture.name,width:272,height:340,dark:dark,output:output)
            }
        }
        guard !NSApp.isActive,NSApp.windows.allSatisfy({!$0.isVisible}) else {throw NSError(domain:"ReferenceWindows",code:1)}
        let environment: [String:Any]=["os":ProcessInfo.processInfo.operatingSystemVersionString,"locale":Locale.current.identifier,"languages":Locale.preferredLanguages,"displayFit":DisplayFit.factor,"active":NSApp.isActive,"visibleWindows":NSApp.windows.filter(\.isVisible).count]
        try JSONSerialization.data(withJSONObject:environment,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("environment.json"))
    }
}
'''
    return source


def main():
    if sys.platform != "darwin":
        raise SystemExit("Original SwiftUI chat references require macOS.")
    output = ROOT / "target/linux-chat-references"
    output.mkdir(parents=True, exist_ok=True)
    (output / "manifest.json").unlink(missing_ok=True)
    subprocess.run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--locked", "--no-default-features", "--example", "chat-fixtures"], cwd=ROOT, check=True)
    data = subprocess.check_output([ROOT / "apps/linux/target/debug/examples/chat-fixtures"])
    (output / "fixture.json").write_bytes(data)
    app = output / "ChatReference.app"
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / "apps/localization", resources / "localization", dirs_exist_ok=True)
    for font in ["Manrope", "JetBrainsMono"]:
        shutil.copy2(ROOT / f"apps/mac/Resources/Fonts/{font}-Variable.ttf", resources / f"{font}-Variable.ttf")
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"com.example.tokenstat.chat-reference", "CFBundleExecutable":"reference", "CFBundlePackageType":"APPL"}))
    subprocess.run(["xcrun", "actool", "--platform", "macosx", "--minimum-deployment-target", "14.0", "--target-device", "mac", "--compile", resources, ROOT / "apps/mac/Resources/Brands.xcassets", ROOT / "apps/mac/Resources/FeatureMarks.xcassets"], check=True)
    source = output / "Reference.swift"
    captured = set()
    original_declaration = c.declaration
    def tracked_declaration(path, marker):
        captured.add(SOURCE / path)
        return original_declaration(path, marker)
    c.declaration = tracked_declaration
    try:
        source.write_text(harness())
    finally:
        c.declaration = original_declaration
    executable = app / "Contents/MacOS/reference"
    compile_sources = [SOURCE / name for name in ["Design/AppFonts.swift", "Design/L10n.swift", "Design/SyntaxKind.swift", "Design/ActionIcon.swift", "Features/Work/WorkReference.swift", "App/Route.swift"]]
    subprocess.run(["swiftc", "-parse-as-library", *compile_sources, source, "-o", executable], check=True)
    subprocess.run([executable, output / "fixture.json", output], check=True, timeout=60)
    images = []
    for fixture in json.loads(data):
        for theme in ["light", "dark"]:
            name = f"children-{fixture['name']}-{theme}"
            png = (output / f"{name}.png").read_bytes()
            assert png[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", png[16:24]) == (544, 680), name
            images.append({"name":name, "sha256":hashlib.sha256(png).hexdigest(), "pixelSize":[544,680]})
    inputs = compile_sources + [source, Path(__file__), ROOT / "scripts/tests/linux-swiftui-render.py", ROOT / "scripts/tests/linux-swiftui-contract.py", ROOT / "apps/linux/src/chat/fixtures.rs"]
    inputs += [SOURCE / name for name in ["App/RootView.swift", "Bridge/Models.swift", "Bridge/GitPullModels.swift", "Design/Theme.swift", "Design/CompactAge.swift", "Design/Skeleton.swift", "App/SidebarRowActions.swift", "App/SidebarHoverCard.swift", "Features/Work/ChatDraftMark.swift", "Features/Workspaces/Chat/ChatHistoryWindow.swift", "Features/Workspaces/Chat/ChatTurnTiming.swift", "Features/Workspaces/Chat/ChatModel.swift", "Features/Workspaces/WorkspaceDirectoryPresentation.swift", "Features/Workspaces/GitPullView.swift"]]
    inputs += list((ROOT / "apps/mac/Resources/Fonts").glob("*.ttf"))
    inputs += [p for catalog in ["Brands.xcassets", "FeatureMarks.xcassets"] for p in (ROOT / "apps/mac/Resources" / catalog).rglob("*") if p.is_file()]
    inputs += list((ROOT / "apps/localization").rglob("*.json"))
    inputs += list(captured) + [SOURCE / "Design/ThemedSheet.swift"]
    manifest = {"renderer":"original SwiftUI projectChildren/chatHistory/row bodies in transparent, unordered windows", "scale":2, "images":images, "pixelParityVerified":False, "fixtureSha256":hashlib.sha256(data).hexdigest(), "inputs":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(inputs))}, "fixtureInjections":["fixed CompactAge/TurnElapsed clocks", "initial per-row hover state", "reduced motion", "inert chat/draft/terminal/job owners", "closed native/context menu and detail adapters"]}
    manifest["toolchain"] = {"swift":subprocess.check_output(["xcrun","swiftc","--version"],text=True,stderr=subprocess.STDOUT).strip(), "sdk":subprocess.check_output(["xcrun","--show-sdk-version"],text=True).strip()}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Rendered {len(images)} original chat-child references. No GPUI/Linux pixel or native input approval.")


if __name__ == "__main__":
    main()
