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
        if (identity.Length == 0) throw new InvalidOperationException(L10n.Text("windows.chatpage_queue.sign_in_again_before_queuing_messages.622d70dc"));
        return ChatOutbox.Key(Format.Text(account, "host") + ":" + identity, _workspaceId, chat);
    }

    private UIElement PendingMessages()
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        if (_outboxKey is not string key || _openId is not string chat) return body;
        var generation = _openGeneration;
        bool Current() => OpenChatIs(chat) && generation == _openGeneration && _outboxKey == key;
        try
        {
            var items = ChatOutbox.Shared.Read(key);
            if (items.Count == 0) return body;
            body.Children.Add(new TextBlock { Text = L10n.Text("windows.chatpage_queue.pending_messages_0.c3f22136", $"{items.Count}"), FontSize = 12, Foreground = Theme.AccentBrush });
            foreach (var item in items)
            {
                var row = new StackPanel { Spacing = 4 };
                row.Children.Add(new TextBlock { Text = item.Text.Length == 0 ? L10n.Text("windows.chatpage_queue.attached_files.ecc5a28d") : item.Text,
                    TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 2, TextWrapping = TextWrapping.Wrap });
                row.Children.Add(Muted(item.AttemptedAt.HasValue ? L10n.Text("windows.chatpage_queue.delivery_needs_checking.62805e9a") :
                    _authorizedQueue.Contains(item.Id) ? L10n.Text("windows.chatpage_queue.queued_after_the_current_turn.bdddd9f5") : L10n.Text("windows.chatpage_queue.paused_review_before_sending.2e920ca8")));
                var actions = new FlowPanel { Spacing = Theme.SpaceS };
                if (item.AttemptedAt.HasValue)
                {
                    actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.chatpage_queue.check_delivery.b8e3662d"), ActionIcon.Refresh, async (_, _) =>
                    {
                        try
                        {
                            if (!Current()) return;
                            var currentKey = await OutboxKeyAsync(chat);
                            if (!Current()) return;
                            if (currentKey != key)
                                throw new InvalidOperationException(L10n.Text("windows.chatpage_queue.reopen_this_conversation_with_its_original.bb0e73dd"));
                            var receipt = await CallChatAsync("chat.receipt", new JsonObject { ["id"] = chat, ["clientMessageId"] = item.Id });
                            if (Format.Text(receipt, "state") == "accepted") ChatOutbox.Shared.Accept(key, item, null);
                            else if (Current()) Banner(L10n.Text("windows.chatpage_queue.delivery_is_not_confirmed_review_the_conve.8a519f20"));
                            if (Current()) PaintConversation();
                        }
                        catch (Exception ex) { if (Current()) Banner(ex.Message); }
                    }));
                }
                else
                {
                    actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.chatpage_queue.use_latest_context.a29959ec"), ActionIcon.Run, async (_, _) =>
                    {
                        try
                        {
                            if (!Current()) return;
                            await RefreshCatalogAsync();
                            if (!Current()) return;
                            _openChat = FindChat(chat);
                            var revision = Format.Long(_openChat, "sendRevision");
                            ChatOutbox.Shared.Update(key, rows =>
                            {
                                var index = rows.FindIndex(row => row.Id == item.Id);
                                if (index >= 0 && !rows[index].AttemptedAt.HasValue) rows[index] = rows[index] with { Revision = revision, State = "waiting" };
                            });
                            _authorizedQueue.Add(item.Id);
                            await DrainQueueAsync();
                            if (Current()) { PaintConversation(); StartPoll(); }
                        }
                        catch (Exception ex) { if (Current()) Banner(ex.Message); }
                    }));
                    if (items.IndexOf(item) > 0 && !items[items.IndexOf(item) - 1].AttemptedAt.HasValue)
                        actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.chatpage_queue.move_up.c66feb5e"), ActionIcon.Move, (_, _) =>
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
                    actions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.edit"), ActionIcon.Edit, async (_, _) =>
                    {
                        var edit = new TextBox { Text = item.Text, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 100 };
                        var dialog = new ContentDialog { Title = L10n.Text("windows.chatpage_queue.edit_pending_message.7567a871"), Content = edit, PrimaryButtonText = L10n.Text("common.save"), CloseButtonText = L10n.Text("common.cancel") };
                        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary) return;
                        try
                        {
                            ChatOutbox.Shared.Update(key, rows => { var index = rows.FindIndex(row => row.Id == item.Id); if (index >= 0 && !rows[index].AttemptedAt.HasValue) rows[index] = rows[index] with { Text = edit.Text }; });
                            PaintConversation();
                        }
                        catch (Exception ex) { Banner(ex.Message); }
                    }));
                }
                actions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.remove"), ActionIcon.Delete, (_, _) =>
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
        var generation = _openGeneration;
        var before = Busy();
        var hasAuthorizedQueue = _authorizedQueue.Count > 0;
        var hasNote = PendingSteerText(_openChat).Length > 0;
        if (hasAuthorizedQueue || hasNote) await DrainQueueAsync();
        if (!IsLoaded || _openId != chat || generation != _openGeneration) return false;
        if (hasAuthorizedQueue || before != Busy()) PaintConversation();
        return true;
    }

    private async Task DrainQueueAsync(bool deliverNote = true)
    {
        // A parked note does not need the outbox key, and it goes out before
        // any queued message. The flag is set by the delivery itself so a
        // poll tick cannot start a second one.
        if (_sending || _deliveringSteer || _clearingSteer || _openId is not string chat || !IsLoaded) return;
        if (PendingSteerText(_openChat).Length > 0)
        {
            if (!deliverNote || Busy()) return;
            await DeliverParkedSteerAsync(chat);
            return;
        }
        if (Busy() || _outboxKey is not string key) return;
        var generation = _openGeneration;
        bool Current() => OpenChatIs(chat) && generation == _openGeneration && _outboxKey == key;
        var candidate = ChatOutbox.Shared.Read(key).FirstOrDefault();
        if (candidate is null || candidate.AttemptedAt.HasValue || !_authorizedQueue.Contains(candidate.Id)) return;
        _sending = true;
        try
        {
            var currentKey = await OutboxKeyAsync(chat);
            if (!Current()) return;
            if (currentKey != key) throw new InvalidOperationException(L10n.Text("windows.chatpage_queue.the_signed_in_account_changed_pending_mess.54c18f45"));
            await RefreshCatalogAsync();
            if (!Current()) return;
            var live = _chats.FirstOrDefault(row => Format.Text(row, "id") == chat)
                ?? throw new InvalidOperationException(L10n.Text("windows.chatpage_queue.this_conversation_is_no_longer_available.07f8c47b"));
            if (Format.Flag(live, "running")) return;
            if (live["sendRevision"] is null || Format.Long(live, "sendRevision") != candidate.Revision)
            {
                _authorizedQueue.Remove(candidate.Id);
                Banner(L10n.Text("windows.chatpage_queue.the_conversation_settings_changed_review_t.6038328c"));
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
            if (Current())
            { _openChat = ChatSteerOverlay.MergeRecord(updated, _openChat); _running = true; _started = true; }
        }
        catch (Exception ex)
        {
            _authorizedQueue.Remove(candidate.Id);
            if (Current()) Banner(L10n.Text("windows.chatpage_queue.the_pending_copy_is_saved_0.215c8440", $"{ex.Message}"));
        }
        finally { _sending = false; }
    }
}
