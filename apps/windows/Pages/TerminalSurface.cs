// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Tokenstat.Design;
using Windows.ApplicationModel.DataTransfer;

namespace Tokenstat.Pages;

/// <summary>A local, bundled VT terminal. Terminal bytes are data, never HTML or script.</summary>
internal sealed class TerminalSurface : Grid
{
    private WebView2 _web = new();
    private TaskCompletionSource _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly SemaphoreSlim _inputGate = new(1, 1);
    private readonly SemaphoreSlim _resizeGate = new(1, 1);
    private readonly SemaphoreSlim _lifecycle = new(1, 1);
    private int _generation;
    private bool _starting;
    private bool _closed;
    public int Rows { get; private set; } = 30;
    public int Cols { get; private set; } = 100;
    public Func<byte[], Task>? Input { get; set; }
    public Func<int, int, Task>? Resized { get; set; }
    public event Action<string>? Failed;
    public Task Ready => _ready.Task.WaitAsync(TimeSpan.FromSeconds(15));

    public TerminalSurface()
    {
        Children.Add(_web);
        Loaded += async (_, _) => await InitializeAsync();
        ActualThemeChanged += (_, _) => SendTheme();
    }

    /// <summary>
    /// After <see cref="Close"/>, put a fresh WebView2 in the tree so a
    /// cached page can come back. The PTY session is separate and survives.
    /// Starts the new controller here: Grid.Loaded may already have fired
    /// while this surface was closed.
    /// </summary>
    public void PrepareForReuse()
    {
        if (!_closed) return;
        _web = new WebView2();
        _ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _starting = false;
        _closed = false;
        Children.Clear();
        Children.Add(_web);
        _ = InitializeAsync();
    }

    private async Task InitializeAsync()
    {
        await _lifecycle.WaitAsync();
        var claimed = false;
        var started = false;
        try
        {
            if (_starting || _closed) return;
            _starting = true;
            claimed = true;
            var web = _web;
            var generation = _generation;
            await web.EnsureCoreWebView2Async();
            if (_closed || generation != _generation || !ReferenceEquals(web, _web))
            {
                try { web.Close(); } catch { /* Closed while the runtime was starting. */ }
                return;
            }
            var core = web.CoreWebView2;
            core.SetVirtualHostNameToFolderMapping("terminal.tokenstat.invalid", Path.Combine(AppContext.BaseDirectory, "Assets"), CoreWebView2HostResourceAccessKind.DenyCors);
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreBrowserAcceleratorKeysEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            core.NavigationStarting += (_, e) => e.Cancel = e.Uri != "https://terminal.tokenstat.invalid/Terminal/terminal.html";
            core.NewWindowRequested += (_, e) => e.Handled = true;
            core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
            core.WebMessageReceived += async (_, e) =>
            {
                if (_closed || generation != _generation
                    || e.Source != "https://terminal.tokenstat.invalid/Terminal/terminal.html") return;
                try
                {
                    using var document = JsonDocument.Parse(e.WebMessageAsJson);
                    var message = document.RootElement;
                    var type = message.GetProperty("type").GetString();
                    if (type is "resize" or "ready")
                    {
                        Rows = Math.Clamp(message.GetProperty("rows").GetInt32(), 5, 200);
                        Cols = Math.Clamp(message.GetProperty("cols").GetInt32(), 20, 400);
                        if (type == "ready") { _ready.TrySetResult(); SendTheme(); }
                        var rows = Rows; var cols = Cols;
                        await _resizeGate.WaitAsync();
                        try
                        {
                            if (!_closed && generation == _generation && rows == Rows && cols == Cols
                                && Resized is not null) await Resized(rows, cols);
                        }
                        finally { _resizeGate.Release(); }
                    }
                    else if (type == "contextMenu")
                    {
                        var selection = message.GetProperty("selection").GetString() ?? "";
                        var menu = new MenuFlyout();
                        ContextMenus.Add(menu, "Copy", () =>
                        {
                            var data = new DataPackage(); data.SetText(selection); Clipboard.SetContent(data);
                        }, () => selection.Length > 0);
                        ContextMenus.AddAsync(menu, "Paste", async () =>
                        {
                            try
                            {
                                var data = Clipboard.GetContent();
                                if (data.Contains(StandardDataFormats.Text)) Paste(await data.GetTextAsync());
                            }
                            catch (Exception ex) { Failed?.Invoke(ex.Message); }
                        });
                        ContextMenus.Add(menu, "Select all", () => Send(new { type = "selectAll" }));
                        menu.ShowAt(web, new Microsoft.UI.Xaml.Controls.Primitives.FlyoutShowOptions
                        {
                            Position = new Windows.Foundation.Point(message.GetProperty("x").GetDouble(), message.GetProperty("y").GetDouble()),
                        });
                    }
                    else if (type == "copy")
                    {
                        var content = new DataPackage();
                        content.SetText(message.GetProperty("data").GetString() ?? "");
                        Clipboard.SetContent(content);
                    }
                    else if (type == "pasteRequest")
                    {
                        var content = Clipboard.GetContent();
                        if (content.Contains(StandardDataFormats.Text)) Paste(await content.GetTextAsync());
                    }
                    else if (type is "input" or "binary")
                    {
                        var data = message.GetProperty("data").GetString() ?? "";
                        var bytes = type == "binary" ? data.Select(c => (byte)c).ToArray() : Encoding.UTF8.GetBytes(data);
                        await _inputGate.WaitAsync();
                        try
                        {
                            if (!_closed && generation == _generation && Input is not null) await Input(bytes);
                        }
                        finally { _inputGate.Release(); }
                    }
                }
                catch (Exception ex) { if (!_closed && generation == _generation) Failed?.Invoke(ex.Message); }
            };
            web.Source = new Uri("https://terminal.tokenstat.invalid/Terminal/terminal.html");
            started = true;
        }
        catch (Exception ex)
        {
            _ready.TrySetException(ex);
            if (!_closed) Failed?.Invoke(ex.Message);
        }
        finally
        {
            if (claimed && !started) _starting = false;
            _lifecycle.Release();
        }
    }

