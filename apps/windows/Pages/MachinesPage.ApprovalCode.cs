// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed partial class MachinesPage
{
    private bool _approvalCodeOpen;

    private void AddApprovalCodeAction(Panel actions, JsonNode? machine, JsonNode peer, string name)
    {
        var key = Format.Text(peer, "key");
        if (machine is null || key.Length == 0 || Format.Text(peer, "trust") != "approved" || !CanConnect(machine)) return;
        var account = AppServices.AccountGeneration;
        actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.machinespage.enter_approval_code"), ActionIcon.Approve,
            async (_, _) => await EnterApprovalCodeAsync(key, name, MachineOnline(machine), account)));
    }

    private async Task EnterApprovalCodeAsync(string peer, string name, bool? online, long account)
    {
        bool Current() => IsLoaded && account == AppServices.AccountGeneration;
        if (_approvalCodeOpen || !Current()) return;
        _approvalCodeOpen = true;
        var input = new TextBox
        {
            Header = L10n.Text("windows.machinespage.approval_code"),
            PlaceholderText = "WXYZ-2345",
            IsSpellCheckEnabled = false,
            IsTextPredictionEnabled = false,
        };
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.machinespage.approval_code_instructions", name),
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(input);
        body.Children.Add(error);
        var dialog = new ContentDialog
        {
            Title = L10n.Text("windows.machinespage.enter_approval_code"),
            Content = body,
            PrimaryButtonText = L10n.Text("windows.machinespage.use_approval_code"),
            CloseButtonText = L10n.Text("common.cancel"),
            IsPrimaryButtonEnabled = false,
        };
        string Code() => string.Concat(input.Text.Where(c => !char.IsWhiteSpace(c) && c != '-')).ToUpperInvariant();
        bool Valid(string code) => code.Length == 8 && code.All(char.IsAsciiLetterOrDigit);
        var working = false;
        var granted = false;
        input.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !working && Valid(Code());
        dialog.Closing += (_, args) => args.Cancel = working && Current();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var code = Code();
            if (working || !Current() || !Valid(code)) return;
            working = true;
            input.IsEnabled = dialog.IsPrimaryButtonEnabled = false;
            error.Visibility = Visibility.Collapsed;
            try
            {
                var result = await RemoteWorkspaces.CallOnPeerAsync(peer, "workspace.access.redeem", new JsonObject { ["code"] = code });
                if (!Current()) return;
                granted = Format.Flag(result, "granted");
                if (!granted) throw new InvalidOperationException(L10n.Text("windows.machinespage.approval_code_refused"));
            }
            catch (Exception ex)
            {
                if (Current())
                {
                    error.Text = FriendlyError.Display(ex.Message);
                    error.Visibility = Visibility.Visible;
                }
            }
            finally
            {
                working = false;
                if (granted || !Current()) dialog.Hide();
                else
                {
                    input.IsEnabled = true;
                    dialog.IsPrimaryButtonEnabled = Valid(Code());
                }
            }
        };
        try
        {
            await Chrome.ShowDialog(this, dialog);
            if (granted && Current()) await ConnectPeerAsync(peer, name, online);
        }
        finally
        {
            input.Text = "";
            _approvalCodeOpen = false;
        }
    }
}
