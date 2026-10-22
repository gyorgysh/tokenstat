// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>
/// The member's side of Teams on Windows: set up Teams on this device, pick
/// an organization, and see each repository's computers with their work in
/// progress, with Land or Discard for kept work. Shared chats open read with
/// comments and Ask. Publishing a project and choosing how its work lands
/// happen on the computer that owns it, as on the other clients.
/// </summary>
internal sealed class TeamsPage : Page
{
    private readonly StackPanel _body = new() { Spacing = Theme.SpaceM, Padding = new Thickness(24), MaxWidth = 900, HorizontalAlignment = HorizontalAlignment.Left };
    private JsonObject? _scope;
    private string? _session;
    private JsonObject? _organization;
    // Bumped by every redraw, so a load or a watch that outlived its screen
    // stops instead of drawing over the one now shown.
    private int _view;
    // A result to show once the reload after Land or Discard has drawn.
    private string? _flash;
    // One id per comment text: a retry after an unknown result is the same
    // message, so the host keeps one copy.
    private (string Text, string Id, long CreatedAtMs)? _commentAttempt;

    public TeamsPage()
    {
        Content = new ScrollViewer { Content = _body };
        Loaded += async (_, _) => await LoadAsync();
    }

    /// Every Team call carries the signed-in account's receipt. The host drops
    /// a call when that login is no longer the one it was made for.
    private async Task<JsonNode> CallAsync(string method, JsonObject? fields = null)
    {
        var body = fields?.DeepClone() as JsonObject ?? new JsonObject();
        body["_accountScope"] = _scope?.DeepClone();
        if (_session is not null) body["_accountSession"] = _session;
        return await AppServices.Host.CallAsync(method, body);
    }

    private static JsonObject Page100() => new() { ["limit"] = 100, ["offset"] = 0 };

    private static JsonObject Target(string org, string repo, string checkout, string? share = null)
    {
        var target = new JsonObject { ["organization"] = org, ["repository"] = repo, ["checkout"] = checkout };
        if (share is not null) target["share"] = share;
        return target;
    }

    private void Reset(string title)
    {
        _view++;
        _body.Children.Clear();
        _body.Children.Add(new TextBlock { Text = title, FontSize = 22, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
    }

    private void Note(string text, bool warning = false) => _body.Children.Add(new TextBlock
    {
        Text = text, TextWrapping = TextWrapping.Wrap, Opacity = warning ? 1 : 0.75,
        Foreground = warning ? Theme.Brush(static () => Theme.Warning) : null,
    });

    private async Task LoadAsync()
    {
        Reset(L10n.Text("common.teams.title"));
        try
        {
            var status = await AppServices.Host.CallAsync("account.status");
            _scope = SshVaultScope.From(status);
            _session = Format.Text(status, "accountSession");
            if (_scope is null) { Note(L10n.Text("common.teams.load_failed"), true); return; }
            var capabilities = await CallAsync("teams.capabilities");
            if (!Format.Flag(capabilities, "enabled")) { Note(L10n.Text("common.teams.load_failed"), true); return; }
            if (!Format.Flag(capabilities, "ready")) { ShowAuthorize(); return; }
            var organizations = (await CallAsync("teams.directory", new JsonObject { ["operation"] = "organizations.list", ["page"] = Page100() }))["organizations"] as JsonArray;
            var rows = organizations?.OfType<JsonObject>().ToList() ?? [];
            if (rows.Count == 0)
            {
                Note(L10n.Text("common.teams.no_organizations"));
                Note(L10n.Text("common.teams.no_organizations_detail"));
                return;
            }
            _organization ??= rows.Count == 1 ? rows[0] : null;
            if (_organization is null)
            {
                foreach (var org in rows)
                {
                    var chosen = org;
                    _body.Children.Add(ActionIconGlyph.Button(Format.Text(org, "name"), ActionIcon.Next, async (_, _) => { _organization = chosen; await LoadAsync(); }));
                }
                return;
            }
            await ShowRepositoriesAsync(_organization, rows.Count > 1);
        }
        catch (Exception error)
        {
            Note(error.Message, true);
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => await LoadAsync()));
        }
    }

