// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed partial class ChatPage
{
    private readonly ContentControl _handoffSlot = new();
    private bool _handoffOpen;
    private const int HandoffProtocol = 12;

    private JsonObject HandoffTarget(string chat) => new() { ["workspaceId"] = _workspaceId, ["conversationId"] = chat };

    private Task<JsonNode> HandoffReadAsync(string chat) => CallChatAsync("work.continuity.get", HandoffTarget(chat));

    private async Task RefreshHandoffOfferAsync(string chat, int generation)
    {
        _handoffSlot.Content = null;
        var account = AppServices.AccountGeneration;
        bool Current() => IsLoaded && !SharedSource && OpenChatIs(chat) && _openGeneration == generation && account == AppServices.AccountGeneration;
        if (!Current()) return;
        try
        {
            var protocol = RemoteFeatureGate.ProtocolOf(await CallChatAsync("protocol"));
            if (!Current() || protocol is null or < HandoffProtocol) return;
            var response = await HandoffReadAsync(chat);
            if (!Current() || response["handoff"] is not JsonObject handoff) return;
            var device = Format.Text(await AppServices.Host.CallAsync("machine.identity"), "key");
            if (!Current() || device.Length == 0 || Format.Text(handoff, "deviceId", device) == device) return;
            var row = new FlowPanel { Spacing = Theme.SpaceS };
            row.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.handoff.from", Format.Text(handoff, "deviceName")),
                ActionIcon.Device, async (_, _) =>
                {
                    _handoffSlot.Content = null;
                    await ShowHandoffAsync();
                }));
            row.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.handoff.keep_working"), ActionIcon.Dismiss,
                (_, _) => _handoffSlot.Content = null));
            _handoffSlot.Content = row;
        }
        catch { /* The sheet is reachable even if the background offer failed. */ }
    }

    private async Task ShowHandoffAsync()
    {
        if (_handoffOpen || _opening || SharedSource || _openId is not { } chat) return;
        var generation = _openGeneration;
        var account = AppServices.AccountGeneration;
        bool Current() => IsLoaded && !_opening && !SharedSource && OpenChatIs(chat) && generation == _openGeneration && account == AppServices.AccountGeneration;
        _handoffOpen = true;
        try
        {
            var protocol = RemoteFeatureGate.ProtocolOf(await CallChatAsync("protocol"));
            if (!Current()) return;
            if (protocol is null or < HandoffProtocol) throw new InvalidOperationException(L10n.Text("windows.handoff.update_host"));
            var identity = await AppServices.Host.CallAsync("machine.identity");
            if (!Current()) return;
            var deviceName = Format.Text(identity, "label", Environment.MachineName).Trim();
            if (deviceName.Length == 0 || deviceName.Any(char.IsControl) || Encoding.UTF8.GetByteCount(deviceName) > 128)
                deviceName = L10n.Text("windows.accountpage.this_pc.66f5aa0b");
            var response = await HandoffReadAsync(chat);
            var saved = response["handoff"] as JsonObject;
            JsonObject? pending = null;
            string? notice = null;
            var conflict = false;
            while (Current())
            {
                var include = new CheckBox
                {
                    Content = L10n.Text("windows.handoff.include_draft"),
                    IsEnabled = !_queueing && !_sending && (_draft.Text.Length > 0 || _attachments.Count > 0),
                };
                var body = new StackPanel { Spacing = Theme.SpaceS, Children =
                {
                    HandoffText(ReviewTitle),
                    HandoffText(L10n.Text("windows.handoff.explanation")),
                } };
                if (pending is null && include.IsEnabled) body.Children.Add(include);
                if (notice is not null) body.Children.Add(HandoffText(notice));
                var sharedDraft = saved?["draft"] as JsonObject;
                var sharedAnchor = saved?["anchor"] as JsonObject;
                var readPlace = false;
                var dialog = new ContentDialog
                {
                    Title = L10n.Text("windows.handoff.title"),
                    Content = new ScrollViewer { Content = body, MaxHeight = 500 },
                    PrimaryButtonText = conflict ? L10n.Text("windows.handoff.share_mine") : pending is not null
                        ? L10n.Text("common.retry") : L10n.Text("windows.handoff.share"),
                    SecondaryButtonText = sharedDraft is null || _sending || _queueing ? null : L10n.Text("windows.handoff.use_draft"),
                    CloseButtonText = L10n.Text("common.close"), DefaultButton = ContentDialogButton.Close,
                };
                if (saved is not null)
                {
                    var shared = new StackPanel { Spacing = Theme.SpaceS };
                    if (sharedDraft is not null)
                    {
                        var text = Format.Text(sharedDraft, "text");
                        if (text.Length > 0) shared.Children.Add(HandoffText(text));
                        if (sharedDraft["attachmentIds"] is JsonArray { Count: > 0 } files)
                            shared.Children.Add(HandoffText(L10n.Text("windows.handoff.file_count", files.Count)));
                        if (_draft.Text.Length > 0 || _attachments.Count > 0)
                            shared.Children.Add(HandoffText(L10n.Text("windows.handoff.replaces")));
                    }
                    if (sharedAnchor is not null)
                        shared.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.handoff.continue_reading"), ActionIcon.History, (_, _) =>
                        {
                            readPlace = true;
                            dialog.Hide();
                        }));
                    body.Children.Add(Chrome.Card(L10n.Text("windows.handoff.from", Format.Text(saved, "deviceName")), shared));
                }
                var result = await Chrome.ShowDialog(this, dialog);
                if (!Current()) return;
                if (readPlace && sharedAnchor is not null)
                {
                    await ContinueReadingHandoffAsync(chat, sharedAnchor, Current);
                    return;
                }
                if (result == ContentDialogResult.None) return;
                try
                {
                    if (result == ContentDialogResult.Secondary && sharedDraft is not null)
                    {
                        await UseHandoffDraftAsync(chat, sharedDraft, Current);
                        return;
                    }
                    if (result != ContentDialogResult.Primary) return;
                    if (pending is null)
                    {
                        var anchor = CaptureHandoffAnchor();
                        var draft = include.IsChecked == true ? await PrepareHandoffDraftAsync(chat, Current) : null;
                        if (!Current()) return;
                        if (anchor is null && draft is null) throw new InvalidOperationException(L10n.Text("windows.handoff.empty"));
                        pending = new JsonObject { ["deviceName"] = deviceName, ["draft"] = draft, ["anchor"] = anchor };
                    }
                    if (conflict || pending["requestId"] is null)
                    {
                        pending["requestId"] = Guid.NewGuid().ToString("N");
                        pending["expectedRevision"] = Format.Long(saved, "revision");
                    }
                    conflict = false;
                    var target = HandoffTarget(chat);
                    target["handoff"] = pending.DeepClone();
                    var answer = await CallChatAsync("work.continuity.put", target);
                    if (!Current()) return;
                    if (Format.Text(answer, "status") == "saved")
                    {
                        _handoffSlot.Content = Chrome.Banner(L10n.Text("windows.handoff.shared"), Theme.Accent, Symbol.Accept);
                        return;
                    }
                    if (Format.Text(answer, "status") != "conflict") throw new InvalidDataException(L10n.Text("windows.handoff.unconfirmed"));
                    saved = answer["current"] as JsonObject;
                    conflict = true;
                    notice = L10n.Text("windows.handoff.conflict");
                }
                catch (OperationCanceledException) { if (!Current()) return; }
                catch (Exception error) { notice = FriendlyError.Display(error.Message); }
            }
        }
        catch (Exception error) { if (Current()) Banner(FriendlyError.Display(error.Message)); }
        finally { _handoffOpen = false; }
    }

    private static TextBlock HandoffText(string text) => new()
        { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };

    private async Task<JsonObject> PrepareHandoffDraftAsync(string chat, Func<bool> current)
    {
        if (_queueing || _sending || _fileTransfer is not null || _pickingAttachment || _dropImport is not null)
            throw new InvalidOperationException(L10n.Text("common.chat_files_busy"));
        var text = _draft.Text;
        if (Encoding.UTF8.GetByteCount(text) > 256 * 1024) throw new IOException(L10n.Text("windows.handoff.draft_too_large"));
        var files = _attachments.ToArray();
        var ids = new List<string>();
        _queueing = true;
        RebuildComposerActions();
        try
        {
            foreach (var staged in files)
            {
                if (!current()) throw new OperationCanceledException();
                var id = staged.Id;
                if (staged.LocalFile is { } local)
                {
                    if (!local.IsCurrent()) throw new IOException(L10n.Text("windows.handoff.files_unavailable"));
                    var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(local.Path);
                    if (!current()) throw new OperationCanceledException();
                    id = Format.Text(await UploadFileAsync(chat, file, current), "id");
                }
                if (id.Length == 0) throw new IOException(L10n.Text("windows.handoff.files_unavailable"));
                ids.Add(id);
            }
            return new JsonObject
            {
                ["text"] = text,
                ["attachmentIds"] = new JsonArray(ids.Distinct(StringComparer.Ordinal).Select(id => (JsonNode?)JsonValue.Create(id)).ToArray()),
            };
        }
        finally
        {
            _queueing = false;
            if (current()) RebuildComposerActions();
        }
    }

    private async Task UseHandoffDraftAsync(string chat, JsonObject shared, Func<bool> current)
    {
        var oldText = _draft.Text;
        var oldFiles = _attachments.ToArray();
        if (shared["attachmentIds"] is not JsonArray ids || ids.Count > NewChatFile.MaximumCount)
            throw new InvalidDataException(L10n.Text("windows.handoff.files_unavailable"));
        var target = HandoffTarget(chat);
        target["attachmentIds"] = ids.DeepClone();
        var metadata = Format.Items(await CallChatAsync("work.continuity.attachments", target));
        if (!current()) return;
        if (metadata is null || metadata.Count != ids.Count) throw new InvalidDataException(L10n.Text("windows.handoff.files_unavailable"));
        var files = new List<StagedFile>();
        for (var i = 0; i < ids.Count; i++)
        {
            var id = Format.Text(metadata[i], "id");
            var name = Format.Text(metadata[i], "name");
            if (id.Length == 0 || id != ids[i]?.ToString() || name.Length == 0)
                throw new InvalidDataException(L10n.Text("windows.handoff.files_unavailable"));
            files.Add(new StagedFile(id, name));
        }
        if (_queueing || _sending || _fileTransfer is not null || oldText != _draft.Text || !_attachments.SequenceEqual(oldFiles))
            throw new InvalidOperationException(L10n.Text("windows.handoff.draft_changed"));
        _attachments.Clear();
        _attachments.AddRange(files);
        _draft.Text = Format.Text(shared, "text");
        RememberDraft();
        foreach (var old in oldFiles) old.LocalFile?.Discard();
        _handoffSlot.Content = null;
        RebuildAttachStrip();
        RebuildComposerActions();
    }

    private List<DisplayItem> HandoffTranscript() =>
        ChatImageGallery.Compose(ChatDetailFold.Fold(Coalesce(_events), ChatDetailPreference.Level, _running, IsGroupOpen));

    private JsonObject? CaptureHandoffAnchor()
    {
        if (_scroll is not { } scroll) return null;
        var items = HandoffTranscript();
        if (_followEnd && _sliceOlder == 0)
        {
            var last = items.LastOrDefault(item => item.SourceSequence.HasValue);
            return last.SourceSequence is long latest ? Anchor(last, latest, 0, true) : null;
        }
        var stable = items.Where(item => item.SourceSequence.HasValue).ToDictionary(item => item.Id, StringComparer.Ordinal);
        for (var i = 0; i < _drawnRows.Count && i + _drawnPrefix < _transcript.Children.Count; i++)
        {
            if (!stable.TryGetValue(_drawnRows[i], out var item) || item.SourceSequence is not long seq
                || _transcript.Children[i + _drawnPrefix] is not FrameworkElement row) continue;
            var top = row.TransformToVisual(scroll).TransformPoint(new Windows.Foundation.Point(0, 0)).Y;
            var height = row.ActualHeight;
            if (height <= 0 || top + height <= 0) continue;
            if (top > scroll.ViewportHeight) break;
            return Anchor(item, seq, (int)Math.Clamp(-top / height * 10_000, 0, 10_000), false);
        }
        return null;

        static JsonObject Anchor(DisplayItem item, long seq, int fraction, bool latest) => new()
        {
            ["eventId"] = (item.Kind == ItemKind.User ? "user-s" : "text-s") + seq.ToString(CultureInfo.InvariantCulture),
            ["fraction"] = fraction, ["followsLatest"] = latest,
        };
    }

    private async Task ContinueReadingHandoffAsync(string chat, JsonObject anchor, Func<bool> current)
    {
        if (Format.Flag(anchor, "followsLatest")) { ResumeFollow(); return; }
        var eventId = Format.Text(anchor, "eventId");
        var suffix = eventId.LastIndexOf("-s", StringComparison.Ordinal);
        if (suffix < 0 || !long.TryParse(eventId.AsSpan(suffix + 2), NumberStyles.None, CultureInfo.InvariantCulture, out var seq))
            throw new InvalidDataException(L10n.Text("windows.handoff.place_unavailable"));
        var history = _historyGeneration;
        PauseFollow();
        while (current() && history == _historyGeneration)
        {
            var items = HandoffTranscript();
            var earliest = items.Where(item => item.SourceSequence.HasValue).Select(item => item.SourceSequence!.Value)
                .DefaultIfEmpty(long.MaxValue).Min();
            if (seq >= earliest || !_hasEarlier)
            {
                var match = items.FindLastIndex(item => item.SourceSequence is long candidate && candidate <= seq);
                if (match < 0 || _scroll is not { } scroll) break;
                _moving = true;
                try
                {
                    _sliceOlder = SliceClamp(items.Count - match - (SliceLength - 10), items.Count);
                    RebuildTranscript(full: true);
                    scroll.UpdateLayout();
                    var local = _drawnRows.IndexOf(items[match].Id);
                    if (local < 0 || _transcript.Children[local + _drawnPrefix] is not FrameworkElement row) break;
                    var top = row.TransformToVisual(scroll).TransformPoint(new Windows.Foundation.Point(0, 0)).Y;
                    var offset = row.ActualHeight * Math.Clamp(Format.Long(anchor, "fraction"), 0, 10_000) / 10_000d;
                    scroll.ChangeView(null, Math.Clamp(scroll.VerticalOffset + top + offset, 0, scroll.ScrollableHeight), null, true);
                    return;
                }
                finally { _moving = false; }
            }
            if (_historyLoading) throw new InvalidOperationException(L10n.Text("windows.handoff.history_busy"));
            var cursor = _historyCursor;
            _historyLoading = true;
            try
            {
                var page = await CallChatAsync("chat.eventPage", new JsonObject
                    { ["id"] = chat, ["cursor"] = cursor, ["limit"] = EarlierPageEvents, ["stablePositions"] = true });
                if (!current() || history != _historyGeneration) return;
                ApplyHistoryPage(page, replace: false);
                if (_hasEarlier && _historyCursor == cursor) break;
            }
            finally { if (current() && history == _historyGeneration) _historyLoading = false; }
        }
        if (current()) throw new InvalidOperationException(L10n.Text("windows.handoff.place_unavailable"));
    }
}
