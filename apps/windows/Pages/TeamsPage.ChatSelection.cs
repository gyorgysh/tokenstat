// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using static Tokenstat.Pages.TeamManagementModel;

namespace Tokenstat.Pages;

internal sealed partial class TeamsPage
{
    private bool _canReviewChatSelection;
    private bool _canArchiveRepositories;
    private Task ShowTeamLocalChatsAsync(TeamPublisherModel publisher, JsonObject repository, JsonObject publication, Func<Task> back) =>
        _canReviewChatSelection ? ShowTeamChatSelectionAsync(publisher, repository, publication, back) : ShowTeamSingleChatsAsync(publisher, repository, publication, back);

    private async Task ShowTeamChatSelectionAsync(TeamPublisherModel publisher, JsonObject repository, JsonObject publication, Func<Task> back)
    {
        Reset(L10n.Text("common.teams.share_chat")); var view = _view;
        var model = new TeamChatSelectionModel(publisher, Text(publication, "id"));
        try { await model.LoadSaved(); if (model.Selection is null) await model.LoadOptions(); }
        catch (Exception error) {
            if (!IsLoaded || _view != view) return; Note(TeamError(error), true);
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => { if (IsLoaded && _view == view) await ShowTeamChatSelectionAsync(publisher, repository, publication, back); }));
            NavBack(L10n.Text("common.back"), async (_, _) => { if (IsLoaded && _view == view) await back(); }); return;
        }
        if (IsLoaded && _view == view) DrawChatSelection(publisher, repository, publication, back, model);
    }
    private void DrawChatSelection(TeamPublisherModel publisher, JsonObject repository, JsonObject publication, Func<Task> back, TeamChatSelectionModel model, string? error = null)
    {
        Reset(L10n.Text("common.teams.share_chat")); var view = _view;
        Task Draw() { DrawChatSelection(publisher, repository, publication, back, model); return Task.CompletedTask; }
        async Task Move(Func<Task> action) {
            if (!IsLoaded || _view != view) return; Reset(L10n.Text("common.teams.review_sharing")); var pending = _view; string? failure = null;
            try { await action(); }
            catch (Exception e) { failure = TeamError(e); try { await model.LoadSaved(); } catch { if (IsLoaded && _view == pending) { await ShowTeamChatSelectionAsync(publisher, repository, publication, back); return; } } }
            if (IsLoaded && _view == pending) DrawChatSelection(publisher, repository, publication, back, model, failure);
        }
        NavBack(L10n.Text("common.back"), async (_, _) => { if (IsLoaded && _view == view) await back(); });
        if (error is not null) Note(error, true);
        if (model.Selection is not { } selection)
        {
            Note(L10n.Text("common.teams.select_existing_chats"));
            var start = ActionIconGlyph.Button(L10n.Text("common.teams.review_selected_chats"), ActionIcon.Preview, async (_, _) => await Move(model.Begin));
            start.IsEnabled = model.Picked.Count > 0; start.SetValue(Microsoft.UI.Xaml.Automation.AutomationProperties.AutomationIdProperty, "team.chat.selection.begin");
            foreach (var chat in model.Options.Rows.Where(r => !Flag(r, "shared")))
            {
                var id = Text(chat, "id"); var check = new CheckBox { Content = Text(chat, "title"), IsChecked = model.Picked.Contains(id) };
                check.SetValue(Microsoft.UI.Xaml.Automation.AutomationProperties.AutomationIdProperty, "team.chat.selection.option." + id);
                check.Checked += (_, _) => { if (IsLoaded && _view == view) { if (model.Picked.Count >= 100 && !model.Picked.Contains(id)) check.IsChecked = false; else model.Choose(id, true); start.IsEnabled = model.Picked.Count > 0; } };
                check.Unchecked += (_, _) => { if (IsLoaded && _view == view) { model.Choose(id, false); start.IsEnabled = model.Picked.Count > 0; } };
                _body.Children.Add(check);
            }
            _body.Children.Add(start);
            if (model.Options.Next is not null) _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.load_more"), ActionIcon.More, async (_, _) => await Move(() => model.LoadOptions(true))));
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.manage_shared_chats"), ActionIcon.Settings, async (_, _) => { if (IsLoaded && _view == view) await ShowTeamSingleChatsAsync(publisher, repository, publication, back); }));
            return;
        }
        Note(Flag(selection, "complete") ? L10n.Text("common.teams.chat_review_finished") : L10n.Text("common.teams.saved_chat_selection"));
        foreach (var item in selection["items"]!.AsArray().OfType<JsonObject>())
        {
            var conversation = Text(item, "conversation"); var card = TeamCard(Text(item, "title") is { Length: > 0 } title ? title : L10n.Text("common.teams.shared_chat"), "");
            if (Flag(item, "shared") || Flag(item, "skipped")) card.Children.Add(TeamText(L10n.Text(Flag(item, "shared") ? "common.teams.chat_is_shared" : "common.teams.chat_kept_private")));
            else {
                var review = ActionIconGlyph.Button(L10n.Text("common.teams.review_sharing"), ActionIcon.Preview, async (_, _) => {
                    if (IsLoaded && _view == view) await ReviewSelectedTeamChatAsync(model, repository, conversation, Draw);
                }); review.IsEnabled = Flag(item, "available"); review.SetValue(Microsoft.UI.Xaml.Automation.AutomationProperties.AutomationIdProperty, "team.chat.selection.review." + conversation); card.Children.Add(review);
                card.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.keep_chat_private"), ActionIcon.Dismiss, (_, _) => {
                    if (!IsLoaded || _view != view) return;
                    TeamEditor(L10n.Text("common.teams.keep_chat_private"), TeamCard(L10n.Text("common.teams.keep_chat_private"), L10n.Text("common.teams.stop_chat_review_detail")), L10n.Text("common.teams.keep_chat_private"), () => true,
                        async () => { await model.Skip(conversation); return new JsonObject(); }, Draw, _ => Draw(), confirmation: true);
                }));
            }
            _body.Children.Add(card);
        }
        if (!Flag(selection, "complete")) _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.stop_chat_review"), ActionIcon.Dismiss, (_, _) => {
            if (!IsLoaded || _view != view) return;
            TeamEditor(L10n.Text("common.teams.stop_chat_review"), TeamCard(L10n.Text("common.teams.stop_chat_review"), L10n.Text("common.teams.stop_chat_review_detail")), L10n.Text("common.teams.stop_chat_review"), () => true,
                async () => { await model.Discard(); return new JsonObject(); }, Draw, _ => ShowTeamChatSelectionAsync(publisher, repository, publication, back), confirmation: true);
        }));
    }
    private async Task ReviewSelectedTeamChatAsync(TeamChatSelectionModel model, JsonObject repository, string conversation, Func<Task> back)
    {
        Reset(L10n.Text("common.teams.review_sharing")); var view = _view; var stage = "preview";
        try {
            var review = await model.Preview(conversation); if (!IsLoaded || _view != view) return;
            stage = "transcript";
            var fields = TeamCard(Text(review.Preview["history"], "title"), L10n.Text("common.teams.share_chat_audience", Text(repository, "name")));
            fields.Children.Add(TeamText(L10n.Text("common.teams.share_chat_contents")));
            fields.Children.Add(TeamText(L10n.Text("common.teams.history_preview")));
            if (Flag(review.Preview["history"], "historyTrimmed")) fields.Children.Add(TeamText(L10n.Text("common.teams.shared_history_trimmed")));
            foreach (var block in TeamTranscript.Project(review.Preview["history"]!["events"]!.AsArray().OfType<JsonObject>(), Text(review.Preview["history"], "backend"))) {
                if (block.Kind == TeamBlockKind.File) fields.Children.Add(TeamText(Text(block.File, "name")));
                else fields.Children.Add(TranscriptRow(new(), block));
            }
            stage = "consent";
            TeamEditor(L10n.Text("common.teams.share_chat"), fields, L10n.Text("common.teams.share_chat"), () => true,
                async () => { await model.Publish(review); return new JsonObject(); }, back, _ => back(), confirmation: true);
        } catch (Exception error) {
            if (Environment.GetEnvironmentVariable("TOKENSTAT_SCREEN_FIXTURE") is not null)
                Console.Error.WriteLine($"Team history fixture phase={stage}; type={error.GetType().Name}; HRESULT=0x{error.HResult:x8}");
            if (!IsLoaded || _view != view) return; Note(TeamError(error), true);
            NavBack(L10n.Text("common.back"), async (_, _) => { if (IsLoaded && _view == view) await back(); });
        }
    }
}
