// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>The account vault uses the same envelopes as Mac and Android.</summary>
internal static class SshVault
{
    public static async Task<UIElement> CardAsync(UIElement owner, Func<Task> reload)
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        try
        {
            var account = await AppServices.Host.CallAsync("account.status");
            if (!Format.Flag(account, "signedIn"))
                await AppServices.Host.CallAsync("ssh.vault.status");
            var scope = SshVaultScope.From(account)
                ?? throw new InvalidOperationException("the signed-in account changed; retry from the current account");
            var status = await SshVaultScope.CallAsync("ssh.vault.status", null, scope);
            var problem = Format.Text(status, "unreachable");
            var created = Format.Flag(status, "created");
            var locked = Format.Flag(status, "locked");
            if (created && !locked && problem.Length == 0 && !Format.Flag(status, "needsRecreate"))
            {
                try { await SshVaultSync.SyncAsync(scope); }
                catch (Exception ex) { body.Children.Add(Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important)); }
            }
            body.Children.Add(new TextBlock
            {
                Text = problem.Length > 0 ? FriendlyError.Display(problem)
                    : Format.Flag(status, "needsRecreate") ? L10n.Text("windows.sshvault.this_vault_needs_to_be_upgraded_on_another.5deceb54")
                    : !created ? L10n.Text("windows.sshvault.sync_ssh_hosts_folders_keys_and_snippets_w.0ff9d4c7")
                    : locked ? L10n.Text("windows.sshvault.unlock_your_encrypted_account_vault_on_thi.98b2d1e3")
                    : L10n.Text("windows.sshvault.encrypted_account_vault_0_records.91a6c040", $"{Format.Long(status, "recordCount")}"),
                TextWrapping = TextWrapping.Wrap,
            });
            if (problem.Length == 0 && !Format.Flag(status, "needsRecreate"))
            {
                if (!created || locked)
                    body.Children.Add(ActionIconGlyph.Button(created ? L10n.Text("windows.sshvault.unlock_vault.75018776") : L10n.Text("windows.sshvault.create_vault.c8c44253"), ActionIcon.Security,
                        async (_, _) => { await UnlockAsync(owner, created, scope); await reload(); }));
                else
                {
                    body.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.sshvault.sync_vault.67cde0cd"), ActionIcon.Refresh, async (_, _) =>
                    {
                        try { await SshVaultSync.SyncAsync(scope); await reload(); }
                        catch (Exception ex) { body.Children.Add(Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important)); }
                    }));
                    body.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.sshvault.lock_vault.441f34d1"), ActionIcon.Security, async (_, _) =>
                    {
                        try { await SshVaultScope.CallAsync("ssh.vault.lock", null, scope); await reload(); }
                        catch (Exception ex) { body.Children.Add(Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important)); }
                    }));
                }
            }
        }
        catch (Exception ex) { body.Children.Add(Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important)); }
        return Chrome.Card(L10n.Text("windows.sshvault.ssh_vault.1e6e22e7"), body);
    }

    private static async Task UnlockAsync(UIElement owner, bool created, JsonObject scope)
    {
        var password = new PasswordBox { PlaceholderText = L10n.Text("windows.sshvault.vault_password.1853752f") };
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var body = new StackPanel { Spacing = Theme.SpaceM, Children = { password, error } };
        var dialog = new ContentDialog { Title = created ? L10n.Text("windows.sshvault.unlock_ssh_vault.6a4d33fa") : L10n.Text("windows.sshvault.create_ssh_vault.bd59e9da"), Content = body,
            PrimaryButtonText = created ? L10n.Text("windows.sshvault.unlock.4ac709aa") : L10n.Text("windows.sshvault.create.4759498a"), CloseButtonText = L10n.Text("common.cancel") };
        JsonNode? result = null;
        dialog.Closing += (_, args) => args.Cancel = !dialog.IsPrimaryButtonEnabled && result is null;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            dialog.IsPrimaryButtonEnabled = false;
            error.Text = L10n.Text("windows.sshvault.opening_vault.ea4c6380");
            try
            {
                result = await SshVaultScope.CallAsync(created ? "ssh.vault.unlock" : "ssh.vault.create",
                    new JsonObject { ["password"] = password.Password, ["migrate"] = true }, scope);
                password.Password = "";
                dialog.Hide();
            }
            catch (Exception ex) { error.Text = FriendlyError.Display(ex.Message); }
            finally { dialog.IsPrimaryButtonEnabled = true; }
        };
        await Chrome.ShowDialog(owner, dialog);
        password.Password = "";
        if (result is null) return;
        var recovery = Format.Text(result, "recovery");
        if (recovery.Length > 0)
            await Chrome.ShowDialog(owner, new ContentDialog
            {
                Title = L10n.Text("windows.sshvault.save_your_recovery_code.1060e6a8"), CloseButtonText = L10n.Text("common.done"),
                Content = new TextBlock { Text = L10n.Text("windows.sshvault.keep_this_code_somewhere_safe_it_can_reset.f28683b9", $"{recovery}"),
                    IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap },
            });
        try { await SshVaultSync.SyncAsync(scope); }
        catch (Exception ex)
        {
            await Chrome.ShowDialog(owner, new ContentDialog { Title = L10n.Text("windows.sshvault.vault_sync.65415a6c"), Content = FriendlyError.Display(ex.Message), CloseButtonText = L10n.Text("common.close") });
        }
    }
}
