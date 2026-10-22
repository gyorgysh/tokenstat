// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Host;

namespace Tokenstat.Pages;

/// <summary>
/// The member's side of Teams on Windows: set up Teams on this device, pick
/// an organization, and see each repository's computers with their work in
/// progress, with Land or Discard for kept work. Shared chats open read with
/// comments and Ask. Publishing a project and choosing how its work lands
/// happen on the computer that owns it, as on the other clients.
/// </summary>
internal sealed partial class TeamsPage : Page
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
    private TeamCommentModel? _currentComment;
    private bool CommentIdle => _currentComment is not { } comment || !comment.Busy && comment.Text.Length == 0 && comment.RecoveredText is null;
    private string? _person;
    private readonly Dictionary<TeamCommentTarget, TeamCommentModel> _comments = new();
    private readonly Dictionary<string, string> _checkoutHosts = new();
    private readonly Dictionary<string, string> _newChatWriting = new();
    private readonly Dictionary<string, (string Title, string Id)> _newChatRequests = new();
    private readonly Dictionary<string, JsonObject> _askAttempts = new();
    private readonly Dictionary<string, string> _askWriting = new();
    private readonly Dictionary<string, JsonNode> _activeRuns = new();
    private readonly HashSet<string> _stoppingRuns = new();
    private string? _historyTarget;
    private TeamHistoryWindow _history = new([]);
    private bool _readingEarlier;
    // Images opened in a chat, kept so the live refresh does not close them.
    private readonly Dictionary<string, Microsoft.UI.Xaml.Media.Imaging.BitmapImage> _openedImages = new();

    public TeamsPage()
    {
        Content = new ScrollViewer { Content = _body };
        Loaded += async (_, _) => await LoadAsync();
        Unloaded += (_, _) => _view++;
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
        _currentComment = null;
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
        var view = _view;
        try
        {
            var status = await AppServices.Host.CallAsync("account.status");
            if (!IsLoaded || _view != view) return;
            var scope = SshVaultScope.From(status);
            var session = Format.Text(status, "accountSession");
            if (_scope?.ToJsonString() != scope?.ToJsonString() || _session != session)
            {
                _organization = null;
                _comments.Clear(); _checkoutHosts.Clear(); _newChatWriting.Clear(); _newChatRequests.Clear(); _askAttempts.Clear(); _openedImages.Clear(); _flash = null;
                _askWriting.Clear(); _activeRuns.Clear(); _stoppingRuns.Clear();
                _historyTarget = null; _history = new([]); _readingEarlier = false;
            }
            _scope = scope; _session = session;
            _person = Format.Text(status, "accountId");
            if (_scope is null) { Note(L10n.Text("common.teams.load_failed"), true); return; }
            AddDraftsButton();
            var capabilities = await CallAsync("teams.capabilities");
            if (!IsLoaded || _view != view) return;
            if (!Format.Flag(capabilities, "enabled")) { Note(L10n.Text("common.teams.load_failed"), true); return; }
            if (!Format.Flag(capabilities, "ready")) { ShowAuthorize(); return; }
            var actor = Format.Text(capabilities, "actorId");
            if (actor.Length == 0 || !string.IsNullOrEmpty(_person) && _person != actor) throw new HostException("account_changed", L10n.Text("common.teams.account_changed"));
            _person = actor;
            var organizations = (await CallAsync("teams.directory", new JsonObject { ["operation"] = "organizations.list", ["page"] = Page100() }))["organizations"] as JsonArray;
            var rows = organizations?.OfType<JsonObject>().ToList() ?? [];
            if (!IsLoaded || _view != view) return;
            if (rows.Count == 0)
            {
                Note(L10n.Text("common.teams.no_organizations"));
                Note(L10n.Text("common.teams.no_organizations_detail"));
                return;
            }
            _organization = rows.FirstOrDefault(row => Format.Text(row, "id") == Format.Text(_organization, "id"))
                ?? (rows.Count == 1 ? rows[0] : null);
            if (_organization is null)
            {
                foreach (var org in rows)
                {
                    var chosen = org;
                    _body.Children.Add(ActionIconGlyph.Button(Format.Text(org, "name"), ActionIcon.Next, async (_, _) => { _organization = chosen; await LoadAsync(); }));
                }
                return;
            }
            Reset(Format.Text(_organization, "name"));
            AddDraftsButton();
            view = _view;
            await ShowRepositoriesAsync(_organization, rows.Count > 1);
        }
        catch (Exception error)
        {
            if (!IsLoaded || _view != view) return;
            Note(error.Message, true);
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => await LoadAsync()));
        }
    }

    private void ShowAuthorize()
    {
        var view = _view;
        Note(L10n.Text("common.teams.enable_title"));
        Note(L10n.Text("common.teams.device_consent_detail"));
        Note(L10n.Text("common.teams.metadata_disclosure"));
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.continue_browser"), ActionIcon.External, async (_, _) =>
        {
            try
            {
                var preview = await CallAsync("teams.authorizationPreview");
                if (!IsLoaded || _view != view) return;
                var prepared = await CallAsync("teams.prepareAuthorization", new JsonObject
                {
                    ["confirmMetadata"] = true,
                    ["expectedDeviceKey"] = Format.Text(preview, "deviceKey"),
                });
                var url = Format.Text(prepared, "authorizationURL");
                if (!IsLoaded || _view != view) return;
                if (Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme == "https")
                    await Windows.System.Launcher.LaunchUriAsync(uri);
            }
            catch (Exception error) { if (IsLoaded && _view == view) Note(error.Message, true); }
        }));
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.refresh"), ActionIcon.Refresh, async (_, _) => await LoadAsync()));
    }

    private async Task ShowRepositoriesAsync(JsonObject organization, bool canSwitch)
    {
        var orgId = Format.Text(organization, "id");
        var view = _view;
        if (_flash is { } flash) { _flash = null; Note(flash); }
        if (canSwitch)
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.organizations"), ActionIcon.Back, async (_, _) => { _organization = null; await LoadAsync(); }));
        var repositories = (await CallAsync("teams.directory", new JsonObject
        {
            ["operation"] = "repositories.list", ["organization"] = orgId, ["page"] = Page100(),
        }))["repositories"] as JsonArray;
        var rows = repositories?.OfType<JsonObject>().ToList() ?? [];
        if (!IsLoaded || _view != view) return;
        if (rows.Count == 0) { Note(L10n.Text("common.teams.no_repositories")); Note(L10n.Text("common.teams.no_repositories_member")); return; }
        foreach (var repo in rows)
        {
            if (_view != view) return;
            await AddRepositoryAsync(orgId, repo);
        }
    }

    private async Task AddRepositoryAsync(string orgId, JsonObject repo)
    {
        var view = _view;
        var repoId = Format.Text(repo, "id");
        var card = new StackPanel { Spacing = Theme.SpaceS, Padding = new Thickness(16), Background = Theme.PanelBrush, CornerRadius = new CornerRadius(10) };
        _body.Children.Add(card);
        List<JsonObject> checkouts = [];
        var lanes = new Dictionary<string, List<JsonObject>>();
        var shares = new Dictionary<string, List<JsonObject>>();
        var cursors = new Dictionary<string, string>();
        var failures = new Dictionary<string, string>();
        int? nextOffset = 0;
        var loading = false; var loaded = false; string? error = null;
        bool Current() => IsLoaded && _view == view;
        static string Message(Exception e) => e is InvalidDataException ? L10n.Text("common.teams.load_failed") : e.Message;
        async Task LoadCatalog(string checkout, bool more = false)
        {
            var cursor = more ? cursors.GetValueOrDefault(checkout) : null;
            var query = new JsonObject { ["limit"] = 50 };
            if (cursor is not null) query["cursor"] = cursor;
            var answer = await CallAsync("teams.connection.call", new JsonObject { ["target"] = Target(orgId, repoId, checkout), ["method"] = "team.chat.catalog", ["params"] = query });
            if (!Current()) return;
            var page = TeamCatalogPage.Read(answer, checkout, cursor);
            shares[checkout] = TeamCatalogPage.Append(more ? shares.GetValueOrDefault(checkout) ?? [] : [], page.Rows);
            cursors.Remove(checkout); if (page.Next is not null) cursors[checkout] = page.Next;
            failures.Remove(checkout);
        }
        async Task LoadWork(string id)
        {
            var work = await CallAsync("teams.connection.call", new JsonObject { ["target"] = Target(orgId, repoId, id), ["method"] = "team.lanes", ["params"] = new JsonObject() });
            if (!Current()) return;
            lanes[id] = (work["lanes"] as JsonArray)?.OfType<JsonObject>().ToList() ?? [];
            await LoadCatalog(id);
        }
        async Task LoadMore()
        {
            if (loading || nextOffset is null || !Current()) return;
            loading = true; Render();
            try
            {
                var offset = nextOffset.Value;
                var answer = await CallAsync("teams.directory", new JsonObject { ["operation"] = "checkouts.list", ["organization"] = orgId, ["repository"] = repoId, ["page"] = new JsonObject { ["limit"] = 3, ["offset"] = offset } });
                if (!Current()) return;
                var page = TeamDirectoryPage.Read(answer, "checkouts", offset);
                checkouts = TeamCatalogPage.Append(checkouts, page.Rows); nextOffset = page.Next; loaded = true; error = null;
                foreach (var checkout in page.Rows)
                {
                    var id = Format.Text(checkout, "id");
                    _checkoutHosts[Target(orgId, repoId, id).ToJsonString()] = Format.Text(checkout, "hostKey");
                    try
                    {
                        await LoadWork(id);
                    }
                    catch (Exception e) { if (!Current()) return; failures[id] = Message(e); }
                    if (!Current()) return;
                }
            }
            catch (Exception e) { if (Current()) error = Message(e); }
            finally { loading = false; if (Current()) Render(); }
        }
        void Render()
        {
            if (!Current()) return;
            card.Children.Clear();
            card.Children.Add(new TextBlock { Text = Format.Text(repo, "name"), FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            if (repo["role"] is null) { card.Children.Add(new TextBlock { Text = L10n.Text("common.teams.no_access"), Opacity = 0.7 }); return; }
            if (error is not null) card.Children.Add(new TextBlock { Text = error, TextWrapping = TextWrapping.Wrap });
            if (loaded && checkouts.Count == 0) card.Children.Add(new TextBlock { Text = L10n.Text("common.teams.repository_not_shared"), Opacity = 0.7 });
            if (loading) card.Children.Add(new ProgressRing { IsActive = true, Width = 20, Height = 20 });
            if (nextOffset is not null || failures.Count > 0) card.Children.Add(new TextBlock { Text = L10n.Text("common.teams.partial_lanes"), Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
            var all = lanes.Values.SelectMany(rows => rows).ToList();
            foreach (var checkout in checkouts)
            {
                var id = Format.Text(checkout, "id");
                var computer = Format.Text(checkout, "deviceName", L10n.Text("common.teams.computer"));
                card.Children.Add(new TextBlock { Text = computer, Opacity = 0.8, Margin = new Thickness(0, 6, 0, 0) });
                if (failures.TryGetValue(id, out var failure))
                {
                    card.Children.Add(new TextBlock { Text = failure, TextWrapping = TextWrapping.Wrap });
                    var retry = ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => {
                        loading = true; Render();
                        try { await LoadWork(id); } catch (Exception e) { if (Current()) failures[id] = Message(e); }
                        finally { loading = false; if (Current()) Render(); }
                    });
                    retry.IsEnabled = !loading; card.Children.Add(retry);
                }
                foreach (var lane in lanes.GetValueOrDefault(id) ?? []) card.Children.Add(LaneRow(orgId, repoId, id, lane, all));
                foreach (var share in shares.GetValueOrDefault(id) ?? [])
                {
                    var shareId = Format.Text(share, "id"); var title = Format.Text(share, "title");
                    if (title.Length == 0) title = L10n.Text("common.teams.shared_chat");
                    card.Children.Add(ActionIconGlyph.Button(title, ActionIcon.Comment, async (_, _) => await ShowChatAsync(Target(orgId, repoId, id, shareId), title, computer)));
                }
                if (cursors.ContainsKey(id))
                {
                    var more = ActionIconGlyph.Button(L10n.Text("common.teams.load_more"), ActionIcon.More, async (_, _) => {
                        loading = true; Render();
                        try { await LoadCatalog(id, true); } catch (Exception e) { if (Current()) failures[id] = Message(e); }
                        finally { loading = false; if (Current()) Render(); }
                    });
                    more.IsEnabled = !loading; card.Children.Add(more);
                }
                if (Format.Text(repo, "role") is "contributor" or "maintainer") card.Children.Add(NewChat(orgId, repoId, id, computer));
            }
            if (nextOffset is not null)
            {
                var more = ActionIconGlyph.Button(L10n.Text(loaded ? "common.teams.load_more_computers" : "common.retry"), ActionIcon.More, async (_, _) => await LoadMore());
                more.IsEnabled = !loading; card.Children.Add(more);
            }
        }
        Render();
        if (repo["role"] is not null) await LoadMore();
    }

    /// A member starts an empty shared chat on that computer and asks its
    /// agent there, without waiting for the owner to share one.
    private UIElement NewChat(string orgId, string repoId, string checkout, string computer)
    {
        var view = _view;
        var panel = new StackPanel { Spacing = Theme.SpaceXs, Margin = new Thickness(0, 4, 0, 0) };
        var box = new TextBox { Header = L10n.Text("common.teams.new_chat_title"), PlaceholderText = L10n.Text("common.teams.new_chat_placeholder") };
        var key = Target(orgId, repoId, checkout).ToJsonString();
        box.Text = _newChatWriting.GetValueOrDefault(key) ?? "";
        box.TextChanged += (_, _) => { if (_view == view) _newChatWriting[key] = box.Text; };
        Button? start = null;
        start = ActionIconGlyph.Button(L10n.Text("common.teams.new_chat"), ActionIcon.Create, async (_, _) =>
        {
            var title = box.Text.Trim();
            if (title.Length == 0) return;
            if (!_newChatRequests.TryGetValue(key, out var pending) || pending.Title != title) _newChatRequests[key] = pending = (title, "new-" + Guid.NewGuid().ToString("N"));
            start!.IsEnabled = false;
            try
            {
                var made = await CallAsync("teams.ask", new JsonObject
                {
                    ["target"] = Target(orgId, repoId, checkout), ["method"] = "team.chat.new",
                    ["params"] = new JsonObject { ["title"] = title, ["requestId"] = pending.Id },
                });
                var share = Format.Text(made, "share");
                if (!IsLoaded || _view != view) return;
                if (_newChatWriting.GetValueOrDefault(key)?.Trim() == title) _newChatWriting.Remove(key);
                if (_newChatRequests.GetValueOrDefault(key) == pending) _newChatRequests.Remove(key);
                if (share.Length > 0) await ShowChatAsync(Target(orgId, repoId, checkout, share), title, computer);
            }
            catch (Exception error)
            {
                if (!IsLoaded || _view != view) return;
                panel.Children.Add(new TextBlock { Text = error.Message, Foreground = Theme.Brush(static () => Theme.Warning), TextWrapping = TextWrapping.Wrap });
                start.IsEnabled = true;
            }
        });
        panel.Children.Add(box);
        panel.Children.Add(start);
        panel.Children.Add(new TextBlock { Text = L10n.Text("common.teams.new_chat_detail", computer), Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
        return panel;
    }

    private UIElement LaneRow(string orgId, string repoId, string checkout, JsonObject lane, List<JsonObject> all)
    {
        var view = _view;
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
                    if (!IsLoaded || _view != view) return;
                    var message = Format.Text(result, "message");
                    if (message.Length == 0 && Format.Flag(result, "discarded")) message = L10n.Text("common.teams.lane_discarded");
                    if (message.Length > 0) _flash = message;
                }
                catch (Exception error) { if (!IsLoaded || _view != view) return; _flash = error.Message; }
                await LoadAsync();
            }
            if (state == "ready") actions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.land"), ActionIcon.Merge, async (_, _) => await Act("team.lanes.land")));
            actions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.discard"), ActionIcon.Delete, async (_, _) => await Act("team.lanes.discard")));
            row.Children.Add(actions);
        }
        return row;
    }

    private async Task<bool> ShowChatAsync(JsonObject target, string title, string computer, string? earlierCursor = null)
    {
        Reset(title);
        var view = _view;
        var targetKey = target.ToJsonString();
        var previous = _historyTarget == targetKey ? _history : new TeamHistoryWindow([]);
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.back"), ActionIcon.Back, async (_, _) => await LoadAsync()));
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.refresh"), ActionIcon.Refresh, async (_, _) => await ShowChatAsync(target, title, computer)));
        JsonNode details, page;
        try
        {
            details = await CallAsync("teams.connection.call", new JsonObject { ["target"] = target.DeepClone(), ["method"] = "team.chat.details", ["params"] = new JsonObject() });
            if (!IsLoaded || _view != view) return false;
            var query = new JsonObject { ["direction"] = "older", ["limit"] = 100 };
            if (earlierCursor is not null) query["cursor"] = earlierCursor;
            page = await CallAsync("teams.connection.call", new JsonObject { ["target"] = target.DeepClone(), ["method"] = "team.chat.events", ["params"] = query });
            if (!IsLoaded || _view != view) return false;
            if (Format.Text(details["chat"], "id") != Format.Text(target, "share") || Format.Text(details["chat"], "checkoutId") != Format.Text(target, "checkout")
                || Format.Text(page, "shareId") != Format.Text(target, "share"))
                throw new HostException("invalid_response", L10n.Text("common.teams.history_cannot_display"));
            var incoming = (page["events"] as JsonArray)?.OfType<JsonObject>().ToList() ?? [];
            var next = Format.Text(page, "nextCursor");
            if (Format.Flag(page, "hasMore") && (incoming.Count == 0 || next.Length == 0 || next == earlierCursor))
                throw new HostException("invalid_response", L10n.Text("common.teams.history_cannot_display"));
            var window = await Task.Run(() => previous.Merge(incoming, earlierCursor is not null));
            if (!IsLoaded || _view != view) return false;
            _historyTarget = targetKey; _history = window; _readingEarlier = earlierCursor is not null;
        }
        catch (Exception error) { if (IsLoaded && _view == view) Note(error.Message, true); return false; }
        if (!IsLoaded || _view != view) return false;
        if (Format.Flag(page, "hasMore"))
        {
            var next = Format.Text(page, "nextCursor");
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.load_earlier"), ActionIcon.History,
                async (_, _) => await ShowChatAsync(target, title, computer, next)));
        }
        if (_history.Truncated) Note(L10n.Text("common.teams.shared_history_window"));
        foreach (var item in _history.Events)
        {
            if (Format.Text(item["event"], "kind") == "attachment")
            {
                _body.Children.Add(SharedFile(target, item["event"]!.AsObject()));
                continue;
            }
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
        if (Format.Flag(chat, "allowsComments")) await AddCommentComposerAsync(target, title, computer, view);
        if (!IsLoaded || _view != view) return false;
        if (_activeRuns.TryGetValue(targetKey, out var running))
        {
            var status = new TextBlock { Text = _stoppingRuns.Contains(targetKey) ? L10n.Text("common.teams.agent_stopping") : L10n.Text("common.teams.agent_working", computer), TextWrapping = TextWrapping.Wrap };
            _body.Children.Add(status);
            Button? stop = null;
            stop = ActionIconGlyph.Button(L10n.Text("common.teams.stop_agent"), ActionIcon.Stop, async (_, _) =>
            {
                stop!.IsEnabled = false; _stoppingRuns.Add(targetKey);
                status.Text = L10n.Text("common.teams.agent_stopping");
                try { await CallAsync("teams.ask", new JsonObject { ["target"] = target.DeepClone(), ["method"] = "team.chat.ask.stop", ["params"] = new JsonObject { ["fence"] = running.DeepClone() } }); }
                catch (Exception error)
                {
                    if (!IsLoaded || _view != view) return;
                    _stoppingRuns.Remove(targetKey); stop.IsEnabled = true; status.Text = error.Message;
                }
            });
            stop.IsEnabled = !_stoppingRuns.Contains(targetKey);
            _body.Children.Add(stop);
            _ = WatchAsync(target, running, title, computer, view, status, stop);
        }
        else if (Format.Flag(chat, "allowsAgentRuns"))
        {
            var ask = new TextBox { PlaceholderText = L10n.Text("common.teams.ask_placeholder"), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
            ask.Text = _askWriting.GetValueOrDefault(targetKey) ?? "";
            if (_askAttempts.TryGetValue(targetKey, out var pendingAsk)) { ask.Text = Format.Text(pendingAsk, "text"); ask.IsReadOnly = true; }
            ask.TextChanged += (_, _) => { if (_view == view) _askWriting[targetKey] = ask.Text; };
            _body.Children.Add(ask);
            Button? askButton = null;
            askButton = ActionIconGlyph.Button(L10n.Text("common.teams.ask"), ActionIcon.Run, async (_, _) =>
            {
                if (string.IsNullOrWhiteSpace(ask.Text)) return;
                askButton!.IsEnabled = false; ask.IsReadOnly = true;
                try
                {
                    if (!_askAttempts.TryGetValue(targetKey, out var attempt))
                    {
                        var review = await CallAsync("teams.ask", new JsonObject { ["target"] = target.DeepClone(), ["method"] = "team.chat.ask.review", ["params"] = new JsonObject() });
                        if (!IsLoaded || _view != view) return;
                        if (!Format.Flag(review, "agentRuns")) { Note(L10n.Text("common.teams.agent_runs_off", computer), true); return; }
                        _askAttempts[targetKey] = attempt = new JsonObject
                        {
                            ["text"] = ask.Text.Trim(), ["review"] = Format.Text(review, "review"),
                            ["clientMessageId"] = Guid.NewGuid().ToString(),
                            ["clientMessageCreatedAtMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                        };
                    }
                    var sent = await CallAsync("teams.ask", new JsonObject
                    {
                        ["target"] = target.DeepClone(), ["method"] = "team.chat.ask",
                        ["params"] = attempt.DeepClone(),
                    });
                    if (!IsLoaded || _view != view) return;
                    _askAttempts.Remove(targetKey);
                    _askWriting.Remove(targetKey);
                    if (Format.Text(sent, "state") == "running" && sent["fence"] is JsonNode fence) _activeRuns[targetKey] = fence.DeepClone();
                    await ShowChatAsync(target, title, computer);
                }
                catch (Exception error)
                {
                    if (!IsLoaded || _view != view) return;
                    if (error is HostException { Code: "team_run_review_changed" or "invalid_ask" }) _askAttempts.Remove(targetKey);
                    Note(error.Message, true);
                }
                finally
                {
                    askButton.IsEnabled = true;
                    ask.IsReadOnly = _askAttempts.ContainsKey(targetKey);
                }
            });
            _body.Children.Add(askButton);
            Note(L10n.Text("common.teams.ask_detail", computer));
        }
        if (!_readingEarlier && !_activeRuns.ContainsKey(targetKey)) _ = KeepCurrentAsync(target, title, computer, view, _body.Children.OfType<TextBox>().ToList());
        return true;
    }

    /// New comments and agent output appear while the chat is open. Stops
    /// when another screen is drawn, and waits while someone is typing.
    private async Task KeepCurrentAsync(JsonObject target, string title, string computer, int view, List<TextBox> inputs)
    {
        while (true)
        {
            await Task.Delay(10_000);
            if (!IsLoaded || _view != view) return;
            if (CommentIdle && inputs.All(box => box.Text.Length == 0))
            {
                await ShowChatAsync(target, title, computer);
                return;
            }
        }
    }

    /// A file the shared history shows. Images open inline on request. Nothing
    /// is handed to another app: the file comes from someone else's computer
    /// and its name comes from an agent's output.
    private UIElement SharedFile(JsonObject target, JsonObject file)
    {
        var panel = new StackPanel { Spacing = Theme.SpaceXs };
        var id = Format.Text(file, "id");
        var name = new string(Format.Text(file, "name").Where(c => !char.IsControl(c)
            && char.GetUnicodeCategory(c) != System.Globalization.UnicodeCategory.Format).ToArray());
        if (name.Length == 0) name = L10n.Text("common.teams.shared_file");
        panel.Children.Add(new TextBlock { Text = name, TextTrimming = TextTrimming.CharacterEllipsis });
        var key = Format.Text(target, "share") + "/" + id;
        if (_openedImages.TryGetValue(key, out var opened))
        {
            panel.Children.Add(new Image { Source = opened, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left });
            return panel;
        }
        Button? open = null;
        open = ActionIconGlyph.Button(L10n.Text("common.teams.open_file_action"), ActionIcon.Download, async (_, _) =>
        {
            open!.IsEnabled = false;
            try
            {
                var reply = await CallAsync("teams.connection.call", new JsonObject
                {
                    ["target"] = target.DeepClone(), ["method"] = "team.chat.attachment", ["params"] = new JsonObject { ["attachment"] = id },
                });
                var media = Format.Text(reply["attachment"], "mediaType");
                if (media.StartsWith("image/", StringComparison.Ordinal) && media != "image/svg+xml")
                {
                    var data = Format.Text(reply, "data");
                    if (data.Length > 8 * 1024 * 1024) throw new InvalidOperationException(L10n.Text("common.teams.file_unavailable"));
                    var bytes = await Task.Run(() => Convert.FromBase64String(data));
                    using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
                    await stream.WriteAsync(bytes.AsBuffer());
                    stream.Seek(0);
                    // A small file can still describe a huge bitmap. Read its
                    // real size first, refuse extremes, and only scale down.
                    var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);
                    uint width = decoder.PixelWidth, height = decoder.PixelHeight;
                    if (width == 0 || height == 0 || (ulong)width * height > 100_000_000UL || Math.Max(width, height) / Math.Min(width, height) > 50)
                        throw new InvalidOperationException(L10n.Text("common.teams.file_unavailable"));
                    stream.Seek(0);
                    var bitmap = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage();
                    if (width >= height) bitmap.DecodePixelWidth = (int)Math.Min(width, 2048u);
                    else bitmap.DecodePixelHeight = (int)Math.Min(height, 2048u);
                    await bitmap.SetSourceAsync(stream);
                    if (_openedImages.Count >= 16) _openedImages.Clear();
                    _openedImages[key] = bitmap;
                    panel.Children.Remove(open);
                    panel.Children.Add(new Image { Source = bitmap, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left });
                }
                else
                {
                    panel.Children.Add(new TextBlock { Text = L10n.Text("common.teams.file_on_computer"), Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
                }
            }
            catch (Exception error)
            {
                panel.Children.Add(new TextBlock { Text = error.Message, Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
                open.IsEnabled = true;
            }
        });
        panel.Children.Add(open);
        return panel;
    }

    /// Refresh while the agent works, with Stop, until the host says it ended.
    private async Task WatchAsync(JsonObject target, JsonNode fence, string title, string computer, int view, TextBlock status, Button stop)
    {
        var key = target.ToJsonString();
        while (true)
        {
            await Task.Delay(3000);
            if (!IsLoaded || _view != view) return;
            try
            {
                var reply = await CallAsync("teams.ask", new JsonObject { ["target"] = target.DeepClone(), ["method"] = "team.chat.ask.status", ["params"] = new JsonObject { ["fence"] = fence.DeepClone() } });
                if (!IsLoaded || _view != view) return;
                if (!Format.Flag(reply, "running"))
                {
                    _activeRuns.Remove(key); _stoppingRuns.Remove(key);
                    if (_readingEarlier) { status.Text = L10n.Text("common.done"); stop.IsEnabled = false; return; }
                    await ShowChatAsync(target, title, computer);
                    return;
                }
                status.Text = _stoppingRuns.Contains(key) ? L10n.Text("common.teams.agent_stopping") : L10n.Text("common.teams.agent_working", computer);
                // Paging back and writing both keep the mounted controls. A
                // status check never throws away the reader's place or text.
                if (!_readingEarlier && CommentIdle && _body.Children.OfType<TextBox>().All(box => box.Text.Length == 0))
                {
                    await ShowChatAsync(target, title, computer);
                    return;
                }
            }
            catch (Exception error)
            {
                if (!IsLoaded || _view != view) return;
                if (error is HostException failure && failure.Code is not ("team_connection_unavailable" or "teams_unreachable" or "teams_busy" or "host_timeout" or "host_unavailable"))
                {
                    _activeRuns.Remove(key); _stoppingRuns.Remove(key);
                    await ShowChatAsync(target, title, computer);
                    return;
                }
                status.Text = error.Message;
            }
        }
    }
}
