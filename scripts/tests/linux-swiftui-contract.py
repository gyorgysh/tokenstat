#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compare Rust design/navigation/layout with the actual compiled Swift sources.

This validates source/state parity. It is not a rendered UI or Linux acceptance test.
"""
from pathlib import Path
import json
import math
import re
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "apps/mac/Sources"


def declaration(path, marker):
    """Retain the original declaration, ignoring delimiters inside comments/strings."""
    return declaration_text((SOURCES / path).read_text(), marker)


def declaration_text(source, marker):
    """Extract a nested declaration from an already selected source owner."""
    start = source.index(marker)
    opening = source.index("{", start)
    index, depth, comment, quoted = opening, 0, 0, False
    while index < len(source):
        if comment:
            if source.startswith("/*", index):
                comment += 1
                index += 2
            elif source.startswith("*/", index):
                comment -= 1
                index += 2
            else:
                index += 1
            continue
        if quoted:
            if source[index] == "\\":
                index += 2
                continue
            if source[index] == '"':
                quoted = False
        elif source.startswith("//", index):
            next_line = source.find("\n", index)
            index = len(source) if next_line < 0 else next_line
            continue
        elif source.startswith("/*", index):
            comment = 1
            index += 2
            continue
        elif source[index] == '"':
            quoted = True
        elif source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
        index += 1
    raise ValueError(f"Unclosed Swift declaration: {marker}")


def swift_string(value):
    """Keep permitted JSON scalars that Swift source literals cannot contain."""
    literal = json.dumps(value, ensure_ascii=False)
    return "".join(f"\\u{{{ord(c):x}}}" if 0x7f <= ord(c) <= 0x9f or ord(c) in [0x2028, 0x2029] else c for c in literal)


def swift_harness(rust):
    chunks = ["import AppKit\nimport SwiftUI\nimport Foundation\n"]
    for file, marker in [
        ("Design/Theme.swift", "enum Theme {"),
        ("Design/Theme.swift", "extension Color {"),
        ("Design/Theme.swift", "enum DisplayFit {"),
        ("App/ShellChrome.swift", "enum ShellMetrics {"),
        ("App/ShellChrome.swift", "enum RailPlace:"),
        ("App/DesktopWorkbenchState.swift", "enum DesktopWorkbenchLayout {"),
    ]:
        chunks.append(declaration(file, marker))
    theme = (SOURCES / "Design/Theme.swift").read_text()
    for name in ["DetailChromeBarHeight", "DetailChromeBottomSpacing"]:
        chunks.append(re.search(rf"^let {name}: CGFloat = .+$", theme, re.MULTILINE)[0])
    chunks.append("""final class LayoutReference {
    var sidebarWidth = 272.0
    var inspectorWidth = 400.0
    var columnVisibilityChoice: NavigationSplitViewVisibility = .all
    var showsWorkspaceCompanion = false
    var browserPaneWidth = 520.0
    var windowContentWidth = 0.0
    var isSidebarPinned = false
    var isSidebarOverlayVisible = false
""")
    for marker in [
        "private static var widthForSidebar: CGFloat",
        "private func inspectorFits(at width: CGFloat)",
        "private func showsSidebarColumn(at width: CGFloat)",
        "private func sidebarColumnFits(width: Double, browserOpen: Bool, persistedBrowser: Double)",
        "private var sidebarColumnFits: Bool",
        "private func toggleLeftSidebar()",
    ]:
        chunks.append(declaration("App/RootView.swift", marker))
    root_view = (SOURCES / "App/RootView.swift").read_text()
    chunks.append(re.search(r"private static let comfortDetail: CGFloat = .+$", root_view, re.MULTILINE)[0])
    chunks.append("""
    func geometry(width: Double, companion: Double?, chosen: Bool, sidebar: Double, inspector: Double) -> [String: Any] {
        sidebarWidth = sidebar
        inspectorWidth = inspector
        columnVisibilityChoice = chosen ? .all : .detailOnly
        showsWorkspaceCompanion = companion != nil
        browserPaneWidth = companion ?? 520
        return ["width":width,"companion":companion.map { $0 as Any } ?? NSNull(),"chosen":chosen,"sidebarWidth":sidebar,"inspectorWidth":inspector,
                "sidebarFits":sidebarColumnFits(width:width,browserOpen:showsWorkspaceCompanion,persistedBrowser:browserPaneWidth),
                "showsSidebar":showsSidebarColumn(at:width),"inspectorFits":inspectorFits(at:width)]
    }
    func toggle(width: Double) -> [String: Any] {
        windowContentWidth = width
        toggleLeftSidebar()
        return ["width":width,"chosen":columnVisibilityChoice == .all,"pinned":isSidebarPinned,"overlay":isSidebarOverlayVisible]
    }
}
""")
    chunks.append(declaration("Design/NativeMenuTrigger.swift", "struct NativeMenuItem {"))
    chunks.append("""
final class AccountFixture {
    var signedIn = false
    var isSyncing = false
    var syncCooldownUntil: Date?
    func signIn() {}
    func sync() async {}
    func signOut() async {}
}
final class UpdateFixture {
    var isChecking = false
    func checkNow() async {}
}
struct AccountMenuReference {
    let account = AccountFixture()
    let appUpdate = UpdateFixture()
    func navigate(to route: Route) {}
""")
    chunks.append(declaration("App/RootView.swift", "private var accountMenuItems: [NativeMenuItem]"))
    chunks.append("""
    func snapshot(bits: Int) -> [[String:Any]] {
        account.signedIn = bits & 1 != 0
        account.isSyncing = bits & 2 != 0
        account.syncCooldownUntil = bits & 4 != 0 ? Date() : nil
        appUpdate.isChecking = bits & 8 != 0
        return accountMenuItems.map { entry in
            let kind: String
            switch entry.kind { case .action: kind = "action"; case .separator: kind = "separator"; case .heading: kind = "heading" }
            return ["kind":kind,"title":entry.title,"enabled":entry.isEnabled,"selected":entry.isSelected,"symbol":entry.symbol as Any? ?? NSNull(),"destructive":entry.destructive]
        }
    }
}
func colour(_ value: Color, dark: Bool) -> [Any] {
    var result: [Any] = []
    let appearance = NSAppearance(named:dark ? .darkAqua : .aqua)!
    appearance.performAsCurrentDrawingAppearance {
        let c = NSColor(value).usingColorSpace(.sRGB)!
        let rgb = (Int((c.redComponent*255).rounded()) << 16) | (Int((c.greenComponent*255).rounded()) << 8) | Int((c.blueComponent*255).rounded())
        result = [rgb,c.alphaComponent]
    }
    return result
}
@main struct Reference {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppFonts.register()
        guard AppFonts.registered else { throw NSError(domain:"FontFixture",code:1) }
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width:1440,height:900)
        var design: [String: Any] = [:]
