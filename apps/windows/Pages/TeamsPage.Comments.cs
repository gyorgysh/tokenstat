// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal sealed partial class TeamsPage
{
    private static string CommentMessage(string key) => key switch
    {
        "comment_draft_changed" => L10n.Text("common.teams.comment_draft_changed"),
        "comment_check_first" => L10n.Text("common.teams.comment_check_first"),
        "comment_save_failed" => L10n.Text("common.teams.comment_save_failed"),
        "comment_too_long" => L10n.Text("common.teams.comment_too_long"),
        "comment_unconfirmed" => L10n.Text("common.teams.comment_unconfirmed"),
        "comment_posted" => L10n.Text("common.teams.comment_posted"),
        "comment_not_accepted" => L10n.Text("common.teams.comment_not_accepted"),
        "account_changed" => L10n.Text("common.teams.account_changed"),
        _ => L10n.Text("common.teams.comment_save_failed"),
    };
    private void AddDraftsButton()
    {
        var origin = Format.Text(_scope, "origin"); var person = _person;
        if (origin.Length == 0 || string.IsNullOrEmpty(person)) return;
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.comment_drafts"), ActionIcon.History,
            async (_, _) => await ShowDraftsAsync(origin, person)));
    }
    private async Task AddCommentComposerAsync(JsonObject target, string title, string computer, int view)
    {
        var checkout = target.DeepClone().AsObject(); checkout.Remove("share");
        var host = _checkoutHosts.GetValueOrDefault(checkout.ToJsonString());
        var origin = Format.Text(_scope, "origin"); var person = _person;
        if (string.IsNullOrEmpty(host) || origin.Length == 0 || string.IsNullOrEmpty(person)) { Note(L10n.Text("common.teams.comment_save_failed"), true); return; }
        var binding = new TeamCommentTarget(origin, person, Format.Text(target, "organization"), Format.Text(target, "repository"), Format.Text(target, "checkout"), Format.Text(target, "share"), host);
        if (!_comments.TryGetValue(binding, out var model))
        {
            var accountScope = _scope!.DeepClone(); var session = _session;
            // Capture the account once. A late storage completion cannot use
            // the next login's mutable page scope to send old writing.
            async Task<JsonNode> BoundCall(string method, JsonObject fields)
            {
                fields["_accountScope"] = accountScope.DeepClone();
                if (session is not null) fields["_accountSession"] = session;
                return await _call(method, fields);
            }
            static string Label(string text) => string.Concat(text.EnumerateRunes().Take(160).Select(r => System.Text.Rune.IsControl(r) ? " " : r.ToString()));
            _comments[binding] = model = new(TeamCommentDraftStore.Shared, binding, Label(title) + " · " + Label(computer), BoundCall);
        }
        await model.RestoreAsync();
        if (!IsLoaded || _view != view) return;
        _currentComment = model;
        var panel = new StackPanel { Spacing = Theme.SpaceS };
        var box = new TextBox { Text = model.Text, PlaceholderText = L10n.Text("common.teams.comment_placeholder"), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
        var note = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var recovered = new TextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        Button? send = null; Button? check = null;
        void Update()
        {
            if (!IsLoaded || _view != view) return;
            box.IsReadOnly = !model.Loaded || model.Busy || model.Pending || model.RecoveredText is not null;
            if (box.Text != model.Text) box.Text = model.Text;
            send!.IsEnabled = model.CanSend;
            var sendTitle = L10n.Text(model.Pending ? "common.teams.send_same_comment" : "common.teams.post_comment");
            ((StackPanel)send.Content).Children.OfType<TextBlock>().Last().Text = sendTitle;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(send, sendTitle);
            check!.Visibility = model.Pending ? Visibility.Visible : Visibility.Collapsed;
            check.IsEnabled = !model.Busy;
            var messages = new[] { model.Error, model.Status }.Where(s => s is not null).Select(s => CommentMessage(s!));
            note.Text = string.Join("\n", messages);
            if (model.TooLong) note.Text += "\n" + L10n.Text("common.teams.comment_too_long");
            recovered.Text = model.RecoveredText is null ? "" : L10n.Text("common.teams.unsaved_comment_copy") + "\n" + model.RecoveredText;
        }
        box.TextChanged += (_, _) => { if (_view == view && box.Text != model.Text) { model.Edit(box.Text); Update(); } };
        send = ActionIconGlyph.Button(L10n.Text("common.teams.post_comment"), ActionIcon.Comment, async (_, _) => {
            var action = model.SendAsync(); Update(); await action; Update();
            if (IsLoaded && _view == view && model.Status == "comment_posted" && !_readingEarlier) await ShowChatAsync(target, title, computer);
        });
        check = ActionIconGlyph.Button(L10n.Text("common.teams.check_delivery"), ActionIcon.Refresh, async (_, _) => {
            var action = model.CheckAsync(); Update(); await action; Update();
            if (IsLoaded && _view == view && model.Status == "comment_posted" && !_readingEarlier) await ShowChatAsync(target, title, computer);
        });
        panel.Children.Add(box); panel.Children.Add(note); panel.Children.Add(recovered);
        panel.Children.Add(send); panel.Children.Add(check);
        panel.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.copy_draft"), ActionIcon.Copy, (_, _) => CopyDraft(model.RecoveredText ?? model.Text)));
        panel.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.load_saved_draft"), ActionIcon.Refresh, async (_, _) => { var action = model.ReloadAsync(); Update(); await action; Update(); }));
        model.Changed = Update;
        _body.Children.Add(panel); Update();
    }
    private static void CopyDraft(string text)
    {
        var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(text);
        Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data);
    }
    private async Task ShowDraftsAsync(string origin, string person, string? after = null)
    {
        Reset(L10n.Text("common.teams.comment_drafts")); var view = _view;
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.back"), ActionIcon.Back, async (_, _) => await LoadAsync()));
        Note(L10n.Text("common.teams.comment_drafts_detail"));
        try
        {
            var page = await Task.Run(() => TeamCommentDraftStore.Shared.List(origin, person, after));
            if (!IsLoaded || _view != view) return;
            if (page.Unreadable) Note(L10n.Text("common.teams.comment_drafts_unreadable"), true);
            if (page.Entries.Count == 0) Note(L10n.Text("common.teams.no_comment_drafts"));
            foreach (var entry in page.Entries)
            {
                var panel = new StackPanel { Spacing = Theme.SpaceS, Padding = new Thickness(12), Background = Theme.ControlSeatBrush };
                var text = entry.Unsaved?.Text ?? entry.Draft?.Text ?? "";
                panel.Children.Add(new TextBlock { Text = entry.Unsaved?.Label ?? entry.Draft?.Label ?? L10n.Text("common.teams.saved_comment_draft"), TextWrapping = TextWrapping.Wrap });
                panel.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, MaxHeight = 240, IsTextSelectionEnabled = true });
                if (entry.Draft?.Attempt is not null) panel.Children.Add(new TextBlock { Text = L10n.Text("common.teams.comment_unconfirmed"), TextWrapping = TextWrapping.Wrap });
                panel.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.copy_draft"), ActionIcon.Copy, (_, _) => CopyDraft(text)));
                panel.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.remove_local_draft"), ActionIcon.Delete, async (_, _) => {
                    var confirm = new ContentDialog { XamlRoot = XamlRoot, Title = L10n.Text("common.teams.remove_local_draft"), Content = L10n.Text("common.teams.remove_local_draft_detail"), PrimaryButtonText = L10n.Text("common.teams.remove_draft"), CloseButtonText = L10n.Text("common.cancel") };
                    if (await confirm.ShowAsync() != ContentDialogResult.Primary || !IsLoaded || _view != view) return;
                    try { await Task.Run(() => TeamCommentDraftStore.Shared.Discard(entry)); await ShowDraftsAsync(origin, person, after); }
                    catch (Exception e) { if (IsLoaded && _view == view) Note(CommentMessage(e is TeamDraftException f ? f.Key : "comment_save_failed"), true); }
                }));
                _body.Children.Add(panel);
            }
            if (page.Next is not null) _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.load_more"), ActionIcon.Next, async (_, _) => await ShowDraftsAsync(origin, person, page.Next)));
        }
        catch { if (IsLoaded && _view == view) Note(L10n.Text("common.teams.comment_save_failed"), true); }
    }
}
