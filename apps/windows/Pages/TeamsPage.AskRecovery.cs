// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Host;

namespace Tokenstat.Pages;

internal sealed partial class TeamsPage
{
    private async Task ShowSavedAsksAsync(string origin, string person)
    {
        if (Format.Text(_scope, "origin") != origin || _person != person) return;
        Reset(L10n.Text("common.teams.saved_asks"));
        var view = _view; var scope = _scope!.DeepClone(); var session = _session; var generation = AppServices.AccountGeneration;
        bool Current() => IsLoaded && _view == view && AppServices.AccountGeneration == generation
            && _scope?.ToJsonString() == scope.ToJsonString() && _session == session && _person == person;
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.back"), ActionIcon.Back, async (_, _) => { if (Current()) await LoadAsync(); }));
        Note(L10n.Text("common.teams.saved_asks_detail"));
        var rows = new StackPanel { Spacing = Theme.SpaceM }; _body.Children.Add(rows);
        var note = TeamText(""); _body.Children.Add(note);
        string? next = null; var busy = false; var loaded = false; var unreadable = false;
        var seen = new HashSet<TeamCommentTarget>();
        Button? more = null; Button? refresh = null;
        async Task Load(bool append)
        {
            if (!Current() || busy) return;
            busy = true; more!.IsEnabled = refresh!.IsEnabled = false; note.Text = "";
            try
            {
                var page = await Task.Run(() => _askStorage.List(origin, person, append ? next : null));
                if (!Current()) return;
                if (!append) { rows.Children.Clear(); seen.Clear(); unreadable = false; }
                foreach (var entry in page.Entries) if (seen.Add(entry.Target)) rows.Children.Add(SavedAskRow(entry, scope, session, Current));
                next = page.Next; unreadable |= page.Unreadable; loaded = true;
                if (unreadable) note.Text = L10n.Text("common.teams.saved_asks_unreadable");
                else if (seen.Count == 0 && next is null) note.Text = L10n.Text("common.teams.no_saved_asks");
            }
            catch { if (Current()) note.Text = L10n.Text("common.teams.saved_asks_unreadable"); }
            finally
            {
                busy = false;
                if (Current()) { refresh.IsEnabled = true; more.IsEnabled = true; more.Visibility = loaded && next is not null ? Visibility.Visible : Visibility.Collapsed; }
            }
        }
        refresh = ActionIconGlyph.Button(L10n.Text("common.refresh"), ActionIcon.Refresh, async (_, _) => await Load(false));
        more = ActionIconGlyph.Button(L10n.Text("common.teams.load_more"), ActionIcon.More, async (_, _) => await Load(true));
        _body.Children.Add(refresh); _body.Children.Add(more);
        await Load(false);
    }

    private UIElement SavedAskRow(TeamAskRecoveryStore.Entry entry, JsonNode scope, string? session, Func<bool> current)
    {
        var t = entry.Target; var target = Target(t.Organization, t.Repository, t.Checkout, t.Share);
        var panel = new StackPanel { Spacing = Theme.SpaceS };
        if (entry.Snapshot.Saved.Label.Length != 0) panel.Children.Add(TeamText(entry.Snapshot.Saved.Label));
        panel.Children.Add(new TextBlock { Text = entry.Snapshot.Record.Question, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        panel.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.copy_ask"), ActionIcon.Copy, (_, _) => {
            if (!current()) return;
            var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(entry.Snapshot.Record.Question);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data);
        }));
        async Task<JsonNode> Call(string method, JsonObject input)
        {
            if (!current()) throw new OperationCanceledException();
            if (method is not ("team.chat.ask" or "team.chat.ask.status" or "team.chat.ask.stop")) throw new OperationCanceledException();
            try
            {
                var reply = await _call("teams.ask", new JsonObject { ["target"] = target.DeepClone(), ["method"] = method,
                    ["params"] = input.DeepClone(), ["_accountScope"] = scope.DeepClone(), ["_accountSession"] = session });
                if (!current()) throw new OperationCanceledException();
                return reply;
            }
            catch (HostException failure) when (method == "team.chat.ask" && failure.Code is "team_run_review_changed" or "invalid_ask") { throw new TeamAskNotAccepted(failure.Message); }
        }
        var model = new TeamAskModel(_askStorage, t, entry.Snapshot.Saved.Label, current, Call);
        var actions = new StackPanel { Spacing = Theme.SpaceS }; var note = TeamText(""); actions.Children.Add(note);
        Button? recover = null;
        var retry = ActionIconGlyph.Button(L10n.Text("common.teams.retry_same_ask"), ActionIcon.Run, async (_, _) => { if (current() && model.Pending) await model.AskAsync(); });
        var check = ActionIconGlyph.Button(L10n.Text("common.refresh"), ActionIcon.Refresh, async (_, _) => await model.CheckAsync());
        var stop = ActionIconGlyph.Button(L10n.Text("common.teams.stop_agent"), ActionIcon.Stop, async (_, _) => await model.StopAsync());
        void Update()
        {
            if (!current()) return;
            note.Text = model.Error is { } error ? AskMessage(error, entry.Snapshot.Saved.Label) : model.Loaded && !model.Pending && model.Fence is null ? L10n.Text("common.teams.ask_resolved") : "";
            retry.Visibility = model.Pending ? Visibility.Visible : Visibility.Collapsed; retry.IsEnabled = model.CanAsk;
            check.Visibility = stop.Visibility = model.Fence is not null ? Visibility.Visible : Visibility.Collapsed;
            check.IsEnabled = !model.Busy; stop.IsEnabled = !model.Stopping;
            recover!.Visibility = model.Loaded ? Visibility.Collapsed : Visibility.Visible; recover.IsEnabled = !model.Busy;
        }
        recover = ActionIconGlyph.Button(L10n.Text("common.teams.recover_ask"), ActionIcon.Restore, async (_, _) => {
            if (!current()) return;
            actions.Visibility = Visibility.Visible; await model.RestoreAsync(true);
        });
        panel.Children.Add(recover); actions.Children.Add(retry); actions.Children.Add(check); actions.Children.Add(stop);
        actions.Visibility = Visibility.Collapsed; panel.Children.Add(actions); model.Changed = Update; Update();
        return panel;
    }
}
