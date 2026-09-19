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
            var status = await AppServices.Host.CallAsync("ssh.vault.status");
            var problem = Format.Text(status, "unreachable");
            var created = Format.Flag(status, "created");
            var locked = Format.Flag(status, "locked");
            if (created && !locked && problem.Length == 0 && !Format.Flag(status, "needsRecreate"))
            {
                try { await SshVaultSync.SyncAsync(); }
                catch (Exception ex) { body.Children.Add(Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important)); }
            }
            body.Children.Add(new TextBlock
            {
                Text = problem.Length > 0 ? FriendlyError.Display(problem)
                    : Format.Flag(status, "needsRecreate") ? "This vault needs to be upgraded on another device."
                    : !created ? "Sync SSH hosts, folders, keys and snippets with your other devices."
                    : locked ? "Unlock your encrypted account vault on this PC."
                    : $"Encrypted account vault · {Format.Long(status, "recordCount")} records",
                TextWrapping = TextWrapping.Wrap,
            });
            if (problem.Length == 0 && !Format.Flag(status, "needsRecreate"))
            {
                if (!created || locked)
                    body.Children.Add(ActionIconGlyph.Button(created ? "Unlock vault" : "Create vault", ActionIcon.Security,
                        async (_, _) => { await UnlockAsync(owner, created); await reload(); }));
                else
                {
                    body.Children.Add(ActionIconGlyph.Button("Sync vault", ActionIcon.Refresh, async (_, _) =>
                    {
                        try { await SshVaultSync.SyncAsync(); await reload(); }
                        catch (Exception ex) { body.Children.Add(Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important)); }
                    }));
                    body.Children.Add(ActionIconGlyph.Button("Lock vault", ActionIcon.Security, async (_, _) =>
                    {
                        try { await AppServices.Host.CallAsync("ssh.vault.lock"); await reload(); }
                        catch (Exception ex) { body.Children.Add(Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important)); }
                    }));
                }
            }
        }
        catch (Exception ex) { body.Children.Add(Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important)); }
        return Chrome.Card("SSH vault", body);
    }

    private static async Task UnlockAsync(UIElement owner, bool created)
    {
        var password = new PasswordBox { PlaceholderText = "Vault password" };
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var body = new StackPanel { Spacing = Theme.SpaceM, Children = { password, error } };
        var dialog = new ContentDialog { Title = created ? "Unlock SSH vault" : "Create SSH vault", Content = body,
            PrimaryButtonText = created ? "Unlock" : "Create", CloseButtonText = "Cancel" };
        JsonNode? result = null;
        dialog.Closing += (_, args) => args.Cancel = !dialog.IsPrimaryButtonEnabled && result is null;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            dialog.IsPrimaryButtonEnabled = false;
            error.Text = "Opening vault…";
            try
            {
                result = await AppServices.Host.CallAsync(created ? "ssh.vault.unlock" : "ssh.vault.create",
                    new JsonObject { ["password"] = password.Password, ["migrate"] = true });
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
                Title = "Save your recovery code", CloseButtonText = "Done",
                Content = new TextBlock { Text = "Keep this code somewhere safe. It can reset your vault password.\n\n" + recovery,
                    IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap },
            });
        try { await SshVaultSync.SyncAsync(); }
        catch (Exception ex)
        {
            await Chrome.ShowDialog(owner, new ContentDialog { Title = "Vault sync", Content = FriendlyError.Display(ex.Message), CloseButtonText = "Close" });
        }
    }
}
