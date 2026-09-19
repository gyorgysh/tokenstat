// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal sealed partial class ChatPage
{
    private string? _outboxKey;
    private readonly HashSet<string> _authorizedQueue = [];

    private async Task<string> OutboxKeyAsync(string chat)
    {
        var status = await AppServices.Host.CallAsync("account.status");
        var account = status["account"] ?? status;
        var identity = Format.Flag(account, "signedIn")
            ? Format.Text(account, "accountId", Format.Text(account, "handle")) : "local";
        if (identity.Length == 0) throw new InvalidOperationException("Sign in again before queuing messages.");
        return ChatOutbox.Key(Format.Text(account, "host") + ":" + identity, _workspaceId, chat);
    }

    private UIElement PendingMessages()
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        if (_outboxKey is not string key) return body;
        try
        {
            var items = ChatOutbox.Shared.Read(key);
            if (items.Count == 0) return body;
            body.Children.Add(new TextBlock { Text = $"Pending messages ({items.Count})", FontSize = 12, Foreground = Theme.AccentBrush });
            foreach (var item in items)
            {
                var row = new StackPanel { Spacing = 4 };
                row.Children.Add(new TextBlock { Text = item.Text.Length == 0 ? "Attached files" : item.Text,
                    TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 2, TextWrapping = TextWrapping.Wrap });
                row.Children.Add(Muted(item.AttemptedAt.HasValue ? "Delivery needs checking" :
                    _authorizedQueue.Contains(item.Id) ? "Queued after the current turn" : "Paused — review before sending"));
                var actions = new FlowPanel { Spacing = Theme.SpaceS };
                if (item.AttemptedAt.HasValue)
                {
                    actions.Children.Add(ActionIconGlyph.Button("Check delivery", ActionIcon.Refresh, async (_, _) =>
                    {
                        try
                        {
                            if (_openId is not string currentChat || await OutboxKeyAsync(currentChat) != key)
                                throw new InvalidOperationException("Reopen this conversation with its original account to check delivery.");
                            var receipt = await CallChatAsync("chat.receipt", new JsonObject { ["id"] = _openId, ["clientMessageId"] = item.Id });
                            if (Format.Text(receipt, "state") == "accepted") ChatOutbox.Shared.Accept(key, item, null);
                            else Banner("Delivery is not confirmed. Review the conversation before removing this pending copy; it will not be resent automatically.");
                            PaintConversation();
                        }
                        catch (Exception ex) { Banner(ex.Message); }
                    }));
                }
                else
                {
                    actions.Children.Add(ActionIconGlyph.Button("Use latest context", ActionIcon.Run, async (_, _) =>
                    {
                        try
                        {
                            await RefreshCatalogAsync();
                            _openChat = FindChat(_openId!);
                            var revision = Format.Long(_openChat, "sendRevision");
                            ChatOutbox.Shared.Update(key, rows =>
                            {
                                var index = rows.FindIndex(row => row.Id == item.Id);
                                if (index >= 0 && !rows[index].AttemptedAt.HasValue) rows[index] = rows[index] with { Revision = revision, State = "waiting" };
                            });
                            _authorizedQueue.Add(item.Id);
                            await DrainQueueAsync(); PaintConversation(); StartPoll();
                        }
                        catch (Exception ex) { Banner(ex.Message); }
                    }));
                    if (items.IndexOf(item) > 0 && !items[items.IndexOf(item) - 1].AttemptedAt.HasValue)
                        actions.Children.Add(ActionIconGlyph.Button("Move up", ActionIcon.Move, (_, _) =>
                        {
                            try
                            {
                                ChatOutbox.Shared.Update(key, rows =>
                                {
                                    var index = rows.FindIndex(row => row.Id == item.Id);
                                    if (index > 0 && !rows[index].AttemptedAt.HasValue && !rows[index - 1].AttemptedAt.HasValue)
                                        (rows[index - 1], rows[index]) = (rows[index], rows[index - 1]);
                                });
                                PaintConversation();
                            }
                            catch (Exception ex) { Banner(ex.Message); }
                        }));
                    actions.Children.Add(ActionIconGlyph.Button("Edit", ActionIcon.Edit, async (_, _) =>
                    {
                        var edit = new TextBox { Text = item.Text, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 100 };
                        var dialog = new ContentDialog { Title = "Edit pending message", Content = edit, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
                        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary) return;
                        try
                        {
                            ChatOutbox.Shared.Update(key, rows => { var index = rows.FindIndex(row => row.Id == item.Id); if (index >= 0 && !rows[index].AttemptedAt.HasValue) rows[index] = rows[index] with { Text = edit.Text }; });
                            PaintConversation();
                        }
                        catch (Exception ex) { Banner(ex.Message); }
                    }));
                }
                actions.Children.Add(ActionIconGlyph.Button("Remove", ActionIcon.Delete, (_, _) =>
                {
                    try { ChatOutbox.Shared.Update(key, rows => rows.RemoveAll(row => row.Id == item.Id)); _authorizedQueue.Remove(item.Id); PaintConversation(); }
                    catch (Exception ex) { Banner(ex.Message); }
                }));
                row.Children.Add(actions);
                ContextMenus.AddButtons(ContextMenus.Menu(row), actions);
                body.Children.Add(row);
            }
        }
        catch (Exception ex) { body.Children.Add(Muted(ex.Message)); }
        return new ScrollViewer { Content = body, MaxHeight = 180, HorizontalScrollMode = ScrollMode.Disabled };
    }

    private async Task<bool> DrainQueueOnUiAsync(string chat)
    {
        if (!DispatcherQueue.HasThreadAccess)
        {
            var done = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!DispatcherQueue.TryEnqueue(async () =>
            {
                try { done.TrySetResult(await DrainQueueOnUiAsync(chat)); }
                catch (Exception ex) { done.TrySetException(ex); }
            })) return false;
            return await done.Task;
        }
        if (!IsLoaded || _openId != chat) return false;
        await DrainQueueAsync();
        if (!IsLoaded || _openId != chat) return false;
        PaintConversation();
        return Busy();
    }

    private async Task DrainQueueAsync()
    {
        if (_sending || Busy() || _openId is not string chat || _outboxKey is not string key || !IsLoaded) return;
        var candidate = ChatOutbox.Shared.Read(key).FirstOrDefault();
        if (candidate is null || candidate.AttemptedAt.HasValue || !_authorizedQueue.Contains(candidate.Id)) return;
        _sending = true;
        try
        {
            if (await OutboxKeyAsync(chat) != key) throw new InvalidOperationException("The signed-in account changed. Pending messages remain with the original account.");
            await RefreshCatalogAsync();
            if (!IsLoaded || _openId != chat) return;
            var live = _chats.FirstOrDefault(row => Format.Text(row, "id") == chat)
                ?? throw new InvalidOperationException("This conversation is no longer available.");
            if (Format.Flag(live, "running")) return;
            if (live["sendRevision"] is null || Format.Long(live, "sendRevision") != candidate.Revision)
            {
                _authorizedQueue.Remove(candidate.Id);
                Banner("The conversation settings changed. Review the pending message and choose Use latest context.");
                return;
            }
            var attempted = ChatOutbox.Shared.Stage(key, candidate, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            var updated = await CallChatAsync("chat.send", new JsonObject
            {
                ["id"] = chat, ["text"] = attempted.Text,
                ["attachmentIds"] = new JsonArray(attempted.Attachments.Select(id => (JsonNode?)JsonValue.Create(id)).ToArray()),
                ["clientMessageId"] = attempted.Id, ["clientMessageCreatedAtMs"] = attempted.AttemptedAt,
                ["expectedRevision"] = attempted.Revision,
            });
            ChatOutbox.Shared.Accept(key, attempted, Format.Long(updated, "sendRevision"));
            _authorizedQueue.Remove(attempted.Id);
            if (IsLoaded && _openId == chat) { _openChat = updated; _running = true; _started = true; }
        }
        catch (Exception ex)
        {
            _authorizedQueue.Remove(candidate.Id);
            if (IsLoaded && _openId == chat) Banner("The pending copy is saved. " + ex.Message);
        }
        finally { _sending = false; }
    }
}
