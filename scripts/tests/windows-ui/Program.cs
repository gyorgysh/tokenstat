// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Pages;
using Windows.Media.Core;

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
            Application.Start(_ =>
            {
                SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
                new SmokeApp();
            });
        }
        catch (Exception ex) { Log(ex.ToString()); }
        Log("Native Windows UI result: " + Result);
        return Result;
    }
}
internal sealed class SmokeApp : Application
{
    private Window? _window;
    public SmokeApp()
    {
        Resources.MergedDictionaries.Add(new XamlControlsResources());
        UnhandledException += (_, e) => { Program.Log(e.Exception.ToString()); e.Handled = true; Exit(); };
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Program.Log("Creating editor and player controls");
        var editor = new RichEditBox { AcceptsReturn = true, Height = 160 };
        var video = new MediaPlayerElement { AutoPlay = true, Width = 320, Height = 180 };
        var body = new StackPanel { Children = { editor, video } };
        _window = new Window { Content = body };
        body.Loaded += async (_, _) =>
        {
            Program.Log("Controls loaded");
            H264Streamer? streamer = null;
            try
            {
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
                using var player = new Windows.Media.Playback.MediaPlayer();
                video.SetMediaPlayer(player);
                player.MediaOpened += (_, _) => opened.TrySetResult();
                player.MediaFailed += (_, error) => opened.TrySetException(new Exception(error.ErrorMessage));
                video.Source = MediaSource.CreateFromMediaStreamSource(streamer.Source);
                foreach (var frame in frames) streamer.Push(frame.Payload, frame.Keyframe, TimeSpan.FromTicks((long)frame.TimestampMicroseconds * 10));
                player.Play();
                await opened.Task.WaitAsync(TimeSpan.FromSeconds(15));
                await Task.Delay(500);
                if (player.PlaybackSession.NaturalVideoWidth != 320 || player.PlaybackSession.NaturalVideoHeight != 180)
                    throw new Exception("Native Windows decoder did not accept the host encoder's stream");
                Program.Log("PASS: native host H.264 opens in the production Windows player pipeline");
                Program.Result = 0;
            }
            catch (Exception ex) { Program.Log(ex.ToString()); }
            finally { streamer?.Close(); _window.Close(); Exit(); }
        };
        _window.Activate();
    }
}
