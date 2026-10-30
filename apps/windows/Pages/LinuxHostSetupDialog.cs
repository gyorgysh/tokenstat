// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>
/// Desktop counterpart of the Apple SSH setup flow. Every SSH operation is a
/// local host RPC. The password/private key stays in this dialog, while the
/// fingerprint, server check and final identity come from the remote server.
/// </summary>
internal static class LinuxHostSetupDialog
{
    public static async Task<bool> ShowAsync(Page owner)
    {
        try { return await RunAsync(owner); }
        catch (Exception error)
        {
            await MessageAsync(owner, "Linux host setup", FriendlyError.Display(error.Message));
            return false;
        }
    }

    private static async Task<bool> RunAsync(Page owner)
    {
        var accountScope = await SshVaultScope.RequireAsync();
        var savedHost = new ComboBox { Header = "Saved SSH host", HorizontalAlignment = HorizontalAlignment.Stretch };
        savedHost.Items.Add("New server");
        foreach (var record in (Format.Items(await AppServices.Host.CallAsync("ssh.host.list")) ?? new JsonArray()).OfType<JsonNode>())
            savedHost.Items.Add(new ComboBoxItem { Content = Format.Text(record, "label", Format.Text(record, "hostname")), Tag = record });
        savedHost.SelectedIndex = 0;
        var address = new TextBox { Header = "Server address", PlaceholderText = "server.example.com" };
        var user = new TextBox { Header = "SSH user", Text = "root" };
        var port = new NumberBox { Header = "SSH port", Value = 22, Minimum = 1, Maximum = 65535,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Hidden };
        var name = new TextBox { Header = "Name on your account", Text = "server" };
        var savedKey = new ComboBox { Header = "Saved SSH key", HorizontalAlignment = HorizontalAlignment.Stretch,
            Visibility = Visibility.Collapsed };
        foreach (var key in (Format.Items(await AppServices.Host.CallAsync("ssh.key.list")) ?? new JsonArray()).OfType<JsonNode>())
        {
            var available = SshSecrets.Has(Format.Text(key, "secretRef"));
            savedKey.Items.Add(new ComboBoxItem { Content = Format.Text(key, "label", Format.Text(key, "id")) +
                (available ? "" : " · unavailable on this PC"), Tag = key, IsEnabled = available });
            if (available && savedKey.SelectedItem is null) savedKey.SelectedIndex = savedKey.Items.Count - 1;
        }
        var method = new ComboBox { Header = "Sign in with", Items = { "Password", "Saved key", "Paste private key" },
            SelectedIndex = savedKey.SelectedItem is null ? 0 : 1 };
        var password = new PasswordBox { Header = "SSH password" };
        var privateKey = new TextBox { Header = "Private key", AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap, Height = 96, Visibility = Visibility.Collapsed };
        var passphrase = new PasswordBox { Header = "Key passphrase (if needed)", Visibility = Visibility.Collapsed };
        var validation = new TextBlock { Foreground = Theme.Brush(static () => Theme.Danger), TextWrapping = TextWrapping.Wrap };
        savedHost.SelectionChanged += (_, _) =>
        {
            var record = (savedHost.SelectedItem as ComboBoxItem)?.Tag as JsonNode;
            address.Text = Format.Text(record, "hostname");
            user.Text = Format.Text(record, "username", "root");
            port.Value = record is null ? 22 : Format.Long(record, "port");
            name.Text = Format.Text(record, "label", "server");
            var keyId = Format.Text(record, "keyId", Format.Text(record, "identity", Format.Text(record, "credentialId")));
            foreach (var option in savedKey.Items.OfType<ComboBoxItem>())
                if (option.IsEnabled && Format.Text(option.Tag as JsonNode, "id") == keyId)
                    savedKey.SelectedItem = option;
        };
        void ShowMethod()
        {
            password.Visibility = method.SelectedIndex == 0 ? Visibility.Visible : Visibility.Collapsed;
            savedKey.Visibility = method.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
            privateKey.Visibility = method.SelectedIndex == 2 ? Visibility.Visible : Visibility.Collapsed;
            passphrase.Visibility = method.SelectedIndex == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        method.SelectionChanged += (_, _) => ShowMethod();
        ShowMethod();
        var first = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 430 };
        first.Children.Add(Copy("Connect to a Linux server you control. Setup will verify its identity and inspect it before installation."));
        foreach (var field in new UIElement[] { savedHost, address, user, port, name, method, savedKey, password, privateKey, passphrase, validation })
            first.Children.Add(field);
        first.Children.Add(Copy("Your credential is used for this connection and is not saved by setup."));
        string SelectedPem() => method.SelectedIndex == 1 && savedKey.SelectedItem is ComboBoxItem item
            ? SshSecrets.Get(Format.Text(item.Tag as JsonNode, "secretRef")) ?? ""
            : privateKey.Text.Trim();
        var entry = new ContentDialog { Title = "Set up a Linux host · 1 of 5",
            Content = new ScrollViewer { Content = first, MaxHeight = 520 },
            PrimaryButtonText = "Probe SSH identity", CloseButtonText = L10n.Text("common.cancel"),
            DefaultButton = ContentDialogButton.Primary };
        entry.PrimaryButtonClick += (_, click) =>
        {
            if (address.Text.Trim().Length > 0 && user.Text.Trim().Length > 0 && name.Text.Trim().Length > 0 &&
                double.IsFinite(port.Value) && port.Value is >= 1 and <= 65535 &&
                (method.SelectedIndex == 0 ? password.Password.Length > 0 : SelectedPem().Length > 0)) return;
            validation.Text = "Enter an address, user, name, valid port and credential.";
            click.Cancel = true;
        };
        if (await ShowAsync(owner, entry) != ContentDialogResult.Primary) return false;
        var hostname = address.Text.Trim();
        var username = user.Text.Trim();
        var label = name.Text.Trim();
        var sshPort = double.IsFinite(port.Value) && port.Value is >= 1 and <= 65535
            ? (int)port.Value : 0;
        var auth = method.SelectedIndex == 0
            ? new JsonObject { ["kind"] = "password", ["password"] = password.Password }
            : new JsonObject { ["kind"] = "privateKey", ["pem"] = SelectedPem() };
        if (method.SelectedIndex != 0 && passphrase.Password.Length > 0) auth["passphrase"] = passphrase.Password;
        // Probe sends no credential. A fresh host record is not stored until
        // the user compares the server's fingerprint and confirms it.
        var endpoint = new JsonObject { ["hostname"] = hostname, ["username"] = username,
            ["port"] = sshPort, ["hostKeys"] = new JsonArray() };
        var probe = await AppServices.Host.CallAsync("ssh.host.probe", endpoint, TimeSpan.FromSeconds(20));
        var fingerprint = Format.Text(probe, "fingerprint");
        if (fingerprint.Length == 0) throw new InvalidOperationException("The server returned no SSH fingerprint.");
        var identity = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 430 };
        identity.Children.Add(Copy("Compare this fingerprint with the one shown by your server or provider. No credential is sent until you confirm it."));
        identity.Children.Add(new TextBlock { Text = $"{hostname}:{sshPort}", IsTextSelectionEnabled = true });
        identity.Children.Add(new TextBlock { Text = fingerprint, FontFamily = Fonts.Mono,
            TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        var existing = (savedHost.SelectedItem as ComboBoxItem)?.Tag as JsonObject;
        if (existing?["hostKeys"] is JsonArray oldKeys && oldKeys.Count > 0 &&
            !oldKeys.Any(key => key?.ToString() == fingerprint))
            identity.Children.Add(new TextBlock { Text = "This fingerprint differs from the saved host. Verify the server before replacing its trusted key.",
                TextWrapping = TextWrapping.Wrap, Foreground = Theme.Brush(static () => Theme.Danger) });
        if (!await ConfirmAsync(owner, "Verify identity · 2 of 5", identity, "Trust this server")) return false;
        await RequireSameAccountAsync(accountScope);
        var host = existing is null ? new JsonObject { ["id"] = "", ["initialDirectory"] = "~" }
            : (JsonObject)existing.DeepClone();
        host["label"] = label;
        host["hostname"] = hostname;
        host["port"] = sshPort;
        host["username"] = username;
        host["hostKeys"] = new JsonArray { JsonValue.Create(fingerprint) };
        var saved = await SshVaultSync.WriteAsync("ssh.host.save", host);
        var hostId = Format.Text(saved, "id");
        if (hostId.Length == 0) throw new InvalidOperationException("The SSH host was not saved.");
        JsonObject Connection() => new()
        {
            ["hostname"] = hostname, ["port"] = sshPort, ["username"] = username,
            ["hostId"] = hostId, ["label"] = label, ["initialDirectory"] = "~",
            ["hostKeys"] = host["hostKeys"]!.DeepClone(), ["rows"] = 24, ["cols"] = 100,
            ["auth"] = auth.DeepClone(),
        };
        var check = await AppServices.Host.CallAsync("ssh.provision.check", Connection(), TimeSpan.FromSeconds(30));
        var inspect = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 430 };
        inspect.Children.Add(Copy("The server answered over verified SSH. Review it before anything is installed."));
        inspect.Children.Add(Copy("System: " + Format.Text(check, "distro", Format.Text(check, "os", "Unknown"))));
        inspect.Children.Add(Copy("Architecture: " + Format.Text(check, "arch", "Unknown")));
        inspect.Children.Add(Copy("Service manager: " + (Format.Flag(check, "systemd") ? "systemd" : "Unavailable")));
        inspect.Children.Add(Copy("Free disk: " + (Format.Long(check, "diskFreeMb") / 1024) + " GB"));
        if (Format.Flag(check, "root")) inspect.Children.Add(Copy("Agents will run with root access on this server."));
        if (check["blockers"] is JsonArray blockers)
            foreach (var blocker in blockers) inspect.Children.Add(Copy("• " + blocker));
        if (!Format.Flag(check, "ready"))
        {
            await MessageAsync(owner, "Server check · 3 of 5", "This server is not ready for installation. Fix the listed blockers and run setup again.\n\n" +
                string.Join("\n", (check["blockers"] as JsonArray ?? new()).Select(x => "• " + x)));
            return false;
        }
        var claude = new CheckBox { Content = "Claude Code", IsChecked = true, MinHeight = 44 };
        var codex = new CheckBox { Content = "Codex", MinHeight = 44 };
        inspect.Children.Add(claude);
        inspect.Children.Add(codex);
        if (!await ConfirmAsync(owner, "Check server · 3 of 5", inspect, "Continue to install")) return false;
        await RequireSameAccountAsync(accountScope);
        var local = await AppServices.Host.CallAsync("machine.identity");
        var myKey = Format.Text(local, "key");
        if (myKey.Length != 64) throw new InvalidOperationException("This PC's identity is unavailable.");
        var agents = new JsonArray();
        if (claude.IsChecked == true) agents.Add("claude_code");
        if (codex.IsChecked == true) agents.Add("codex");
        var install = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 430 };
        install.Children.Add(Copy("A one-time code signs this server in. The code is staged in a private file, never typed into the shell or its history."));
        install.Children.Add(Copy("The installer will run on " + hostname + " and allow this PC to open its work."));
        if (!await ConfirmAsync(owner, "Install tokenstat · 4 of 5", install, "Start installation")) return false;
        await RequireSameAccountAsync(accountScope);
        var code = Format.Text(await AppServices.Host.CallAsync("account.pairingCode"), "code");
        if (code.Length == 0) throw new InvalidOperationException("The account returned no pairing code.");
        var stage = Connection();
        stage["code"] = code;
        var staged = await AppServices.Host.CallAsync("ssh.provision.stageCode", stage, TimeSpan.FromSeconds(30));
        var stageId = Format.Text(staged, "stageId");
        string sessionId;
        try
        {
            var line = await AppServices.Host.CallAsync("ssh.provision.line", new JsonObject
            {
                ["allow"] = myKey, ["name"] = label, ["agents"] = agents,
                ["printInvite"] = false, ["codeFile"] = true,
            });
            var command = Format.Text(line, "oneLine");
            if (command.Length == 0) throw new InvalidOperationException("The host returned no install command.");
            var opened = await AppServices.Host.CallAsync("ssh.session.open", Connection(), TimeSpan.FromSeconds(30));
            sessionId = Format.Text(opened, "id");
            if (sessionId.Length == 0) throw new InvalidOperationException("The SSH install session did not open.");
            await Task.Delay(700);
            await AppServices.Host.CallAsync("ssh.session.write", new JsonObject
            { ["id"] = sessionId, ["data"] = Format.ByteArray(Encoding.UTF8.GetBytes(command + "\n")) });
        }
        catch
        {
            var cleanup = Connection(); cleanup["stageId"] = stageId;
            try { await AppServices.Host.CallAsync("ssh.provision.clearCode", cleanup); } catch { }
            throw;
        }
        var output = new TextBox { Header = "Installer output", IsReadOnly = true, AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap, FontFamily = Fonts.Mono, Height = 270 };
        var progress = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 430 };
        progress.Children.Add(Copy("The installer is running on the server. Check its output before verifying the new host."));
        progress.Children.Add(output);
        using var polling = new CancellationTokenSource();
        var poll = PollInstallAsync(sessionId, output, polling.Token);
        var next = await ConfirmAsync(owner, "Verify connection · 5 of 5", progress, "Check host");
        polling.Cancel();
        await poll;
        if (!next) return false;
        // The install shell is left available for inspection. It is not
        // silently killed when this dialog closes.
        await AppServices.Host.CallAsync("remote.serve", new JsonObject { ["tunnel"] = true });
        for (var attempt = 0; attempt < 20; attempt++)
        {
            await RequireSameAccountAsync(accountScope);
            try
            {
                var peer = Format.Text(await AppServices.Host.CallAsync("ssh.provision.identity", Connection(), TimeSpan.FromSeconds(20)), "key");
                if (peer.Length != 64) throw new InvalidOperationException("The server returned no machine identity.");
                await AppServices.Host.CallAsync("machine.pair", new JsonObject
                { ["key"] = peer, ["label"] = label, ["address"] = "" });
                // Account publication can trail the remote service starting.
                // Wait for the new host to appear in this account's directory
                // before asking it for work access, as the Apple flow does.
                var account = await AppServices.Host.CallAsync("account.status");
                if (account["machines"] is not JsonArray machines || !machines.Any(machine =>
                    string.Equals(Format.Text(machine, "publicIdentity"), peer, StringComparison.OrdinalIgnoreCase)))
                    throw new InvalidOperationException("The new host has not appeared on this account yet.");
                var status = await RemoteWorkspaces.CallOnPeerAsync(peer, "host.provisionStatus", patience: TimeSpan.FromSeconds(20));
                if (!string.Equals(Format.Text(status, "machineKey"), peer, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("The host answered with another identity.");
                var access = await RemoteWorkspaces.CallOnPeerAsync(peer, "workspace.access.check", patience: TimeSpan.FromSeconds(20));
                if (!Format.Flag(access, "allowed"))
                    throw new InvalidOperationException("The host is online but has not granted this PC access to its work.");
                await MessageAsync(owner, "Host ready", label + " is on your account and answered over the encrypted connection.");
                return true;
            }
            catch when (attempt < 19)
            {
                await Task.Delay(3000);
            }
        }
        throw new InvalidOperationException("The installer started, but the new host has not answered yet. Check its SSH output, then open Devices to connect when it comes online.");
    }

    private static async Task RequireSameAccountAsync(JsonObject expected)
    {
        var current = await SshVaultScope.RequireAsync();
        if (current.ToJsonString() != expected.ToJsonString())
            throw new InvalidOperationException("The signed-in account changed. Start setup again from the current account.");
    }

    private static async Task PollInstallAsync(string id, TextBox output, CancellationToken stop)
    {
        long offset = 0;
        while (!stop.IsCancellationRequested)
        {
            try
            {
                var chunk = await AppServices.Host.CallAsync("ssh.session.read", new JsonObject
                { ["id"] = id, ["offset"] = offset });
                offset = Math.Max(offset, Format.Long(chunk, "nextOffset"));
                var bytes = Format.Bytes(chunk["data"]);
                if (bytes.Length > 0)
                {
                    var combined = output.Text + Encoding.UTF8.GetString(bytes);
                    output.Text = combined.Length > 32768 ? combined[^32768..] : combined;
                }
                if (Format.Flag(chunk, "closed")) return;
                await Task.Delay(200, stop);
            }
            catch (OperationCanceledException) { return; }
            catch (Exception error) { output.Text += "\n" + FriendlyError.Display(error.Message); return; }
        }
    }

    private static TextBlock Copy(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };

    private static Task<ContentDialogResult> ShowAsync(Page owner, ContentDialog dialog) => Chrome.ShowDialog(owner, dialog);

    private static async Task<bool> ConfirmAsync(Page owner, string title, UIElement content, string action) =>
        await ShowAsync(owner, new ContentDialog { Title = title, Content = content, PrimaryButtonText = action,
            CloseButtonText = L10n.Text("common.cancel"), DefaultButton = ContentDialogButton.Close }) == ContentDialogResult.Primary;

    private static async Task MessageAsync(Page owner, string title, string message)
    {
        await ShowAsync(owner, new ContentDialog { Title = title, Content = Copy(message), CloseButtonText = L10n.Text("common.done") });
    }
}
