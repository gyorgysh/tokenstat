#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the real tab mount gate with delayed native lifecycle delivery."""
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
