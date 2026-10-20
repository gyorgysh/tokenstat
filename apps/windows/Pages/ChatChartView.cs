// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Tokenstat.Design;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;

namespace Tokenstat.Pages;

/// <summary>An offline chart has an isolated browser profile and a narrow export bridge.</summary>
internal sealed class ChatChartView : Grid
{
    private const string PageUri = "https://charts.tokenstat.invalid/index.html";
    private static Task<CoreWebView2Environment>? _environment;
    private readonly string _source;
    private readonly bool _pending;
    private WebView2? _web;
    private int _epoch;
    private bool _loaded;
    private bool _exporting;

    public ChatChartView(string source, bool pending = false)
    {
        _source = source;
        _pending = pending;
        MinHeight = 60;
        HorizontalAlignment = HorizontalAlignment.Stretch;
        Loaded += async (_, _) => await StartAsync();
        Unloaded += (_, _) => Close();
        ActualThemeChanged += async (_, _) => { if (_loaded) await RenderAsync(_epoch); };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(this, "chat.chart");
    }

    private static Task<CoreWebView2Environment> EnvironmentAsync()
    {
        if (_environment is null || _environment.IsCanceled || _environment.IsFaulted)
            _environment = CreateEnvironmentAsync();
        return _environment;
    }

    private static async Task<CoreWebView2Environment> CreateEnvironmentAsync() =>
        await CoreWebView2Environment.CreateWithOptionsAsync(null,
            Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData), "tokenstat", "ChartWebView"),
            new CoreWebView2EnvironmentOptions());

    private void ShowError(string message)
    {
        Close();
        Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Margin = new Thickness(12) });
        Height = double.NaN;
    }

    private async Task StartAsync()
    {
        if (_web is not null) return;
        if (_pending) { ShowError(L10n.Text("common.chart.loading")); return; }
        if (Encoding.UTF8.GetByteCount(_source) > 256 * 1024) { ShowError(L10n.Text("common.chart.too_large")); return; }
        var epoch = ++_epoch;
        var web = new WebView2 { HorizontalAlignment = HorizontalAlignment.Stretch, DefaultBackgroundColor = Microsoft.UI.Colors.Transparent };
        _web = web;
        Children.Clear(); Children.Add(web); Height = 430;
        try
        {
            var environment = await EnvironmentAsync();
            if (epoch != _epoch) return;
            await web.EnsureCoreWebView2Async(environment);
            if (epoch != _epoch) { web.Close(); return; }
            var core = web.CoreWebView2;
            core.SetVirtualHostNameToFolderMapping("charts.tokenstat.invalid", Path.Combine(AppContext.BaseDirectory, "Assets", "Charts"), CoreWebView2HostResourceAccessKind.Deny);
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.AreBrowserAcceleratorKeysEnabled = false;
            ulong pageNavigation = 0;
            core.NavigationStarting += (_, e) =>
            {
                e.Cancel = e.Uri != PageUri;
                if (!e.Cancel) pageNavigation = e.NavigationId;
            };
            core.NewWindowRequested += (_, e) => e.Handled = true;
            core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
            core.DownloadStarting += (_, e) => e.Cancel = true;
            core.NavigationCompleted += async (_, e) =>
            {
                if (epoch != _epoch || e.NavigationId != pageNavigation) return;
                if (!e.IsSuccess) { ShowError(L10n.Text("common.chart.resources_missing")); return; }
                _loaded = true;
                await RenderAsync(epoch);
            };
            core.ProcessFailed += (_, _) => { if (epoch == _epoch) ShowError(L10n.Text("common.chart.unavailable")); };
            core.WebMessageReceived += async (_, e) =>
            {
                if (epoch != _epoch || e.Source != PageUri || e.WebMessageAsJson.Length > 12 * 1024 * 1024) return;
                try
                {
                    using var document = JsonDocument.Parse(e.WebMessageAsJson);
                    var message = document.RootElement;
                    var type = message.GetProperty("type").GetString();
                    if (type == "height" && message.GetProperty("height").TryGetDouble(out var height)
                        && double.IsFinite(height) && height is >= 180 and <= 2200) Height = height;
                    else if (type == "copy")
                    {
                        var text = message.GetProperty("text").GetString();
                        if (text is not null && Encoding.UTF8.GetByteCount(text) <= 64 * 1024)
                        { var package = new DataPackage(); package.SetText(text); Clipboard.SetContent(package); }
                    }
                    else if (type == "export") await ExportAsync(message);
                }
                catch (Exception error) when (error is JsonException or InvalidOperationException or FormatException or IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException or KeyNotFoundException or ArgumentException)
                { if (epoch == _epoch) ShowError(L10n.Text("common.chart.unavailable") + ": " + error.Message); }
            };
            core.Navigate(PageUri);
        }
        catch (Exception error)
        { if (epoch == _epoch) { Close(); ShowError(L10n.Text("common.chart.unavailable") + ": " + error.Message); } }
    }

    private async Task RenderAsync(int epoch)
    {
        if (epoch != _epoch || !_loaded || _web?.CoreWebView2 is not { } core) return;
        var settings = JsonSerializer.Serialize(new { dark = ActualTheme == ElementTheme.Dark,
            locale = CultureInfo.CurrentCulture.Name, reducedMotion = !new Windows.UI.ViewManagement.UISettings().AnimationsEnabled,
            strings = ChartWords.All });
        var encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(_source));
        try { await core.ExecuteScriptAsync($"window.TokenstatChart.render(new TextDecoder().decode(Uint8Array.from(atob('{encoded}'), c => c.charCodeAt(0))), {settings});"); }
        catch (Exception error) { if (epoch == _epoch) ShowError(error.Message); }
    }

    private async Task ExportAsync(JsonElement message)
    {
        if (_exporting) return;
        var format = message.GetProperty("format").GetString();
        if (format is not ("png" or "svg" or "csv" or "json")) return;
        var content = message.GetProperty("content").GetString();
        if (content is null || content.Length > 12 * 1024 * 1024) return;
        var base64 = message.TryGetProperty("base64", out var encoded) && encoded.ValueKind == JsonValueKind.True;
        if (base64 != (format == "png")) return;
        var data = base64
            ? Convert.FromBase64String(content) : Encoding.UTF8.GetBytes(content);
        if (data.Length > 8 * 1024 * 1024) return;
        _exporting = true;
        try
        {
            var picker = new FileSavePicker { SuggestedFileName = "chart." + format };
            picker.FileTypeChoices.Add(format.ToUpperInvariant(), new List<string> { "." + format });
            if (App.CurrentWindow is not { } window) return;
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
            var destination = await picker.PickSaveFileAsync();
            if (destination is not null) await Windows.Storage.FileIO.WriteBytesAsync(destination, data);
        }
        finally { _exporting = false; }
    }

    private void Close()
    {
        ++_epoch; _loaded = false;
        var web = _web; _web = null;
        if (web is not null) { try { web.Close(); } catch { /* A failed browser may already have closed. */ } }
        Children.Clear();
    }
}