""")
    prefixes = {"shell":"ShellMetrics", "space":"Theme.Space", "control":"Theme.Control", "modal":"Theme.Modal", "cards":"Theme", "workbench":"DesktopWorkbenchLayout"}
    for group, prefix in prefixes.items():
        values = []
        for name in rust["design"][group]:
            assert re.fullmatch(r"[a-zA-Z][a-zA-Z0-9]*", name)
            values.append(f'"{name}": {prefix}.{name}')
        chunks.append(f'design["{group}"] = [{",".join(values)}] as [String: Any]')
    chunks.append("""design["chromeHeight"] = DetailChromeBarHeight
        design["chromeBottomSpacing"] = DetailChromeBottomSpacing
        design["sidebarRange"] = [ShellMetrics.sidebarRange.lowerBound,ShellMetrics.sidebarRange.upperBound]
        design["inspectorRange"] = [ShellMetrics.inspectorRange.lowerBound,ShellMetrics.inspectorRange.upperBound]
        var palette: [String: Any] = [:]
""")
    for name in rust["palette"]:
        assert re.fullmatch(r"[a-zA-Z][a-zA-Z0-9]*", name)
        chunks.append(f'palette["{name}"] = ["light":colour(Theme.{name},dark:false),"dark":colour(Theme.{name},dark:true)]')
    chunks.append('let actionIcons: [[String:String]] = [')
    for icon in rust["actionIcons"]:
        name = icon["id"]
        assert re.fullmatch(r"[a-zA-Z][a-zA-Z0-9]*", name)
        chunks.append(f'["id":"{name}","symbol":ActionIcon.{name}.symbol],')
    chunks.append(']')
    chunks.append('var formatting: [[String:Any]] = []')
    for case in rust["formatting"]:
        # JSON string literals share Swift's syntax for these literal fixture values.
        template = json.dumps(case["template"], ensure_ascii=False)
        arguments = json.dumps(case["arguments"], ensure_ascii=False)
        chunks.append(f'formatting.append(["template":{template},"arguments":{arguments} as [String],"result":LanguageCatalog(strings:["fixture":{template}]).text("fixture",arguments:{arguments})])')
    chunks.append("""
        let rail = RailPlace.allCases.map { ["id":$0.rawValue,"label":$0.label,"symbol":$0.symbol] }
        let global = GlobalSection.allCases.map { section -> [String:Any] in
            let route = Route.global(section)
            return ["id":section.rawValue,"label":section.label,"symbol":section.symbol,"rail":RailPlace.of(route)?.rawValue as Any? ?? NSNull(),"hasInspector":route.hasInspector]
        }
        let workspace = WorkspaceSection.allCases.map { section -> [String:Any] in
            let route = Route.workspace(id:"fixture",section:section)
            return ["id":section.rawValue,"label":section.label,"symbol":section.symbol,"rail":RailPlace.of(route)?.rawValue as Any? ?? NSNull(),"hasInspector":route.hasInspector]
        }
        var geometry: [[String:Any]] = []
        for width in [0.0,720,999,1000,1260,1468,1600] {
            for companion: Double? in [nil,320,520] {
                for chosen in [false,true] {
                    for sidebar in [220.0,272,440] {
                        for inspector in [300.0,400,640] {
                            geometry.append(LayoutReference().geometry(width:width,companion:companion,chosen:chosen,sidebar:sidebar,inspector:inspector))
                        }
                    }
                }
            }
        }
        let reference = LayoutReference()
        let toggles = [1500.0,1500,720,720,720,1500].map { reference.toggle(width:$0) }
        let accountMenus = (0..<16).map { AccountMenuReference().snapshot(bits:$0) }
        let result: [String:Any] = ["rail":rail,"global":global,"workspace":workspace,"design":design,"palette":palette,"accountMenus":accountMenus,"actionIcons":actionIcons,"formatting":formatting,"home":try await homeSnapshot(),
            "fonts":["interface":AppFonts.interface,"mono":AppFonts.mono],"screen":[screen.width,screen.height],"floatingChrome":ShellMetrics.usesGlass,
            "displayFit":["factor":DisplayFit.factor,"box100":DisplayFit.box(100),"dp14":DisplayFit.dp(14),"scale100":DisplayFit.scale(100)],"geometry":geometry,"toggles":toggles]
        let data = try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
}
""")
    reference = (ROOT/"apps/linux/reference/ProjectMenuReference.swift").read_text()
    for marker, source in [
        ("PIN_ACTION", ("App/SidebarRowActions.swift", "enum SidebarPinAction {")),
        ("PROJECT_ACTIONS", ("App/RootView.swift", "private func projectActions(")),
        ("ROW_MENU", ("App/RootView.swift", "private var menu: [NativeMenuItem]")),
        ("PIN_REFERENCE", ("App/RootView.swift", "private func pinReference(")),
        ("REMOVE", ("Features/Workspaces/WorkspacesModel.swift", "func remove(_ folder:")),
    ]:
        reference = reference.replace(f"/* SOURCE_{marker} */", declaration(*source))
    data = swift_string(json.dumps(rust["projects"],ensure_ascii=False))
    reference += f'\n@MainActor func projectSnapshot() async throws -> [String:Any] {{ try await ProjectMenuReference.snapshot(JSONSerialization.jsonObject(with:Data({data}.utf8)) as! [String:Any]) }}\n'
    sidebar = (ROOT/"apps/linux/reference/SidebarReference.swift").read_text()
    sidebar = sidebar.replace("/* SOURCE_DISPLAY */", declaration("App/SidebarPreferences.swift", "enum SidebarProjectsDisplay: String, CaseIterable, Sendable {"))
    sidebar = sidebar.replace("/* SOURCE_SORT */", declaration("App/SidebarPreferences.swift", "enum SidebarProjectsSort: String, CaseIterable, Sendable {"))
    sidebar = sidebar.replace("/* SOURCE_PREFERENCES */", declaration("App/SidebarPreferences.swift", "final class SidebarPreferences {").replace("UserDefaults", "Defaults"))
    for name, marker in [("SECTION_SETTER", "private func setSidebarSectionExpanded("), ("PROJECT_SETTER", "private func setProjectExpanded(")]:
        sidebar = sidebar.replace(f"/* SOURCE_{name} */", declaration("App/RootView.swift", marker))
    # Only the disclosure portion is compiled here. Directory/route/retained
    # workbench cleanup is covered separately and is not claimed by this test.
    arrival = root_view.index("let incoming = Set(ids)", root_view.index(".onChange(of: workspaces.folders.map"))
    end = root_view.index("desktopWorkbench.retain(workspaces:", arrival)
    sidebar = sidebar.replace("/* SOURCE_ARRIVAL */", root_view[arrival:end])
    data = swift_string(json.dumps({"cases":[{"input":case["input"]} for case in rust["sidebar"]["cases"]]},ensure_ascii=False))
    sidebar += f'\nfunc sidebarSnapshot() throws -> [String:Any] {{ SidebarReference.snapshot(try JSONSerialization.jsonObject(with:Data({data}.utf8)) as! [String:Any]) }}\n'
    chat = (ROOT/"apps/linux/reference/ChatSidebarReference.swift").read_text()
    for name, source in [
        ("PATIENCE", ("Bridge/Bridge.swift", "enum Patience {")),
        ("HISTORY", ("Features/Workspaces/Chat/ChatHistoryWindow.swift", "enum ChatHistoryWindow {")),
        ("PRESENTATION", ("Features/Workspaces/WorkspaceDirectoryPresentation.swift", "enum WorkspaceDirectoryPresentation:")),
        ("AGE", ("Design/CompactAge.swift", "enum CompactAge {")),
        ("ELAPSED", ("Features/Workspaces/Chat/ChatTurnTiming.swift", "enum TurnElapsed {")),
        ("SHARING", ("Bridge/Models.swift", "struct ChatSharingMarker:")),
        ("PULL", ("Bridge/GitPullModels.swift", "struct BranchPull:")),
        ("CONVERSATION", ("Bridge/Models.swift", "struct ChatConversation:")),
        ("UNUSED", ("Features/Workspaces/Chat/ChatModel.swift", "func isUnused(")),
        ("UNTOUCHED", ("Features/Workspaces/Chat/ChatModel.swift", "func isUntouched(")),
        ("HOLDING", ("App/RootView.swift", "static func holdingOrder(")),
    ]:
        chat = chat.replace(f"/* SOURCE_{name} */", declaration(*source))
    row = declaration("App/RootView.swift", "private struct ChatSidebarConversationRow:")
    mark = declaration("Design/Marks.swift", "struct HarnessMark:")
    chat = chat.replace("/* SOURCE_INITIAL */", declaration_text(mark,"private var initial:"))
    model_source = (SOURCES/"Features/Workspaces/Chat/ChatModel.swift").read_text()
    chat = chat.replace("/* SOURCE_CACHE_CAP */", re.search(r"private static let chatListCacheCap = .+$",model_source,re.MULTILINE)[0])
    chat = chat.replace("/* SOURCE_MENU */", declaration_text(row, "private var menu:"))
    data = swift_string(json.dumps(rust["chats"],ensure_ascii=False))
    chat += f'\n@MainActor func chatSidebarSnapshot() throws -> [String:Any] {{ try ChatSidebarReference.snapshot(JSONSerialization.jsonObject(with:Data({data}.utf8)) as! [String:Any]) }}\n'
    return "\n\n".join(chunks).replace('"accountMenus":accountMenus,', '"accountMenus":accountMenus,"projects":try await projectSnapshot(),"sidebar":try sidebarSnapshot(),"chats":try chatSidebarSnapshot(),').replace("@main struct Reference", home_harness(rust["home"]) + reference + sidebar + chat + "\n@main struct Reference")


def home_harness(cases):
    """Compile original Home geometry/copy/formatting; no account/host operation runs."""
    chunks = [declaration(file, marker) for file, marker in [
        ("Bridge/Models.swift", "struct HeatCell:"),
        ("Bridge/Models.swift", "struct MonthLabel:"),
        ("Bridge/Models.swift", "struct ActivityCalendar:"),
        ("Bridge/Models.swift", "struct Money:"),
        ("Bridge/Models.swift", "func formatSpend("),
        ("Design/Greeting.swift", "enum HomeGreeting"),
        ("Features/Home/HomeModel.swift", "enum ActivityScope:"),
        ("Features/Home/HeatmapView.swift", "private struct GridLayout"),
        ("Features/Home/HeatmapView.swift", "private struct HoveredSlot"),
        ("Design/Theme.swift", "func quantised("),
    ]]
    chunks.append(day_harness(cases["day"]))
    chunks.append(layout_harness(cases["layout"]))
    chunks.append(plans_harness(cases["plans"]))
    chunks.append(devices_harness(cases["devices"]))
    chunks.append(work_harness(cases["work"]))
    chunks.append(storage_harness())
    chunks.append((SOURCES/"Features/Home/PlanLimitsStore.swift").read_text())
    store_reference = (ROOT/"apps/linux/reference/PlanLimitsReference.swift").read_text()
    store_reference = store_reference.replace("/* SOURCE_OWNER_UPDATE */", declaration("Features/Work/WorkSessionContext.swift", "func update(account:"))
    chunks.append(store_reference)
    chunks.append("final class FigureReference { var calendar: ActivityCalendar?")
    for marker in ["var todayValue:", "var weekValue:", "private var calendarDays:"]:
        chunks.append(declaration("Features/Home/HomeModel.swift", marker))
    chunks.append("func snapshot() -> [String:String] { [\"today\":todayValue.formatted,\"week\":weekValue.formatted] }\n}")
    chunks.append("struct CalendarShape { var weeks: Int; var rows: [[HeatCell?]] }\nfinal class HeatmapReference { var calendar = CalendarShape(weeks:0,rows:[])")
    source = (SOURCES / "Features/Home/HeatmapView.swift").read_text()
    for name in ["gutter", "gapRatio", "maxCell", "maxGapRatio"]:
        chunks.append(re.search(rf"private let {name}: CGFloat = .+$", source, re.MULTILINE)[0])
    for marker in ["private func cellSize(", "private func gapSize(", "private func gridHeight("]:
        chunks.append(declaration("Features/Home/HeatmapView.swift", marker))
    chunks.append("""
    func snapshot(width: Double, weeks: Int, rows: Int, points: [[Double]]) -> [String:Any] {
        calendar = CalendarShape(weeks:weeks,rows:Array(repeating:[],count:rows))
        let quantisedWidth = quantised(width,step:4)
        let cell = cellSize(for:quantisedWidth)
        let gap = gapSize(for:quantisedWidth,cell:cell)
        let layout = GridLayout(cell:cell,gap:gap,gutter:gutter,weeks:weeks,rows:rows)
        let cells: [[HeatCell?]] = rows == 0 ? [] : [[HeatCell(date:"2026-11-09",value:100,level:1,locked:false),nil,HeatCell(date:"2026-11-11",value:0,level:4,locked:true)]]
        let slots: [[String:Any]] = points.map { p in
            let slot = layout.slot(at:CGPoint(x:p[0],y:p[1]),in:cells)
            return ["x":p[0],"y":p[1],"slot":slot.map { [$0.row,$0.column] as Any } ?? NSNull()]
        }
        return ["width":width,"weeks":weeks,"rows":rows,"cell":cell,"gap":gap,"contentWidth":layout.contentWidth,"contentHeight":layout.contentHeight,"reservedHeight":gridHeight(for:width),"slots":slots]
    }
}
final class HomeFixtureModel { var calendar: ActivityCalendar?; var deliveredScope = ActivityScope.thisMachine; var scopeNotice: String?; var needsAccountSignIn = false }
final class HomeCopyReference { let model = HomeFixtureModel()
""")
    chunks.append(declaration("Features/Home/HomeView.swift", "private var activitySubtitle:").replace("private var", "var", 1))
    chunks.append("}\n@MainActor func homeSnapshot() async throws -> [String:Any] {")
    fixture_json = json.dumps(json.dumps(cases["fixture"], ensure_ascii=False), ensure_ascii=False)
    chunks.append(f"let fixtureData = Data({fixture_json}.utf8)\nlet fixture = try JSONDecoder().decode(ActivityCalendar.self,from:fixtureData)")
    chunks.append("let reference = HeatmapReference()\nvar geometry: [[String:Any]] = []")
    for case in cases["geometry"]:
        points = [[slot["x"], slot["y"]] for slot in case["slots"]]
        chunks.append(f'geometry.append(reference.snapshot(width:{case["width"]},weeks:{case["weeks"]},rows:{case["rows"]},points:{json.dumps(points)}))')
    chunks.append("var spend: [[String:Any]] = []")
    for case in cases["spend"]:
        chunks.append(f'let m{case["micros"]}: UInt64 = {case["micros"]}\nspend.append(["micros":m{case["micros"]},"text":formatSpend(m{case["micros"]})])')
    chunks.append("var greetings: [[String:Any]] = []")
    for case in cases["greetings"]:
        history = str(case["history"]).lower()
        chunks.append(f'greetings.append(["hour":{case["hour"]},"history":{history},"day":{case["day"]},"text":HomeGreeting.phrase(hour:{case["hour"]},hasHistory:{history},dayOfYear:{case["day"]})])')
    chunks.append("var subtitles: [[String:Any]] = []")
    for case in cases["subtitles"]:
        notice = json.dumps(case["noticeCode"]) if case["noticeCode"] is not None else "nil"
        chunks.append(f"""do {{
            let copy = HomeCopyReference(); var grid = fixture
            grid.scope = "{case['scope']}"; grid.noticeCode = {notice}; grid.notice = grid.noticeCode == nil ? nil : "Fixture notice"
            copy.model.calendar = grid; copy.model.deliveredScope = grid.scope == "account" ? .allMachines : .thisMachine
            copy.model.scopeNotice = grid.notice; copy.model.needsAccountSignIn = grid.noticeCode == "auth"
            subtitles.append(["scope":"{case['scope']}","noticeCode":grid.noticeCode as Any? ?? NSNull(),"text":copy.activitySubtitle])
        }}""")
    chunks.append("var lineHeights: [[String:Any]] = []")
    for case in cases["lineHeights"]:
        mono = str(case["mono"]).lower()
        family = "AppFonts.mono" if case["mono"] else "AppFonts.interface"
        chunks.append(f'lineHeights.append(["mono":{mono},"points":{case["points"]},"height":NSHostingView(rootView:Text("12345 days").font(.custom({family},fixedSize:{case["points"]}).weight(.medium))).fittingSize.height])')
    chunks.append("var figures: [[String:Any]] = []")
    for case in cases["figures"]:
        raw = json.dumps(json.dumps(case["input"], ensure_ascii=False), ensure_ascii=False)
        chunks.append(f' do {{ let data = Data({raw}.utf8); let ref = FigureReference(); ref.calendar = try JSONDecoder().decode(ActivityCalendar.self,from:data); var row: [String:Any] = ref.snapshot(); row["input"] = try JSONSerialization.jsonObject(with:data); figures.append(row) }}')
    owners = json.dumps(json.dumps(cases["store"]["owners"], ensure_ascii=False), ensure_ascii=False)
    chunks.append(f'let store = try await storeSnapshot(ownersJSON:{owners})')
    storage_json = swift_string(json.dumps(cases["storage"], ensure_ascii=False))
    chunks.append(f'let storage = try WorkStorageReference.snapshot({storage_json})')
    chunks.append("""return ["geometry":geometry,"spend":spend,"greetings":greetings,"subtitles":subtitles,"lineHeights":lineHeights,"day":try daySnapshot(),"layout":layoutSnapshot(),"plans":try plansSnapshot(),"figures":figures,"store":store,"devices":try devicesSnapshot(),"work":try workSnapshot(),"storage":storage,
        "fixture":try JSONSerialization.jsonObject(with:fixtureData),
        "heat":Theme.heat.map { ["light":colour($0,dark:false),"dark":colour($0,dark:true)] },
        "scopes":ActivityScope.allCases.map { ["wire":$0.wire,"label":$0.label,"symbol":$0.symbol] }]
    }
