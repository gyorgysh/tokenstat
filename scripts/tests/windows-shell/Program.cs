// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Tokenstat.Design;
using Tokenstat.Pages;
using Tokenstat.Navigation;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
var directory = Path.Combine(Path.GetTempPath(), "tokenstat-shell-test-" + Guid.NewGuid());
Directory.CreateDirectory(directory);
try
{
    var path = Path.Combine(directory, "widths.json");
    var widths = new ShellWidths(path);
    Check(widths.Sidebar == 280 && widths.Inspector == 280, "Missing preferences changed the default layout");
    widths.RememberSidebar(360);
    widths.RememberInspector(430);
    var reopened = new ShellWidths(path);
    Check(reopened.Sidebar == 360 && reopened.Inspector == 430, "Reopening lost a panel width");
    reopened.RememberSidebar(double.NaN);
    reopened.RememberInspector(9000);
    var bounded = new ShellWidths(path);
    Check(bounded.Sidebar == 280 && bounded.Inspector == 480, "Invalid sizes escaped the panel limits");
    File.WriteAllText(path, "{\"sidebar\": 0, \"inspector\": \"bad\"}");
    bounded = new ShellWidths(path);
    Check(bounded.Sidebar == 240 && bounded.Inspector == 280, "Malformed sizes were not recovered independently");
    File.WriteAllText(path, "not json");
    bounded = new ShellWidths(path);
    Check(bounded.Sidebar == 280 && bounded.Inspector == 280, "Corrupt preferences prevented a default layout");
    Check(ShellWidths.InspectorFitEdge(480) - ShellWidths.InspectorFitEdge(280) == 200,
        "A wider inspector did not reserve a comfortable content column");
    var historyPath = Path.Combine(directory, "browser.json");
    var history = new BrowserHistory(historyPath);
    var scope = BrowserHistory.AccountScope("HTTPS://EXAMPLE.INVALID:443/", "account-a");
    Check(scope == BrowserHistory.AccountScope("https://example.invalid", "account-a"), "Equivalent account origins split ownership");
    var owner = BrowserHistory.Key(scope, "host-a", "project-a");
    Check(history.Remember(owner, "3000"), "A valid port was not recorded");
    history.Remember(owner, "http://127.0.0.1:3000/path?q=1#preview");
    Check(history.Read(owner).Count == 1 && history.Read(owner)[0].EndsWith("/path?q=1#preview"), "Recent ports duplicated or lost the canonical path");
    Check(!history.Remember(owner, "0") && !history.Remember(owner, "ftp://example.invalid/")
        && !history.Remember(owner, "http://user:password@example.invalid/"), "Invalid or credential-bearing targets were persisted");
    for (int port = 3001; port <= 3010; port++) history.Remember(owner, port.ToString());
    var restored = new BrowserHistory(historyPath);
    Check(restored.Read(owner).Count == 8 && restored.Read(owner)[0] == "http://127.0.0.1:3010/", "Recent ports were unbounded or not restored newest first");
    Check(restored.Read(BrowserHistory.Key(scope, "host-b", "project-a")).Count == 0
        && restored.Read(BrowserHistory.Key(scope, "host-a", "project-b")).Count == 0
        && restored.Read(BrowserHistory.Key(BrowserHistory.AccountScope("https://example.invalid", "account-b"), "host-a", "project-a")).Count == 0
        && restored.Read(BrowserHistory.Key(BrowserHistory.AccountScope("https://other.invalid", "account-a"), "host-a", "project-a")).Count == 0,
        "Browser targets crossed account, server, host or project ownership");
    Check(BrowserHistory.Key("a:b", "c") != BrowserHistory.Key("a", "b:c"), "Owner components collide");
    Check(BrowserHistory.CanonicalTarget("localhost:3000") == "http://localhost:3000/", "Loopback target gained TLS");
    Check(BrowserHistory.CanonicalTarget("0.0.0.0:3000") == "http://0.0.0.0:3000/", "A wildcard loopback target gained TLS");
    Check(BrowserHistory.CanonicalTarget("65536") is null, "An invalid port was reinterpreted as a website");
    var pinsPath = Path.Combine(directory, "pins.json");
    var pins = new PinnedWorkStore(pinsPath);
    for (int index = 0; index < 8; index++) Check(pins.Pin(new(scope, owner, "project-a", "chat-" + index, "Chat " + index, "Project")), "Pin capacity was too small");
    Check(!pins.Pin(new(scope, owner, "project-a", "overflow", "Extra", "Project")), "Pin capacity was not enforced");
    pins.Rename(owner, "chat-0", "Renamed");
    var restoredPins = new PinnedWorkStore(pinsPath);
    Check(restoredPins.Read(scope).Count == 8 && restoredPins.Read(scope)[0].Label == "Renamed", "Pins or renamed labels were not saved");
    Check(restoredPins.Read("other-account").Count == 0 && !restoredPins.Contains("other-host", "chat-0"), "A pin crossed account or host ownership");
    restoredPins.Remove(owner, "chat-0");
    Check(restoredPins.Read(scope).Count == 7 && restoredPins.Pin(new(scope, owner, "project-a", "replacement", "Replacement", "Project")), "Unpin did not free capacity");
    Check(ChatHistoryWindow.Visible(30, null, false) == (0, 5), "Collapsed chats exceeded the warm sidebar budget");
    var older = ChatHistoryWindow.Visible(30, 22, false);
    Check(older.Count == 10 && older.Start <= 22 && older.Start + older.Count > 22, "An older selected chat disappeared from the sidebar");
    Check(ChatHistoryWindow.Visible(30, 7, true) == (0, 10), "Selecting a warm chat shifted the first ten");
    var routes = new BrowserRouteState();
    for (var port = 3000; port < 3021; port++)
    {
        var retired = routes.Retire();
        Check(routes.Active is null, "A rotated page retained its previous active listener");
        if (port > 3000) Check(retired?.Port == port - 1, "Rotation retired the wrong endpoint");
        routes.Activate(new("127.0.0.1", port, 1, $"http://127.0.0.1:{40000 + port - 3000}/"));
    }
    var oldProxy = new Uri("http://127.0.0.1:40000/path?q=1#preview");
    Check(routes.Display(oldProxy.AbsoluteUri) == "http://127.0.0.1:3000/path?q=1#preview"
        && routes.Request(oldProxy, "GET", true, 1) == BrowserRouteState.RequestAction.Reopen,
        "Listener rotation lost canonical Back navigation");
    Check(routes.Request(oldProxy, "POST", true, 1) == BrowserRouteState.RequestAction.Block
        && !routes.AllowsFrame(oldProxy, 1), "An inactive listener was reused by a form or frame");
    Check(routes.Request(oldProxy, "GET", BrowserRouteState.IsTopLevelDocument(true, "iframe"), 1) == BrowserRouteState.RequestAction.Block
        && routes.Request(oldProxy, "GET", BrowserRouteState.IsTopLevelDocument(true, null), 1) == BrowserRouteState.RequestAction.Block
        && routes.Request(oldProxy, "GET", BrowserRouteState.IsTopLevelDocument(true, "document"), 1) == BrowserRouteState.RequestAction.Reopen,
        "A frame document or request without browser metadata switched the page's active listener");
    routes.Retire();
    routes.Activate(new("127.0.0.1", 3000, 1, "http://127.0.0.1:45000/"));
    Check(routes.Request(oldProxy, "POST", false, 1) == BrowserRouteState.RequestAction.Rewrite
        && routes.AllowsFrame(oldProxy, 1), "Canonical Back reacquisition left mapped page requests on the retired listener");
    routes.Retire();
    routes.Activate(new("127.0.0.1", 3020, 1, "http://127.0.0.1:40020/"));
    var unknown = new Uri("http://localhost:8080/form");
    Check(BrowserRouteState.WorkerRequest(unknown, false) == BrowserRouteState.RequestAction.Block
        && BrowserRouteState.WorkerRequest(new Uri("http://127.0.0.1:45000/worker"), true) == BrowserRouteState.RequestAction.Pass
        && BrowserRouteState.WorkerRequest(new Uri("https://example.invalid/worker"), false) == BrowserRouteState.RequestAction.Pass,
        "A worker accessed device localhost or another tab refused a confirmed current listener");
    Check(routes.Request(unknown, "POST", true, 1) == BrowserRouteState.RequestAction.Block
        && routes.Request(unknown, "GET", false, 1) == BrowserRouteState.RequestAction.Block
        && !routes.AllowsFrame(unknown, 1), "An unmapped remote form or frame fell back to device localhost");
    var activeOriginal = new Uri("http://127.0.0.1:3020/form?q=1");
    Check(routes.Request(activeOriginal, "POST", true, 1) == BrowserRouteState.RequestAction.Rewrite
        && BrowserRouteState.Through(routes.Active!, activeOriginal) == "http://127.0.0.1:40020/form?q=1",
        "A mapped request lost its original method-safe route or query");
    var tls = new BrowserRouteState.Lease("localhost", 443, 1, "http://127.0.0.1:45001/");
    routes.Activate(tls);
    Check(BrowserRouteState.Through(tls, new Uri("https://localhost/status")) == "https://127.0.0.1:45001/status"
        && routes.IsActiveProxy(new Uri("https://127.0.0.1:45001/status"), 1)
        && routes.Display("https://127.0.0.1:45001/status") == "https://localhost/status",
        "A raw TLS bridge lost HTTPS or its canonical proxy mapping");
    routes.Activate(new("127.0.0.1", 40000, 2, "http://127.0.0.1:50000/"));
    routes.ForgetBefore(2);
    Check(routes.Active?.Generation == 2 && routes.Historical(oldProxy, 1) is null
        && routes.Request(oldProxy, "POST", true, 2) == BrowserRouteState.RequestAction.Rewrite,
        "Old cleanup removed the new account lease or treated an explicit matching port as an old proxy");
    var accountEpoch = new OperationEpoch();
    var queuedOpen = accountEpoch.Capture();
    accountEpoch.Advance();
    var acquired = 0;
    Check(await queuedOpen.AcquireAsync(() => { acquired++; return Task.FromResult("http://127.0.0.1:40001/"); }, () => Task.CompletedTask) is null && acquired == 0,
        "A queued Open from the previous account acquired a listener");
    var pendingBridge = new TaskCompletionSource<string>();
    var releaseCount = 0;
    var open = accountEpoch.Capture();
    var acquisition = open.AcquireAsync(() => pendingBridge.Task, () => { releaseCount++; return Task.CompletedTask; });
    accountEpoch.Advance();
    pendingBridge.SetResult("http://127.0.0.1:40002/");
    Check(await acquisition is null && releaseCount == 1 && !open.IsCurrent,
        "A stale account Open retained a listener or could record/navigate its target");
    await BrowserBridgePoolTests.RunAsync();
    Console.WriteLine("Shell widths: persistence, independent panels, malformed preferences and adaptive fit passed");
}
finally { Directory.Delete(directory, recursive: true); }
