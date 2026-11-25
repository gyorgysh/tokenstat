// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal sealed partial class SshPage
{
    private bool _cloudImporting;

    private void AddCloudImport()
    {
        var actions = new FlowPanel { Spacing = Theme.SpaceS };
        actions.Children.Add(ActionIconGlyph.Button("DigitalOcean", ActionIcon.Download, async (_, _) => await ImportCloudAsync(true)));
        actions.Children.Add(ActionIconGlyph.Button("AWS EC2", ActionIcon.Download, async (_, _) => await ImportCloudAsync(false)));
        _listRoot.Children.Add(Chrome.Card(L10n.Text("windows.sshcloud.import"), actions));
    }

    private async Task ImportCloudAsync(bool digitalOcean)
    {
        if (_cloudImporting) return;
        _cloudImporting = true;
        var account = AppServices.AccountGeneration;
        bool Current() => IsLoaded && account == AppServices.AccountGeneration;
        var token = new PasswordBox { Header = L10n.Text("windows.sshcloud.token") };
        var username = new TextBox { Header = L10n.Text("windows.sshcloud.username"), Text = digitalOcean ? "root" : "ec2-user" };
        var profile = new TextBox { Header = L10n.Text("windows.sshcloud.profile") };
        var region = new TextBox { Header = L10n.Text("windows.sshcloud.region") };
        var form = new StackPanel { Spacing = Theme.SpaceS };
        form.Children.Add(new TextBlock { Text = digitalOcean ? L10n.Text("windows.sshcloud.digital_ocean_help")
            : L10n.Text("windows.sshcloud.aws_help"), TextWrapping = TextWrapping.Wrap });
        if (digitalOcean) form.Children.Add(token);
        else
        {
            form.Children.Add(profile);
            form.Children.Add(region);
        }
        form.Children.Add(username);
        var dialog = new ContentDialog
        {
            Title = digitalOcean ? L10n.Text("windows.sshcloud.digital_ocean_title") : L10n.Text("windows.sshcloud.aws_title"),
            Content = form,
            PrimaryButtonText = L10n.Text("windows.sshcloud.import_action"),
            CloseButtonText = L10n.Text("common.cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        void Update() => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(username.Text)
            && (!digitalOcean || !string.IsNullOrWhiteSpace(token.Password));
        username.TextChanged += (_, _) => Update();
        token.PasswordChanged += (_, _) => Update();
        Update();
        var progress = new ProgressBar { IsIndeterminate = true, Margin = new Thickness(0, 0, 0, Theme.SpaceS) };
        JsonObject? parameters = null;
        try
        {
            if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary || !Current()) return;
            parameters = new JsonObject { ["username"] = username.Text.Trim() };
            if (digitalOcean) parameters["token"] = token.Password.Trim();
            else
            {
                if (!string.IsNullOrWhiteSpace(profile.Text)) parameters["profile"] = profile.Text.Trim();
                if (!string.IsNullOrWhiteSpace(region.Text)) parameters["region"] = region.Text.Trim();
            }
            token.Password = "";
            _listRoot.Children.Insert(Math.Min(1, _listRoot.Children.Count), progress);
            var saved = await SshVaultSync.WriteAsync(digitalOcean ? "ssh.provider.digitalOcean.import"
                : "ssh.provider.aws.import", parameters, account);
            if (!Current()) return;
            await LoadAsync();
            if (!Current()) return;
            _listRoot.Children.Insert(Math.Min(1, _listRoot.Children.Count), Chrome.Banner(
                L10n.Text("windows.sshcloud.imported", Format.Long(saved, "imported")), Theme.Success, Symbol.Accept));
        }
        catch (Exception ex)
        {
            if (!Current()) return;
            await LoadAsync();
            if (Current()) LibraryBanner(ex.Message);
        }
        finally
        {
            token.Password = "";
            parameters?.Remove("token");
            _listRoot.Children.Remove(progress);
            _cloudImporting = false;
        }
    }
}