    public void Write(byte[] bytes) => Send(new { type = "output", data = Convert.ToBase64String(bytes) });
    public void Paste(string text) => Send(new { type = "paste", data = text });
    public void Reset() => Send(new { type = "reset" });
    public void SetGeometry(int rows, int cols) => Send(new { type = "geometry", rows = Math.Clamp(rows, 5, Rows), cols = Math.Clamp(cols, 20, Cols) });
    public void FocusTerminal()
    {
        if (_closed) return;
        try { _web.Focus(FocusState.Programmatic); }
        catch { /* The controller can already be gone on the way out. */ }
        Send(new { type = "focus" });
    }
    private void SendTheme()
    {
        var accent = Theme.Accent;
        var selected = Theme.RowSelected;
        Send(new { type = "theme", theme = new
        {
            background = $"#{TerminalPalette.BackgroundHex(Theme.IsDark):X6}",
            foreground = $"#{TerminalPalette.ForegroundHex(Theme.IsDark):X6}",
            cursor = $"#{accent.R:X2}{accent.G:X2}{accent.B:X2}",
            selectionBackground = $"#{selected.R:X2}{selected.G:X2}{selected.B:X2}{selected.A:X2}",
        } });
    }
    private void Send(object message)
    {
        if (_closed || !_ready.Task.IsCompletedSuccessfully) return;
        try { _web.CoreWebView2?.PostWebMessageAsJson(JsonSerializer.Serialize(message)); }
        catch (Exception ex) { Failed?.Invoke(ex.Message); }
    }
    public void Close()
    {
        if (_closed) return;
        _closed = true;
        _generation++;
        _ready.TrySetCanceled();
        try { _web.Close(); }
        catch { /* A controller already torn down must not take the process with it. */ }
        try { Children.Remove(_web); }
        catch { /* The visual tree may already have dropped this control. */ }
    }
}
