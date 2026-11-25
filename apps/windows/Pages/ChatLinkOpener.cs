// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Windows.System;

namespace Tokenstat.Pages;

internal static class ChatLinkOpener
{
    private const string Ask = "ask";
    private const string TokenstatBrowser = "tokenstat";
    private const string SystemBrowser = "browser";
    private static readonly string PreferencePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "chat-link-destination.txt");
    private static string? _destination;

    private static string Destination => _destination ??= Read();

    private static string Read()
    {
        try { return File.ReadAllText(PreferencePath).Trim() switch
            {
                TokenstatBrowser => TokenstatBrowser,
                SystemBrowser => SystemBrowser,
                _ => Ask,
            };
        }
        catch (IOException) { return Ask; }
        catch (UnauthorizedAccessException) { return Ask; }
    }

    private static void Remember(string destination)
    {
        _destination = destination;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(PreferencePath)!);
            File.WriteAllText(PreferencePath, destination);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    internal static async Task OpenAsync(UIElement owner, Uri url, Func<bool> current)
    {
        var destination = Destination;
        if (destination == Ask)
        {
            var remember = new CheckBox { Content = L10n.Text("common.pulls.open_remember") };
            var body = new StackPanel { Spacing = Theme.SpaceS };
            body.Children.Add(new TextBlock
            {
                Text = url.AbsoluteUri, IsTextSelectionEnabled = true,
                TextWrapping = TextWrapping.Wrap, MaxLines = 3,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            body.Children.Add(remember);
            var result = await Chrome.ShowDialog(owner, new ContentDialog
            {
                Title = L10n.Text("windows.chatlinks.open_title"),
                Content = body,
                PrimaryButtonText = L10n.Text("windows.chatlinks.open_in_tokenstat"),
                SecondaryButtonText = L10n.Text("common.pulls.open_browser"),
                CloseButtonText = L10n.Text("common.cancel"),
            });
            if (result == ContentDialogResult.None || !current()) return;
            destination = result == ContentDialogResult.Primary ? TokenstatBrowser : SystemBrowser;
            if (remember.IsChecked == true) Remember(destination);
        }
        if (!current()) return;
        if (destination == TokenstatBrowser)
        {
            if (WorkspaceTabsPage.Find(owner) is { } workspace)
                workspace.OpenBrowser(url.AbsoluteUri, "127.0.0.1", 0, false, null);
            else
                AppServices.OpenBrowser?.Invoke(url.AbsoluteUri, "127.0.0.1", 0, false, null);
        }
        else if (!await Launcher.LaunchUriAsync(url))
        {
            throw new InvalidOperationException(L10n.Text("windows.chatlinks.open_failed"));
        }
    }

    internal static UIElement SettingsCard() => Chrome.Card(L10n.Text("windows.chatlinks.settings_title"),
        SegmentedCapsule.View(
            [
                (Ask, L10n.Text("common.pulls.open_in_ask"), null),
                (TokenstatBrowser, "tokenstat", null),
                (SystemBrowser, L10n.Text("common.pulls.open_in_browser"), null),
            ],
            Destination, value => { Remember(value); return Task.CompletedTask; }),
        L10n.Text("windows.chatlinks.settings_help"));
}