""")
    return "\n".join(chunks)


def layout_harness(cases):
    """Invoke the unmodified HomeLayout's pure normalization and movement."""
    inputs = json.dumps(json.dumps(cases, ensure_ascii=False), ensure_ascii=False)
    return """
@MainActor func layoutSnapshot() -> [String:Any] {
    let input = try! JSONSerialization.jsonObject(with:Data(INPUT.utf8)) as! [String:Any]
    func sections(_ raw: [String]) -> [HomeSection] { raw.compactMap(HomeSection.init(rawValue:)) }
    let sectionRows = HomeSection.allCases.map { ["id":$0.rawValue,"label":$0.label,"detail":$0.detail,"symbol":$0.symbol] }
    let presets: [[String:Any]] = HomePreset.allCases.map { preset in ["id":preset.rawValue,"label":preset.label,"order":preset.order.map(\\.rawValue),"hidden":preset.hidden.map(\\.rawValue).sorted(),"visible":preset.order.filter { !preset.hidden.contains($0) }.map(\\.rawValue)] }
    let normalizations: [[String:Any]] = (input["normalizations"] as! [[String:Any]]).map { item in
        let hidden = item["hidden"] as! [String]
        let order = (item["input"] as? [String]).map(sections)
        let result = HomeLayout.normalize(order:order,hidden:sections(hidden))
        return ["input":item["input"]!,"hidden":hidden,"order":result.order.map(\\.rawValue),"resolvedHidden":result.hidden.map(\\.rawValue).sorted()]
    }
    let moves: [[String:Any]] = (input["moves"] as! [[String:Any]]).map { item in
        let order = sections(item["input"] as! [String]); let hidden = Set(sections(item["hidden"] as! [String]))
        let offsets = IndexSet(item["offsets"] as! [Int]); let destination = item["destination"] as! Int
        return ["input":item["input"]!,"hidden":item["hidden"]!,"offsets":item["offsets"]!,"destination":destination,
                "all":HomeLayout.moved(order,from:offsets,to:destination).map(\\.rawValue),
                "visible":HomeLayout.movedVisible(order,hidden:hidden,from:offsets,to:destination).map(\\.rawValue)]
    }
    return ["sections":sectionRows,"presets":presets,"normalizations":normalizations,"moves":moves]
}
""".replace("INPUT", inputs)


