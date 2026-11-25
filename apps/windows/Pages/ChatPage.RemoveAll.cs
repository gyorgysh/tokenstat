// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed partial class ChatPage
{
    private bool _deletingAllChats;

    private async Task ConfirmDeleteAllAsync()
    {
        if (_deletingAllChats || !_listReady || _openId is not null) return;
        _deletingAllChats = true;
        var generation = _openGeneration;
        var account = AppServices.AccountGeneration;
        bool Current() => IsLoaded && generation == _openGeneration && account == AppServices.AccountGeneration;
        var target = new JsonObject { ["workspaceId"] = _workspaceId };
        async Task<HashSet<string>> ChatIdsAsync()
        {
            var response = await CallChatAsync("chat.list", target);
            var rows = response as JsonArray ?? (response as JsonObject)?["items"] as JsonArray;
            var ids = rows?.Select(chat => Format.Text(chat, "id")).ToHashSet(StringComparer.Ordinal);
            if (ids is null || ids.Contains("")) throw new IOException(L10n.Text("windows.chatpage.delete_all_list_failed"));
            return ids;
        }
        var removedOnHost = false;
        try
        {
            var protocol = RemoteFeatureGate.ProtocolOf(await CallChatAsync("protocol"));
            if (!Current()) return;
            if (protocol is null or < RemoteFeatureGate.ChatRemoveAllMinProtocol)
            {
                Banner(L10n.Text("windows.chatpage.delete_all_update_host"));
                return;
            }
            var title = L10n.Text("windows.chatpage.delete_all_chats");
            var dialog = new ContentDialog
            {
                Title = title,
                Content = L10n.Text("windows.chatpage.delete_all_chats_confirm", _folderName),
                PrimaryButtonText = title,
                CloseButtonText = L10n.Text("common.cancel"),
                DefaultButton = ContentDialogButton.Close,
            };
            if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary || !Current()) return;

            var outboxAccount = await OutboxAccountAsync();
            var before = await ChatIdsAsync();
            if (!Current()) return;
            await CallChatAsync("chat.removeAll", target);
            removedOnHost = true;
            AppServices.NotifyConversationsChanged();
            if (account != AppServices.AccountGeneration) return;
            var remaining = await ChatIdsAsync();
            if (account != AppServices.AccountGeneration) return;
            before.ExceptWith(remaining);

            string? cleanupError = null;
            foreach (var id in before)
            {
                var key = ChatOutbox.Key(outboxAccount, _workspaceId, id);
                if (_drafts.Remove(key, out var draft))
                    foreach (var attachment in draft.Attachments) attachment.LocalFile?.Discard();
                ChatDraftStore.Shared.Write(key, "");
                try { ChatOutbox.Shared.Remove(key); }
                catch (Exception error) { cleanupError ??= FriendlyError.Display(error.Message); }
            }
            var openWasRemoved = _openId is { } open && before.Contains(open);
            if (openWasRemoved)
            {
                _outboxKey = null;
                foreach (var attachment in _attachments) attachment.LocalFile?.Discard();
                _attachments.Clear();
                _draft.Text = "";
            }
            if (!Current() && (!IsLoaded || !openWasRemoved)) return;
            await ShowListAsync();
            if (cleanupError is not null && IsLoaded && _openId is null && account == AppServices.AccountGeneration)
                Banner(L10n.Text("windows.chatpage.delete_all_cleanup_failed", cleanupError));
        }
        catch (Exception error)
        {
            if (!Current()) return;
            if (removedOnHost) await ShowListAsync();
            if (IsLoaded && _openId is null && account == AppServices.AccountGeneration)
                Banner(removedOnHost ? L10n.Text("windows.chatpage.delete_all_cleanup_failed", FriendlyError.Display(error.Message))
                    : FriendlyError.Display(error.Message));
        }
        finally { _deletingAllChats = false; }
    }
}
