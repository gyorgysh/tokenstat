// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Windows.ApplicationModel.DataTransfer;
using WinRT.Interop;

namespace Tokenstat.Pages;

internal sealed partial class ScreenPage
{
    private const int ScreenClipboardLimit = 4096;
    private DispatcherQueueTimer? _clipboardTimer;
    private uint _clipboardSequence;
    private string? _clipboardNote;
    private string? _clipboardFromHost;
    private Window? _clipboardWindow;

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();

    private bool ScreenClipboardCurrent(string session) => IsLoaded && !_closed && _control && _sessionId == session
        && _accountGeneration == AppServices.AccountGeneration && App.CurrentWindow is { } window
        && GetForegroundWindow() == WindowNative.GetWindowHandle(window);

    private void UpdateScreenClipboard()
    {
        _clipboardTimer?.Stop();
        _clipboardTimer = null;
        if (_clipboardWindow is { } previous) previous.Activated -= ScreenClipboardWindowActivated;
        _clipboardWindow = null;
        _clipboardNote = _clipboardFromHost = null;
        if (_closed || !_control || _sessionId is not { Length: > 0 } session || App.CurrentWindow is not { } window) return;
        _clipboardWindow = window;
        window.Activated += ScreenClipboardWindowActivated;
        _clipboardSequence = GetClipboardSequenceNumber();
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(250);
        timer.Tick += (_, _) => _ = SendScreenClipboardAsync(session);
        _clipboardTimer = timer;
        timer.Start();
    }

    private void ScreenClipboardWindowActivated(object sender, WindowActivatedEventArgs args) =>
        _clipboardSequence = GetClipboardSequenceNumber();

    private async Task SendScreenClipboardAsync(string session)
    {
        if (!ScreenClipboardCurrent(session))
        {
            // Changes made while another window had focus do not carry over
            // when the viewer takes focus again.
            _clipboardSequence = GetClipboardSequenceNumber();
            return;
        }
        var sequence = GetClipboardSequenceNumber();
        if (sequence == 0 || sequence == _clipboardSequence) return;
        _clipboardSequence = sequence;
        try
        {
            var data = Clipboard.GetContent();
            if (!data.Contains(StandardDataFormats.Text)) return;
            var text = await data.GetTextAsync();
            if (!ScreenClipboardCurrent(session) || sequence != GetClipboardSequenceNumber() || text == _clipboardFromHost
                || Encoding.UTF8.GetByteCount(text) > ScreenClipboardLimit) return;
            _clipboardFromHost = null;
            await SendEventAsync(new JsonObject { ["type"] = "clipboard", ["text"] = text });
        }
        catch (Exception error) when (error is COMException or UnauthorizedAccessException or InvalidOperationException)
        {
            // A locked or unavailable Windows clipboard does not stop video.
        }
    }

    private void ApplyScreenClipboard(JsonObject payload)
    {
        if (_sessionId is not { Length: > 0 } session || !ScreenClipboardCurrent(session)
            || payload["text"] is not JsonValue value || !value.TryGetValue<string>(out var text)
            || Encoding.UTF8.GetByteCount(text) > ScreenClipboardLimit) return;
        var note = Format.Text(payload, "id");
        if (note.Length > 0 && note == _clipboardNote) return;
        try
        {
            var data = new DataPackage();
            data.SetText(text);
            Clipboard.SetContent(data);
            _clipboardNote = note;
            _clipboardSequence = GetClipboardSequenceNumber();
            _clipboardFromHost = text;
        }
        catch (Exception error) when (error is COMException or UnauthorizedAccessException or InvalidOperationException)
        {
            // The host can send a later clipboard change after Windows frees it.
        }
    }
}