def plans_harness(cases):
    """Decode the actual bridge types and invoke original panel presentation rules."""
    chunks = [declaration(file, marker) for file, marker in [
        ("Bridge/Models.swift", "enum LimitSeverity:"),
        ("Bridge/Models.swift", "struct UsageWindow:"),
        ("Bridge/Models.swift", "struct ProviderLimits:"),
        ("Bridge/Models.swift", "struct LimitsSyncState:"),
        ("Features/Home/PlanLimitsOrder.swift", "enum PlanLimitsOrder"),
        ("Features/Insights/PlanLimitsCard.swift", "enum PlanLimits {"),
    ]]
    chunks.append("private enum PanelWidthFixture { static var width: CGFloat = 330 }\nprivate extension CGFloat { static var panelWidth: CGFloat { PanelWidthFixture.width } }\nfinal class PlanColumnsReference { var panels: [Int] = []")
    chunks.append(declaration("Features/Home/HomeView.swift", "private func columnCount("))
    chunks.append("func snapshot(width: Double,count: Int,panelWidth: Double) -> Int { panels=Array(repeating:0,count:count); PanelWidthFixture.width=panelWidth; return columnCount(for:width) }\n}")
    raw = json.dumps(json.dumps(cases, ensure_ascii=False), ensure_ascii=False)
    chunks.append("@MainActor func plansSnapshot() throws -> [String:Any] {")
    chunks.append(f'let input = try JSONSerialization.jsonObject(with:Data({raw}.utf8)) as! [String:Any]')
    chunks.append("""
    func decode<T: Decodable>(_ type: T.Type,_ value: Any) throws -> T { try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value)) }
    let windows: [[String:Any]] = try (input["windows"] as! [[String:Any]]).map { item in
        let window = try decode(UsageWindow.self,item["input"]!)
        return ["input":item["input"]!,"label":window.displayLabel,"fraction":window.fraction,"percent":"\\(Int(window.percent.rounded()))%"]
    }
    let colors: [[String:Any]] = [LimitSeverity.normal,.warning,.critical].map { ["severity":$0.rawValue,"light":colour($0.tint,dark:false),"dark":colour($0.tint,dark:true)] }
    let providers: [[String:Any]] = try (input["providers"] as! [[String:Any]]).map { item in
        let provider = try decode(ProviderLimits.self,item["input"]!)
        let next = provider.nextReset.map { Int64(($0.timeIntervalSince1970*1000).rounded()) }
        return ["input":item["input"]!,"visible":!PlanLimits.visible([provider]).isEmpty,"stale":provider.isStale,"nextReset":next as Any? ?? NSNull(),"observed":provider.observedAt != nil]
    }
    let orderingInput = input["ordering"] as! [String:Any]
    let state = try decode(LimitsSyncState.self,orderingInput["input"]!)
    let ordered = PlanLimitsOrder.ordered(PlanLimits.visible(state.providers.filter { !state.skip.contains($0.source) }),source:\\.source)
    let ordering: [String:Any] = ["input":orderingInput["input"]!,"visible":ordered.map(\\.source)]
    let reference = PlanColumnsReference()
    let columns: [[String:Any]] = (input["columns"] as! [[String:Any]]).map { item in
        var result = item; result["columns"] = reference.snapshot(width:item["width"] as! Double,count:item["count"] as! Int,panelWidth:item["panelWidth"] as! Double); return result
    }
    let cache: [[String:Any]] = try (input["cache"] as! [[String:Any]]).map { item in
        let state = try decode(LimitsSyncState.self,item["input"]!)
        return ["input":item["input"]!,"enabled":state.enabled,"skip":state.skip,"providers":try JSONSerialization.jsonObject(with:JSONEncoder().encode(state.providers))]
    }
    let capitalized: [[String:Any]] = (input["capitalized"] as! [[String:Any]]).map { item in
        let text = item["input"] as! String; return ["input":text,"text":text.capitalized]
    }
    return ["windows":windows,"colors":colors,"providers":providers,"ordering":ordering,"columns":columns,"cache":cache,"capitalized":capitalized]
}
""")
    return "\n".join(chunks)


