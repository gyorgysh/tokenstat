// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed partial class ChatPage
{
    private bool SharedSource => ChatLocalSharingModel.Paused(_openChat);
    private UIElement SharedSourceNotice()
    {
        var panel = new StackPanel { Spacing = Theme.SpaceS };
        panel.Children.Add(new TextBlock { Text = L10n.Text("common.teams.shared_chat"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(Muted(L10n.Text("common.teams.private_source_notice")));
        if (RemoteWorkspaces.TrySplit(_workspaceId, out _, out _)) panel.Children.Add(Muted(L10n.Text("common.teams.recover_on_publisher")));
        else panel.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.manage_sharing"), ActionIcon.Connect, async (_, _) => await ManageLocalSharingAsync()));
        return panel;
    }
    private async Task ManageLocalSharingAsync()
    {
        if (!SharedSource || _openId is not { } chat || RemoteWorkspaces.TrySplit(_workspaceId, out _, out _)) return;
        var generation = _openGeneration; var account = AppServices.AccountGeneration;
        bool Current() => IsLoaded && _openId == chat && _openGeneration == generation && AppServices.AccountGeneration == account;
        var marker = _openChat?["teamShare"] as JsonObject;
        var model = new ChatLocalSharingModel(_workspaceId, chat, Format.Text(marker, "id"), _openChat?["teamRunFence"] is not null,
            Current, (method, input) => AppServices.Host.CallAsync(method, input));
        async Task RefreshSource()
        {
            if (!Current()) return;
            await RefreshCatalogAsync(refreshMenus: false);
            if (!Current()) return;
            var record = _chats.FirstOrDefault(row => Format.Text(row, "id") == chat);
            if (record is null) return;
            _openChat = ChatSteerOverlay.MergeRecord(record, _openChat);
            // Paused private messages require their own review after sharing
            // ends; this action never resumes the personal outbox.
            _authorizedQueue.Clear(); PaintConversation();
            AppServices.NotifyConversationsChanged();
        }
        var dialog = new ContentDialog { Title = L10n.Text("common.teams.stop_sharing_chat"),
            Content = new ChatLocalSharingPanel(model, Current, RefreshSource), CloseButtonText = L10n.Text("common.done") };
        await Chrome.ShowDialog(this, dialog);
    }
}
