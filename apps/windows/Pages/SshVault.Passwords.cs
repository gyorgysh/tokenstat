// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal static partial class SshVault
{
    private enum VaultPasswordAction { Change, Reset, ReplaceCode }

    private static void AddPasswordManagement(StackPanel body, UIElement owner, JsonObject scope, bool locked, Func<Task> reload)
    {
        var account = AppServices.AccountGeneration;
        async Task Edit(VaultPasswordAction action)
        {
            bool Current() => owner.XamlRoot is not null && AppServices.AccountGeneration == account;
            if (!Current()) return;
            if (await ChangeVaultPasswordAsync(owner, scope, action, Current) && Current()) await reload();
        }
        var actions = new FlowPanel { Spacing = Theme.SpaceS };
        if (!locked)
        {
            actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.sshvault.password_change"), ActionIcon.Security,
                async (_, _) => await Edit(VaultPasswordAction.Change)));
            actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.sshvault.recovery_replace"), ActionIcon.Refresh,
                async (_, _) => await Edit(VaultPasswordAction.ReplaceCode)));
        }
        actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.sshvault.password_reset"), ActionIcon.Restore,
            async (_, _) => await Edit(VaultPasswordAction.Reset)));
        body.Children.Add(actions);
    }

    private static async Task<bool> ChangeVaultPasswordAsync(UIElement owner, JsonObject scope, VaultPasswordAction action, Func<bool> current)
    {
        var reset = action == VaultPasswordAction.Reset;
        var rotate = action == VaultPasswordAction.ReplaceCode;
        var title = action switch
        {
            VaultPasswordAction.Change => L10n.Text("windows.sshvault.password_change"),
            VaultPasswordAction.Reset => L10n.Text("windows.sshvault.password_reset"),
            _ => L10n.Text("windows.sshvault.recovery_replace"),
        };
        var proof = new PasswordBox { Header = reset ? L10n.Text("windows.sshvault.recovery_code") : L10n.Text("windows.sshvault.current_password") };
        var password = new PasswordBox { Header = L10n.Text("windows.sshvault.new_password") };
        var confirm = new PasswordBox { Header = L10n.Text("windows.sshvault.confirm_password") };
        var acknowledge = new CheckBox { Content = L10n.Text("windows.sshvault.acknowledge_retire") };
        var notice = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var body = new StackPanel { Spacing = Theme.SpaceS, Children =
        {
            new TextBlock { TextWrapping = TextWrapping.Wrap, Text = rotate
                ? L10n.Text("windows.sshvault.recovery_replace_detail") : L10n.Text("windows.sshvault.password_change_detail") }, proof,
        } };
        if (!rotate) { body.Children.Add(password); body.Children.Add(confirm); }
        body.Children.Add(acknowledge);
        body.Children.Add(notice);
        var dialog = new ContentDialog
        {
            Title = title, Content = body, PrimaryButtonText = title, CloseButtonText = L10n.Text("common.cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        var working = false;
        string? recovery = null;
        bool Ready() => !working && proof.Password.Length > 0 && acknowledge.IsChecked == true
            && (rotate || (password.Password.Length > 0 && password.Password == confirm.Password));
        void Update()
        {
            proof.IsEnabled = password.IsEnabled = confirm.IsEnabled = acknowledge.IsEnabled = !working;
            dialog.IsPrimaryButtonEnabled = Ready();
        }
        proof.PasswordChanged += (_, _) => Update();
        password.PasswordChanged += (_, _) => Update();
        confirm.PasswordChanged += (_, _) => Update();
        acknowledge.Checked += (_, _) => Update();
        acknowledge.Unchecked += (_, _) => Update();
        dialog.Closing += (_, args) => args.Cancel = working && current();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (!Ready() || !current()) return;
            working = true;
            Update();
            notice.Text = L10n.Text("common.loading");
            try
            {
                var parameters = new JsonObject();
                parameters[reset ? "recovery" : "password"] = proof.Password;
                if (!rotate) parameters["newPassword"] = password.Password;
                var answer = await SshVaultScope.CallAsync(rotate ? "ssh.vault.recovery.rotate" : "ssh.vault.password.set",
                    parameters, scope);
                if (!current()) return;
                recovery = Format.Text(answer, "recovery");
                if (recovery.Length == 0 || (!rotate && !Format.Flag(answer, "changed")))
                {
                    recovery = null;
                    throw new InvalidDataException(L10n.Text("windows.sshvault.change_unconfirmed"));
                }
            }
            catch (Exception error) { if (current()) notice.Text = FriendlyError.Display(error.Message); }
            finally
            {
                proof.Password = password.Password = confirm.Password = "";
                working = false;
                Update();
                if (recovery is not null || !current()) dialog.Hide();
            }
        };
        Update();
        await Chrome.ShowDialog(owner, dialog);
        proof.Password = password.Password = confirm.Password = "";
        if (recovery is null || !current()) return false;
        await ShowRecoveryCodeAsync(owner, recovery);
        return true;
    }
}