def devices_harness(cases):
    chunks = [declaration(file,marker) for file,marker in [
        ("Bridge/Models.swift","struct Machine:"),
        ("Client/ClientDeviceName.swift","enum ClientDeviceIcon"),
    ]]
    # Retain the exact Text expressions from the real Home device row.
    source = (SOURCES/"Features/Home/DesktopHomeWork.swift").read_text()
    label = re.search(r'Text\((machine\.label\.flatMap.*?)\)\s*\.font',source,re.DOTALL)[1]
    status = re.search(r'Text\((machine\.online == true.*?)\)\s*\.font',source,re.DOTALL)[1]
    chunks.append(f'''func deviceReading(_ machine: Machine) -> [String:Any] {{
        ["id":machine.id,"display":machine.displayName,"subtitle":machine.subtitle as Any? ?? NSNull(),"isHost":machine.isHost,"reportsArchiveSync":machine.reportsArchiveSync,
         "symbol":ClientDeviceIcon.symbol(for:machine),"homeLabel":{label},"status":{status}]
    }}''')
    chunks.append("struct Peer { var key: String }\nfinal class DeviceSelectionReference { var selectedKind: DeviceKind?; var peers: [Peer] = []; var accountMachines: [Machine] = []")
    for marker in ["enum DeviceKind:","enum SelectedDevice", "var selectedDevice:","func selectAccount("]:
        chunks.append(declaration("Features/Machines/MachinesModel.swift",marker))
    chunks.append('''func snapshot(before: [Machine],after: [Machine],index: Int?) -> [String:Any] {
        accountMachines=before; if let index { selectAccount(before[index]) }
        accountMachines=after
        let key: String?; if case let .account(id)? = selectedKind { key=id } else { key=nil }
        let selected: Any; if case let .account(machine) = selectedDevice { selected=deviceReading(machine) } else { selected=NSNull() }
        return ["key":key as Any? ?? NSNull(),"selected":selected]
    }\n}''')
    raw=json.dumps(json.dumps(cases,ensure_ascii=False),ensure_ascii=False)
    chunks.append(f'func devicesSnapshot() throws -> [String:Any] {{ let cases = try JSONSerialization.jsonObject(with:Data({raw}.utf8)) as! [String:Any]')
    chunks.append('''func machines(_ raw: Any) throws -> [Machine] { try JSONDecoder().decode([Machine].self,from:JSONSerialization.data(withJSONObject:raw)) }
        let records: [[String:Any]] = try (cases["records"] as! [[String:Any]]).map { item in
            let machine=try machines([item["input"]!])[0]; return ["input":item["input"]!,"reading":deviceReading(machine)]
        }
        let selections: [[String:Any]] = try (cases["selections"] as! [[String:Any]]).map { item in
            let reference=DeviceSelectionReference(); var row=item
            row.merge(try reference.snapshot(before:machines(item["before"]!),after:machines(item["after"]!),index:item["index"] as? Int)) { _,new in new }
            return row
        }
        return ["records":records,"selections":selections,"fixture":cases["fixture"]!]
    }''')
    return "\n".join(chunks)


