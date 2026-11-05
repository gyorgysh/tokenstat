#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise production Windows image selection, touch and keyboard handlers with held I/O."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/windows/Pages/ChatPage.Images.cs').read_text()

def block(marker):
    start = source.index('{', source.index(marker))
    end, depth = start + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

code = '''
using Tokenstat.Pages;
namespace Microsoft.UI.Input { enum PointerDeviceType { Touch, Mouse, Pen } }
class Checks {
    record Item(string Name);
    Item[] images = [new("first"), new("second")];
    int selected, revision;
    long _imageViewerRevision;
    bool hasSelection, live = true, hold;
    CancellationTokenSource viewerCancellation = new();
    CancellationTokenSource? selectionCancellation;
    string? currentFile, _imageViewedFile;
    int reads;
    List<CancellationToken> tokens = [];
    Queue<TaskCompletionSource<string?>> downloads = new();
    bool Current() => live;
    Task<string?> ImageFileAsync(Item item, bool initiated, CancellationToken token) {
        reads++; tokens.Add(token);
        if (!hold) return Task.FromResult<string?>(item.Name);
        var completion = new TaskCompletionSource<string?>(); downloads.Enqueue(completion);
        return completion.Task;
    }
    Task<object> DecodeImageAsync(string file, int edge) => Task.FromResult<object>(file);
    class Image { public object? Source; public double MaxWidth, MaxHeight; }
    class Label { public string Text = ""; }
    class Button { public bool IsEnabled; }
    class Panel { public double Width = 800; public List<Button> Children = [new(), new()]; }
    class Viewer {
        public float ZoomFactor = 1;
        public double Height = 600, ActualWidth = 600;
        public int Changes;
        public void ChangeView(double x, double y, float zoom, bool disableAnimation) { Changes++; ZoomFactor = zoom; }
    }
    class Dialog { public bool Hidden; public void Hide() => Hidden = true; }
    enum VirtualKey { Escape, Left, Right }
    class KeyArgs { public VirtualKey Key; public bool Handled; }
    static class L10n { public static string Text(string key, params string[] values) => key + string.Join("/", values); }
    class Pointer { public uint PointerId; public bool IsInContact = true; public Microsoft.UI.Input.PointerDeviceType PointerDeviceType = Microsoft.UI.Input.PointerDeviceType.Touch; }
    class PointerRoutedEventArgs {
        public Pointer Pointer = new(); public double X, Y;
        public PointerPoint GetCurrentPoint(Viewer view) => new(X, Y);
    }
    record Position(double X, double Y);
    record PointerPoint(Position Position) { public PointerPoint(double x, double y) : this(new Position(x, y)) {} }
    class Surface {
        public int Cancels, Captures, Releases; public bool CaptureSucceeds = true;
        public bool CancelDirectManipulations() { Cancels++; return true; }
        public bool CapturePointer(Pointer pointer) { Captures++; return CaptureSucceeds; }
        public void ReleasePointerCapture(Pointer pointer) { Releases++; }
    }
    static class UIElement {
        public static List<uint> Native = []; public static bool Throws, Accepts = true;
        public static bool TryStartDirectManipulation(Pointer pointer) {
            Native.Add(pointer.PointerId);
            if (Throws) throw new ArgumentException();
            return Accepts;
        }
    }
    enum WindowActivationState { Deactivated, CodeActivated }
    class WindowActivatedEventArgs { public WindowActivationState WindowActivationState; }
    Surface surface = new();
    Pointer? firstContact;
    ChatImageSwipe swipe = new();
    Image image = new();
    Label name = new(), count = new();
    Panel actions = new(), body = new();
    Viewer viewer = new();
    Dialog dialog = new();
    async Task Show(int next)
''' + block('async Task Show(int next)') + '''
    void KeyDown(KeyArgs args)
''' + block('dialog.PreviewKeyDown +=') + '''
    void ResetSwipe()
''' + block('void ResetSwipe()') + '''
    bool ResumeNative(Pointer? contact)
''' + block('bool ResumeNative(Pointer? contact)') + '''
    void PointerPressed(object sender, PointerRoutedEventArgs args)
''' + block('void PointerPressed(object sender') + '''
    void PointerReleased(object sender, PointerRoutedEventArgs args)
''' + block('void PointerReleased(object sender') + '''
    void PointerCancelled(object sender, PointerRoutedEventArgs args)
''' + block('void PointerCancelled(object sender') + '''
    void PointerCaptureLost(object sender, PointerRoutedEventArgs args)
''' + block('void PointerCaptureLost(object sender') + '''
    void ViewerWindowActivated(object sender, WindowActivatedEventArgs args)
''' + block('void ViewerWindowActivated(object sender') + '''
    static PointerRoutedEventArgs Touch(uint id, double x, double y) => new() { Pointer = new() { PointerId = id }, X = x, Y = y };
    static List<string> failures = [];
    static void Check(bool condition, string message) { if (!condition) failures.Add(message); }
    static async Task Main() {
        var first = new Checks(); await first.Show(0); first.viewer.ZoomFactor = 2;
        await first.Show(-1); await first.Show(0);
        Check(first.reads == 1 && first.viewer.ZoomFactor == 2 && (string?)first.image.Source == "first", "First-image boundary/duplicate selection reloaded the image or reset zoom");
        var last = new Checks(); await last.Show(1); last.viewer.ZoomFactor = 3;
        await last.Show(2); await last.Show(int.MaxValue);
        Check(last.reads == 1 && last.viewer.ZoomFactor == 3 && (string?)last.image.Source == "second", "Last-image boundary reloaded the image or reset zoom");
        var pending = new Checks { hold = true }; var opening = pending.Show(0);
        var boundary = pending.Show(-1); var duplicate = pending.Show(0);
        Check(pending.reads == 1 && !pending.tokens[0].IsCancellationRequested, "A no-op selection cancelled or restarted the active transfer");
        while (pending.downloads.TryDequeue(out var completion)) completion.SetResult("first");
        await Task.WhenAll(opening, boundary, duplicate);
        var keys = new Checks(); await keys.Show(0); keys.viewer.ZoomFactor = 2;
        var right = new KeyArgs { Key = VirtualKey.Right }; keys.KeyDown(right);
        Check(!right.Handled && keys.reads == 1, "Zoomed arrow keys stole native scrolling and selected another image");
        keys.viewer.ZoomFactor = 1; right = new() { Key = VirtualKey.Right }; keys.KeyDown(right);
        Check(right.Handled && keys.selected == 1 && (string?)keys.image.Source == "second", "Fitted arrow keys did not navigate");
        var escape = new KeyArgs { Key = VirtualKey.Escape }; keys.KeyDown(escape);
        Check(escape.Handled && keys.dialog.Hidden, "Escape did not close the viewer");
        var retired = new Checks { live = false }; await retired.Show(0);
        Check(retired.reads == 0 && retired.viewer.Changes == 0, "A retired viewer started work");
        var race = new Checks { hold = true }; var old = race.Show(0); var next = race.Show(1);
        Check(race.tokens[0].IsCancellationRequested, "Real navigation did not cancel the prior transfer");
        var oldReply = race.downloads.Dequeue(); race.downloads.Dequeue().SetResult("second"); await next;
        oldReply.SetResult("first"); await old;
        Check((string?)race.image.Source == "second" && race.currentFile == "second", "Late old image overwrote the current selection");
        var closing = new Checks { hold = true }; var late = closing.Show(0); closing.live = false;
        closing.downloads.Dequeue().SetResult("first"); await late;
        Check(closing.image.Source is null && closing.currentFile is null, "Closed viewer accepted a late image");
        var touch = new Checks(); await touch.Show(0);
        touch.PointerPressed(touch, Touch(1, 200, 150)); touch.PointerReleased(touch, Touch(1, 20, 150));
        Check(touch.selected == 1 && touch.reads == 2 && touch.surface.Cancels == 1 && touch.surface.Captures == 1,
            "Fitted touch handlers did not select the next image");
        var pinch = new Checks(); await pinch.Show(0); UIElement.Native.Clear();
        pinch.PointerPressed(pinch, Touch(1, 200, 150)); pinch.PointerPressed(pinch, Touch(2, 300, 150));
        Check(UIElement.Native.SequenceEqual(new uint[] { 1, 2 }) && pinch.surface.Cancels == 1,
            "Pinch did not resume native manipulation for both contacts");
        pinch.PointerReleased(pinch, Touch(1, 0, 150)); pinch.PointerReleased(pinch, Touch(2, 0, 150));
        Check(pinch.reads == 1, "Finishing a pinch selected another image");
        pinch.PointerPressed(pinch, Touch(3, 200, 150)); pinch.PointerReleased(pinch, Touch(3, 0, 150));
        Check(pinch.selected == 1, "A new swipe after a pinch did not navigate");
        var pan = new Checks(); await pan.Show(0); pan.viewer.ZoomFactor = 2;
        pan.PointerPressed(pan, Touch(1, 200, 150)); pan.PointerReleased(pan, Touch(1, 0, 150));
        Check(pan.reads == 1 && pan.surface.Cancels == 0 && pan.surface.Captures == 0, "Zoomed panning was intercepted");
        foreach (var device in new[] { Microsoft.UI.Input.PointerDeviceType.Mouse, Microsoft.UI.Input.PointerDeviceType.Pen }) {
            var untouched = new Checks(); await untouched.Show(0); var input = Touch(1, 200, 150); input.Pointer.PointerDeviceType = device;
            untouched.PointerPressed(untouched, input); input.X = 0; untouched.PointerReleased(untouched, input);
            Check(untouched.reads == 1 && untouched.surface.Cancels == 0, "Mouse or pen input was taken as a touch swipe");
        }
        var lost = new Checks(); await lost.Show(0);
        lost.PointerPressed(lost, Touch(1, 200, 150)); lost.PointerCaptureLost(lost, Touch(1, 0, 150)); lost.PointerReleased(lost, Touch(1, 0, 150));
        Check(lost.reads == 1, "Losing pointer capture selected another image");
        var inactive = new Checks(); await inactive.Show(0);
        inactive.PointerPressed(inactive, Touch(1, 200, 150));
        inactive.ViewerWindowActivated(inactive, new() { WindowActivationState = WindowActivationState.Deactivated });
        inactive.PointerReleased(inactive, Touch(1, 0, 150));
        Check(inactive.reads == 1 && inactive.surface.Releases == 1, "Window deactivation left a swipe active");
        var failedCapture = new Checks(); await failedCapture.Show(0); failedCapture.surface.CaptureSucceeds = false; UIElement.Native.Clear();
        UIElement.Throws = true; failedCapture.PointerPressed(failedCapture, Touch(1, 200, 150)); UIElement.Throws = false;
        failedCapture.PointerReleased(failedCapture, Touch(1, 0, 150));
        Check(failedCapture.reads == 1 && UIElement.Native.SequenceEqual(new uint[] { 1 }), "Failed capture did not safely return input to native handling");
        var retiredTouch = new Checks(); await retiredTouch.Show(0);
        retiredTouch.PointerPressed(retiredTouch, Touch(1, 200, 150)); retiredTouch.live = false; retiredTouch.PointerReleased(retiredTouch, Touch(1, 0, 150));
        Check(retiredTouch.reads == 1, "A retired viewer accepted touch navigation");
        foreach (var failure in failures) Console.WriteLine("FAIL: " + failure);
        if (failures.Count != 0) throw new Exception($"{failures.Count} image navigation regressions");
        Console.WriteLine("Windows image handlers: touch swipes, native pinch handoff, capture loss, deactivation, boundaries, duplicate selections, held transfers, zoomed keys, navigation, close and late replies passed");
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-windows-images-') as directory:
    folder = Path(directory)
    (folder / 'Program.cs').write_text(code)
    (folder / 'ChatImageSwipe.cs').write_text((root / 'apps/windows/Pages/ChatImageSwipe.cs').read_text())
    (folder / 'Checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable><NoWarn>CS0649</NoWarn></PropertyGroup></Project>')
    subprocess.run(['dotnet', 'run', '--project', str(folder / 'Checks.csproj'), '-c', 'Release'], check=True)
