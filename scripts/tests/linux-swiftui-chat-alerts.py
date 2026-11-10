#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Measure the actual sidebar fork alert in transparent, owned SwiftUI windows.

Content snapshots omit the separate native glass compositor. No host or account
is constructed; this is reference evidence, not Linux pixel/input acceptance.
"""
from pathlib import Path
import hashlib
import argparse
import importlib.util
import json
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "apps/mac/Sources"
spec = importlib.util.spec_from_file_location("renderer", Path(__file__).with_name("linux-swiftui-render.py"))
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


def harness():
    row = renderer.contract.declaration("App/RootView.swift", "private struct ChatSidebarConversationRow:")
    alert = row[row.index("        .alert("):row.index("        .confirmationDialog(")]
    prefix = renderer.harness().split("@main struct Reference {")[0]
    return prefix + r'''
@MainActor final class AlertState: ObservableObject {
    @Published var error: String?
    init(_ error: String) {self.error=error}
}
struct AlertSurface: View {
    @ObservedObject var state: AlertState
    var actionError: String? {get {state.error} nonmutating set {state.error=newValue}}
    var body: some View {Theme.background.frame(width:800,height:600)
/* ORIGINAL_ALERT */
    }
}
@MainActor final class TransparentParent: NSObject,NSWindowDelegate {
    func window(_ window: NSWindow,willPositionSheet sheet: NSWindow,using rect: NSRect) -> NSRect {
        sheet.alphaValue=0
        for owned in NSApp.windows {owned.alphaValue=0}
        return rect
    }
}
@main struct AlertReference {
    @MainActor static func spin(_ seconds: TimeInterval) {
        let end=Date().addingTimeInterval(seconds)
        while Date()<end {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
    }
    static func descendants(_ view: NSView) -> [NSView] {[view]+view.subviews.flatMap(descendants)}
    static func rect(_ view: NSView,in content: NSView) -> [CGFloat] {
        let f=view.convert(view.bounds,to:content)
        return [f.minX,content.bounds.height-f.maxY,f.width,f.height]
    }
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited);AppFonts.register()
        let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        NSApp.applicationIconImage=NSImage(contentsOfFile:CommandLine.arguments[2])
        let cases=[("failed","The host could not copy this chat."),
                   ("long","The host could not copy this chat. A deliberately long failure message wraps over several lines so the original native alert decides its own content size."),
                   ("unicode","東京・árvíztűrő・🐧\nThe host is unavailable."),
                   ("account-changed",L10n.text("apple.chatmodel.the_account_changed_while_copying_the_chat.223191a0")),
                   ("unsupported",L10n.text("apple.bridge.update_the_project_s_computer_to_fork_chat.4d57279f"))]
        var records:[[String:Any]]=[]
        for dark in [false,true] {
            let appearance=NSAppearance(named:dark ? .darkAqua : .aqua)!
            NSApp.appearance=appearance
            for (name,message) in cases {
                let state=AlertState(message),delegate=TransparentParent()
                let host=NSHostingView(rootView:AlertSurface(state:state).environment(\.colorScheme,dark ? .dark : .light))
                let parent=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
                parent.isReleasedWhenClosed=false;parent.alphaValue=0;parent.delegate=delegate;parent.appearance=appearance
                parent.contentView=host;host.frame=NSRect(x:0,y:0,width:800,height:600)
                host.layoutSubtreeIfNeeded();parent.displayIfNeeded()
                let deadline=Date().addingTimeInterval(5)
                while parent.attachedSheet==nil && Date()<deadline {spin(0.02)}
                spin(0.12)
                guard let sheet=parent.attachedSheet,let content=sheet.contentView else {throw NSError(domain:"AlertMissing",code:1)}
                guard NSApp.windows.allSatisfy({$0.alphaValue==0}) else {throw NSError(domain:"ReferenceNotTransparent",code:1)}
                let views=descendants(content)
                let buttons=views.compactMap {$0 as? NSButton}.sorted {rect($0,in:content)[0]<rect($1,in:content)[0]}
                let fields=views.compactMap {$0 as? NSTextField}.filter {!$0.isHidden}.sorted {rect($0,in:content)[1]<rect($1,in:content)[1]}
                let images=views.compactMap {$0 as? NSImageView}.filter {!$0.isHidden}.map {image -> [String:Any] in ["frame":rect(image,in:content),"size":image.image.map {[$0.size.width,$0.size.height]} ?? [],"name":image.image?.name() as Any? ?? NSNull()]}
                let text:[[String:Any]]=fields.map {field in ["text":field.stringValue,"frame":rect(field,in:content),"points":field.font?.pointSize ?? 0,"font":field.font?.fontName ?? "","alignment":field.alignment.rawValue]}
                let buttonRows:[[String:Any]]=buttons.map {button in ["title":button.title,"frame":rect(button,in:content),"key":button.keyEquivalent,"modifiers":button.keyEquivalentModifierMask.rawValue,"destructive":button.hasDestructiveAction]}
                var radius:CGFloat=0
                if let glass=NSApp.windows.flatMap({$0.contentView.map(descendants) ?? []}).first(where:{String(describing:type(of:$0))=="NSGlassEffectView"}),glass.responds(to:NSSelectorFromString("cornerRadius")) {radius=(glass.value(forKey:"cornerRadius") as? NSNumber)?.doubleValue ?? 0}
                guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(content.bounds.width)*2,pixelsHigh:Int(content.bounds.height)*2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) else {throw NSError(domain:"BitmapMissing",code:1)}
                bitmap.size=content.bounds.size;content.cacheDisplay(in:content.bounds,to:bitmap)
                let image="fork-\(name)-\(dark ? "dark" : "light").png"
                var visiblePixels=0
                for y in 0..<bitmap.pixelsHigh {for x in 0..<bitmap.pixelsWide {
                    if (bitmap.colorAt(x:x,y:y)?.alphaComponent ?? 0)>0 {visiblePixels += 1}
                }}
                guard visiblePixels>100 else {throw NSError(domain:"EmptyNativeAlertCapture",code:1)}
                try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(image))
                // Native glass lives in a separate window. This labelled matte
                // is for inspection, never a glass or pixel comparison.
                let previewName="fork-\(name)-\(dark ? "dark" : "light")-flat-preview.png"
                let preview=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:bitmap.pixelsWide,pixelsHigh:bitmap.pixelsHigh,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                preview.size=content.bounds.size
                let graphics=NSGraphicsContext(bitmapImageRep:preview)!
                let context=graphics.cgContext
                context.concatenate(context.ctm.inverted())
                let pixels=CGRect(x:0,y:0,width:bitmap.pixelsWide,height:bitmap.pixelsHigh)
                var background=NSColor.white
                appearance.performAsCurrentDrawingAppearance {background=NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)!}
                context.setFillColor(red:background.redComponent,green:background.greenComponent,blue:background.blueComponent,alpha:1)
                context.fill(pixels);context.setBlendMode(.normal)
                context.draw(bitmap.cgImage!,in:pixels)
                guard (preview.colorAt(x:0,y:0)?.alphaComponent ?? 0)==1 else {throw NSError(domain:"InvalidInspectionMatte",code:1)}
                try preview.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(previewName))
                let initial=(sheet.initialFirstResponder as? NSButton)?.title
                let defaultButton=(sheet.defaultButtonCell?.controlView as? NSButton)?.title
                let enter=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:sheet.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
                let handled=sheet.performKeyEquivalent(with:enter);spin(0.03)
                let afterReturn=state.error==nil
                let buttonFocused=buttons.first.map {sheet.makeFirstResponder($0)} ?? false
                let focusedReturn=sheet.performKeyEquivalent(with:enter);spin(0.03)
                let afterFocusedReturn=state.error==nil
                var escaped=false
                if state.error != nil {
                    if name=="failed" {
                        let escape=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:sheet.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
                        escaped=sheet.performKeyEquivalent(with:escape)
                    } else {buttons.first?.performClick(nil)}
                    spin(0.03)
                }
                records.append(["name":name,"dark":dark,"message":message,"size":[content.bounds.width,content.bounds.height],"texts":text,"buttons":buttonRows,"images":images,"initialButton":initial as Any? ?? NSNull(),"defaultButton":defaultButton as Any? ?? NSNull(),"returnHandled":handled,"dismissedAfterReturn":afterReturn,"focusedReturnHandled":focusedReturn,"buttonFocused":buttonFocused,"dismissedAfterFocusedReturn":afterFocusedReturn,"escapeHandled":escaped,"dismissed":state.error==nil,"contentImage":image,"inspectionPreview":previewName,"visiblePixels":visiblePixels,"allWindowsTransparent":true,"appActive":NSApp.isActive,"cornerRadius":radius])
                state.error=nil;spin(0.03);parent.orderOut(nil);parent.close()
                for owned in NSApp.windows {owned.alphaValue=0;owned.orderOut(nil)}
            }
        }
        let outputData:[String:Any]=["cases":records,"glassComposited":false,"pixelParityVerified":false,"os":ProcessInfo.processInfo.operatingSystemVersionString]
        try JSONSerialization.data(withJSONObject:outputData,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("native.json"))
    }
}
'''.replace("/* ORIGINAL_ALERT */", alert)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compare-gpui", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "target/linux-chat-alert-reference")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("The original native SwiftUI alert requires macOS.")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / "manifest.json").unlink(missing_ok=True)
    for name in ["gpui.json", "layout-comparison.json"]:
        (output / name).unlink(missing_ok=True)
    app = output / "Reference.app"
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    (app / "Contents/MacOS").mkdir(exist_ok=True)
    shutil.copytree(ROOT / "apps/localization", resources / "localization", dirs_exist_ok=True)
    for font in ["Manrope", "JetBrainsMono"]:
        shutil.copy2(ROOT / f"apps/mac/Resources/Fonts/{font}-Variable.ttf", resources / f"{font}-Variable.ttf")
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.example.tokenstat.chat-alert-reference", "CFBundleExecutable": "reference", "CFBundlePackageType": "APPL"}))
    source = output / "Reference.swift"
    source.write_text(harness())
    compiled = [SOURCE / name for name in ["Design/AppFonts.swift", "Design/L10n.swift", "Design/SyntaxKind.swift", "Design/ActionIcon.swift", "Features/Work/WorkReference.swift"]]
    icon = ROOT / "apps/mac/Resources/Assets.xcassets/AppIcon.appiconset/app-icon-light-128.png"
    binary = app / "Contents/MacOS/reference"
    subprocess.run(["swiftc", "-parse-as-library", *compiled, source, "-o", binary], check=True, timeout=120)
    subprocess.run([binary, output, icon], check=True, timeout=40)
    native = json.loads((output / "native.json").read_text())
    for case in native["cases"]:
        assert case["allWindowsTransparent"] and not case["appActive"] and case["dismissed"]
        assert not case["images"] and case["cornerRadius"] == 26
        assert len(case["buttons"]) == 1 and not case["buttons"][0]["destructive"]
        assert case["buttons"][0]["key"] == "\x1b" and case["initialButton"] == case["buttons"][0]["title"]
        assert case["defaultButton"] is None and not case["returnHandled"] and not case["dismissedAfterReturn"]
        assert case["buttonFocused"] and not case["focusedReturnHandled"] and not case["dismissedAfterFocusedReturn"]
        assert case["escapeHandled"] == (case["name"] == "failed")
    inputs = [*compiled, SOURCE / "App/RootView.swift", Path(__file__).resolve(), icon,
              ROOT / "scripts/tests/linux-swiftui-render.py", ROOT / "scripts/tests/linux-swiftui-contract.py"]
    inputs += list((ROOT / "apps/localization").rglob("*.json"))
    inputs += list((ROOT / "apps/mac/Resources/Fonts").glob("*.ttf"))
    if args.compare_gpui:
        inputs += [ROOT / name for name in ["apps/linux/src/confirmation.rs", "apps/linux/src/desktop/confirmation_view.rs",
                   "apps/linux/src/desktop.rs", "apps/linux/src/presentation.rs", "apps/linux/src/design.rs",
                   "apps/linux/src/chat/fixtures.rs", "apps/linux/examples/fork-alert-contract.rs",
                   "apps/linux/Cargo.toml", "apps/linux/Cargo.lock", "apps/linux/build.rs"]]
    manifest = {"cases": len(native["cases"]), "glassComposited": False, "pixelParityVerified": False,
                "substitutions": ["original sidebar alert modifier on an inert error binding", "product app icon assigned inside the reference process", "transparent inactive owned windows"],
                "inputs": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs},
                "harnessSha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                "images": {case[key]: hashlib.sha256((output / case[key]).read_bytes()).hexdigest() for case in native["cases"] for key in ["contentImage", "inspectionPreview"]},
                "inspectionPreview": "native foreground over a flat semantic background; separate glass is not captured",
                "swift": subprocess.check_output(["swiftc", "--version"], text=True).strip(),
                "sdk": subprocess.check_output(["xcrun", "--show-sdk-version"], text=True).strip()}
    if args.compare_gpui:
        manifest["rust"] = subprocess.check_output(["rustc", "--version"], text=True).strip()
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Measured {len(native['cases'])} original fork alerts; no native input or pixel signoff.")
    if args.compare_gpui:
        subprocess.run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--locked", "--example", "fork-alert-contract"], cwd=ROOT, check=True)
        result = subprocess.check_output([ROOT / "apps/linux/target/debug/examples/fork-alert-contract", output / "native.json"], cwd=ROOT, timeout=40)
        (output / "gpui.json").write_bytes(result)
        measured = json.loads(result)
        assert len(measured["cases"]) == len(native["cases"])
        report = []
        for source, actual in zip(native["cases"], measured["cases"]):
            assert (source["name"], source["dark"]) == (actual["name"], actual["dark"])
            assert [source["texts"][0]["text"], source["message"]] == [actual["content"]["title"], actual["content"]["message"]]
            assert len(actual["content"]["buttons"]) == 1
            assert actual["content"]["buttons"][0]["title"] == source["buttons"][0]["title"]
            assert actual["content"]["buttons"][0]["role"] == "cancel"
            panel = actual["rects"]["panel"]
            assert panel[2:] == source["size"], (source["name"], panel, source["size"])
            assert actual["fixtureSize"] == source["size"], (source["name"], actual["fixtureSize"], source["size"])
            for key, expected in [("title", source["texts"][0]["frame"]), ("message", source["texts"][1]["frame"]), ("cancel", source["buttons"][0]["frame"])]:
                rect = actual["rects"][key]
                assert [rect[0] - panel[0], rect[1] - panel[1], *rect[2:]] == expected, (source["name"], key, rect, expected)
            report.append({"name": source["name"], "dark": source["dark"], "framesMatch": True})
        (output / "layout-comparison.json").write_text(json.dumps({"cases": report, "pixelParityVerified": False, "activeFocusVerified": False}, indent=2) + "\n")
        print(f"Actual GPUI/native alert content frames match in {len(report)} cases; pixels/materials/active input remain open.")
    manifest["outputs"] = {name: hashlib.sha256((output / name).read_bytes()).hexdigest()
                           for name in ["native.json", *(["gpui.json", "layout-comparison.json"] if args.compare_gpui else [])]}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