def pin_declarations():
    chunks = ["enum PinnedWorkStore {"]
    for marker in ["struct Pin:", "nonisolated static func pinKey(", "private nonisolated static func validScope(", "private nonisolated static func validIdentifier("]:
        chunks.append(declaration("Features/Work/PinnedWork.swift", marker))
    return "\n".join(chunks) + "\n}"


def storage_harness():
    reference=(ROOT/"apps/linux/reference/WorkStorageReference.swift").read_text()
    reference=reference.replace("/* SOURCE_SCOPE_KEY */",declaration("Features/Work/WorkCache.swift","static func scope(for"))
    for marker,path in [("PINS","Features/Work/PinnedWork.swift"),("CONTINUITY","Features/Work/WorkContinuityStore.swift")]:
        source=(SOURCES/path).read_text()
        source=re.sub(r"^import .+$","",source,flags=re.MULTILINE)
        source=re.sub(r"\bUserDefaults\b","Defaults",source)
        reference=reference.replace(f"/* SOURCE_{marker} */",source)
    return reference


def work_harness(cases):
    chunks = [declaration("Features/Work/WorkDestinationResolver.swift", "enum WorkDestinationResolver"),
              declaration("Features/Work/WorkPlace.swift", "struct WorkPlace:"),
              declaration("Features/Work/WorkPlace.swift", "enum WorkPlaceRestoration"),
              declaration("Features/Home/DesktopHomeWork.swift", "struct DesktopHomeDestination:")]
    reference = (ROOT/"apps/linux/reference/HomeWorkReference.swift").read_text()
    for marker,source in [
        ("RECORD_ID", ("Features/Work/WorkCache.swift", "static func recordID(for")),
        ("RECORD_PREFIX", ("Features/Work/WorkCache.swift", "private static func recordPrefix(")),
        ("PIN", ("Features/Work/PinnedWork.swift", "struct Pin:")),
        ("PIN_KEY", ("Features/Work/PinnedWork.swift", "nonisolated static func pinKey(")),
        ("VALID_SCOPE", ("Features/Work/PinnedWork.swift", "private nonisolated static func validScope(")),
        ("VALID_IDENTIFIER", ("Features/Work/PinnedWork.swift", "private nonisolated static func validIdentifier(")),
        ("RECENT", ("App/RootView.swift", "private var recentHomeWork:")),
        ("AVAILABILITY", ("App/RootView.swift", "private func desktopAvailability(")),
        ("MESSAGE", ("App/RootView.swift", "private func workAvailabilityMessage(")),
        ("PIN_SUBTITLE", ("App/RootView.swift", "private func pinSubtitle(")),
        ("PIN_AVAILABILITY", ("App/RootView.swift", "private func pinAvailability(")),
        ("TERMINAL", ("App/RootView.swift", "private func terminalForPin(")),
        ("OPEN_RECENT", ("App/RootView.swift", "private func openHomeWork(")),
        ("OPEN_PIN", ("App/RootView.swift", "private func openPin(")),
    ]:
        reference = reference.replace(f"/* SOURCE_{marker} */", declaration(*source))
    chunks.append(reference)
    raw = json.dumps(json.dumps(cases, ensure_ascii=False), ensure_ascii=False)
    chunks.append(f'@MainActor func workSnapshot() throws -> [String:Any] {{ let cases=try JSONSerialization.jsonObject(with:Data({raw}.utf8)) as! [String:Any]')
    chunks.append('''let availability = (cases["availability"] as! [[String:Any]]).map { row -> [String:Any] in
        let input=row["input"] as! [String:Any]
        var facts=WorkDestinationResolver.AvailabilityFacts()
        facts.accountVerified=input["accountVerified"] as! Bool; facts.hostLinked=input["hostLinked"] as! Bool
        facts.accessAllowed=input["accessAllowed"] as? Bool; facts.supported=input["supported"] as? Bool; facts.itemExists=input["itemExists"] as? Bool
        facts.connected=input["connected"] as! Bool; facts.savedCopy=input["savedCopy"] as! Bool; facts.reconnecting=input["reconnecting"] as! Bool
        let result=WorkDestinationResolver.availability(facts)
        let message: String?
        switch result {
        case .live,.savedCopy: message=nil
        case .accessRequired: message=L10n.text("apple.rootview.verify_this_account_and_its_project_access.e7a9f207")
        case .hostRemoved: message=L10n.text("apple.rootview.this_machine_is_no_longer_linked.b502d162")
        case .itemDeleted: message=L10n.text("apple.rootview.this_work_is_no_longer_available.81259506")
        case .unsupportedHost: message=L10n.text("apple.rootview.update_the_host_to_open_this_work.596b980e")
        case .reconnecting: message=L10n.text("apple.rootview.reconnecting_to_the_machine.ff19692f")
        case .unavailable: message=L10n.text("apple.rootview.connect_the_machine_and_open_its_folder_in.04907021")
        }
        return ["input":input,"result":String(describing:result),"message":message as Any? ?? NSNull()]
    }
    let routes=(cases["routes"] as! [[String:Any]]).map { row -> [String:Any] in
        let result=WorkDestinationResolver.route(folderID:row["folder"] as! String,explicitPeer:row["explicit"] as? String)
        return ["folder":row["folder"]!,"explicit":row["explicit"]!,"result":["workspaceId":result.workspaceID,"peer":result.peer as Any? ?? NSNull()]]
    }
    let projections=try (cases["projections"] as! [[String:Any]]).map { row -> [String:Any] in
        let input=try JSONDecoder().decode(HomeWorkInput.self,from:JSONSerialization.data(withJSONObject:row["input"]!))
        return ["variant":row["variant"]!,"input":row["input"]!,"reading":HomeWorkProjectionReference(input).reading(input)]
    }
    return ["availability":availability,"routes":routes,"projections":projections,"fixture":cases["fixture"]!]
    }''')
    return "\n".join(chunks)


