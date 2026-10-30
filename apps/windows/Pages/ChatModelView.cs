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

    public ChatModelView(string path, string name)
    {
        _path = path;
        _extension = Path.GetExtension(name).TrimStart('.').ToLowerInvariant();
        Height = 260;
        Background = Theme.PanelBrush;
        Children.Add(_web);
        Loaded += async (_, _) => await OpenAsync();
        Unloaded += (_, _) => Dispose();
    }

    public static bool CanPreview(string name) => Path.GetExtension(name).ToLowerInvariant() is
        ".glb" or ".gltf" or ".fbx" or ".obj" or ".stl" or ".ply";

    private static Task<CoreWebView2Environment> EnvironmentAsync() => _environment ??=
        CoreWebView2Environment.CreateWithOptionsAsync(null,
            Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData),
                "tokenstat", "ModelWebView"), new CoreWebView2EnvironmentOptions());

    private async Task OpenAsync()
    {
        try
        {
            if (_disposed || !File.Exists(_path) || new FileInfo(_path).Length > 12 * 1024 * 1024) return;
            await _web.EnsureCoreWebView2Async(await EnvironmentAsync());
            if (_disposed || _web.CoreWebView2 is not { } core) return;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreHostObjectsAllowed = false;
            core.Settings.IsWebMessageEnabled = false;
            core.PermissionRequested += (_, args) => args.State = CoreWebView2PermissionState.Deny;
            core.NewWindowRequested += (_, args) => args.Handled = true;
            core.NavigationStarting += (_, args) =>
            {
                if (!string.Equals(args.Uri, "https://models.tokenstat.invalid/model.html", StringComparison.Ordinal)) args.Cancel = true;
            };
            core.SetVirtualHostNameToFolderMapping("models.tokenstat.invalid",
                Path.Combine(AppContext.BaseDirectory, "Assets", "Charts"), CoreWebView2HostResourceAccessKind.Deny);
            var ready = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            core.NavigationCompleted += (_, _) => ready.TrySetResult(true);
            core.Navigate("https://models.tokenstat.invalid/model.html");
            await ready.Task;
            if (_disposed || !File.Exists(_path) || new FileInfo(_path).Length > 12 * 1024 * 1024) return;
            var encoded = Convert.ToBase64String(await File.ReadAllBytesAsync(_path));
            if (_disposed) return;
            await core.ExecuteScriptAsync($"TokenstatModel.load('{encoded}','{_extension}','#08070d')");
        }
        catch (Exception error)
        {
            if (_disposed) return;
            Children.Clear();
            Children.Add(new TextBlock { Text = error.Message, TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(16), Opacity = 0.7 });
        }
    }

    private void Dispose()
    {
        _disposed = true;
        try { _web.CoreWebView2?.Stop(); } catch { }
    }
}
