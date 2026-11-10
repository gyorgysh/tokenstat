#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Render original SwiftUI desktop components with synthetic Linux parity fixtures.

No visible window, live host, archive or account is opened. PNGs are reference
evidence, not a passing pixel comparison or Linux acceptance result.
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import plistlib
import re
import shutil
import subprocess
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "apps/mac/Sources"
spec = importlib.util.spec_from_file_location("swift_contract", Path(__file__).with_name("linux-swiftui-contract.py"))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


def harness():
    declarations = [
        ("Design/Theme.swift", "enum Theme {"),
        ("Design/Theme.swift", "extension Color {"),
        ("Design/Theme.swift", "enum DisplayFit {"),
        ("Design/Theme.swift", "struct Card<"),
        ("Design/Theme.swift", "struct Stat:"),
        ("Design/Theme.swift", "struct ThemeRule:"),
        ("Design/Theme.swift", "private struct ChromeBarMetrics:"),
        ("Design/Theme.swift", "struct InspectorChromeBar<"),
        ("Design/Theme.swift", "struct InspectorTitle:"),
        ("Design/Theme.swift", "extension InspectorChromeBar where Accessory == EmptyView"),
        ("Design/Theme.swift", "struct InspectorCloseButton:"),
        ("Design/Theme.swift", "struct ActionLabelStyle:"),
        ("Design/Theme.swift", "struct AccentButtonStyle:"),
        ("Design/Theme.swift", "struct ThemedFieldStyle:"),
        ("Design/Theme.swift", "extension TextFieldStyle where Self == ThemedFieldStyle"),
        ("Design/Theme.swift", "struct ThemedFieldBox:"),
        ("Design/FeatureMark.swift", "struct FeatureMark:"),
        ("Design/Marks.swift", "struct HarnessMark:"),
        ("Design/Marks.swift", "private extension Image"),
        ("Features/Workspaces/WorkspaceInspector.swift", "struct InspectorEmptyState<"),
        ("Features/Workspaces/WorkspaceInspector.swift", "extension InspectorEmptyState where Action == EmptyView"),
        ("Bridge/Models.swift", "struct HeatCell:"),
        ("Bridge/Models.swift", "struct DayDetail:"),
        ("Bridge/Models.swift", "struct DayPart:"),
        ("Bridge/Models.swift", "struct Counters:"),
        ("Bridge/Models.swift", "struct Bucket:"),
        ("Bridge/Models.swift", "struct Totals:"),
        ("Bridge/Models.swift", "struct Money:"),
        ("Bridge/Models.swift", "struct Machine:"),
        ("Client/ClientDeviceName.swift", "enum ClientDeviceIcon"),
        ("Features/Home/DesktopHomeWork.swift", "struct DesktopHomeMachines:"),
        ("Features/Home/DesktopHomeWork.swift", "struct DesktopHomeDestination:"),
        ("Features/Home/DesktopHomeWork.swift", "struct DesktopContinueSection:"),
        ("Features/Home/DesktopPinnedWorkSection.swift", "struct DesktopPinnedWorkSection:"),
        ("Design/Theme.swift", "struct ToolbarIconButton:"),
        ("Bridge/Models.swift", "extension UInt64 {"),
        ("Bridge/Models.swift", "func formatTokens("),
        ("Bridge/Models.swift", "func shortModel("),
        ("Bridge/Models.swift", "func harnessCanonicalID("),
        ("Bridge/Models.swift", "func harnessToolKey("),
        ("Bridge/Models.swift", "func harnessName("),
        ("Bridge/Models.swift", "func harnessBrandAsset("),
        ("Features/Home/HomeModel.swift", "struct DayOverview:"),
        ("Features/Home/HeatmapView.swift", "struct HoveredCellFrame:"),
        ("Features/Home/DayDetailPopover.swift", "struct DayDetailPopover:"),
        ("Features/Home/HomeInspector.swift", "struct HomeInspector:"),
        ("Features/Home/HomeInspector.swift", "private struct DayGroupRow:"),
    ]
    chunks = ["import AppKit\nimport SwiftUI\nimport Foundation\n"]
    chunks.extend(contract.declaration(path, marker) for path, marker in declarations)
    chunks.append((SOURCE/"Design/ThemedSheet.swift").read_text())
    chunks.append("extension View {"+contract.declaration("Design/Theme.swift","func themedFieldBox(")+"}")
    rename = contract.declaration("App/SidebarRowActions.swift","struct SidebarRenameSheet:")
    for before, after in [
        ('@State private var name = ""','@State private var name = RenameFixtureInput.name'),
        ('@State private var saving = false','@State private var saving = RenameFixtureInput.saving'),
        ('@State private var error: String?','@State private var error: String? = RenameFixtureInput.error'),
    ]:
        assert before in rename
        rename = rename.replace(before,after,1)
    chunks.append('enum RenameFixtureInput { static var name="alpha"; static var saving=false; static var error: String? }')
    chunks.append(rename)
    chunks.append(contract.pin_declarations())
    chunks.append('enum PinnedWorkActions { static func unpin(_ reference: WorkReference) async { fatalError("render fixture action must not run") } }')
    theme = (SOURCE / "Design/Theme.swift").read_text()
    for name in ["DetailChromeBarHeight", "DetailChromeBottomSpacing"]:
        chunks.append(re.search(rf"^let {name}: CGFloat = .+$", theme, re.MULTILINE)[0])
    chunks.append("extension View {" + contract.declaration("Design/Theme.swift", "func chromeBarMetrics()") + "}")
    chunks.append(r'''
// Immutable fixture state only. The original view reads these five properties;
// the production model, its polling and all host access are deliberately absent.
final class HomeModel {
    var selectedDay: HeatCell?
    var selectedDetail: DayDetail?
    var selectedOverview: DayOverview?
    var isLoadingSelectedDetail = false
    var isLoadingSelectedOverview = false
}
private struct OverviewInput: Decodable {
    var totals: Totals?; var byModel: [Bucket]; var bySource: [Bucket]; var byProject: [Bucket]; var bySession: [Bucket]
    var original: DayOverview { DayOverview(totals:totals,byModel:byModel,bySource:bySource,byProject:byProject,bySession:bySession) }
}
@main struct Reference {
    @MainActor static func render<V: View>(_ value: V, name: String, width: Int, height: Int, dark: Bool, output: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        let content = value
            .frame(width:CGFloat(width),height:CGFloat(height))
            .background(Theme.background)
            .tint(Theme.accent)
            .environment(\.colorScheme,dark ? .dark : .light)
        let view = NSHostingView(rootView:content)
        view.appearance = appearance
        let rect = NSRect(x:0,y:0,width:width,height:height)
        let window = NSWindow(contentRect:rect,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = view
        view.frame = rect
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // A fixed two-pixel scale, independent of the attached display.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width*2,pixelsHigh:height*2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) else { throw NSError(domain:"Bitmap",code:1) }
        bitmap.size = NSSize(width:width,height:height)
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let png = bitmap.representation(using:.png,properties:[:]) else { throw NSError(domain:"PNG",code:1) }
        try png.write(to:output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        window.contentView = nil
        window.close()
    }
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppFonts.register()
        guard AppFonts.registered else { throw NSError(domain:"Fonts",code:1) }
        let input = URL(fileURLWithPath:CommandLine.arguments[1])
        let output = URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        if CommandLine.arguments.count > 3 {
            let metricsInput = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3]))) as! [String:Any]
            let cases = metricsInput["cases"] as! [[String:Any]]
            var metrics: [[String:Any]] = []
            for value in cases {
                var result = value
                let points = value["points"] as! Double
                let weight: Font.Weight
                switch value["weight"] as! Int { case 700: weight = .bold; case 600: weight = .semibold; case 500: weight = .medium; default: weight = .regular }
                let font: Font
                if value["family"] as! String == ".SystemUIFont" { font = .system(size:points,weight:weight) }
                else if value["numeric"] as? Bool == true { font = Theme.numeric(points,weight:weight) }
                else { font = Theme.font(points,weight:weight) }
                let measured = NSHostingView(rootView:Text(value["text"] as! String).font(font)).fittingSize
                result["width"] = measured.width
                result["seat"] = ["line_height":measured.height]
                metrics.append(result)
            }
            try JSONSerialization.data(withJSONObject:["cases":metrics],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("swift-fonts.json"))
        }
        let raw = try JSONSerialization.jsonObject(with:Data(contentsOf:input)) as! [String:Any]
        let readings = ((raw["home"] as! [String:Any])["day"] as! [String:Any])["readings"] as! [[String:Any]]
        let fixture = readings[2]
        let detail = try JSONDecoder().decode(DayDetail.self,from:JSONSerialization.data(withJSONObject:fixture["detail"]!))
        let extra = try JSONDecoder().decode(OverviewInput.self,from:JSONSerialization.data(withJSONObject:fixture["extra"]!)).original
        for dark in [false,true] {
            for state in ["ready","empty","error","saving","retry"] {
                RenameFixtureInput.name = state == "empty" ? "" : "alpha"
                RenameFixtureInput.saving = state == "saving" || state == "retry"
                RenameFixtureInput.error = state == "error" || state == "retry" ? "The host could not rename this project." : nil
                try render(SidebarRenameSheet(title:L10n.text("apple.rootview.rename_project.2a0478ee"),currentName:RenameFixtureInput.name,save:{ _ in fatalError("render fixture action must not run") }),name:"rename-\(state)",width:460,height:RenameFixtureInput.error != nil ? 300 : 250,dark:dark,output:output)
                RenameFixtureInput.error = state == "error" || state == "retry" ? "The host could not rename this chat." : nil
                try render(SidebarRenameSheet(title:L10n.text("apple.rootview.rename_chat.26076241"),currentName:RenameFixtureInput.name,save:{ _ in fatalError("render fixture action must not run") }),name:"rename-chat-\(state)",width:460,height:RenameFixtureInput.error != nil ? 300 : 250,dark:dark,output:output)
            }
            for state in ["ready","empty","loading","locked","no-selection"] {
                let model = HomeModel()
                if state != "no-selection" { model.selectedDay = HeatCell(date:detail.date,value:1_500_000,level:2,locked:state == "locked") }
                if state == "ready" { model.selectedDetail = detail; model.selectedOverview = extra }
                model.isLoadingSelectedDetail = state == "loading"
                try render(HomeInspector(model:model,onOpenInsights:{ _ in },onClose:{}),name:"inspector-\(state)",width:400,height:797,dark:dark,output:output)
            }
            let anchor = HoveredCellFrame(date:detail.date,frame:CGRect(x:16,y:194,width:12,height:12))
            for loading in [false,true] {
                try render(DayDetailPopover(detail:loading ? nil : detail,isLoading:loading,anchor:anchor,windowSize:CGSize(width:360,height:400)),name:loading ? "popover-loading" : "popover-ready",width:360,height:400,dark:dark,output:output)
            }
            let devices = ((raw["home"] as! [String:Any])["devices"] as! [String:Any])["fixture"]!
            let machines = try JSONDecoder().decode([Machine].self,from:JSONSerialization.data(withJSONObject:devices))
            try render(DesktopHomeMachines(machines:machines,onOpen:{ _ in }),name:"machines-ready",width:400,height:220,dark:dark,output:output)
            try render(DesktopHomeMachines(machines:[],onOpen:{ _ in }),name:"machines-empty",width:400,height:220,dark:dark,output:output)
            let work = (raw["home"] as! [String:Any])["work"] as! [String:Any]
            let reading = (work["projections"] as! [[String:Any]])[0]["reading"] as! [String:Any]
            func reference(_ raw: Any) throws -> WorkReference { try JSONDecoder().decode(WorkReference.self,from:JSONSerialization.data(withJSONObject:raw)) }
            let destinations = try (reading["recent"] as! [[String:Any]]).map { row in
                DesktopHomeDestination(reference:try reference(row["reference"]!),title:row["title"] as! String,subtitle:row["subtitle"] as! String,unavailable:row["unavailable"] as? String)
            }
            let pinRows = reading["pins"] as! [[String:Any]]
            let pins = try pinRows.map { row -> PinnedWorkStore.Pin in
                let pin=row["pin"] as! [String:Any]
                return .init(reference:try reference(pin["reference"]!),label:pin["label"] as! String,folderName:pin["folderName"] as! String,pinnedAt:Date(timeIntervalSince1970:0))
            }
            let availability: (PinnedWorkStore.Pin) -> String? = { pin in pinRows.first { (($0["pin"] as! [String:Any])["label"] as? String) == pin.label }?["unavailable"] as? String }
            let subtitle: (PinnedWorkStore.Pin) -> String = { pin in pinRows.first { (($0["pin"] as! [String:Any])["label"] as? String) == pin.label }?["subtitle"] as? String ?? "" }
            try render(DesktopContinueSection(destinations:destinations,onOpen:{ _ in }),name:"continue-ready",width:400,height:360,dark:dark,output:output)
            try render(DesktopContinueSection(destinations:[],onOpen:{ _ in }),name:"continue-empty",width:400,height:360,dark:dark,output:output)
            try render(DesktopPinnedWorkSection(pins:pins,availability:availability,subtitle:subtitle,onOpen:{ _ in }),name:"pinned-ready",width:400,height:360,dark:dark,output:output)
            try render(DesktopPinnedWorkSection(pins:[],availability:availability,subtitle:subtitle,onOpen:{ _ in }),name:"pinned-empty",width:400,height:360,dark:dark,output:output)
        }
        let environment: [String:Any] = [
            "locale":Locale.current.identifier,
            "languages":Locale.preferredLanguages,
            "timezone":TimeZone.current.identifier,
            "displayFit":DisplayFit.factor,
            "os":ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        try JSONSerialization.data(withJSONObject:environment,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("environment.json"))
    }
}
''')
    return "\n\n".join(chunks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "target/linux-day-visuals")
    parser.add_argument("--compare-gpui-fonts", action="store_true", help="Also compare hidden-window GPUI font shaping/line boxes on this Mac.")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("Rendering the original SwiftUI reference requires macOS.")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # A failed rerun must not leave a previous success report looking current.
    for report in ["manifest.json","font-comparison.json"]:
        (output/report).unlink(missing_ok=True)
    metrics = None
    if args.compare_gpui_fonts:
        subprocess.run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--locked", "--example", "font-contract"], cwd=ROOT, check=True)
        metrics = output / "gpui-fonts.json"
        metrics.write_bytes(subprocess.check_output([ROOT / "apps/linux/target/debug/examples/font-contract"]))
    subprocess.run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--locked", "--no-default-features", "--example", "desktop-contract"], cwd=ROOT, check=True)
    fixture = subprocess.check_output([ROOT / "apps/linux/target/debug/examples/desktop-contract"], text=True)
    (output / "fixture.json").write_text(fixture)
    app = output / "SwiftUI Day Reference.app"
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / "apps/localization", resources / "localization", dirs_exist_ok=True)
    for font in ["Manrope", "JetBrainsMono"]:
        shutil.copy2(ROOT / f"apps/mac/Resources/Fonts/{font}-Variable.ttf", resources / f"{font}-Variable.ttf")
    # A test harness, never the product identity or an installed desktop variant.
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"com.example.tokenstat.swiftui-reference", "CFBundleExecutable":"reference", "CFBundlePackageType":"APPL"}))
    subprocess.run(["xcrun", "actool", "--platform", "macosx", "--minimum-deployment-target", "14.0", "--target-device", "mac", "--compile", resources, ROOT / "apps/mac/Resources/Brands.xcassets", ROOT / "apps/mac/Resources/FeatureMarks.xcassets"], check=True)
    source = output / "Reference.swift"
    source.write_text(harness())
    executable = app / "Contents/MacOS/reference"
    compile_sources=[SOURCE/"Design/AppFonts.swift",SOURCE/"Design/L10n.swift",SOURCE/"Design/SyntaxKind.swift",SOURCE/"Design/ActionIcon.swift",SOURCE/"Features/Work/WorkReference.swift"]
    subprocess.run(["swiftc", "-parse-as-library", *compile_sources, source, "-o", executable], check=True)
    subprocess.run([executable, output / "fixture.json", output] + ([metrics] if metrics else []), check=True)
    images = []
    names = [f"inspector-{state}-{theme}" for state in ["ready", "empty", "loading", "locked", "no-selection"] for theme in ["light", "dark"]]
    names += [f"popover-{state}-{theme}" for state in ["ready", "loading"] for theme in ["light", "dark"]]
    names += [f"machines-{state}-{theme}" for state in ["ready", "empty"] for theme in ["light", "dark"]]
    names += [f"{surface}-{state}-{theme}" for surface in ["continue", "pinned"] for state in ["ready", "empty"] for theme in ["light", "dark"]]
    names += [f"rename-{state}-{theme}" for state in ["ready","empty","error","saving","retry"] for theme in ["light","dark"]]
    names += [f"rename-chat-{state}-{theme}" for state in ["ready","empty","error","saving","retry"] for theme in ["light","dark"]]
    for name in names:
        png = (output / f"{name}.png").read_bytes()
        assert png[:8] == b"\x89PNG\r\n\x1a\n", f"{name}: missing PNG"
        dimensions = struct.unpack(">II", png[16:24])
        expected = (920,600 if any(state in name for state in ["-error-","-retry-"]) else 500) if name.startswith("rename-") else (800, 1594) if name.startswith("inspector-") else (800,440) if name.startswith("machines-") else (800,720) if name.startswith(("continue-","pinned-")) else (720, 800)
        assert dimensions == expected, f"{name}: wrong pixel dimensions {dimensions}"
        images.append({"name":name, "pixelSize":dimensions, "sha256":hashlib.sha256(png).hexdigest()})
    inputs=list(compile_sources)+[ROOT/"scripts/tests/linux-swiftui-render.py",ROOT/"scripts/tests/linux-swiftui-contract.py"]
    inputs += [SOURCE/name for name in ["Features/Home/DesktopHomeWork.swift","Features/Home/DesktopPinnedWorkSection.swift","Features/Work/PinnedWork.swift","Design/Theme.swift"]]
    inputs += [SOURCE/"Design/ThemedSheet.swift",SOURCE/"App/SidebarRowActions.swift"]
    inputs += list((ROOT/"apps/mac/Resources/Fonts").glob("*.ttf"))
    for catalog in ["Brands.xcassets","FeatureMarks.xcassets"]:
        inputs += [p for p in (ROOT/"apps/mac/Resources"/catalog).rglob("*") if p.is_file()]
    inputs += list((ROOT/"apps/localization").rglob("*.json"))
    manifest = {"renderer":"original SwiftUI views in hidden NSHostingView windows", "scale":2,
                "fixtureSha256":hashlib.sha256((output / "fixture.json").read_bytes()).hexdigest(),
                "harnessSha256":hashlib.sha256(source.read_bytes()).hexdigest(), "images":images,
                "inputs":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(inputs))},
                "pixelParityVerified":False, "fontComparisonRequested":bool(metrics)}
    (output / "manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
    print(f"Rendered and checked {len(images)} original SwiftUI component references in {output}. No pixel-parity signoff.", flush=True)
    if metrics:
        swift = json.loads((output / "swift-fonts.json").read_text())
        gpui = json.loads(metrics.read_text())
        differences = []
        for reference, actual in zip(swift["cases"], gpui["cases"], strict=True):
            label = f"fonts.{reference['family']}.{reference['points']}.{reference['weight']}.{reference['text']}"
            for key in ["family", "points", "weight", "text", "width"]:
                try:
                    contract.compare(reference[key], actual[key], f"{label}.{key}")
                except AssertionError as error:
                    differences.append(str(error))
            try:
                contract.compare(reference["seat"]["line_height"], actual["seat"]["line_height"], f"{label}.height")
            except AssertionError as error:
                differences.append(str(error))
        (output / "font-comparison.json").write_text(json.dumps({"cases":len(swift["cases"]), "differences":differences, "passed":not differences, "baselinesVerified":False},indent=2)+"\n")
        assert not differences, "Font parity is incomplete:\n" + "\n".join(differences)
        print(f"Native font comparison passed for {len(swift['cases'])} shaping widths and line boxes. Baseline seats are recorded separately, not signed off.")


if __name__ == "__main__":
    main()
