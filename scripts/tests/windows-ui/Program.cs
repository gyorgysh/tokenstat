// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Pages;
using Tokenstat.Design;
using Tokenstat.Navigation;
using Windows.Media.Core;

namespace NativeUiTests;

internal static class Program
{
    internal static int Result = 1;
    internal static void Log(string message)
    {
        var folder = Environment.GetEnvironmentVariable("TOKENSTAT_SCREEN_FIXTURE") ?? Path.GetTempPath();
        Directory.CreateDirectory(folder);
        File.AppendAllText(Path.Combine(folder, "ui-tests.log"), message + Environment.NewLine);
        Console.WriteLine(message);
    }
    [STAThread]
    private static int Main()
    {
        try
        {
            Log("Starting native Windows UI tests");
            WinRT.ComWrappersSupport.InitializeComWrappers();
            Log("Starting XAML application");
            Application.Start(_ =>
            {
                Log("XAML dispatcher initialized");
                SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
                new SmokeApp();
            });
        }
        catch (Exception ex) { Log(ex.ToString()); }
        Log("Native Windows UI result: " + Result);
        return Result;
    }
}
public sealed partial class SmokeApp : Application
{
    private Window? _window;
    public SmokeApp()
    {
        InitializeComponent();
        UnhandledException += (_, e) => { Program.Result = 1; Program.Log(e.Exception.ToString()); e.Handled = true; Exit(); };
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Program.Log("Creating editor and player controls");
        var editor = new RichEditBox { AcceptsReturn = true, Height = 160 };
        var video = new MediaPlayerElement { AutoPlay = true, Width = 320, Height = 180 };
        var terminal = new TerminalSurface { Height = 200, Width = 640 };
        var body = new StackPanel { Children = { editor, video, terminal } };
        _window = new Window { Content = body };
        body.Loaded += async (_, _) =>
        {
            Program.Log("Controls loaded");
            H264Streamer? streamer = null;
            try
            {
                var tree = EditorTree.Create();
                tree.Height = 90;
                var filename = new TextBlock { Text = "README.md" };
                var fileNode = new TreeViewNode { Content = filename };
                tree.RootNodes.Add(fileNode);
                body.Children.Add(tree);
                tree.UpdateLayout();
                await Task.Delay(250);
                if (Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(filename) is null || filename.ActualWidth <= 0)
                    throw new Exception("File tree rendered a node type name instead of the filename content");
                if (tree.CanDragItems || tree.CanReorderItems) throw new Exception("File tree permits visual-only file moves");
                body.Children.Remove(tree);
                Program.Log("PASS: production file tree renders filename content in native containers");
                var workspaceTabs = new WorkspaceTabStrip();
                var tabView = workspaceTabs.View;
                tabView.Height = 160;
                if (tabView.GetType() != typeof(TabView)) throw new Exception("Workspace tabs must use the native TabView type for style compatibility");
                body.Children.Add(tabView);
                var launch = workspaceTabs.Open("launcher", "Launch", () => new TextBlock { Text = "Launcher" }, false);
                var draft = new TextBox { Text = "Unsaved document" };
                var document = workspaceTabs.Open("file:README.md", "README.md", () => draft);
                workspaceTabs.Open("launcher", "Launch", () => throw new Exception("Existing launcher recreated"));
                workspaceTabs.Open("file:README.md", "README.md", () => throw new Exception("Existing document recreated"));
                tabView.ApplyTemplate();
                tabView.UpdateLayout();
                await Task.Delay(250);
                if (tabView.TabItems.Count != 2 || !ReferenceEquals(tabView.SelectedItem, document)
                    || draft.Text != "Unsaved document" || draft.ActualWidth <= 0 || draft.ActualHeight < 90)
                    throw new Exception("Workspace tabs lost selection, document content, or layout while switching");
                workspaceTabs.Forget(document);
                if (tabView.TabItems.Count != 1 || !ReferenceEquals(tabView.SelectedItem, launch))
                    throw new Exception("Closing a document did not return to the remaining workspace surface");
                body.Children.Remove(tabView);
                Program.Log("PASS: workspace tabs retain unsaved documents, deduplicate surfaces, and close cleanly");
                await terminal.Ready;
                terminal.Write(System.Text.Encoding.UTF8.GetBytes("\u001b[2J\u001b[H\u001b[31mred\u001b[0m\r\n"));
                // A UTF-8 scalar split across host reads must remain intact.
                terminal.Write(new byte[] { 0xf0, 0x9f });
                terminal.Write(new byte[] { 0x98, 0x80 });
                var web = (WebView2)terminal.Children[0];
                await Task.Delay(200);
                var screen = await web.ExecuteScriptAsync("JSON.stringify([terminal.buffer.active.getLine(0).translateToString(true),terminal.buffer.active.getLine(1).translateToString(true),terminal.buffer.active.getLine(0).getCell(0).getFgColor()])");
                var decoded = System.Text.Json.JsonSerializer.Deserialize<string>(screen);
                if (decoded != "[\"red\",\"😀\",1]") throw new Exception("Terminal did not render VT colors and split UTF-8: " + decoded);
                var typed = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
                terminal.Input = bytes => { typed.TrySetResult(bytes); return Task.CompletedTask; };
                await web.ExecuteScriptAsync("terminal.input('hello\\r', true)");
                if (System.Text.Encoding.UTF8.GetString(await typed.Task.WaitAsync(TimeSpan.FromSeconds(5))) != "hello\r")
                    throw new Exception("Terminal keyboard input did not reach the host bridge");
                var originalCols = terminal.Cols;
                terminal.Width = 320;
                terminal.Height = 150;
                body.UpdateLayout();
                await Task.Delay(350);
                if (terminal.Cols >= originalCols || terminal.Rows > 10)
                    throw new Exception("Terminal did not refit after the viewport shrank");
                terminal.Width = 640;
                terminal.Height = 200;
                body.UpdateLayout();
                Program.Log("PASS: production terminal renders VT colors, split UTF-8, direct input and fits a shrinking viewport");
                body.Children.Remove(terminal);
                terminal.Width = double.NaN;
                terminal.Height = double.NaN;
                var terminalGrid = new Grid();
                terminalGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                terminalGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
                terminalGrid.Children.Add(new TextBlock { Text = "Terminal" });
                Grid.SetRow(terminal, 1);
                terminalGrid.Children.Add(terminal);
                tabView.Height = 400;
                body.Children.Add(tabView);
                workspaceTabs.Open("terminal:test", "Shell", () => new Page { Content = terminalGrid });
                body.UpdateLayout();
                await Task.Delay(500);
                if (terminal.ActualHeight < 300 || terminal.Rows < 15)
                    throw new Exception($"Terminal tab collapsed to {terminal.ActualHeight}px / {terminal.Rows} rows");
                body.Children.Remove(tabView);
                Program.Log("PASS: a terminal page fills the native workspace tab content area");
                // Exercise the outer production shell too: NavigationView has
                // a second content presenter, independent of TabView's.
                tabView.Height = double.NaN;
                var workspaceFrame = new Frame { Content = new Page { Content = tabView } };
                var inspectorHost = new InspectorHost { RouteAllowsInspector = true };
                inspectorHost.SetContent(workspaceFrame);
                inspectorHost.SetInspector(new TextBlock { Text = "Files" }, true);
                var shellBody = new Grid();
                shellBody.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                shellBody.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
                shellBody.Children.Add(new TextBlock { Text = "Workspace toolbar" });
                Grid.SetRow(inspectorHost, 1);
                shellBody.Children.Add(inspectorHost);
                var contentHost = new Border { Child = shellBody };
                var navigation = new NavigationView { Content = contentHost, Height = 650, Width = 1100 };
                navigation.Loaded += (_, _) => NativeContentLayout.Stretch(navigation, contentHost);
                body.Children.Add(navigation);
                body.UpdateLayout();
                await Task.Delay(500);
                if (terminal.ActualHeight < 450 || terminal.Rows < 25)
                    throw new Exception($"Shell terminal collapsed: {terminal.ActualHeight}px / {terminal.Rows} rows");
                navigation.Height = 450;
                body.UpdateLayout();
                await Task.Delay(350);
                if (terminal.ActualHeight < 250 || terminal.ActualHeight > 400)
                    throw new Exception($"Shell terminal failed resize: {terminal.ActualHeight}px");
                body.Children.Remove(navigation);
                Program.Log("PASS: terminal fills NavigationView, Frame, inspector host, page and tab after resize");
                var actions = new FlowPanel { Width = 248, Spacing = 8 };
                foreach (var label in new[] { "0 of 8 selected", "Select all", "Clear", "Review and commit", "Review all" })
                    actions.Children.Add(new Button { Content = label });
                body.Children.Add(actions);
                body.UpdateLayout();
                if (actions.ActualHeight < 64) throw new Exception("Inspector actions did not wrap");
                foreach (FrameworkElement action in actions.Children)
                {
                    var point = action.TransformToVisual(actions).TransformPoint(new Windows.Foundation.Point());
                    if (point.X + action.ActualWidth > 248.5) throw new Exception("Inspector action overflowed");
                }
                body.Children.Remove(actions);
                var largeText = string.Concat(Enumerable.Repeat("let value = 123;\r", 5000));
                editor.Document.SetText(TextSetOptions.None, largeText);
                editor.Document.Selection.SetRange(5, 5);
                var beforeFormatting = EditorText.Read(editor.Document);
                var formattingTime = System.Diagnostics.Stopwatch.StartNew();
                EditorText.Format(editor.Document, () =>
                {
                    for (var offset = 0; offset < largeText.Length; offset += 17)
                        editor.Document.GetRange(offset, Math.Min(offset + 3, largeText.Length)).CharacterFormat.ForegroundColor = Microsoft.UI.Colors.Purple;
                });
                if (formattingTime.Elapsed > TimeSpan.FromSeconds(10)) throw new Exception("Batched syntax formatting stalled the UI");
                if (EditorText.Read(editor.Document) != beforeFormatting || editor.Document.Selection.StartPosition != 5)
                    throw new Exception("Syntax formatting changed the document or caret");
                Program.Log("PASS: narrow inspector actions wrap and large editor formatting preserves text and caret");
                var cards = new FlowPanel { MinimumItemWidth = 300, Spacing = 10 };
                var shortCard = new Border { MinHeight = 40 };
                var tallCard = new Border { MinHeight = 80 };
                cards.Children.Add(shortCard); cards.Children.Add(tallCard);
                // Measure the real mounted surface. Off-tree Arrange can leave
                // ActualHeight unpublished until the native layout pass runs.
                cards.Width = 640;
                body.Children.Add(cards);
                body.UpdateLayout();
                await Task.Delay(250);
                if (Math.Abs(shortCard.ActualHeight - 80) > 0.5 || Math.Abs(tallCard.ActualHeight - 80) > 0.5)
                    throw new Exception($"Responsive cards have heights {shortCard.ActualHeight} / {tallCard.ActualHeight}, expected 80");
                cards.Width = 300;
                body.UpdateLayout();
                await Task.Delay(250);
                if (Math.Abs(cards.ActualHeight - 130) > 0.5)
                    throw new Exception($"Responsive cards did not wrap: height {cards.ActualHeight}, expected 130");
                body.Children.Remove(cards);
                Program.Log("PASS: responsive device cards align and wrap");
                var stable = new NavigationViewItem { Tag = "live:1", Content = new TextBlock { Text = "Before" } };
                IList<object> liveRows = new List<object> { stable };
                NavigationRows.Reconcile(liveRows, new[] { new NavigationViewItem { Tag = "live:1", Content = new TextBlock { Text = "After" } } }, "live:", 0);
                if (!ReferenceEquals(liveRows[0], stable) || ((TextBlock)stable.Content).Text != "After")
                    throw new Exception("Sidebar refresh replaced a live navigation container");
                Program.Log("PASS: sidebar refresh retains live row containers");
                var hosts = new NavigationViewItem { Tag = "ssh:Hosts" };
                var ssh = new NavigationViewItem { Tag = "ssh:Hosts", MenuItems = { hosts }, IsExpanded = true };
                var files = new NavigationViewItem { Tag = "ws:folder:Files" };
                var folder = new NavigationViewItem { Tag = "ws:folder:Files", MenuItems = { files }, IsExpanded = false };
                var expansion = NavigationExpansion.Capture(new[] { ssh, hosts, folder, files });
                if (expansion.Count != 2 || !expansion["ssh:Hosts"] || expansion["ws:folder:Files"])
                    throw new Exception("Navigation expansion did not preserve the group state for shared landing routes");
                Program.Log("PASS: navigation groups can share landing routes with their child pages");
                foreach (var original in new[] { "", "hello", "one\ntwo", "one\ntwo\n", "one\ntwo\n\n", "one\r\ntwo\r\n", "😀 café\n" })
                {
                    editor.Document.SetText(TextSetOptions.None, original);
                    await Task.Delay(20);
                    var read = EditorText.Read(editor.Document);
                    if (EditorText.ForFile(read, original) != original) throw new Exception($"Editor changed file text: expected {System.Text.Json.JsonSerializer.Serialize(original)}, got {System.Text.Json.JsonSerializer.Serialize(read)}");
                    var actual = read.Replace("\r\n", "\n").Replace('\r', '\n');
                    var expected = original.Replace("\r\n", "\n");
                    if (actual != expected) throw new Exception($"Editor altered file text: expected {System.Text.Json.JsonSerializer.Serialize(expected)}, got {System.Text.Json.JsonSerializer.Serialize(actual)}");
                }
                Program.Log("PASS: native RichEdit preserves text and real trailing newlines");
                var fixture = Environment.GetEnvironmentVariable("TOKENSTAT_SCREEN_FIXTURE") ?? throw new Exception("Screen fixture path missing");
                var frames = Directory.GetFiles(fixture, "frame-*.bin").Order().Select(path => ScreenFrame.Parse(File.ReadAllBytes(path))!).ToArray();
                if (frames.Length < 3 || frames.Any(frame => frame is null)) throw new Exception("Native encoder fixture missing");
                streamer = new H264Streamer((uint)frames[0].Width, (uint)frames[0].Height);
                var opened = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                string? playbackFailure = null;
                using var player = new Windows.Media.Playback.MediaPlayer();
                video.SetMediaPlayer(player);
                player.MediaOpened += (_, _) => opened.TrySetResult();
                player.MediaFailed += (_, error) =>
                {
                    playbackFailure = error.ErrorMessage;
                    opened.TrySetException(new Exception(playbackFailure));
                };
                video.Source = MediaSource.CreateFromMediaStreamSource(streamer.Source);
                foreach (var frame in frames) streamer.Push(frame.Payload, frame.Keyframe, TimeSpan.FromTicks((long)frame.TimestampMicroseconds * 10), frame.Sequence);
                player.Play();
                await opened.Task.WaitAsync(TimeSpan.FromSeconds(15));
                await Task.Delay(500);
                if (playbackFailure is not null) throw new Exception(playbackFailure);
                if (player.PlaybackSession.NaturalVideoWidth != 320 || player.PlaybackSession.NaturalVideoHeight != 180)
                    throw new Exception("Native Windows decoder did not accept the host encoder's stream");
                Program.Log("PASS: native host H.264 opens in the production Windows player pipeline");
                // The relay may skip frames or restart an encoder. Resume on
                // an independent frame without passing broken references on.
                foreach (var frame in frames)
                    streamer.Push(frame.Payload, frame.Keyframe,
                        TimeSpan.FromSeconds(1) + TimeSpan.FromTicks((long)frame.TimestampMicroseconds * 10), frame.Sequence + 100);
                await Task.Delay(500);
                if (playbackFailure is not null) throw new Exception(playbackFailure);
                Program.Log("PASS: player accepts a stream sequence discontinuity");
                video.SetMediaPlayer(null);
                streamer.Close();
                player.Source = null;
                for (var iteration = 0; iteration < 3; iteration++)
                {
                    streamer = new H264Streamer((uint)frames[0].Width, (uint)frames[0].Height);
                    using var next = new Windows.Media.Playback.MediaPlayer();
                    var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                    next.MediaOpened += (_, _) => ready.TrySetResult();
                    next.MediaFailed += (_, error) => ready.TrySetException(new Exception($"{error.Error}: {error.ErrorMessage}"));
                    video.SetMediaPlayer(next);
                    next.Source = MediaSource.CreateFromMediaStreamSource(streamer.Source);
                    foreach (var frame in frames) streamer.Push(frame.Payload, frame.Keyframe, TimeSpan.FromTicks((long)frame.TimestampMicroseconds * 10), frame.Sequence);
                    next.Play();
                    await ready.Task.WaitAsync(TimeSpan.FromSeconds(15));
                    await Task.Delay(100);
                    // Reconfigure/navigate while the live stream is waiting for more data.
                    video.SetMediaPlayer(null);
                    streamer.Close();
                    next.Source = null;
                }
                await Task.Delay(200);
                Program.Log("PASS: repeated screen detach, decoder disposal and reopen");
                Program.Result = 0;
            }
            catch (Exception ex) { Program.Log(ex.ToString()); }
            finally { terminal.Close(); video.SetMediaPlayer(null); streamer?.Close(); _window.Close(); Exit(); }
        };
        _window.Activate();
    }
}