def day_harness(cases):
    """Use original day models, placement and pure inspector grouping methods."""
    chunks = [declaration(file, marker) for file, marker in [
        ("Bridge/Models.swift", "struct DayDetail:"),
        ("Bridge/Models.swift", "struct DayPart:"),
        ("Bridge/Models.swift", "struct Counters:"),
        ("Bridge/Models.swift", "struct Bucket:"),
        ("Bridge/Models.swift", "struct Totals:"),
        ("Bridge/Models.swift", "extension UInt64 {"),
        ("Bridge/Models.swift", "func formatTokens("),
        ("Bridge/Models.swift", "func shortModel("),
        ("Bridge/Models.swift", "func harnessCanonicalID("),
        ("Bridge/Models.swift", "func harnessToolKey("),
        ("Bridge/Models.swift", "func harnessName("),
        ("Bridge/Models.swift", "func harnessBrandAsset("),
        ("Features/Home/HomeModel.swift", "struct DayOverview:"),
        ("Features/Home/HomeInspector.swift", "private struct DayGroupRow:"),
        ("Features/Home/HeatmapView.swift", "struct HoveredCellFrame:"),
    ]]
    chunks.append("final class PopoverReference { var anchor: HoveredCellFrame?; var windowSize = CGSize.zero")
    source = (SOURCES / "Features/Home/DayDetailPopover.swift").read_text()
    for name in ["margin", "edgeInset"]:
        chunks.append(re.search(rf"private let {name}: CGFloat = .+$", source, re.MULTILINE)[0])
    for marker in ["private var preferredLeft:", "private var cardWidth:", "private var cardHeight:", "private var clampedX:", "private var clampedY:"]:
        chunks.append(declaration("Features/Home/DayDetailPopover.swift", marker))
    chunks.append("""
    func snapshot(width: Double,height: Double,rect: [String:Double]?) -> [String:Any] {
        windowSize = CGSize(width:width,height:height)
        anchor = rect.map { HoveredCellFrame(date:"fixture",frame:CGRect(x:$0["x"]!,y:$0["y"]!,width:$0["width"]!,height:$0["height"]!)) }
        return ["width":cardWidth,"height":cardHeight,"center_x":clampedX,"center_y":clampedY]
    }
}
final class InspectorReference {
""")
    for marker in ["private func modelRows(", "private func pricedModelRows(", "private func unpricedModelRows(", "private func isUnpriced(", "private func matchesUnpriced(", "private func harnessRows(", "private func bucketRow(", "private func fold(", "private static func sumCounters("]:
        chunks.append(declaration("Features/Home/HomeInspector.swift", marker))
    split = declaration("Features/Home/HomeInspector.swift", "private func split(")
    split_math = split.split("{", 1)[1].split("guard grand > 0", 1)[0]
    chunks.append("private func segments(_ detail: DayDetail) -> [[String:Any]] {" + split_math + """
        guard grand > 0 else { return [] }
        var result: [[String:Any]] = []
        for (kind,value) in [total.cacheRead,total.cacheWrite,total.output,total.fresh].enumerated() where value > 0 {
            let width = max(2,296 * Double(value) / Double(grand))
            let percent = Int(round(100 * Double(value) / Double(grand)))
            let item: [String:Any] = ["kind":kind,"value":value,"total":grand,"width":width,"percent":percent]
            result.append(item)
        }
        return result
    }
    private func row(_ value: DayGroupRow) -> [String:Any] {
        ["key":value.key,"label":value.label,"tokens":value.tokens,"value":value.value as Any? ?? NSNull(),"monospaced":value.monospaced]
    }
    func snapshot(_ detail: DayDetail,extra: DayOverview?) -> [String:Any] {
        let sums = Self.sumCounters(detail.rows)
        return ["priced":pricedModelRows(detail,extra:extra).map(row),"unpriced":unpricedModelRows(detail,extra:extra).map(row),"harnesses":harnessRows(detail,extra:extra).map(row),
            "projects":(extra?.byProject ?? []).map { row(bucketRow($0,display:$0.key,monospaced:true)) },"sessions":(extra?.bySession ?? []).map { row(bucketRow($0,display:$0.key,monospaced:true)) },
            "counters":[sums.fresh,sums.cacheRead,sums.cacheWrite5m,sums.cacheWrite1h,sums.output].map { $0 as Any? ?? NSNull() },"segments":segments(detail)]
    }
}
private struct OverviewInput: Decodable {
    var totals: Totals?; var byModel: [Bucket]; var bySource: [Bucket]; var byProject: [Bucket]; var bySession: [Bucket]
    var original: DayOverview { DayOverview(totals:totals,byModel:byModel,bySource:bySource,byProject:byProject,bySession:bySession) }
}
func daySnapshot() throws -> [String:Any] {
    var result: [String:Any] = [:]
""")
    encoded = json.dumps(json.dumps(cases, ensure_ascii=False), ensure_ascii=False)
    chunks.append(f"let input = try JSONSerialization.jsonObject(with:Data({encoded}.utf8)) as! [String:Any]")
    chunks.append("""
    result["geometry"] = (input["geometry"] as! [[String:Any]]).map { value -> [String:Any] in
        var out = value; let size = value["window"] as! [Double]
        out["result"] = PopoverReference().snapshot(width:size[0],height:size[1],rect:value["anchor"] as? [String:Double]); return out
    }
    result["money"] = (input["money"] as! [[String:Any]]).map { value -> [String:Any] in
        var out = value; out["text"] = Money(micros:(value["micros"] as! NSNumber).int64Value,estimated:value["estimated"] as! Bool,complete:value["complete"] as! Bool).formatted; return out
    }
    result["tokens"] = (input["tokens"] as! [[String:Any]]).map { value -> [String:Any] in
        var out = value; out["text"] = formatTokens((value["n"] as! NSNumber).uint64Value); return out
    }
    result["models"] = (input["models"] as! [[String:Any]]).map { value -> [String:Any] in
        var out = value; out["text"] = shortModel(value["id"] as! String); return out
    }
    result["harnesses"] = (input["harnesses"] as! [[String:Any]]).map { value -> [String:Any] in
        let id = value["id"] as! String
        return ["id":id,"canonical":harnessCanonicalID(id),"key":harnessToolKey(id),"name":harnessName(id),"asset":harnessBrandAsset(id) as Any? ?? NSNull()]
    }
    result["readings"] = try (input["readings"] as! [[String:Any]]).map { value -> [String:Any] in
        var out = value
        let detail = try JSONDecoder().decode(DayDetail.self,from:JSONSerialization.data(withJSONObject:value["detail"]!))
        let extra = value["extra"] is NSNull ? nil : try JSONDecoder().decode(OverviewInput.self,from:JSONSerialization.data(withJSONObject:value["extra"]!)).original
        out["result"] = InspectorReference().snapshot(detail,extra:extra); return out
    }
    return result
}
""")
    return "\n".join(chunks)


