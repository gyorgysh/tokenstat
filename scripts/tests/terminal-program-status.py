#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise production Mac attention transitions and Windows status labels."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--platform", choices=("all", "apple", "windows"), default="all")
platform = parser.parse_args().platform

root = Path(__file__).resolve().parents[2]
mac = (root / "apps/mac/Sources/Features/Terminals/TerminalSession.swift").read_text()
models = (root / "apps/mac/Sources/Bridge/Models.swift").read_text()
windows = (root / "apps/windows/Navigation/SidebarLive.cs").read_text()


def between(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]


state = between(mac, "enum SessionState:", "/// Live token")
status = between(models, "struct PtyProgramStatus:", "struct PtySessionInfo:")
transition = between(mac, "    private var attentionAcknowledged", "    /// Dismiss the current")
transition = transition.replace("private var", "var").replace("private func", "func")
label = between(mac, "    var statusLabel:", "    ///")
win_method = between(windows, "    public static (string Label, Windows.UI.Color Tint) SessionState", "    /// <summary>\n    /// The meter line")

swift = r'''
import Foundation
enum L10n {
    static func text(_ key: String) -> String { key }
}
@MainActor final class RunNotifications {
    static let shared = RunNotifications()
    var handled = 0
    func attentionHandled(sessionID: String) { handled += 1 }
}
STATE
STATUS
@MainActor final class Session {
    let id = "test"
    var state: SessionState = .working
    var programStatus: PtyProgramStatus?
    var hostReportedActivity = false
    var idleCheckTask: Task<Void, Never>?
    var cpuPercent: Double?, memoryMb: Double?
    var announcements = 0
    func announceAttention() { announcements += 1 }
LABEL
TRANSITION
}
@main struct Test {
    @MainActor static func main() {
        let session = Session()
        var report = PtyProgramStatus(state: "blocked", kind: "permission", app: "claude-code", revision: 1)
        func apply(_ activity: String = "idle", _ attention: String? = "permission") {
            session.applyActivity(activity, cpuPercent: 4.1, memoryMb: 42.3,
                                  attention: attention, programStatus: report)
        }
        apply()
        assert(session.state == .needsAttention && session.announcements == 1)
        assert(session.statusLabel == "common.needs_approval")
        session.attentionAcknowledged = true
        apply()
        assert(session.state == .needsAttention && session.announcements == 1, "acknowledgement silences notification without claiming idle")
        report.progress = 50
        apply()
        assert(session.state == .needsAttention && session.announcements == 1, "progress is not another question")
        report.revision = 2
        report.kind = "question"
        apply("idle", "question")
        assert(session.state == .needsAttention && session.announcements == 2, "new question rearms attention")
        assert(session.statusLabel == "common.needs_answer")
        report.revision = 3
        report.kind = "auth"
        apply("idle", "auth")
        assert(session.statusLabel == "common.sign_in_required")
        report.state = "working"; report.kind = nil; report.revision = 4
        apply("working", nil)
        assert(RunNotifications.shared.handled == 1, "host resume removes the old notification")
        assert(session.state == .working && session.statusLabel == "common.working · 50%")
        report.state = "done"; report.revision = 5; report.progress = nil
        apply("idle", nil)
        assert(session.state == .done, "turn completion does not require process exit")
        report.state = "error"; report.revision = 6
        apply("idle", nil)
        assert(session.state == .failed)
        session.applyActivity("idle", cpuPercent: 0, attention: nil, programStatus: nil)
        assert(session.state == .idle && session.programStatus == nil, "cleared reports return to fallback")
        print("Mac program status and attention episodes passed")
    }
}
'''.replace("STATE", state).replace("STATUS", status).replace("LABEL", label).replace("TRANSITION", transition)

