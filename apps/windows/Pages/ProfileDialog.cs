// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal static class ProfileDialog
{
    public static async Task ShowAsync(UIElement owner, JsonNode account, Func<Task> reload, bool offer = false)
    {
        var accountGeneration = AppServices.AccountGeneration;
        bool Current() => accountGeneration == AppServices.AccountGeneration;
        var host = Format.Text(account, "host");
        var handle = Format.Text(account, "handle");
        var profile = account["profile"] as JsonObject;
        var isPublic = profile is null ? Format.Flag(account, "profilePublic") : Format.Flag(profile, "public");
        var indexable = profile?["indexable"] is not JsonValue listed || !listed.TryGetValue<bool>(out var on) || on;

        var body = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 340 };
        if (offer)
            body.Children.Add(new TextBlock { Text = L10n.Text("common.handle.claim_note"), TextWrapping = TextWrapping.Wrap });
        var error = new TextBlock { Foreground = Theme.Brush(static () => Theme.Danger), TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        void Fail(Exception ex) { error.Text = ex.Message; error.Visibility = Visibility.Visible; }

        string Address(string name) => host.Split("://").Last().TrimEnd('/') + "/" + name;

        var field = new TextBox
        {
            Header = L10n.Text("common.handle.field_label"),
            PlaceholderText = L10n.Text("common.handle.placeholder"),
            Text = handle,
        };
        var status = new TextBlock { Opacity = 0.75, FontSize = 12, TextWrapping = TextWrapping.Wrap };
        status.Text = handle.Length > 0 ? L10n.Text("common.handle.current") : L10n.Text("common.handle.hint", "4");
        var claim = Buttons.Primary(L10n.Text("common.handle.claim"), ActionIcon.Claim, (_, _) => { });
        claim.IsEnabled = false;
        var checkVersion = 0;
        field.TextChanged += async (_, _) =>
        {
            var typed = field.Text.Trim().ToLowerInvariant();
            var version = ++checkVersion;
            claim.IsEnabled = false;
            if (typed.Length == 0 || typed == handle)
            {
                status.Text = typed == handle && handle.Length > 0 ? L10n.Text("common.handle.current") : L10n.Text("common.handle.hint", "4");
                return;
            }
            status.Text = L10n.Text("common.handle.checking");
            await Task.Delay(350);
            if (version != checkVersion || !Current()) return;
            try
            {
                var answer = await AppServices.Host.CallAsync("account.checkHandle", new JsonObject { ["handle"] = typed });
                if (version != checkVersion || !Current()) return;
                var available = Format.Flag(answer, "available");
                var message = Format.Text(answer, "message");
                status.Text = available ? L10n.Text("common.handle.available")
                    : message.Length > 0 ? message : L10n.Text("common.handle.reason.unavailable");
                claim.IsEnabled = available;
            }
            catch
            {
                if (version == checkVersion) status.Text = L10n.Text("common.handle.check_failed");
            }
        };
        var handleRow = new Grid { ColumnSpacing = Theme.SpaceS };
        handleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        handleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        claim.VerticalAlignment = VerticalAlignment.Bottom;
        Grid.SetColumn(claim, 1);
        handleRow.Children.Add(field);
        handleRow.Children.Add(claim);
        body.Children.Add(handleRow);
        body.Children.Add(status);
        var address = new TextBlock
        {
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas"),
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.Wrap,
        };
        body.Children.Add(address);

        body.Children.Add(new TextBlock { Text = L10n.Text("common.profile.who_can_open"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        var privateChoice = new RadioButton { GroupName = "profile-visibility", IsChecked = !isPublic, Content = Choice(L10n.Text("common.profile.private"), L10n.Text("common.profile.private_detail")) };
        var publicChoice = new RadioButton { GroupName = "profile-visibility", IsChecked = isPublic, IsEnabled = handle.Length > 0, Content = Choice(L10n.Text("common.profile.public"), L10n.Text("common.profile.public_detail")) };
        var makePublic = Buttons.Secondary(L10n.Text("common.profile.make_public"), ActionIcon.Browser, (_, _) => { });
        makePublic.Visibility = Visibility.Collapsed;
        body.Children.Add(privateChoice);
        body.Children.Add(publicChoice);
        body.Children.Add(makePublic);

        bool saving = false;
        var listing = new CheckBox { Content = L10n.Text("common.profile.indexable"), IsChecked = indexable, IsEnabled = isPublic };
        var listingNote = new TextBlock { FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(28, -6, 0, 0) };
        void Note() => listingNote.Text = listing.IsChecked == true
            ? L10n.Text("common.profile.indexable_on_detail")
            : L10n.Text("common.profile.indexable_off_detail");
        Note();
        listing.Click += async (_, _) => { Note(); await SetAsync(null, listing.IsChecked == true); };
        body.Children.Add(listing);
        body.Children.Add(listingNote);

        makePublic.Click += async (_, _) => await SetAsync(true, null);
        privateChoice.Checked += async (_, _) => { makePublic.Visibility = Visibility.Collapsed; if (isPublic) await SetAsync(false, null); };
        publicChoice.Checked += (_, _) => { if (!isPublic) makePublic.Visibility = Visibility.Visible; };

        async Task SetAsync(bool? makeVisible, bool? list)
        {
            if (!Current() || saving) return;
            saving = true;
            error.Visibility = Visibility.Collapsed;
            try
            {
                var change = new JsonObject();
                if (makeVisible is bool visible) change["public"] = visible;
                if (list is bool shown) change["indexable"] = shown;
                await AppServices.Host.CallAsync("account.setVisibility", change);
                if (!Current()) return;
                if (list is bool updated) indexable = updated;
                if (makeVisible is bool now)
                {
                    isPublic = now;
                    makePublic.Visibility = Visibility.Collapsed;
                    listing.IsEnabled = now;
                }
                await reload();
            }
            catch (Exception ex)
            {
                Fail(ex);
                privateChoice.IsChecked = !isPublic;
                publicChoice.IsChecked = isPublic;
                listing.IsChecked = indexable;
                Note();
            }
            finally { saving = false; }
        }

        body.Children.Add(error);
        var dialog = new ContentDialog
        {
            XamlRoot = owner.XamlRoot,
            Title = L10n.Text(offer ? "common.handle.claim_title" : "common.profile.title"),
            Content = new ScrollViewer { Content = body, MaxHeight = 560 },
            CloseButtonText = L10n.Text("common.done"),
            DefaultButton = ContentDialogButton.Close,
        };
        void RefreshHandle()
        {
            publicChoice.IsEnabled = handle.Length > 0;
            address.Visibility = handle.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            address.Text = Address(handle);
            dialog.PrimaryButtonText = handle.Length > 0 && host.Length > 0 ? L10n.Text("common.profile.view") : "";
        }
        RefreshHandle();
        claim.Click += async (_, _) =>
        {
            if (!Current() || saving) return;
            saving = true;
            claim.IsEnabled = false;
            field.IsEnabled = false;
            error.Visibility = Visibility.Collapsed;
            var candidate = field.Text.Trim().ToLowerInvariant();
            ++checkVersion;
            try
            {
                await AppServices.Host.CallAsync("account.claimHandle", new JsonObject { ["handle"] = candidate });
                if (!Current()) return;
                handle = candidate;
                status.Text = L10n.Text("common.handle.current");
                RefreshHandle();
                await reload();
            }
            catch (Exception ex) { Fail(ex); claim.IsEnabled = true; }
            finally { saving = false; field.IsEnabled = true; }
        };
        var result = await Chrome.ShowDialog(owner, dialog);
        ++checkVersion;
        if (!Current()) return;
        if (result == ContentDialogResult.Primary
            && Uri.TryCreate(host.TrimEnd('/') + "/" + Uri.EscapeDataString(handle), UriKind.Absolute, out var page)
            && page.Scheme is "https" or "http")
        {
            _ = Windows.System.Launcher.LaunchUriAsync(page);
        }
        if (offer && handle.Length == 0 && !saving)
        {
            try
            {
                await AppServices.Host.CallAsync("account.skipHandle", new JsonObject());
                if (Current()) await reload();
            }
            catch { }
        }
    }

    private static StackPanel Choice(string title, string detail)
    {
        var panel = new StackPanel { Spacing = 2 };
        panel.Children.Add(new TextBlock { Text = title });
        panel.Children.Add(new TextBlock { Text = detail, FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
        return panel;
    }
}