def compare(expected, actual, path="contract"):
    if isinstance(expected, dict):
        assert isinstance(actual, dict) and expected.keys() == actual.keys(), f"{path}: different keys"
        for key in expected:
            compare(expected[key], actual[key], f"{path}.{key}")
    elif isinstance(expected, list):
        assert isinstance(actual, list) and len(expected) == len(actual), f"{path}: different rows"
        for index, (left, right) in enumerate(zip(expected, actual)):
            compare(left, right, f"{path}[{index}]")
    elif type(expected) is int and type(actual) is int:
        assert expected == actual, f"{path}: Swift {expected} != Rust {actual}"
    elif isinstance(expected, (int, float)) and not isinstance(expected, bool):
        assert isinstance(actual, (int, float)) and math.isclose(expected, actual, rel_tol=1e-6, abs_tol=1e-5), f"{path}: Swift {expected} != Rust {actual}"
    else:
        assert expected == actual, f"{path}: Swift {expected!r} != Rust {actual!r}"


def main():
    if sys.platform != "darwin":
        raise SystemExit("The compiled SwiftUI reference requires macOS. Run the Rust tests on Linux.")
    subprocess.run(["cargo","build","--manifest-path","apps/linux/Cargo.toml","--locked","--no-default-features","--example","desktop-contract"],cwd=ROOT,check=True)
    binary = ROOT / "apps/linux/target/debug/examples/desktop-contract"
    output = ROOT / "target/linux-parity-reference"
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output) as temporary:
        work = Path(temporary)
        # Cargo's all-target GUI build can replace the public example path
        # while Swift compiles. Both reads must use one immutable executable;
        # feature-unified serde_json can otherwise change nested seed bytes.
        reference_binary = work / "desktop-contract"
        shutil.copy2(binary, reference_binary)
        rust = json.loads(subprocess.check_output([reference_binary],text=True))
        harness = work / "Reference.swift"
        harness.write_text(swift_harness(rust))
        app = work/"Reference.app"
        resources = app/"Contents/Resources"
        resources.mkdir(parents=True)
        (app/"Contents/MacOS").mkdir()
        shutil.copytree(ROOT/"apps/localization",resources/"localization")
        for font in ["Manrope", "JetBrainsMono"]:
            shutil.copy2(ROOT/f"apps/mac/Resources/Fonts/{font}-Variable.ttf",resources/f"{font}-Variable.ttf")
        (app/"Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"com.example.tokenstat.swiftui-contract","CFBundleExecutable":"reference","CFBundlePackageType":"APPL"}))
        executable = app/"Contents/MacOS/reference"
        subprocess.run(["swiftc","-parse-as-library",SOURCES/"App/Route.swift",SOURCES/"Design/AppFonts.swift",SOURCES/"Design/L10n.swift",SOURCES/"Design/SyntaxKind.swift",SOURCES/"Design/ActionIcon.swift",SOURCES/"Features/Home/HomeLayout.swift",SOURCES/"Features/Work/WorkReference.swift",harness,"-o",executable],check=True)
        swift = json.loads(subprocess.check_output([executable],text=True,timeout=90))
        rust = json.loads(subprocess.check_output([reference_binary,str(swift["screen"][0]),str(swift["screen"][1]),"floating" if swift["floatingChrome"] else "flat"],text=True))
        (output/"swift.json").write_text(json.dumps(swift,indent=2)+"\n")
        (output/"rust.json").write_text(json.dumps(rust,indent=2)+"\n")
        compare(swift,rust)
    print(f"SwiftUI/Rust source contract passed: {len(swift['rail'])} rail destinations, {len(swift['global'])} global routes, {len(swift['workspace'])} workspace routes, {len(swift['palette'])} adaptive colours, {len(swift['geometry'])} layout cases, {len(swift['toggles'])} sidebar transitions, {len(swift['accountMenus'])} account-menu states, {len(swift['actionIcons'])} action glyph mappings and {len(swift['formatting'])} text-formatting cases.")
    print(f"Home source contract passed: {len(swift['home']['geometry'])} heatmap layouts with gap/future/locked hit tests, {len(swift['home']['heat'])} heat levels, {len(swift['home']['scopes'])} scope options, {len(swift['home']['subtitles'])} delivered-scope subtitles, {len(swift['home']['spend'])} USD boundaries, {len(swift['home']['greetings'])} greetings and {len(swift['home']['lineHeights'])} native SwiftUI font line boxes.")
    day = swift["home"]["day"]
    print(f"Day source contract passed: {len(day['geometry'])} popover placements, {len(day['readings'])} inspector breakdowns, {len(day['money'])} qualified signed money values, {len(day['tokens'])} compact token boundaries, {len(day['models'])} model labels and {len(day['harnesses'])} harness labels/aliases.")
    layout = swift["home"]["layout"]
    print(f"Home arrangement source contract passed: {len(layout['sections'])} sections, {len(layout['presets'])} presets, {len(layout['normalizations'])} stored arrangements and {len(layout['moves'])} visible/full-list moves.")
    plans = swift["home"]["plans"]
    print(f"Home plan source contract passed: {len(plans['windows'])} quota labels/percentages, {len(plans['providers'])} provider visibility/stale/reset states, {len(plans['colors'])} severity colours, {len(plans['columns'])} panel layouts, {len(plans['cache'])} cache defaults, {len(plans['capitalized'])} plan titles and {len(swift['home']['figures'])} delivered-calendar figure cases.")
    store = swift["home"]["store"]
    print(f"Shared quota source contract passed: {len(store['transcript'])} original async store checkpoints and {len(store['owners'])} login/helper lifetime transitions.")
    devices = swift["home"]["devices"]
    print(f"Home device source contract passed: {len(devices['records'])} device labels/status/icons/identity cases and {len(devices['selections'])} selection/refresh/removal cases.")
    work = swift["home"]["work"]
    print(f"Home work source contract passed: {len(work['availability'])} availability states, {len(work['routes'])} identifier routes and {len(work['projections'])} original Home row/open-gate projections.")
    storage = swift["home"]["storage"]
    print(f"Work storage source contract passed: {len(storage['scopes'])} account origins, {len(storage['labels'])} Unicode labels, {len(storage['keys'])} identifier keys and {len(storage['cases'])} complete store traces.")
    print(f"Project menu source contract passed: {len(swift['projects']['menus'])} original project/row/pin menu states and {len(swift['projects']['references'])} captured target references.")
    print(f"Project removal source contract passed: {len(swift['projects']['removals'])} original dirty/local/remote/failure/selection traces.")
    print(f"Sidebar preferences source contract passed: {len(swift['sidebar']['cases'])} original store/disclosure/window traces, {sum(len(case['rows']) for case in swift['sidebar']['cases'])} checkpoints.")
    chats = swift["chats"]
    print(f"Chat sidebar source contract passed: {len(chats['windows'])} windows, {len(chats['loops'])} arrow steps, {len(chats['orders'])} held orders, {len(chats['menus'])} menus, {len(chats['presentation'])} directory states, {len(chats['untouched'])} untouched filters, {len(chats['wires'])} sidebar wire projections and {len(chats['initials'])} grapheme initials.")


if __name__ == "__main__":
    main()
