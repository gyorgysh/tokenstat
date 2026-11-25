// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal sealed partial class ChatPage
{
    private bool _savingOffline;

    private async Task KeepOfflineAsync()
    {
        if (_savingOffline || _openChat is null || _openId is not string chat || SharedSource) return;
        var generation = _openGeneration;
        var account = AppServices.AccountGeneration;
        bool Current() => IsLoaded && generation == _openGeneration && account == AppServices.AccountGeneration && OpenChatIs(chat);
        _savingOffline = true;
        try
        {
            const int maximumCharacters = 300_000;
            var lines = new List<string>();
            var remaining = maximumCharacters;
            var partial = _hasEarlier;
            foreach (var item in Coalesce(_events).AsEnumerable().Reverse())
            {
                if (item.Kind is not (ItemKind.User or ItemKind.Assistant) || string.IsNullOrWhiteSpace(item.Text)) continue;
                var speaker = item.Kind == ItemKind.User ? L10n.Text("windows.savedwork.you") : L10n.Text("windows.savedwork.agent");
                var line = speaker + "\n" + item.Text;
                if (line.Length + 2 > remaining)
                {
                    if (lines.Count == 0)
                    {
                        var end = maximumCharacters - 1;
                        if (char.IsHighSurrogate(line[end - 1])) end--;
                        lines.Add(line[..end] + "…");
                    }
                    partial = true;
                    break;
                }
                lines.Add(line);
                remaining -= line.Length + 2;
            }
            if (lines.Count == 0) { Banner(L10n.Text("windows.savedwork.no_messages")); return; }
            lines.Reverse();
            var title = Format.Text(_openChat, "title", L10n.Text("windows.chatpage.new_chat.db18382a"));
            var store = await SavedWork.OpenAsync();
            if (!Current()) return;
            await store.KeepAsync(_workspaceId, chat, title, string.Join("\n\n", lines), partial);
            if (Current()) Banner(L10n.Text("windows.savedwork.kept"));
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (Current()) Banner(ex.Message); }
        finally { _savingOffline = false; }
    }
}
