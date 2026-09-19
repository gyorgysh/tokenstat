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
    [STAThread]
    private static int Main()
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            new SmokeApp();
        });
        return Result;
    }
}
internal sealed class SmokeApp : Application
{
    private Window? _window;
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var editor = new RichEditBox { AcceptsReturn = true, Height = 160 };
        var video = new MediaPlayerElement { AutoPlay = true, Width = 320, Height = 180 };
        var body = new StackPanel { Children = { editor, video } };
        _window = new Window { Content = body };
        body.Loaded += async (_, _) =>
        {
            H264Streamer? streamer = null;
            try
            {
                foreach (var original in new[] { "", "hello", "one\ntwo", "one\ntwo\n", "one\ntwo\n\n", "one\r\ntwo\r\n", "😀 café\n" })
                {
                    editor.Document.SetText(TextSetOptions.None, original);
                    await Task.Delay(20);
                    var actual = EditorText.Read(editor.Document).Replace("\r\n", "\n").Replace('\r', '\n');
                    var expected = original.Replace("\r\n", "\n");
                    if (actual != expected) throw new Exception($"Editor altered file text: expected {System.Text.Json.JsonSerializer.Serialize(expected)}, got {System.Text.Json.JsonSerializer.Serialize(actual)}");
                }
                Console.WriteLine("PASS: native RichEdit preserves text and real trailing newlines");
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
                Console.WriteLine("PASS: native host H.264 opens in the production Windows player pipeline");
                Program.Result = 0;
            }
            catch (Exception ex) { Console.Error.WriteLine(ex); }
            finally { streamer?.Close(); _window.Close(); Exit(); }
        };
        _window.Activate();
    }
}
