#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run the production Windows image selection and keyboard handlers with held I/O."""
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
        public double Height = 600;
        public int Changes;
        public void ChangeView(double x, double y, float zoom, bool disableAnimation) { Changes++; ZoomFactor = zoom; }
    }
    class Dialog { public bool Hidden; public void Hide() => Hidden = true; }
    enum VirtualKey { Escape, Left, Right }
    class KeyArgs { public VirtualKey Key; public bool Handled; }
    static class L10n { public static string Text(string key, params string[] values) => key + string.Join("/", values); }
    Image image = new();
    Label name = new(), count = new();
    Panel actions = new(), body = new();
    Viewer viewer = new();
    Dialog dialog = new();
    async Task Show(int next)
''' + block('async Task Show(int next)') + '''
    void KeyDown(KeyArgs args)
''' + block('dialog.PreviewKeyDown +=') + '''
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
        foreach (var failure in failures) Console.WriteLine("FAIL: " + failure);
        if (failures.Count != 0) throw new Exception($"{failures.Count} image navigation regressions");
        Console.WriteLine("Windows image handlers: boundaries, duplicate selections, held transfers, zoomed keys, navigation, close and late replies passed");
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-windows-images-') as directory:
    folder = Path(directory)
    (folder / 'Program.cs').write_text(code)
    (folder / 'Checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable><NoWarn>CS0649</NoWarn></PropertyGroup></Project>')
    subprocess.run(['dotnet', 'run', '--project', str(folder / 'Checks.csproj'), '-c', 'Release'], check=True)
