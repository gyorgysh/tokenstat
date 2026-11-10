#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Measure the original SwiftUI confirmation with transparent owned windows.

Native view content omits AppKit's separate glass compositor. Images and metrics
are reference evidence, not pixel parity or active keyboard/focus acceptance.
"""
from pathlib import Path
import argparse
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


def harness():
    prefix = renderer.harness().split("@main struct Reference {")[0]
    return prefix + "\nstruct WorkspaceFolder { var name: String }\n" + renderer.contract.declaration("App/RootView.swift", "private struct RemoveWorkspaceConfirm:") + r'''
@MainActor final class ConfirmationState: ObservableObject {
    @Published var folder: WorkspaceFolder?
    var removed: [String]=[]
    init(_ name: String) { folder=WorkspaceFolder(name:name) }
}
struct ConfirmationSurface: View {
    @ObservedObject var state: ConfirmationState
    var body: some View {
        Theme.background.frame(width:800,height:600)
            .background(RemoveWorkspaceConfirm(folder:$state.folder) { folder in state.removed.append(folder.name) })
            .tint(Theme.accent)
    }
}
@MainActor final class TransparentParent: NSObject, NSWindowDelegate {
    func window(_ window: NSWindow,willPositionSheet sheet: NSWindow,using rect: NSRect) -> NSRect {
        sheet.alphaValue=0
        for owned in NSApp.windows { owned.alphaValue=0 }
        return rect
    }
}
@main struct ConfirmationReference {
    @MainActor static func spin(_ seconds: TimeInterval) {
        let end=Date().addingTimeInterval(seconds)
        while Date()<end {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
    }
    static func rect(_ view: NSView,in content: NSView) -> [CGFloat] {
        let frame=view.convert(view.bounds,to:content)
        return [frame.minX,content.bounds.height-frame.maxY,frame.width,frame.height]
    }
    static func descendants(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(descendants) }
    static func colour(_ color: NSColor?) -> Any {
        guard let value=color?.usingColorSpace(.deviceRGB) else {return NSNull()}
        return [value.redComponent,value.greenComponent,value.blueComponent,value.alphaComponent]
    }
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppFonts.register()
        let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let cases=[("ready","alpha"),("long","A project with a deliberately long workspace name that wraps over multiple lines"),("unicode","東京・árvíztűrő・🐧"),("multiline","alpha\nnew line")]
        var records: [[String:Any]]=[]
        for dark in [false,true] {
            let appearance=NSAppearance(named:dark ? .darkAqua : .aqua)!
            NSApp.appearance=appearance
            for (name,folder) in cases {
                let state=ConfirmationState(folder),delegate=TransparentParent()
                let host=NSHostingView(rootView:ConfirmationSurface(state:state).environment(\.colorScheme,dark ? .dark : .light))
                let parent=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
                parent.isReleasedWhenClosed=false;parent.alphaValue=0;parent.delegate=delegate;parent.appearance=appearance
                parent.titleVisibility = .hidden;parent.titlebarAppearsTransparent=true
                parent.contentView=host;host.frame=NSRect(x:0,y:0,width:800,height:600)
                host.layoutSubtreeIfNeeded();parent.displayIfNeeded()
                let deadline=Date().addingTimeInterval(5)
                while parent.attachedSheet == nil && Date()<deadline {spin(0.02)}
                spin(0.12)
                guard let sheet=parent.attachedSheet, let content=sheet.contentView else {throw NSError(domain:"SourceConfirmationMissing",code:1)}
                guard NSApp.windows.allSatisfy({$0.alphaValue == 0}) else {throw NSError(domain:"ReferenceWindowNotTransparent",code:1)}
                let views=descendants(content)
                let buttons=views.compactMap {$0 as? NSButton}.sorted {rect($0,in:content)[0]<rect($1,in:content)[0]}
                let fields=views.compactMap {$0 as? NSTextField}.filter {!$0.isHidden}.sorted {rect($0,in:content)[1]<rect($1,in:content)[1]}
                let rows:[[String:Any]]=buttons.map { button in
                    ["title":button.title,"frame":rect(button,in:content),"destructive":button.hasDestructiveAction,"key":button.keyEquivalent,"modifiers":button.keyEquivalentModifierMask.rawValue,"enabled":button.isEnabled]
                }
                let texts:[[String:Any]]=fields.map { field in
                    ["text":field.stringValue,"frame":rect(field,in:content),"points":field.font?.pointSize ?? 0,"font":field.font?.fontName ?? "","alignment":field.alignment.rawValue,"colour":colour(field.textColor)]
                }
                var radius: CGFloat=0
                if let glass=NSApp.windows.flatMap({$0.contentView.map(descendants) ?? []}).first(where:{String(describing:type(of:$0)) == "NSGlassEffectView"}),glass.responds(to:NSSelectorFromString("cornerRadius")) {
                    radius=(glass.value(forKey:"cornerRadius") as? NSNumber)?.doubleValue ?? 0
                }
                guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(content.bounds.width)*2,pixelsHigh:Int(content.bounds.height)*2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) else {throw NSError(domain:"Bitmap",code:1)}
                bitmap.size=content.bounds.size;content.cacheDisplay(in:content.bounds,to:bitmap)
                let image="confirmation-\(name)-\(dark ? "dark" : "light")-content.png"
                try bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent(image))
                let enter=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:sheet.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
                let measuredSize=[content.bounds.width,content.bounds.height]
                let returnHandled=sheet.performKeyEquivalent(with:enter)
                spin(0.02)
                let afterReturnRemoved=state.removed
                let defaultButton=(sheet.defaultButtonCell?.controlView as? NSButton)?.title
                let initial=(sheet.initialFirstResponder as? NSButton)?.title
                var focusedReturn: [[String:Any]]=[]
                for button in buttons {
                    let focused=sheet.makeFirstResponder(button)
                    sheet.sendEvent(enter);spin(0.02)
                    focusedReturn.append(["title":button.title,"focused":focused,"removed":state.removed,"dismissed":state.folder == nil])
                }
                if name == "ready" {
                    let escape=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:sheet.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
                    _ = sheet.performKeyEquivalent(with:escape)
                } else {buttons.first(where:{$0.hasDestructiveAction})?.performClick(nil)}
                spin(0.06)
                var colours: [String:Any]=[:]
                appearance.performAsCurrentDrawingAppearance {
                    for (key,value) in ["window":NSColor.windowBackgroundColor,"control":.controlColor,"text":.labelColor,"red":.systemRed,"focus":.keyboardFocusIndicatorColor] {colours[key]=colour(value)}
                }
                records.append(["name":name,"folder":folder,"dark":dark,"size":measuredSize,"texts":texts,"buttons":rows,"cornerRadius":radius,"defaultButton":defaultButton as Any? ?? NSNull(),"initialButton":initial as Any? ?? NSNull(),"returnHandled":returnHandled,"focusedReturn":focusedReturn,"removedAfterReturn":afterReturnRemoved,"removedAfterResponse":state.removed,"dismissed":state.folder == nil,"colours":colours,"contentImage":image,"allWindowsTransparent":true,"appActive":NSApp.isActive])
                state.folder=nil;spin(0.06)
                parent.orderOut(nil);parent.close()
                for owned in NSApp.windows {owned.alphaValue=0;owned.orderOut(nil)}
                _ = delegate
            }
        }
        let result:[String:Any]=["cases":records,"glassComposited":false,"pixelParityVerified":false,"os":ProcessInfo.processInfo.operatingSystemVersionString,"locale":Locale.current.identifier,"languages":Locale.preferredLanguages]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("native.json"))
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT/"target/linux-confirmation-reference")
    parser.add_argument("--compare-gpui",action="store_true",help="Compare real hidden-window GPUI component frames with native content frames.")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("The original native SwiftUI confirmation requires macOS.")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    app = output/"Reference.app"
    resources = app/"Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    (app/"Contents/MacOS").mkdir(exist_ok=True)
    shutil.copytree(ROOT/"apps/localization", resources/"localization", dirs_exist_ok=True)
    for font in ["Manrope", "JetBrainsMono"]:
        shutil.copy2(ROOT/f"apps/mac/Resources/Fonts/{font}-Variable.ttf", resources/f"{font}-Variable.ttf")
    (app/"Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"com.example.tokenstat.confirmation-reference","CFBundleExecutable":"reference","CFBundlePackageType":"APPL"}))
    source = output/"Reference.swift"
    source.write_text(harness())
    compile_sources = [SOURCE/name for name in ["Design/AppFonts.swift","Design/L10n.swift","Design/SyntaxKind.swift","Design/ActionIcon.swift","Features/Work/WorkReference.swift"]]
    binary = app/"Contents/MacOS/reference"
    subprocess.run(["swiftc","-parse-as-library",*compile_sources,source,"-o",binary],check=True)
    subprocess.run([binary,output],check=True,timeout=40)
    native=json.loads((output/"native.json").read_text())
    for case in native["cases"]:
        assert case["allWindowsTransparent"] and not case["appActive"]
        assert case["defaultButton"] is None and not case["returnHandled"] and not case["removedAfterReturn"]
        assert case["buttons"][0]["key"] == "\x1b" and not case["buttons"][0]["destructive"]
        assert case["buttons"][1]["destructive"] and not case["buttons"][1]["key"]
        assert case["initialButton"] == case["buttons"][0]["title"]
        assert all(row["focused"] and not row["removed"] and not row["dismissed"] for row in case["focusedReturn"])
        assert case["dismissed"]
        assert case["removedAfterResponse"] == ([] if case["name"] == "ready" else [case["folder"]])
    inputs=compile_sources+[SOURCE/"App/RootView.swift",SOURCE/"App/TokenstatApp.swift",SOURCE/"Design/Theme.swift",SOURCE/"Design/ThemedSheet.swift",SOURCE/"App/SidebarRowActions.swift",Path(__file__).resolve(),ROOT/"scripts/tests/linux-swiftui-render.py",ROOT/"scripts/tests/linux-swiftui-contract.py"]
    inputs+=list((ROOT/"apps/localization").rglob("*.json"))+list((ROOT/"apps/mac/Resources/Fonts").glob("*.ttf"))
    for case in native["cases"]:
        data=(output/case["contentImage"]).read_bytes()
        assert data[:8] == b"\x89PNG\r\n\x1a\n"
        assert struct.unpack(">II",data[16:24]) == tuple(int(size*2) for size in case["size"])
    manifest={"cases":len(native["cases"]),"swift":subprocess.check_output(["swiftc","--version"],text=True,stderr=subprocess.STDOUT).strip(),"sdk":subprocess.check_output(["xcrun","--show-sdk-version"],text=True).strip(),"inputs":{str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs},"harnessSha256":hashlib.sha256(source.read_bytes()).hexdigest(),"images":{case["contentImage"]:hashlib.sha256((output/case["contentImage"]).read_bytes()).hexdigest() for case in native["cases"]},"glassComposited":False,"pixelParityVerified":False}
    (output/"manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
    print(f"Measured {len(native['cases'])} original SwiftUI confirmations and verified native role/key-equivalent/response cases. Glass, active focus and Linux pixels remain unverified.")
    if args.compare_gpui:
        subprocess.run(["cargo","build","--manifest-path","apps/linux/Cargo.toml","--locked","--example","confirmation-contract"],cwd=ROOT,check=True)
        result=subprocess.check_output([ROOT/"apps/linux/target/debug/examples/confirmation-contract",output/"native.json"],cwd=ROOT)
        (output/"gpui.json").write_bytes(result)
        gpui=json.loads(result)
        assert len(gpui["cases"]) == len(native["cases"])
        report=[]
        for source, actual in zip(native["cases"],gpui["cases"]):
            assert (source["name"],source["dark"]) == (actual["name"],actual["dark"])
            assert actual["content"]["title"] == source["texts"][0]["text"]
            assert actual["content"]["message"] == source["texts"][1]["text"]
            for native_button,button in zip(source["buttons"],actual["content"]["buttons"]):
                assert button["title"] == native_button["title"]
                assert (button["role"] == "destructive") == native_button["destructive"]
            panel=actual["rects"]["panel"]
            assert panel[2:] == source["size"], f"{source['name']}: panel size {panel[2:]} != {source['size']}"
            for key, expected in [("title",source["texts"][0]["frame"]),("message",source["texts"][1]["frame"]),("cancel",source["buttons"][0]["frame"]),("remove",source["buttons"][1]["frame"])]:
                rect=actual["rects"][key]
                relative=[rect[0]-panel[0],rect[1]-panel[1],*rect[2:]]
                assert relative == expected, f"{source['name']}/{key}: {relative} != native {expected}"
            report.append({"name":source["name"],"dark":source["dark"],"framesMatch":True})
        (output/"layout-comparison.json").write_text(json.dumps({"cases":report,"pixelParityVerified":False,"activeFocusVerified":False},indent=2)+"\n")
        print(f"Actual GPUI/native content frames match exactly for {len(report)} cases, including native text wrapping. This is not pixel/material/focus signoff.")


if __name__ == "__main__":
    main()
