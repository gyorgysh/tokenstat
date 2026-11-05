#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run the production Windows model viewer with held WebView2 operations."""
from pathlib import Path
import subprocess
import tempfile
import shutil

root = Path(__file__).resolve().parents[1]
dotnet = shutil.which('dotnet') or str(root / 'target/dotnet-sdk/dotnet')
stubs = r'''
using Microsoft.Web.WebView2.Core;
namespace Microsoft.UI { static class Colors { public static object Transparent = new(); } }
namespace Microsoft.UI.Xaml {
 enum HorizontalAlignment { Stretch, Center } enum VerticalAlignment { Center }
 enum TextWrapping { Wrap } readonly record struct Thickness(int Value);
 class Element {
  public double Height; public object? Background; public HorizontalAlignment HorizontalAlignment;
  public bool IsLoaded = true;
  public event EventHandler? Loaded, Unloaded, ActualThemeChanged;
 }
}
namespace Microsoft.UI.Xaml.Controls {
 class Grid : Microsoft.UI.Xaml.Element { public List<object> Children = []; }
 class TextBlock : Microsoft.UI.Xaml.Element {
  public string Text = ""; public Microsoft.UI.Xaml.TextWrapping TextWrapping;
  public Microsoft.UI.Xaml.VerticalAlignment VerticalAlignment;
  public Microsoft.UI.Xaml.Thickness Margin; public double Opacity;
 }
 class WebView2 : Microsoft.UI.Xaml.Element {
  public object? DefaultBackgroundColor;
  public CoreWebView2? CoreWebView2 = new();
  public Queue<Task> Ensures = new();
  public Task EnsureCoreWebView2Async(CoreWebView2Environment e) => Ensures.TryDequeue(out var task) ? task : Task.CompletedTask;
 }
}
namespace Microsoft.Web.WebView2.Core {
 class CoreWebView2EnvironmentOptions {}
 class CoreWebView2Environment {
  public static Task<CoreWebView2Environment> CreateWithOptionsAsync(string? a, string b, CoreWebView2EnvironmentOptions c) => Task.FromResult(new CoreWebView2Environment());
 }
 enum CoreWebView2PermissionState { Deny }
 enum CoreWebView2HostResourceAccessKind { Deny }
 class Args : EventArgs {
  public CoreWebView2PermissionState State; public bool Handled, Cancel, IsSuccess;
  public string Uri = ""; public ulong NavigationId;
 }
 class Settings {
  public bool AreDevToolsEnabled, AreHostObjectsAllowed, IsWebMessageEnabled, AreDefaultContextMenusEnabled;
 }
 class CoreWebView2 {
  public Settings Settings = new();
  public event EventHandler<Args>? PermissionRequested, NewWindowRequested, DownloadStarting, NavigationStarting, NavigationCompleted, ProcessFailed;
  public List<string> Scripts = []; public Queue<Task<string>> Executions = new();
  public ulong Navigation;
  public void SetVirtualHostNameToFolderMapping(string a, string b, CoreWebView2HostResourceAccessKind c) {}
  public void Navigate(string uri) { Navigation++; NavigationStarting?.Invoke(this, new Args { Uri = uri, NavigationId = Navigation }); }
  public void Complete(ulong id, bool success) => NavigationCompleted?.Invoke(this, new Args { NavigationId = id, IsSuccess = success });
  public Task<string> ExecuteScriptAsync(string script) { Scripts.Add(script); return Executions.TryDequeue(out var task) ? task : Task.FromResult("null"); }
  public void FailProcess() => ProcessFailed?.Invoke(this, new Args());
  public void Stop() {}
 }
}
namespace Tokenstat.Design {
 static class Theme { public static object PanelBrush = new(); public static bool IsDark = true; }
}
namespace Tokenstat { static class L10n { public static string Text(string key) => key; } }
'''
tests = r'''
using System.Reflection;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Pages;
class Checks {
 static int failures;
 static void Check(bool ok, string message) { if (!ok) { failures++; Console.WriteLine("FAIL: " + message); } }
 static object Get(object item, string field) => item.GetType().GetField(field, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(item)!;
 static void Set(object item, string field, object value) => item.GetType().GetField(field, BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(item, value);
 static Task Open(ChatModelView view) { long epoch = (long)Get(view, "_epoch") + 1; Set(view, "_epoch", epoch); return (Task)typeof(ChatModelView).GetMethod("OpenAsync", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(view, [epoch])!; }
 static Task Load(ChatModelView view) => (Task)typeof(ChatModelView).GetMethod("LoadModelAsync", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(view, [((WebView2)Get(view,"_web")).CoreWebView2!, Get(view,"_epoch")])!;
 static bool Error(ChatModelView view) => view.Children.OfType<TextBlock>().Any(x => x.Text.Length > 0);
 static async Task Main() {
  var root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString()); Directory.CreateDirectory(root);
  try {
   var file = Path.Combine(root, "triangle.obj");
   var bytes = System.Text.Encoding.UTF8.GetBytes("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n");
   await File.WriteAllBytesAsync(file, bytes);
   var huge = Path.Combine(root,"huge.obj"); using (var stream = File.Create(huge)) stream.SetLength(12 * 1024 * 1024 + 1);
   var empty = Path.Combine(root,"empty.obj"); File.WriteAllBytes(empty, []);
   foreach (var path in new[] { Path.Combine(root,"missing.obj"), huge, empty }) {
    var view = new ChatModelView(path,"model.obj"); await Open(view);
    Check(Error(view), "Unavailable file should show a message: " + Path.GetFileName(path));
   }
   {
    var view = new ChatModelView(file,"model.obj"); var web = (WebView2)Get(view,"_web");
    var old = new TaskCompletionSource(); web.Ensures.Enqueue(old.Task);
    var earlier = Open(view); await Open(view);
    old.SetException(new IOException("Old initialization failed")); await earlier;
    Check(!Error(view), "Old initialization failure must not replace the new preview");
   }
   {
    var view = new ChatModelView(file,"model.obj"); await Open(view);
    var web = (WebView2)Get(view,"_web"); var core = web.CoreWebView2!;
    core.Complete(core.Navigation, false);
    Check(Error(view), "Failed navigation must show a message");
   }
   {
    var view = new ChatModelView(file,"model.obj"); await Open(view);
    var web = (WebView2)Get(view,"_web"); var core = web.CoreWebView2!;
    var oldNavigation = core.Navigation; await Open(view);
    core.Complete(oldNavigation, true);
    await Task.Delay(100);
    Check(core.Scripts.Count == 0, "An old navigation must not load bytes into the current page");
    await Load(view);
    Check(core.Scripts.Last().Contains(Convert.ToBase64String(bytes)), "Load the selected model");
   }
   {
    var view = new ChatModelView(file,"model.obj"); await Open(view);
    var web = (WebView2)Get(view,"_web"); var core = web.CoreWebView2!;
    var old = new TaskCompletionSource<string>(); core.Executions.Enqueue(old.Task);
    var earlier = Load(view);
    for (int i = 0; i < 200 && core.Scripts.Count == 0; i++) await Task.Delay(10);
    Check(core.Scripts.Count == 1, "The earlier render must be pending");
    await Open(view); old.SetException(new IOException("Old script failed")); await earlier;
    Check(!Error(view), "Old render failure must not replace the new preview");
   }
   {
    var view = new ChatModelView(file,"model.obj"); await Open(view);
    var web = (WebView2)Get(view,"_web"); var core = web.CoreWebView2!;
    core.FailProcess();
    Check(Error(view), "A failed renderer process must show a message");
    await Open(view);
    Check(!Error(view), "Reopening restores the model surface after failure");
   }
   {
    var view = new ChatModelView(file,"model.obj"); await Open(view);
    var web = (WebView2)Get(view,"_web"); var core = web.CoreWebView2!;
    var old = new TaskCompletionSource<string>(); core.Executions.Enqueue(old.Task);
    var earlier = Load(view);
    for (int i = 0; i < 200 && core.Scripts.Count == 0; i++) await Task.Delay(10);
    typeof(ChatModelView).GetMethod("Dispose", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(view, null);
    old.SetException(new IOException("Closed script failed")); await earlier;
    Check(!Error(view), "A closed preview must ignore pending errors");
   }
   {
    var view = new ChatModelView(file,"model.obj"); await Open(view);
    File.Delete(file); await Load(view);
    Check(Error(view), "A file removed during navigation must show a message");
   }
  } finally { Directory.Delete(root,true); }
  if (failures > 0) throw new Exception($"{failures} model preview checks failed");
  Console.WriteLine("Windows model preview payload, navigation and load ownership checks passed");
 }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-windows-model-') as directory:
    path = Path(directory)
    (path / 'Stubs.cs').write_text(stubs)
    (path / 'Program.cs').write_text(tests)
    (path / 'ChatModelView.cs').write_text((root / 'apps/windows/Pages/ChatModelView.cs').read_text())
    (path / 'Test.csproj').write_text('''<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable><NoWarn>CS0067;CS0649</NoWarn></PropertyGroup></Project>''')
    subprocess.run([dotnet, 'run', '--project', str(path / 'Test.csproj'), '-c', 'Release', '--nologo'], check=True)
