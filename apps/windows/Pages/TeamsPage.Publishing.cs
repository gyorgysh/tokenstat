// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using static Tokenstat.Pages.TeamManagementModel;

namespace Tokenstat.Pages;

internal sealed partial class TeamsPage
{
    private async Task PublisherRowsAsync(string title, Func<int, Task<TeamDirectoryPage>> load, Action<JsonObject, int> add,
        Func<Task> back, TeamManagementRows? previous = null, Action<int>? header = null)
    {
        Reset(title); var view = _view; var rows = previous ?? new([]); string? error = null;
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.back"), ActionIcon.Back, async (_, _) => { if (IsLoaded && _view == view) await back(); }));
        try { var page = await load(previous?.Next ?? 0); rows = new(TeamCatalogPage.Append(rows.Rows, page.Rows), page.Next, true); }
        catch (Exception failure) { error = TeamError(failure); }
        if (!IsLoaded || _view != view) return;
        header?.Invoke(view); if (error is not null) Note(error, true);
        foreach (var row in rows.Rows) add(row, view);
        if (rows.Next is not null || error is not null) _body.Children.Add(ActionIconGlyph.Button(L10n.Text(error is null ? "common.teams.load_more" : "common.retry"), ActionIcon.More, async (_, _) => {
            if (IsLoaded && _view == view) await PublisherRowsAsync(title, load, add, back, rows.Next is not null ? rows : null, header);
        }));
    }
    private Task ShowTeamPublisherAsync(JsonObject repository)
    {
        var client = DirectoryClient(); var model = new TeamPublisherModel(client, repository);
        Task Reload() => ShowTeamPublisherAsync(repository);
        return PublisherRowsAsync(Text(repository, "name"), model.LocalCheckouts, (row, view) => {
            var card = TeamCard(Text(row, "workspaceId"), L10n.Text(Flag(row, "accountCleanupPending") ? "common.teams.cleanup_pending" : Text(row, "phase") == "active" ? "common.teams.checkout_shared" : "common.teams.publication_pending"));
            if (Text(row, "phase") == "active" && !Flag(row, "accountCleanupPending"))
            {
                card.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.share_chat"), ActionIcon.Comment, async (_, _) => { if (IsLoaded && _view == view) await ShowTeamLocalChatsAsync(model, repository, row, Reload); }));
                card.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.project_settings"), ActionIcon.Settings, async (_, _) => { if (IsLoaded && _view == view) await ShowTeamPublisherSettingsAsync(model, repository, row, Reload); }));
            }
            card.Children.Add(ActionIconGlyph.Button(L10n.Text(Flag(row, "accountCleanupPending") ? "common.teams.retry_cleanup" : "common.teams.stop_sharing"), ActionIcon.Revoke, (_, _) => {
                if (!IsLoaded || _view != view) return;
                TeamEditor(L10n.Text("common.teams.stop_sharing"), TeamCard(Text(repository, "name"), L10n.Text("common.teams.stop_sharing_detail") + "\n" + L10n.Text("common.teams.stop_sharing_files")), L10n.Text("common.teams.stop_sharing"), () => true,
                    () => model.WithdrawCheckout(row), Reload, async _ => { AppServices.NotifyTeamProjectsChanged(); await Reload(); }, confirmation: true);
            })); _body.Children.Add(card);
        }, LoadAsync, header: view => {
            Note(L10n.Text("common.teams.checkout_separate_detail")); Note(L10n.Text("common.teams.this_computer"));
            if (_canPublish && Text(repository, "role") is "contributor" or "maintainer")
                _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.share_checkout"), ActionIcon.Connect, async (_, _) => {
                    if (IsLoaded && _view == view) await ShowTeamCheckoutChoicesAsync(model, repository, Reload);
                }));
        });
    }
    private Task ShowTeamCheckoutChoicesAsync(TeamPublisherModel model, JsonObject repository, Func<Task> back) =>
        PublisherRowsAsync(L10n.Text("common.teams.choose_checkout"), model.CheckoutOptions, (workspace, view) => {
            var card = TeamCard(Text(workspace, "name"), Text(workspace, "path"));
            card.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.review_sharing"), ActionIcon.Preview, async (_, _) => {
                if (IsLoaded && _view == view) await ReviewTeamCheckoutAsync(model, repository, workspace, back);
            })); _body.Children.Add(card);
        }, back, header: _ => Note(L10n.Text("common.teams.choose_checkout_detail")));
    private async Task ReviewTeamCheckoutAsync(TeamPublisherModel model, JsonObject repository, JsonObject workspace, Func<Task> back)
    {
        Reset(L10n.Text("common.teams.review_sharing")); var view = _view;
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.cancel"), ActionIcon.Dismiss, async (_, _) => { if (IsLoaded && _view == view) await back(); }));
        try
        {
            var review = await model.PrepareCheckout(Text(workspace, "id"));
            if (!IsLoaded || _view != view) return;
            var fields = TeamCard(Text(repository, "name"), Text(review.Preview, "workspaceName"));
            fields.Children.Add(TeamText(Text(workspace, "path"))); fields.Children.Add(TeamText(L10n.Text("common.teams.checkout_share_detail")));
            fields.Children.Add(TeamText(L10n.Text("common.teams.checkout_share_exclusions")));
            TeamEditor(L10n.Text("common.teams.share_checkout"), fields, L10n.Text("common.teams.share_checkout"), () => true,
                () => model.PublishCheckout(review), back, async _ => { AppServices.NotifyTeamProjectsChanged(); await back(); }, confirmation: true);
        }
        catch (Exception error)
        {
            if (!IsLoaded || _view != view) return; Note(TeamError(error), true);
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => { if (IsLoaded && _view == view) await ReviewTeamCheckoutAsync(model, repository, workspace, back); }));
        }
    }
    private async Task ShowTeamSingleChatsAsync(TeamPublisherModel model, JsonObject repository, JsonObject publication, Func<Task> back,
        TeamManagementRows? priorOptions = null, TeamManagementRows? priorShares = null, bool moreOptions = false, bool moreShares = false)
    {
        var checkout = Text(publication, "id"); Reset(L10n.Text("common.teams.share_chat")); var view = _view;
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.back"), ActionIcon.Back, async (_, _) => { if (IsLoaded && _view == view) await back(); }));
        var options = priorOptions ?? new([]); var shares = priorShares ?? new([]); string? optionError = null; string? shareError = null;
        if (priorOptions is null || moreOptions) try { var page = await model.Chats(checkout, false, moreOptions ? options.Next ?? 0 : 0); options = new(TeamCatalogPage.Append(options.Rows, page.Rows), page.Next, true); } catch (Exception e) { optionError = TeamError(e); }
        if (!IsLoaded || _view != view) return;
        if (priorShares is null || moreShares) try { var page = await model.Chats(checkout, true, moreShares ? shares.Next ?? 0 : 0); shares = new(TeamCatalogPage.Append(shares.Rows, page.Rows), page.Next, true); } catch (Exception e) { shareError = TeamError(e); }
        if (!IsLoaded || _view != view) return;
        Task Reload() => ShowTeamSingleChatsAsync(model, repository, publication, back);
        Note(L10n.Text("common.teams.project_chats_private"));
        if (optionError is not null) Note(optionError, true); if (shareError is not null) Note(shareError, true);
        foreach (var chat in options.Rows.Where(row => !Flag(row, "shared")))
        {
            var card = TeamCard(Text(chat, "title"), BackendLabel(Text(chat, "backend")));
            card.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.review_sharing"), ActionIcon.Preview, async (_, _) => {
                if (IsLoaded && _view == view) await ReviewTeamChatAsync(model, repository, checkout, chat, Reload);
            })); _body.Children.Add(card);
        }
        if (options.Next is not null || optionError is not null) _body.Children.Add(ActionIconGlyph.Button(L10n.Text(optionError is null ? "common.teams.load_more" : "common.retry"), ActionIcon.More, async (_, _) => {
            if (IsLoaded && _view == view) await ShowTeamSingleChatsAsync(model, repository, publication, back, options.Next is not null ? options : null, shares, moreOptions: options.Next is not null);
        }));
        if (options.Loaded && options.Rows.Count == 0) Note(L10n.Text("common.teams.no_local_chats"));
        Note(L10n.Text("common.teams.your_shared_chats"));
        foreach (var share in shares.Rows)
        {
            var title = options.Rows.FirstOrDefault(row => Text(row, "id") == Text(share, "conversationId")) is { } chat ? Text(chat, "title") : L10n.Text("common.teams.shared_chat");
            var card = TeamCard(title, L10n.Text(Flag(share, "accountCleanupPending") ? "common.teams.cleanup_pending" : "common.teams.chat_is_shared"));
            card.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.stop_sharing"), ActionIcon.Revoke, (_, _) => {
                if (!IsLoaded || _view != view) return;
                TeamEditor(L10n.Text("common.teams.stop_sharing"), TeamCard(title, L10n.Text("common.teams.stop_chat_sharing_detail")), L10n.Text("common.teams.stop_sharing"), () => true,
                    () => model.WithdrawChat(checkout, share), Reload, _ => Reload(), confirmation: true);
            })); _body.Children.Add(card);
        }
        if (shares.Next is not null || shareError is not null) _body.Children.Add(ActionIconGlyph.Button(L10n.Text(shareError is null ? "common.teams.load_more" : "common.retry"), ActionIcon.More, async (_, _) => {
            if (IsLoaded && _view == view) await ShowTeamSingleChatsAsync(model, repository, publication, back, options, shares.Next is not null ? shares : null, moreShares: shares.Next is not null);
        }));
    }
    private async Task ReviewTeamChatAsync(TeamPublisherModel model, JsonObject repository, string checkout, JsonObject chat, Func<Task> back)
    {
        Reset(L10n.Text("common.teams.review_sharing")); var view = _view;
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.cancel"), ActionIcon.Dismiss, async (_, _) => { if (IsLoaded && _view == view) await back(); }));
        try
        {
            var review = await model.PrepareChat(checkout, Text(chat, "id"));
            if (!IsLoaded || _view != view) return;
            var fields = TeamCard(Text(chat, "title"), L10n.Text("common.teams.share_chat_audience", Text(repository, "name")));
            fields.Children.Add(TeamText(L10n.Text("common.teams.share_chat_contents"))); fields.Children.Add(TeamText(L10n.Text("common.teams.execution_separate")));
            fields.Children.Add(TeamText(L10n.Text("common.teams.history_preview")));
            var history = review.Preview["history"]!;
            if (Flag(history, "historyTrimmed")) fields.Children.Add(TeamText(L10n.Text("common.teams.shared_history_trimmed")));
            var events = history["events"]!.AsArray(); Require(events.All(row => row is JsonObject));
            foreach (var block in TeamTranscript.Project(events.OfType<JsonObject>(), Text(chat, "backend")))
            {
                // A private preview has no shared-file authority. Its file names
                // are reviewed here; fetching becomes available after sharing.
                if (block.Kind == TeamBlockKind.File) fields.Children.Add(TeamText(Text(block.File, "name")));
                else fields.Children.Add(TranscriptRow(model.Target(checkout), block));
            }
            TeamEditor(L10n.Text("common.teams.share_chat"), fields, L10n.Text("common.teams.share_chat"), () => true,
                () => model.PublishChat(review), back, _ => back(), confirmation: true);
        }
        catch (Exception error)
        {
            if (!IsLoaded || _view != view) return; Note(TeamError(error), true);
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => { if (IsLoaded && _view == view) await ReviewTeamChatAsync(model, repository, checkout, chat, back); }));
        }
    }
}
