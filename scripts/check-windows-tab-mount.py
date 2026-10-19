#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise native tab readiness and deferred desktop activation ownership."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
code = r'''
using Tokenstat.Pages;
using Microsoft.UI.Xaml.Controls;
namespace Microsoft.UI.Dispatching {
    enum DispatcherQueuePriority { Low }
    sealed class DispatcherQueue {
        readonly Queue<Action> work = new();
        public bool TryEnqueue(DispatcherQueuePriority priority, Action callback) { work.Enqueue(callback); return true; }
        public void Drain() { while (work.TryDequeue(out var callback)) callback(); }
    }
}
namespace Microsoft.UI.Xaml { sealed class RoutedEventArgs : EventArgs {} }
namespace Microsoft.UI.Xaml.Media {
    static class VisualTreeHelper { public static object? GetParent(TabView view) => view.Parent; }
}
namespace Microsoft.UI.Xaml.Controls {
    sealed class TabView {
        public bool IsLoaded;
        public object? Parent;
        public Microsoft.UI.Dispatching.DispatcherQueue DispatcherQueue = new();
        public event Action<object, Microsoft.UI.Xaml.RoutedEventArgs>? Loaded;
        public event Action<object, Microsoft.UI.Xaml.RoutedEventArgs>? Unloaded;
        public void Load() { Parent = new(); IsLoaded = true; Loaded?.Invoke(this, new()); }
        public void Remove(bool deliver = true) { Parent = null; IsLoaded = false; if (deliver) LateUnload(); }
        public void LateUnload() => Unloaded?.Invoke(this, new());
    }
}
class Program {
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    static void Main() {
        var view = new TabView();
        using var mount = new TabViewMount(view);
        var ready = 0;
        mount.Ready += () => ready++;
        view.Loaded += (_, _) => Check(!mount.IsReady, "Native additions became safe during Loaded dispatch");
        view.Load();
        Check(!mount.IsReady, "Mount published readiness synchronously");
        view.DispatcherQueue.Drain();
        Check(mount.IsReady && ready == 1, "Initial mount did not become ready");
        view.Remove(deliver: false);
        Check(!mount.IsReady, "Detached native view stayed ready before Unloaded delivery");
        view.Load();
        view.LateUnload();
        view.DispatcherQueue.Drain();
        Check(mount.IsReady && ready == 2, "An old Unloaded stranded the remounted native control");
        view.Remove(); view.Load(); view.Remove(); view.Load();
        view.DispatcherQueue.Drain();
        Check(mount.IsReady && ready == 3, "Queued mount work did not coalesce to the latest tree");
        view.Remove();
        view.DispatcherQueue.Drain();
        Check(!mount.IsReady && ready == 3, "Unloaded view republished readiness");
        view.Load(); mount.Dispose();
        view.DispatcherQueue.Drain();
        view.Remove(); view.Load(); view.DispatcherQueue.Drain();
        Check(!mount.IsReady && ready == 3, "Disposed mount resumed queued lifecycle work");
        var alreadyLoaded = new TabView(); alreadyLoaded.Load();
        using var existing = new TabViewMount(alreadyLoaded);
        Check(!existing.IsReady, "Existing native view skipped deferred readiness");
        alreadyLoaded.DispatcherQueue.Drain();
        Check(existing.IsReady, "Already loaded native view was never adopted");
        Console.WriteLine("PASS: actual native tab gate survives delayed unload, rapid remount, detached trees and queued disposal");
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-tab-mount-') as temporary:
    folder = Path(temporary)
    (folder / 'Program.cs').write_text(code)
    (folder / 'TabViewMount.cs').write_text((ROOT / 'apps/windows/Pages/TabViewMount.cs').read_text())
    (folder / 'Check.csproj').write_text('''<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>
<OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings>
<Nullable>enable</Nullable></PropertyGroup></Project>''')
    subprocess.run(['dotnet', 'run', '--project', str(folder / 'Check.csproj'), '-c', 'Release'], check=True)

# The actual desktop coordinator must retain cold activations until inventory
# and native layout are ready, and recheck ownership at deferred delivery.
coordinator = r'''
using System.Text.Json.Nodes;
using Tokenstat;
using Tokenstat.Navigation;
using Tokenstat.Pages;
static class Fixture { public const string Project = @"\\?\C:\work\project app"; }
namespace Microsoft.UI.Xaml {
    enum VerticalAlignment { Top }
    readonly record struct Thickness(double Value);
    class Element {
        public bool IsLoaded;
        public VerticalAlignment VerticalAlignment;
        public Thickness Margin;
        public event Action<object, EventArgs>? Loaded;
        public void Load() { IsLoaded = true; Loaded?.Invoke(this, EventArgs.Empty); }
    }
}
namespace Microsoft.UI.Xaml.Controls {
    enum InfoBarSeverity { Warning }
    sealed class InfoBar : Microsoft.UI.Xaml.Element {
        public bool IsClosable, IsOpen;
        public InfoBarSeverity Severity;
        public string Message = "";
    }
    sealed class Grid : Microsoft.UI.Xaml.Element {
        public readonly List<object> Children = [];
        public static void SetRow(InfoBar item, int row) {}
        public static void SetColumn(InfoBar item, int column) {}
    }
}
namespace Microsoft.UI.Windowing {
    enum OverlappedPresenterState { Minimized, Restored }
    sealed class OverlappedPresenter {
        public OverlappedPresenterState State = OverlappedPresenterState.Minimized;
        public void Restore() { State = OverlappedPresenterState.Restored; }
    }
    sealed class AppWindow { public object? Presenter; }
}
namespace Tokenstat.Navigation {
    static class DesktopActivation {
        public static event Action? Changed;
        static readonly Queue<DesktopOpenRequest> Pending = new();
        public static bool TryTake(out DesktopOpenRequest? request) => Pending.TryDequeue(out request);
        public static void Send(DesktopOpenRequest request) { Pending.Enqueue(request); Changed?.Invoke(); }
    }
}
namespace Tokenstat.Pages {
    sealed class WorkspaceTabsPage {
        public readonly List<DesktopOpenRequest> Applied = [];
        readonly Queue<Action> _waiting = new();
        bool _loaded;
        public void WhenLoaded(Action action) { if (_loaded) action(); else _waiting.Enqueue(action); }
        public void Load() { _loaded = true; while (_waiting.TryDequeue(out var action)) action(); }
        public void OpenDesktopAction(DesktopOpenRequest request) { Applied.Add(request); }
    }
    static class RemoteWorkspaces { public static object? CachedFolder(string id) => null; }
}
namespace Tokenstat {
    static class AppServices {
        public static long AccountGeneration;
        public static Action<DesktopOpenRequest>? OpenDesktopAction;
    }
    static class L10n { public static string Text(string key) => key; }
    static class Format { public static string Text(JsonNode? item, string key) => item?[key]?.GetValue<string>() ?? ""; }
    sealed class QueueStub {
        readonly Queue<Action> _work = new();
        public bool TryEnqueue(Action action) { _work.Enqueue(action); return true; }
        public void Drain() { while (_work.TryDequeue(out var action)) action(); }
    }
    public sealed partial class MainWindow {
        readonly Microsoft.UI.Xaml.Controls.Grid RootGrid = new();
        readonly QueueStub DispatcherQueue = new();
        readonly Microsoft.UI.Windowing.AppWindow AppWindow = new();
        readonly Dictionary<string, WorkspaceTabsPage> _pages = new();
        bool _foldersLoaded;
        JsonArray _localFolders = new();
        public event Action<object, EventArgs>? Closed;
        internal readonly List<string> Navigation = [];
        internal int Activations;
        internal MainWindow() { InitializeDesktopActions(); }
        internal void NativeReady() { RootGrid.Load(); DispatcherQueue.Drain(); }
        internal void FoldersReady(params string[] ids) {
            _localFolders = new JsonArray(ids.Select(id => (JsonNode)new JsonObject { ["id"] = id }).ToArray());
            _foldersLoaded = true; ResolveDesktopActions();
        }
        internal void Receive(DesktopOpenRequest request) { QueueDesktopAction(request); }
        internal WorkspaceTabsPage WorkspaceTabs(string id) {
            if (!_pages.TryGetValue(id, out var page)) _pages[id] = page = new();
            return page;
        }
        internal bool ErrorOpen => _desktopActionError.IsOpen;
        internal void Drain() { DispatcherQueue.Drain(); }
        internal void Minimize() { AppWindow.Presenter = new Microsoft.UI.Windowing.OverlappedPresenter(); }
        internal bool Restored => AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter { State: Microsoft.UI.Windowing.OverlappedPresenterState.Restored };
        internal void Close() { Closed?.Invoke(this, EventArgs.Empty); }
        void NavigateTo(string tag) { Navigation.Add(tag); }
        void Activate() { Activations++; }
    }
}
static class Program {
    public static void LogStartup(string text) {}
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    static DesktopOpenRequest Request(string options) => DesktopOpenRequest.Parse("tokenstat://workbench/open?workspace=" + Uri.EscapeDataString(Fixture.Project) + "&" + options)!;
    static void Main() {
        AppServices.AccountGeneration = 1;
        DesktopActivation.Send(Request("tool=terminal&new=1"));
        var cold = new MainWindow();
        cold.NativeReady();
        Check(cold.Navigation.Count == 0, "Cold activation ran before inventory");
        cold.FoldersReady(Fixture.Project);
        var page = cold.WorkspaceTabs(Fixture.Project);
        Check(page.Applied.Count == 0, "Action skipped native readiness");
        page.Load();
        Check(page.Applied.Count == 1 && page.Applied[0].NewTerminal, "Cold action was lost or duplicated");
        cold.FoldersReady(Fixture.Project);
        Check(page.Applied.Count == 1, "Inventory refresh replayed a consumed action");
        cold.Receive(DesktopOpenRequest.Parse("tokenstat://workbench/open?workspace=absent&tool=changes")!);
        Check(cold.ErrorOpen && cold.Navigation.Count == 1, "Unknown project navigated or failed silently");
        cold.Minimize();
        DesktopActivation.Send(Request("tool=browser&url=http%3A%2F%2Flocalhost%3A8000%2Fpreview"));
        cold.Drain();
        Check(cold.Restored && cold.Activations == 1 && !cold.ErrorOpen, "Warm activation did not restore the window or clear the old warning");
        Check(page.Applied.Count == 2 && page.Applied[1].BrowserUrl?.AbsolutePath == "/preview", "Warm preview payload was lost");
        var queued = new MainWindow();
        queued.NativeReady(); queued.Receive(Request("tool=terminal&new=1"));
        AppServices.AccountGeneration = 2;
        queued.FoldersReady(Fixture.Project);
        Check(queued.Navigation.Count == 0, "Inventory wait crossed accounts");
        var deferred = new MainWindow();
        deferred.NativeReady(); deferred.FoldersReady(Fixture.Project);
        deferred.Receive(Request("tool=terminal&new=1"));
        AppServices.AccountGeneration = 3;
        deferred.WorkspaceTabs(Fixture.Project).Load();
        Check(deferred.WorkspaceTabs(Fixture.Project).Applied.Count == 0, "Native layout wait crossed accounts");
        var bounded = new MainWindow();
        bounded.NativeReady();
        for (var index = 0; index < 20; index++) bounded.Receive(Request("tool=terminal&session=session-" + index));
        bounded.FoldersReady(Fixture.Project); bounded.WorkspaceTabs(Fixture.Project).Load();
        Check(bounded.WorkspaceTabs(Fixture.Project).Applied.Count == 16 && bounded.WorkspaceTabs(Fixture.Project).Applied[0].SessionId == "session-4", "Pending navigation was not bounded to recent requests");
        cold.Close(); queued.Close(); deferred.Close(); bounded.Close();
        Console.WriteLine("PASS: actual desktop coordinator retains cold/warm tool payloads, waits for native layout, bounds pending requests and rejects account changes at both delivery boundaries");
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-desktop-actions-') as temporary:
    folder = Path(temporary)
    (folder / 'Program.cs').write_text(coordinator)
    for relative in ['MainWindow.DesktopActions.cs', 'Navigation/DesktopOpenRequest.cs', 'Pages/DesktopWorkbenchState.cs']:
        (folder / Path(relative).name).write_text((ROOT / 'apps/windows' / relative).read_text())
    (folder / 'Check.csproj').write_text('''<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>
<OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings>
<Nullable>enable</Nullable></PropertyGroup></Project>''')
    subprocess.run(['dotnet', 'run', '--project', str(folder / 'Check.csproj'), '-c', 'Release'], check=True)