    private void ShowAuthorize()
    {
        Note(L10n.Text("common.teams.enable_title"));
        Note(L10n.Text("common.teams.device_consent_detail"));
        Note(L10n.Text("common.teams.metadata_disclosure"));
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.continue_browser"), ActionIcon.External, async (_, _) =>
        {
            try
            {
                var preview = await CallAsync("teams.authorizationPreview");
                var prepared = await CallAsync("teams.prepareAuthorization", new JsonObject
                {
                    ["confirmMetadata"] = true,
                    ["expectedDeviceKey"] = Format.Text(preview, "deviceKey"),
                });
                var url = Format.Text(prepared, "authorizationURL");
                if (Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme == "https")
                    await Windows.System.Launcher.LaunchUriAsync(uri);
            }
            catch (Exception error) { Note(error.Message, true); }
        }));
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.refresh"), ActionIcon.Refresh, async (_, _) => await LoadAsync()));
    }

    private async Task ShowRepositoriesAsync(JsonObject organization, bool canSwitch)
    {
        var orgId = Format.Text(organization, "id");
        Reset(Format.Text(organization, "name"));
        var view = _view;
        if (_flash is { } flash) { _flash = null; Note(flash); }
        if (canSwitch)
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.organizations"), ActionIcon.Back, async (_, _) => { _organization = null; await LoadAsync(); }));
        var repositories = (await CallAsync("teams.directory", new JsonObject
        {
            ["operation"] = "repositories.list", ["organization"] = orgId, ["page"] = Page100(),
        }))["repositories"] as JsonArray;
        var rows = repositories?.OfType<JsonObject>().ToList() ?? [];
        if (rows.Count == 0) { Note(L10n.Text("common.teams.no_repositories")); Note(L10n.Text("common.teams.no_repositories_member")); return; }
        foreach (var repo in rows)
        {
            if (_view != view) return;
            await AddRepositoryAsync(orgId, repo);
        }
    }

    private async Task AddRepositoryAsync(string orgId, JsonObject repo)
    {
        var repoId = Format.Text(repo, "id");
        var card = new StackPanel { Spacing = Theme.SpaceS, Padding = new Thickness(16), Background = Theme.PanelBrush, CornerRadius = new CornerRadius(10) };
        card.Children.Add(new TextBlock { Text = Format.Text(repo, "name"), FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        _body.Children.Add(card);
        if (repo["role"] is null) { card.Children.Add(new TextBlock { Text = L10n.Text("common.teams.no_access"), Opacity = 0.7 }); return; }
        List<JsonObject> checkouts;
        try
        {
            checkouts = ((await CallAsync("teams.directory", new JsonObject
            {
                ["operation"] = "checkouts.list", ["organization"] = orgId, ["repository"] = repoId, ["page"] = Page100(),
            }))["checkouts"] as JsonArray)?.OfType<JsonObject>().Take(3).ToList() ?? [];
        }
        catch { checkouts = []; }
        if (checkouts.Count == 0) { card.Children.Add(new TextBlock { Text = L10n.Text("common.teams.repository_not_shared"), Opacity = 0.7 }); return; }
        // Each computer answers for its own lanes and chats. One that is
        // offline shows nothing rather than an error here.
        var lanes = new Dictionary<string, List<JsonObject>>();
        var shares = new Dictionary<string, List<JsonObject>>();
        foreach (var checkout in checkouts)
        {
            var id = Format.Text(checkout, "id");
            try
            {
                var answer = await CallAsync("teams.connection.call", new JsonObject { ["target"] = Target(orgId, repoId, id), ["method"] = "team.lanes", ["params"] = new JsonObject() });
                lanes[id] = (answer["lanes"] as JsonArray)?.OfType<JsonObject>().ToList() ?? [];
            }
            catch { lanes[id] = []; }
            try
            {
                var answer = await CallAsync("teams.connection.call", new JsonObject { ["target"] = Target(orgId, repoId, id), ["method"] = "team.chat.catalog", ["params"] = new JsonObject { ["limit"] = 50 } });
                shares[id] = (answer["shares"] as JsonArray)?.OfType<JsonObject>().ToList() ?? [];
            }
            catch { shares[id] = []; }
        }
        var all = lanes.Values.SelectMany(list => list).ToList();
        foreach (var checkout in checkouts)
        {
            var id = Format.Text(checkout, "id");
            var computer = Format.Text(checkout, "deviceName", L10n.Text("common.teams.computer"));
            card.Children.Add(new TextBlock { Text = computer, Opacity = 0.8, Margin = new Thickness(0, 6, 0, 0) });
            foreach (var lane in lanes[id]) card.Children.Add(LaneRow(orgId, repoId, id, lane, all));
            foreach (var share in shares[id])
            {
                var shareId = Format.Text(share, "id");
                var title = Format.Text(share, "title");
                if (title.Length == 0) title = L10n.Text("common.teams.shared_chat");
                var chosen = (Target(orgId, repoId, id, shareId), title, computer);
                card.Children.Add(ActionIconGlyph.Button(title, ActionIcon.Comment, async (_, _) => await ShowChatAsync(chosen.Item1, chosen.title, chosen.computer)));
            }
        }
    }

    private UIElement LaneRow(string orgId, string repoId, string checkout, JsonObject lane, List<JsonObject> all)
    {
        var row = new StackPanel { Spacing = Theme.SpaceXs, Padding = new Thickness(10), Background = Theme.ControlSeatBrush, CornerRadius = new CornerRadius(8) };
        var state = Format.Text(lane, "state");
        var asker = Format.Text(lane["askedBy"], "name");
        var files = (lane["files"] as JsonArray)?.Select(f => f?.ToString() ?? "").ToHashSet() ?? [];
        var ask = Format.Text(lane, "ask");
        row.Children.Add(new TextBlock { Text = ask.Length > 0 ? ask : Format.Text(lane, "branch"), TextWrapping = TextWrapping.Wrap });
        var detail = state switch
        {
            "running" => L10n.Text("common.teams.lane_running", asker, files.Count.ToString()),
            "ready" => L10n.Text("common.teams.lane_ready", asker, files.Count.ToString()),
            _ => L10n.Text("common.teams.lane_kept", asker, files.Count.ToString()),
        };
        row.Children.Add(new TextBlock { Text = detail, Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
        // Compared across every computer's lanes, as on the Mac and Android.
        var overlapping = all.Where(other => Format.Text(other, "branch") != Format.Text(lane, "branch")
                && ((other["files"] as JsonArray)?.Any(f => files.Contains(f?.ToString() ?? "")) ?? false))
            .Select(other => Format.Text(other, "ask") is { Length: > 0 } text ? text : Format.Text(other, "branch")).ToList();
        if (overlapping.Count > 0)
            row.Children.Add(new TextBlock { Text = L10n.Text("common.teams.lane_overlap", string.Join(", ", overlapping)), Foreground = Theme.Brush(static () => Theme.Warning), TextWrapping = TextWrapping.Wrap });
        var share = Format.Text(lane, "share");
        if (state != "running" && share.Length > 0)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            var where = Target(orgId, repoId, checkout, share);
            var branch = Format.Text(lane, "branch");
            async Task Act(string method)
            {
                try
                {
                    var result = await CallAsync("teams.ask", new JsonObject { ["target"] = where.DeepClone(), ["method"] = method, ["params"] = new JsonObject { ["branch"] = branch } });
                    var message = Format.Text(result, "message");
                    if (message.Length == 0 && Format.Flag(result, "discarded")) message = L10n.Text("common.teams.lane_discarded");
                    if (message.Length > 0) _flash = message;
                }
                catch (Exception error) { _flash = error.Message; }
                await LoadAsync();
            }
            if (state == "ready") actions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.land"), ActionIcon.Merge, async (_, _) => await Act("team.lanes.land")));
            actions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.discard"), ActionIcon.Delete, async (_, _) => await Act("team.lanes.discard")));
            row.Children.Add(actions);
        }
        return row;
    }

    private async Task ShowChatAsync(JsonObject target, string title, string computer)
    {
        Reset(title);
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.back"), ActionIcon.Back, async (_, _) => await LoadAsync()));
        JsonNode details, page;
        try
        {
            details = await CallAsync("teams.connection.call", new JsonObject { ["target"] = target.DeepClone(), ["method"] = "team.chat.details", ["params"] = new JsonObject() });
            page = await CallAsync("teams.connection.call", new JsonObject { ["target"] = target.DeepClone(), ["method"] = "team.chat.events", ["params"] = new JsonObject { ["direction"] = "older", ["limit"] = 100 } });
        }
        catch (Exception error) { Note(error.Message, true); return; }
        foreach (var item in (page["events"] as JsonArray)?.OfType<JsonObject>() ?? [])
        {
            var text = Format.Text(item, "text");
            if (text.Length == 0) text = Format.Text(item["event"], "delta");
            if (text.Length == 0) continue;
            var author = Format.Text(item["author"], "kind") == "formerMember"
                ? L10n.Text("common.teams.former_member")
                : Format.Text(item["author"], "name");
            if (author.Length == 0) author = Format.Text(item, "kind");
            _body.Children.Add(new TextBlock { Text = author, Opacity = 0.6, FontSize = 12 });
            _body.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        }
        var chat = details["chat"];
        if (Format.Flag(chat, "allowsComments"))
        {
            var box = new TextBox { PlaceholderText = L10n.Text("common.teams.comment_placeholder"), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
            _body.Children.Add(box);
            Button? send = null;
            send = ActionIconGlyph.Button(L10n.Text("common.teams.comment"), ActionIcon.Comment, async (_, _) =>
            {
                var text = box.Text.Trim();
                if (text.Length == 0) return;
                if (_commentAttempt is not { } attempt || attempt.Text != text)
                    _commentAttempt = attempt = (text, Guid.NewGuid().ToString(), DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                send!.IsEnabled = false;
                try
                {
                    await CallAsync("teams.comment.send", new JsonObject
                    {
                        ["target"] = target.DeepClone(),
                        ["input"] = new JsonObject
                        {
                            ["text"] = text, ["clientMessageId"] = attempt.Id, ["clientMessageCreatedAtMs"] = attempt.CreatedAtMs,
                        },
                    });
                    _commentAttempt = null;
                    await ShowChatAsync(target, title, computer);
                }
                catch (Exception error) { Note(error.Message, true); send.IsEnabled = true; }
            });
            _body.Children.Add(send);
        }
        if (Format.Flag(chat, "allowsAgentRuns"))
        {
            var ask = new TextBox { PlaceholderText = L10n.Text("common.teams.ask_placeholder"), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
            _body.Children.Add(ask);
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.ask"), ActionIcon.Run, async (_, _) =>
            {
                if (string.IsNullOrWhiteSpace(ask.Text)) return;
                try
                {
                    var review = await CallAsync("teams.ask", new JsonObject { ["target"] = target.DeepClone(), ["method"] = "team.chat.ask.review", ["params"] = new JsonObject() });
                    if (!Format.Flag(review, "agentRuns")) { Note(L10n.Text("common.teams.agent_runs_off", computer), true); return; }
                    var sent = await CallAsync("teams.ask", new JsonObject
                    {
                        ["target"] = target.DeepClone(), ["method"] = "team.chat.ask",
                        ["params"] = new JsonObject
                        {
                            ["text"] = ask.Text.Trim(), ["review"] = Format.Text(review, "review"),
                            ["clientMessageId"] = Guid.NewGuid().ToString(),
                            ["clientMessageCreatedAtMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                        },
                    });
                    if (Format.Text(sent, "state") == "running" && sent["fence"] is JsonNode fence) await WatchAsync(target, fence, title, computer);
                    else await ShowChatAsync(target, title, computer);
                }
                catch (Exception error) { Note(error.Message, true); }
            }));
            Note(L10n.Text("common.teams.ask_detail", computer));
        }
    }

    /// Refresh while the agent works, with Stop, until the host says it ended.
    private async Task WatchAsync(JsonObject target, JsonNode fence, string title, string computer)
    {
        var stopping = false;
        while (true)
        {
            await ShowChatAsync(target, title, computer);
            Note(stopping ? L10n.Text("common.teams.agent_stopping") : L10n.Text("common.teams.agent_working", computer));
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.stop_agent"), ActionIcon.Stop, async (_, _) =>
            {
                stopping = true;
                try { await CallAsync("teams.ask", new JsonObject { ["target"] = target.DeepClone(), ["method"] = "team.chat.ask.stop", ["params"] = new JsonObject { ["fence"] = fence.DeepClone() } }); }
                catch (Exception error) { Note(error.Message, true); }
            }));
            var view = _view;
            await Task.Delay(3000);
            if (!IsLoaded || _view != view) return;
            try
            {
                var status = await CallAsync("teams.ask", new JsonObject { ["target"] = target.DeepClone(), ["method"] = "team.chat.ask.status", ["params"] = new JsonObject { ["fence"] = fence.DeepClone() } });
                if (!Format.Flag(status, "running")) break;
            }
            catch { break; }
        }
        await ShowChatAsync(target, title, computer);
    }
}
