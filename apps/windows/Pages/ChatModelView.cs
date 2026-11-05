// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.IO;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>An offline, profile-isolated viewer for portable game model files.</summary>
internal sealed class ChatModelView : Grid
{
    private static Task<CoreWebView2Environment>? _environment;
    private readonly WebView2 _web = new()
    {
        Height = 260,
        HorizontalAlignment = HorizontalAlignment.Stretch,
        DefaultBackgroundColor = Microsoft.UI.Colors.Transparent,
    };
    private readonly string _path;
    private readonly string _extension;
    private bool _disposed;
    private bool _configured;
    private long _epoch;
    private ulong _navigation;
    private long _navigationEpoch;
    private const int InlineByteLimit = 12 * 1024 * 1024;

    public ChatModelView(string path, string name)
    {
        _path = path;
        _extension = Path.GetExtension(name).TrimStart('.').ToLowerInvariant();
        Height = 260;
        Background = Theme.PanelBrush;
        Children.Add(_web);
        Loaded += async (_, _) => { _disposed = false; await OpenAsync(++_epoch); };
        Unloaded += (_, _) => Dispose();
        ActualThemeChanged += async (_, _) => { if (IsLoaded) await OpenAsync(++_epoch); };
    }

    public static bool CanPreview(string name) => Path.GetExtension(name).ToLowerInvariant() is
        ".glb" or ".gltf" or ".fbx" or ".obj" or ".stl" or ".ply";

    private static Task<CoreWebView2Environment> EnvironmentAsync()
    {
        if (_environment is null || _environment.IsCanceled || _environment.IsFaulted)
            _environment = CreateEnvironmentAsync();
        return _environment;
    }

    private static async Task<CoreWebView2Environment> CreateEnvironmentAsync() =>
        await CoreWebView2Environment.CreateWithOptionsAsync(null,
            Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData),
                "tokenstat", "ModelWebView"), new CoreWebView2EnvironmentOptions());

    private async Task OpenAsync(long epoch)
    {
        if (!Current(epoch)) return;
        _navigation = 0;
        try
        {
            CheckFile();
            if (Children.Count != 1 || !ReferenceEquals(Children[0], _web)) { Children.Clear(); Children.Add(_web); }
            var environment = await EnvironmentAsync();
            if (!Current(epoch)) return;
            await _web.EnsureCoreWebView2Async(environment);
            if (!Current(epoch) || _web.CoreWebView2 is not { } core) return;
            if (!_configured)
            {
                _configured = true;
                core.Settings.AreDevToolsEnabled = false;
                core.Settings.AreHostObjectsAllowed = false;
                core.Settings.IsWebMessageEnabled = false;
                core.Settings.AreDefaultContextMenusEnabled = false;
                core.PermissionRequested += (_, args) => args.State = CoreWebView2PermissionState.Deny;
                core.NewWindowRequested += (_, args) => args.Handled = true;
                core.DownloadStarting += (_, args) => args.Cancel = true;
                core.NavigationStarting += (_, args) =>
                {
                    if (!string.Equals(args.Uri, PageUri, StringComparison.Ordinal)) args.Cancel = true;
                    else _navigation = args.NavigationId;
                };
                core.SetVirtualHostNameToFolderMapping("models.tokenstat.invalid",
                    Path.Combine(AppContext.BaseDirectory, "Assets", "Charts"), CoreWebView2HostResourceAccessKind.Deny);
                core.NavigationCompleted += async (_, args) =>
                {
                    var loadEpoch = _navigationEpoch;
                    if (!Current(loadEpoch) || args.NavigationId != _navigation) return;
                    if (!args.IsSuccess) { ShowUnavailable(); return; }
                    await LoadModelAsync(core, loadEpoch);
                };
                core.ProcessFailed += (_, _) => { if (!_disposed) ShowUnavailable(); };
            }
            _navigationEpoch = epoch;
            core.Navigate(PageUri);
        }
        catch (Exception error) { if (Current(epoch)) ShowError(error); }
    }

    private async Task LoadModelAsync(CoreWebView2 core, long epoch)
    {
        try
        {
            if (!Current(epoch)) return;
            CheckFile();
            var path = _path;
            var encoded = await Task.Run(async () =>
            {
                using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
                    64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
                var length = file.Length;
                if (length is <= 0 or > InlineByteLimit) return null;
                var bytes = new byte[(int)length];
                await file.ReadExactlyAsync(bytes).ConfigureAwait(false);
                // Reject growth after opening, without allocating the extra bytes.
                if (file.ReadByte() != -1) return null;
                return Convert.ToBase64String(bytes);
            });
            if (!Current(epoch)) return;
            if (encoded is null) { ShowUnavailable(); return; }
            await core.ExecuteScriptAsync($"TokenstatModel.load('{encoded}','{_extension}','{(Theme.IsDark ? "#08070d" : "#fbfbfd")}')");
        }
        catch (Exception error) { if (Current(epoch)) ShowError(error); }
    }

    private bool Current(long epoch) => !_disposed && epoch == _epoch;

    private void CheckFile()
    {
        var file = new FileInfo(_path);
        if (!file.Exists || file.Length is <= 0 or > InlineByteLimit)
            throw new IOException(L10n.Text("common.chat.model.unavailable"));
    }

    private void ShowUnavailable() => ShowError(new IOException(L10n.Text("common.chat.model.unavailable")));

    private void ShowError(Exception error)
    {
        if (_disposed) return;
        _epoch++;
        _navigation = 0;
        Children.Clear();
        Children.Add(new TextBlock { Text = error.Message, TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(16), Opacity = 0.7 });
    }

    private void Dispose()
    {
        _disposed = true;
        _epoch++;
        try { _web.CoreWebView2?.Stop(); } catch { }
    }

    private const string PageUri = "https://models.tokenstat.invalid/model.html";
}