csharp = r'''
using System.Text.Json.Nodes;
using Tokenstat.Pages;
namespace Windows.UI { public enum Color { Idle, Working, Warning, Danger } }
static class Theme {
    public const Windows.UI.Color StateIdle = Windows.UI.Color.Idle;
    public const Windows.UI.Color StateWorking = Windows.UI.Color.Working;
    public const Windows.UI.Color Warning = Windows.UI.Color.Warning;
    public const Windows.UI.Color Danger = Windows.UI.Color.Danger;
}
static class L10n { public static string Text(string key, params string[] values) => key; }
static class SidebarLive {
METHOD
}
static class Program {
    static void Main() {
        foreach (var (kind, label) in new[] { ("permission", "common.needs_approval"),
                                            ("question", "common.needs_answer"),
                                            ("auth", "common.sign_in_required") }) {
            var result = SidebarLive.SessionState(new JsonObject { ["attention"] = kind, ["activity"] = "idle" });
            if (result != (label, Theme.Warning)) throw new Exception("Lost attention reason " + kind);
        }
        foreach (var (activity, label, color) in new[] { ("working", "common.working", Theme.StateWorking),
                                                       ("idle", "common.idle", Theme.StateIdle),
                                                       ("done", "common.done", Theme.StateIdle),
                                                       ("error", "common.failed", Theme.Danger) }) {
            if (SidebarLive.SessionState(new JsonObject { ["activity"] = activity }) != (label, color))
                throw new Exception("Wrong state " + activity);
            var rich = SidebarLive.SessionState(new JsonObject {
                ["activity"] = activity is "done" or "error" ? "idle" : activity,
                ["programStatus"] = new JsonObject { ["state"] = activity },
            });
            if (rich != (label, color)) throw new Exception("Lost additive status " + activity);
        }
        var progress = JsonNode.Parse("""{"activity":"working","programStatus":{"progress":42}}""")!;
        if (SidebarLive.SessionState(progress).Label != "common.working · 42%") throw new Exception("Lost progress");
        if (SidebarLive.SessionState(new JsonObject()).Label != "windows.sidebarlive.starting.aeed4d26")
            throw new Exception("Unknown old host status became idle");
        var exited = JsonNode.Parse("""{"alive":false,"exitCode":1,"activity":"idle"}""")!;
        if (SidebarLive.SessionState(exited) != ("common.failed", Theme.Danger))
            throw new Exception("Retained idle status hid a failed process exit");
        exited["exitCode"] = 0L;
        if (SidebarLive.SessionState(exited).Label != "common.done") throw new Exception("Lost successful exit");
        exited["exitCode"] = null;
        if (SidebarLive.SessionState(exited).Label != "windows.workbenchops.stopped.1a4f630a")
            throw new Exception("Unknown exit was called successful");
        Console.WriteLine("Windows program status presentation passed");
    }
}
'''.replace("METHOD", win_method)

with tempfile.TemporaryDirectory(prefix="tokenstat-program-status-") as directory:
    work = Path(directory)
    if platform in ("all", "apple"):
        (work / "Fixture.swift").write_text(swift)
        subprocess.run(["swiftc", "-parse-as-library", str(work / "Fixture.swift"), "-o", str(work / "swift-test")], check=True)
        subprocess.run([str(work / "swift-test")], check=True)
    if platform in ("all", "windows"):
        (work / "Program.cs").write_text(csharp)
        shutil.copy2(root / "apps/windows/Pages/Format.cs", work / "Format.cs")
        (work / "StatusTests.csproj").write_text(
            '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType>'
            '<TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings>'
            '<Nullable>enable</Nullable></PropertyGroup></Project>'
        )
        dotnet = shutil.which("dotnet")
        if dotnet is None:
            cached = root / "target/review-dotnet/dotnet"
            if cached.is_file():
                dotnet = str(cached)
        if dotnet is None:
            raise SystemExit("dotnet is required to verify the Windows status presentation")
        environment = os.environ.copy()
        environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        subprocess.run([dotnet, "run", "--project", str(work / "StatusTests.csproj"), "-c", "Release"], env=environment, check=True)
