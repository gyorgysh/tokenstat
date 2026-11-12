// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>
/// The two questions about reading a whole conversation again: sending after
/// the prompt cache expired, and switching the model of a cached one.
/// </summary>
internal sealed partial class ChatPage
{
    private enum ColdSendChoice { Send, StartNew, Cancel }

    /// <summary>
    /// Ask before a message that would make the agent read the whole
    /// conversation again. Send when nothing needs asking.
    /// </summary>
    private async Task<ColdSendChoice> AskBeforeColdSendAsync(bool movable)
    {
        if (ChatCacheRule.IdleSuppressed) return ColdSendChoice.Send;
        if (ChatCacheRule.Idle(_openChat, ChatCacheRule.NowMs) is not long idle
            || ChatCacheRule.Cache(_openChat) is not { } cache) return ColdSendChoice.Send;
        var canStart = movable && await SupportsContinueAsync();
        var message = L10n.Text("common.chat.cache.resume_message",
            ChatCacheRule.Duration(idle), Format.Tokens(Format.Long(cache, "tokens")));
        if (canStart) message += "\n\n" + L10n.Text("common.chat.cache.resume_new_hint");
        var suppress = new CheckBox { Content = L10n.Text("common.chat.cache.dont_ask_again") };
        var content = new StackPanel { Spacing = Theme.SpaceM };
        content.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        content.Children.Add(suppress);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = L10n.Text("common.chat.cache.resume_title"),
            Content = content,
            PrimaryButtonText = canStart ? L10n.Text("common.chat.cache.start_new") : L10n.Text("common.chat.cache.send_here"),
            SecondaryButtonText = canStart ? L10n.Text("common.chat.cache.send_here") : "",
            CloseButtonText = L10n.Text("common.cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        var result = await Chrome.ShowDialog(this, dialog);
        if (result == ContentDialogResult.None) return ColdSendChoice.Cancel;
        if (suppress.IsChecked == true) ChatCacheRule.IdleSuppressed = true;
        if (result == ContentDialogResult.Secondary) return ColdSendChoice.Send;
        return canStart ? ColdSendChoice.StartNew : ColdSendChoice.Send;
    }

    /// <summary>Change the model, asking first when the cache is for another one.</summary>
    private async Task ChangeModelAsync(string next)
    {
        if (!ChatCacheRule.ModelSuppressed
            && ChatCacheRule.Switching(_openChat, next, ChatCacheRule.NowMs)
            && ChatCacheRule.Cache(_openChat) is { } cache)
        {
            var chat = _openId;
            var generation = _openGeneration;
            var from = Format.Text(cache, "model") is { Length: > 0 } model ? model : Format.Text(cache, "selection");
            var suppress = new CheckBox { Content = L10n.Text("common.chat.cache.dont_ask_again") };
            var content = new StackPanel { Spacing = Theme.SpaceM };
            content.Children.Add(new TextBlock
            {
                Text = L10n.Text("common.chat.cache.switch_message", ChatCacheRule.ModelName(from),
                    ChatCacheRule.ModelName(next), Format.Tokens(Format.Long(cache, "tokens"))),
                TextWrapping = TextWrapping.Wrap,
            });
            content.Children.Add(suppress);
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = L10n.Text("common.chat.cache.switch_title"),
                Content = content,
                PrimaryButtonText = L10n.Text("common.chat.cache.switch_model"),
                CloseButtonText = L10n.Text("common.cancel"),
                DefaultButton = ContentDialogButton.Close,
            };
            if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
            {
                // The picker already shows the new choice. Put the saved one back.
                if (chat is not null && OpenChatIs(chat) && generation == _openGeneration)
                {
                    PaintConversation();
                    RenderInspector();
                }
                return;
            }
            if (suppress.IsChecked == true) ChatCacheRule.ModelSuppressed = true;
            if (chat is null || !OpenChatIs(chat) || generation != _openGeneration) return;
        }
        await UpdateAsync(new JsonObject { ["model"] = next });
    }

    private async Task<bool> SupportsContinueAsync()
    {
        try
        {
            var protocol = RemoteFeatureGate.ProtocolOf(await CallChatAsync("protocol", new JsonObject()));
            return RemoteFeatureGate.SupportsProtocol(protocol, ChatCacheRule.ContinueMinProtocol);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Start a chat that continues this one, send it the message, and open it.
    /// The words stay in this composer if any step fails.
    /// </summary>
    private async Task ContinueInNewChatAsync(string chat, string text)
    {
        var generation = _openGeneration;
        var accountGeneration = AppServices.AccountGeneration;
        bool Current() => OpenChatIs(chat) && generation == _openGeneration
            && accountGeneration == AppServices.AccountGeneration;
        string? id = null;
        string? key = null;
        QueuedChatMessage? attempted = null;
        try
        {
            var created = await CallChatAsync("chat.continueInNew", new JsonObject { ["id"] = chat });
            AppServices.NotifyConversationsChanged();
            id = Format.Text(created, "id");
            if (id.Length == 0 || !Current() || _draft.Text.Trim() != text) return;
            key = await OutboxKeyAsync(id);
            if (!Current() || _draft.Text.Trim() != text) return;
            var item = new QueuedChatMessage(Guid.NewGuid().ToString("N"), text, [], Format.Long(created, "sendRevision"));
            ChatOutbox.Shared.Update(key, rows => rows.Add(item));
            _draft.Text = "";
            RememberDraft();
            attempted = ChatOutbox.Shared.Stage(key, item, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            var updated = await CallChatAsync("chat.send", new JsonObject
            {
                ["id"] = id,
                ["text"] = text,
                ["clientMessageId"] = attempted.Id,
                ["clientMessageCreatedAtMs"] = attempted.AttemptedAt,
                ["expectedRevision"] = attempted.Revision,
            });
            ChatOutbox.Shared.Accept(key, attempted, Format.Long(updated, "sendRevision"));
            if (Current()) AppServices.OpenConversation?.Invoke(_workspaceId, id);
        }
        catch (Exception ex)
        {
            // A host refusal proves the message did not start. Release its
            // receipt hold just as the regular outbox does; transport errors
            // remain held until delivery can be checked.
            if (ex is HostException hostError && key is not null && attempted is not null)
            {
                try { ChatOutbox.Shared.Refuse(key, attempted.Id, hostError.Code); }
                catch { /* The saved pending copy can still be reviewed. */ }
            }
            if (Current())
            {
                Banner(ex.Message);
                if (!string.IsNullOrEmpty(id)) AppServices.OpenConversation?.Invoke(_workspaceId, id);
            }
        }
    }
}
