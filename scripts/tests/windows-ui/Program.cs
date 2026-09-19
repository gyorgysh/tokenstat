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
                Program.Log("PASS: production terminal renders VT colors, split UTF-8 and direct input");
                var cards = new FlowPanel { MinimumItemWidth = 300, Spacing = 10 };
                var shortCard = new Border { MinHeight = 40 };
                var tallCard = new Border { MinHeight = 80 };
                cards.Children.Add(shortCard); cards.Children.Add(tallCard);
                cards.Measure(new Windows.Foundation.Size(640, double.PositiveInfinity));
                cards.Arrange(new Windows.Foundation.Rect(0, 0, 640, cards.DesiredSize.Height));
                if (shortCard.ActualHeight != 80 || tallCard.ActualHeight != 80)
                    throw new Exception("Responsive cards did not share their row height");
                cards.Measure(new Windows.Foundation.Size(300, double.PositiveInfinity));
                if (cards.DesiredSize.Height != 130) throw new Exception("Responsive cards did not wrap to fit a narrow viewport");
                Program.Log("PASS: responsive device cards align and wrap");
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
