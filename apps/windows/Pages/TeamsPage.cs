// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;
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
    private readonly StackPanel _body = new() { Spacing = Theme.SpaceM };
    private readonly Func<string, JsonObject?, Task<JsonNode>> _call;
    private JsonObject? _scope;
    private string? _session;
    private JsonObject? _organization;
    private List<JsonObject> _organizations = [];
    private int? _organizationsNext;
    // Bumped by every redraw, so a load or a watch that outlived its screen
    // stops instead of drawing over the one now shown.
    private int _view;
    private int _attachmentRevision;
    // Which side of the shared chat composer was last used: comment or ask.
    private string _composerMode = "comment";
    private bool _attached;
    // A result to show once the reload after Land or Discard has drawn.
    private string? _flash;
    private TeamCommentModel? _currentComment;
    private bool CommentIdle => _fileOperations == 0 && (_currentComment is not { } comment || !comment.Busy && comment.Text.Length == 0 && comment.RecoveredText is null);
    private string? _person;
    private bool _canPublish;
    private JsonObject? _folderShareRequest;
    private JsonObject? _initialProject;
    private bool _startSharedProjects;
    private readonly Dictionary<TeamCommentTarget, TeamCommentModel> _comments = new();
    private readonly Dictionary<string, string> _checkoutHosts = new();
    private readonly Dictionary<string, string> _newChatWriting = new();
    private readonly Dictionary<string, string> _newChatBackends = new();
    private readonly Dictionary<string, IReadOnlyList<TeamBackendOption>> _newChatBackendChoices = new();
    private readonly Dictionary<string, (string Title, string Backend, string Id)> _newChatRequests = new();
    private readonly Dictionary<TeamCommentTarget, TeamAskModel> _asks = new();
    private readonly TeamAskRecoveryStore _askStorage;
    private readonly Func<TeamSharedFileData, Func<bool>, Task>? _saveFile;
    private string? _historyTarget;
    private TeamHistoryWindow _history = new([]);
    private bool _readingEarlier;
    // Images opened in a chat, kept so the live refresh does not close them.
    private readonly Dictionary<string, Microsoft.UI.Xaml.Media.Imaging.BitmapImage> _openedImages = new();

    public TeamsPage() : this(null) { }
    internal TeamsPage(Func<string, JsonObject?, Task<JsonNode>>? call, TeamAskRecoveryStore? askStorage = null,
        JsonObject? folder = null, JsonObject? initialProject = null, bool sharedProjects = false,
        Func<TeamSharedFileData, Func<bool>, Task>? saveFile = null)
    {
        _saveFile = saveFile;
        _folderShareRequest = (JsonObject?)folder?.DeepClone(); _initialProject = (JsonObject?)initialProject?.DeepClone(); _startSharedProjects = sharedProjects;
        _askStorage = askStorage ?? TeamAskRecoveryStore.Shared;
        _call = call ?? ((method, fields) => AppServices.Host.CallAsync(method, fields));
        Content = BuildRoot();
        Loaded += (_, _) => ReconcileAttachment();
        Unloaded += (_, _) => ReconcileAttachment();
    }
    private void ReconcileAttachment()
    {
        var revision = ++_attachmentRevision;
        // WinUI may finish an old Unloaded after the page has reattached.
        // Settle the current tree before starting a load or retiring its watch.
        if (!DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, async () =>
        {
            if (revision != _attachmentRevision) return;
            if (IsLoaded && Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(this) is not null)
            {
                if (_attached) return;
                _attached = true;
                AppServices.AccountChanged += OnTeamAccountChanged;
                await LoadAsync();
            }
            else Detach();
        })) Detach();
    }
    private void Detach()
    {
        if (!_attached) return;
        _attached = false;
        AppServices.AccountChanged -= OnTeamAccountChanged;
        _view++;
    }
    private void OnTeamAccountChanged()
    {
        Interlocked.Increment(ref _view);
        DispatcherQueue.TryEnqueue(async () => { if (IsLoaded) await LoadAsync(); });
    }

    /// Every Team call carries the signed-in account's receipt. The host drops
    /// a call when that login is no longer the one it was made for.
    private async Task<JsonNode> CallAsync(string method, JsonObject? fields = null)
    {
        var body = fields?.DeepClone() as JsonObject ?? new JsonObject();
        body["_accountScope"] = _scope?.DeepClone();
        if (_session is not null) body["_accountSession"] = _session;
        return await _call(method, body);
    }

    private static JsonObject Page100(int offset = 0) => new() { ["limit"] = 100, ["offset"] = offset };

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
        _dockStack.Children.Clear();
        if (_dock is not null) _dock.Visibility = Visibility.Collapsed;
        _body.Children.Add(NavigationRow(title));
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
            var status = await _call("account.status", null);
            if (!IsLoaded || _view != view) return;
            var scope = SshVaultScope.From(status);
            var session = Format.Text(status, "accountSession");
            if (_scope?.ToJsonString() != scope?.ToJsonString() || _session != session)
            {
                if (_scope is not null) _initialProject = null;
                _organization = null;
                _organizations = []; _organizationsNext = null;
                _comments.Clear(); _checkoutHosts.Clear(); _newChatWriting.Clear(); _newChatBackends.Clear(); _newChatBackendChoices.Clear(); _newChatRequests.Clear(); _asks.Clear(); _openedImages.Clear(); _flash = null;
                _historyTarget = null; _history = new([]); _readingEarlier = false;
            }
            _scope = scope; _session = session;
            _person = Format.Text(status, "accountId");
            if (_scope is null) { Note(L10n.Text("common.teams.load_failed"), true); return; }
            AddDraftsButton();
            var capabilities = await CallAsync("teams.capabilities");
            if (!IsLoaded || _view != view) return;
            if (!Format.Flag(capabilities, "enabled")) { Note(L10n.Text("common.teams.load_failed"), true); return; }
            if (!Format.Flag(capabilities, "ready"))
            {
                ShowAuthorize(Format.Flag(capabilities, "deviceRemoved"));
                // Teams should have turned on by itself. Name the step that stopped it.
                if (capabilities["setupIssue"] is JsonObject issue && !Format.Flag(capabilities, "deviceRemoved"))
                    Note(L10n.Text("common.teams.setup_issue", Format.Text(issue, "message"), Format.Text(issue, "code")), true);
                return;
            }
            var actor = Format.Text(capabilities, "actorId");
            if (actor.Length == 0 || !string.IsNullOrEmpty(_person) && _person != actor) throw new HostException("account_changed", L10n.Text("common.teams.account_changed"));
            _person = actor;
            _canPublish = Format.Flag(capabilities, "canPublishCheckouts");
            _canResumeSharing = Format.Flag(capabilities, "canResumeProjectSharing");
            _canReviewChatSelection = Format.Flag(capabilities, "canReviewChatSelection");
            _canArchiveRepositories = (capabilities["features"] as JsonArray)?.Any(feature => feature is JsonValue value
                && value.TryGetValue<string>(out var name) && name == "repository-archive-v1") == true;
            var page = TeamDirectoryPage.Read(await CallAsync("teams.directory", new JsonObject { ["operation"] = "organizations.list", ["page"] = Page100() }), "organizations", 0);
            if (!IsLoaded || _view != view) return;
            _organizations = page.Rows; _organizationsNext = page.Next;
            if (_folderShareRequest is { } folder) { await ShowFolderShareAsync(DirectoryClient(), folder); return; }
            if (_initialProject is { } project) { _initialProject = null; await ShowFocusedTeamProjectAsync(project); return; }
            if (_startSharedProjects) { _startSharedProjects = false; await ShowAllTeamProjectsAsync(DirectoryClient()); return; }
            if (page.Rows.Count == 0 && page.Next is null)
            {
                AddTeamDirectoryActions();
                var empty = new StackPanel { Spacing = Theme.SpaceXs };
                empty.Children.Add(new TextBlock { Text = L10n.Text("common.teams.no_organizations"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
                empty.Children.Add(new TextBlock { Text = L10n.Text("common.teams.no_organizations_detail"), Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
                Section(L10n.Text("common.teams.organizations"), empty, L10n.Text("common.teams.hub_detail"));
                return;
            }
            var selected = page.Rows.FirstOrDefault(row => Format.Text(row, "id") == Format.Text(_organization, "id"));
            if (selected is null && _organization is not null && page.Next is not null)
            {
                // A selected team may be on a later page. Recheck that exact
                // membership instead of redirecting to the first team.
                var current = await CallAsync("teams.directory", new JsonObject { ["operation"] = "organizations.get", ["organization"] = Format.Text(_organization, "id") });
                if (!IsLoaded || _view != view) return;
                selected = current["organization"] as JsonObject ?? throw new InvalidDataException();
                if (Format.Text(selected, "id") != Format.Text(_organization, "id")) throw new InvalidDataException();
            }
            _organization = selected ?? (page.Rows.Count == 1 && page.Next is null ? page.Rows[0] : null);
            if (_organization is null)
            {
                ShowOrganizations();
                return;
            }
            Reset(Format.Text(_organization, "name"));
            AddDraftsButton();
            view = _view;
            await ShowRepositoriesAsync(_organization, page.Rows.Count > 1 || page.Next is not null);
        }
        catch (Exception error)
        {
            if (!IsLoaded || _view != view) return;
            if (_organization is not null && error is HostException { Code: "not_found" or "forbidden" or "organization_paused" or "patron_required" })
            {
                _organization = null; ShowOrganizations(); Note(error.Message, true); return;
            }
            Note(error.Message, true);
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => await LoadAsync()));
        }
    }

    private void ShowOrganizations()
    {
        Reset(L10n.Text("common.teams.title")); AddDraftsButton();
        AddTeamDirectoryActions();
        var view = _view;
        var rows = Rows();
        foreach (var organization in _organizations)
        {
            var chosen = organization;
            var name = Format.Text(organization, "name");
            var slug = Format.Text(organization, "slug");
            var text = Labelled(name, slug.Length > 0 ? "@" + slug : null);
            var line = Marked(Initial(name), text, Badge(TeamRole(Format.Text(organization, "role"))));
            AddRow(rows, OpenRow(line, name, async (_, _) => { if (IsLoaded && _view == view) { _organization = chosen; await LoadAsync(); } }));
        }
        Section(L10n.Text("common.teams.organizations"), rows, L10n.Text("common.teams.hub_detail"));
        if (_organizationsNext is not { } offset) return;
        Button? more = null;
        more = ActionIconGlyph.Button(L10n.Text("common.teams.more_organizations"), ActionIcon.More, async (_, _) =>
        {
            if (!IsLoaded || _view != view || !more!.IsEnabled) return;
            more.IsEnabled = false;
            try
            {
                var page = TeamDirectoryPage.Read(await CallAsync("teams.directory", new JsonObject {
                    ["operation"] = "organizations.list", ["page"] = Page100(offset),
                }), "organizations", offset);
                if (!IsLoaded || _view != view) return;
                _organizations = TeamCatalogPage.Append(_organizations, page.Rows); _organizationsNext = page.Next;
                ShowOrganizations();
            }
            catch (Exception error) { if (IsLoaded && _view == view) Note(error.Message, true); }
            finally { if (IsLoaded && _view == view) more.IsEnabled = true; }
        });
        _body.Children.Add(more);
    }

    /// A signed-in device turns Teams on by itself, so this is shown for a
    /// device the person removed from Teams, or a server that predates that.
    private void ShowAuthorize(bool removed = false)
    {
        var view = _view;
        if (removed)
        {
            Note(L10n.Text("common.teams.device_removed_title"));
            Note(L10n.Text("common.teams.device_removed_detail"));
        }
        else
        {
            Note(L10n.Text("common.teams.enable_title"));
        }
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
        Tool(ActionIcon.Refresh, L10n.Text("common.refresh"), async (_, _) => await LoadAsync());
    }

    private async Task ShowRepositoriesAsync(JsonObject organization, bool canSwitch)
    {
        var orgId = Format.Text(organization, "id");
        var view = _view;
        var client = DirectoryClient();
        AddTeamDirectoryActions();
        Trail(Buttons.Secondary(L10n.Text("common.teams.organization_settings"), ActionIcon.Settings, async (_, _) => {
            if (IsLoaded && _view == view) await ShowTeamManagementAsync(client, new(client, organization));
        }));
        if (_flash is { } flash) { _flash = null; Note(flash); }
        if (canSwitch)
            NavBack(L10n.Text("common.teams.organizations"), async (_, _) => { _organization = null; await LoadAsync(); });
        int? next = 0;
        var seen = new HashSet<string>();
        var loading = false;
        TextBlock? failure = null;
        Button? more = null;
        async Task LoadMore()
        {
            if (loading || next is not { } offset || !IsLoaded || _view != view) return;
            loading = true; more!.IsEnabled = false;
            try
            {
                var page = TeamDirectoryPage.Read(await CallAsync("teams.directory", new JsonObject {
                    ["operation"] = "repositories.list", ["organization"] = orgId, ["page"] = Page100(offset),
                }), "repositories", offset);
                if (!IsLoaded || _view != view) return;
                if (page.Rows.Any(row => Format.Text(row, "organizationId") != orgId)) throw new InvalidDataException();
                if (failure is not null) { _body.Children.Remove(failure); failure = null; }
                _body.Children.Remove(more);
                // A project nobody shares has no chats to read here. It stays
                // in the team's repository list, where an admin can remove it.
                foreach (var repo in page.Rows.Where(TeamManagementModel.Shared))
                {
                    if (!IsLoaded || _view != view) return;
                    if (seen.Add(Format.Text(repo, "id"))) await AddRepositoryAsync(orgId, repo);
                }
                if (!IsLoaded || _view != view) return;
                next = page.Next;
                if (seen.Count == 0 && next is null) { Note(L10n.Text("common.teams.no_repositories")); Note(L10n.Text("common.teams.no_repositories_member")); }
                if (next is not null) _body.Children.Add(more);
            }
            catch (Exception error)
            {
                if (!IsLoaded || _view != view) return;
                if (failure is null) { failure = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Theme.Brush(static () => Theme.Warning) }; _body.Children.Add(failure); }
                failure.Text = error.Message;
                if (!_body.Children.Contains(more)) _body.Children.Add(more);
            }
            finally { loading = false; if (IsLoaded && _view == view) more.IsEnabled = true; }
        }
        more = ActionIconGlyph.Button(L10n.Text("common.teams.load_more"), ActionIcon.More, async (_, _) => await LoadMore());
        await LoadMore();
    }

    private async Task AddRepositoryAsync(string orgId, JsonObject repo)
    {
        var view = _view;
        var repoId = Format.Text(repo, "id");
        var card = new StackPanel { Spacing = Theme.SpaceS };
        var roleText = repo["role"] is null ? L10n.Text("common.teams.no_access") : TeamRole(Format.Text(repo, "role"));
        var settings = _canPublish ? Buttons.Secondary(L10n.Text("common.teams.project_settings"), ActionIcon.Settings, async (_, _) => {
            if (IsLoaded && _view == view) await ShowTeamPublisherAsync(repo);
        }, small: true) : null;
        _body.Children.Add(Chrome.Card(Format.Text(repo, "name"), card, roleText, settings, Chrome.CardMark(ActionIcon.Source)));
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
            _newChatBackendChoices[Target(orgId, repoId, checkout).ToJsonString()] = page.Backends;
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
            if (repo["role"] is null) return;
            if (error is not null) card.Children.Add(new TextBlock { Text = error, TextWrapping = TextWrapping.Wrap });
            if (loaded && checkouts.Count == 0) card.Children.Add(new TextBlock { Text = L10n.Text("common.teams.repository_not_shared"), Opacity = 0.7 });
            if (loading) card.Children.Add(new ProgressRing { IsActive = true, Width = 20, Height = 20 });
            if (nextOffset is not null || failures.Count > 0) card.Children.Add(new TextBlock { Text = L10n.Text("common.teams.partial_lanes"), Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
            var all = lanes.Values.SelectMany(rows => rows).ToList();
            foreach (var checkout in checkouts)
            {
                var id = Format.Text(checkout, "id");
                var computer = Format.Text(checkout, "deviceName", L10n.Text("common.teams.computer"));
                var device = ActionIcon.Computer.Mark(13); device.Opacity = 0.7;
                card.Children.Add(Marked(device, new TextBlock { Text = computer, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center }));
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
                var chats = Rows();
                foreach (var share in shares.GetValueOrDefault(id) ?? [])
                {
                    var shareId = Format.Text(share, "id"); var title = Format.Text(share, "title");
                    if (title.Length == 0) title = L10n.Text("common.teams.shared_chat");
                    var glyph = ActionIcon.Comment.Mark(13);
                    AddRow(chats, OpenRow(Marked(glyph, new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center }), title,
                        async (_, _) => await ShowChatAsync(Target(orgId, repoId, id, shareId), title, computer)));
                }
                if (chats.Children.Count > 0) card.Children.Add(chats);
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
        var panel = new StackPanel { Spacing = Theme.SpaceS, Margin = new Thickness(0, Theme.SpaceXs, 0, 0), Padding = new Thickness(Theme.SpaceM),
            Background = Theme.BackgroundBrush, BorderBrush = Theme.BorderBrush, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12) };
        var box = new TextBox { Header = L10n.Text("common.teams.new_chat_title"), PlaceholderText = L10n.Text("common.teams.new_chat_placeholder") };
        var key = Target(orgId, repoId, checkout).ToJsonString();
        var agent = new ComboBox { Header = L10n.Text("common.teams.agent"), SelectedValuePath = "Tag", MinWidth = 200 };
        agent.Items.Add(new ComboBoxItem { Content = L10n.Text("common.local_provider_use_default"), Tag = "" });
        foreach (var backend in _newChatBackendChoices.GetValueOrDefault(key) ?? [])
            agent.Items.Add(new ComboBoxItem { Content = backend.Label, Tag = backend.Id });
        var selectedBackend = _newChatBackends.GetValueOrDefault(key) ?? "";
        agent.SelectedValue = selectedBackend;
        agent.PlaceholderText = selectedBackend;
        // A refreshed/older catalog must not silently replace an existing
        // draft's backend and the identity of its pending request.
        agent.SelectionChanged += (_, _) => { if (_view == view && agent.SelectedValue is string chosen) _newChatBackends[key] = chosen; };
        box.Text = _newChatWriting.GetValueOrDefault(key) ?? "";
        box.TextChanged += (_, _) => { if (_view == view) _newChatWriting[key] = box.Text; };
        Button? start = null;
        start = Buttons.Primary(L10n.Text("common.teams.new_chat"), ActionIcon.Create, async (_, _) =>
        {
            if (!IsLoaded || _view != view) return;
            var title = box.Text.Trim();
            var backend = _newChatBackends.GetValueOrDefault(key) ?? "";
            if (title.Length == 0) return;
            if (!_newChatRequests.TryGetValue(key, out var pending) || pending.Title != title || pending.Backend != backend)
                _newChatRequests[key] = pending = (title, backend, "new-" + Guid.NewGuid().ToString("N"));
            start!.IsEnabled = false;
            agent.IsEnabled = false;
            try
            {
                var parameters = new JsonObject { ["title"] = title, ["requestId"] = pending.Id };
                if (backend.Length > 0) parameters["backend"] = backend;
                var made = await CallAsync("teams.ask", new JsonObject
                {
                    ["target"] = Target(orgId, repoId, checkout), ["method"] = "team.chat.new",
                    ["params"] = parameters,
                });
                var share = Format.Text(made, "share");
                if (!IsLoaded || _view != view) return;
                if (_newChatWriting.GetValueOrDefault(key)?.Trim() == title && (_newChatBackends.GetValueOrDefault(key) ?? "") == backend) _newChatWriting.Remove(key);
                if (_newChatRequests.GetValueOrDefault(key) == pending) _newChatRequests.Remove(key);
                if (share.Length > 0) await ShowChatAsync(Target(orgId, repoId, checkout, share), title, computer);
            }
            catch (Exception error)
            {
                if (!IsLoaded || _view != view) return;
                panel.Children.Add(new TextBlock { Text = error.Message, Foreground = Theme.Brush(static () => Theme.Warning), TextWrapping = TextWrapping.Wrap });
                start.IsEnabled = true;
                agent.IsEnabled = true;
            }
        });
        // Title, agent and Start side by side, the way the Mac lays out the
        // same card, with what it does underneath.
        var fields = new Grid { ColumnSpacing = Theme.SpaceS };
        fields.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        fields.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        fields.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        fields.Children.Add(box);
        Grid.SetColumn(agent, 1); fields.Children.Add(agent);
        start.VerticalAlignment = VerticalAlignment.Bottom;
        Grid.SetColumn(start, 2); fields.Children.Add(start);
        panel.Children.Add(fields);
        panel.Children.Add(new TextBlock { Text = L10n.Text("common.teams.new_chat_detail", computer), FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
        return panel;
    }

    private UIElement LaneRow(string orgId, string repoId, string checkout, JsonObject lane, List<JsonObject> all)
    {
        var view = _view;
        var row = new StackPanel { Spacing = Theme.SpaceXs, Padding = new Thickness(Theme.SpaceM), Background = Theme.BackgroundBrush,
            BorderBrush = Theme.BorderBrush, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10) };
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
            if (state == "ready") actions.Children.Add(Buttons.Primary(L10n.Text("common.teams.land"), ActionIcon.Merge, async (_, _) => await Act("team.lanes.land"), small: true));
            actions.Children.Add(Buttons.Destructive(L10n.Text("common.teams.discard"), ActionIcon.Delete, async (_, _) => await Act("team.lanes.discard"), small: true));
            row.Children.Add(actions);
        }
        return row;
    }

    private async Task<bool> ShowChatAsync(JsonObject target, string title, string computer, string? earlierCursor = null)
    {
        Reset(title);
        var view = _view;
        var targetKey = target.ToJsonString();
        var loading = true;
        _readingEarlier = earlierCursor is not null;
        var previous = _historyTarget == targetKey ? _history : new TeamHistoryWindow([]);
        NavBack(L10n.Text("common.back"), async (_, _) => await LoadAsync());
        Tool(ActionIcon.Refresh, L10n.Text("common.refresh"), async (_, _) => await ShowChatAsync(target, title, computer));
        var askModel = await AskModelAsync(target, title, computer);
        if (!IsLoaded || _view != view) return false;
        (StackPanel Panel, Action<bool> Allow)? askControls = askModel is null ? null : AskControls(askModel, target, title, computer, view);
        if (askControls is { } initial) Dock(initial.Panel);
        if (askModel?.Fence is not null) _ = WatchAskAsync(askModel, target, title, computer, view, () => !loading && !_readingEarlier && CommentIdle);
        JsonNode details, page;
        List<TeamBlock> transcript;
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
            var projected = await Task.Run(() => {
                var window = previous.Merge(incoming, earlierCursor is not null);
                return (window, rows: TeamTranscript.Project(window.Events, Format.Text(details["chat"], "backend")));
            });
            if (!IsLoaded || _view != view) return false;
            _historyTarget = targetKey; _history = projected.window; transcript = projected.rows;
        }
        catch (Exception error) { loading = false; if (IsLoaded && _view == view) Note(error is InvalidDataException ? L10n.Text("common.teams.history_cannot_display") : error.Message, true); return false; }
        if (!IsLoaded || _view != view) return false;
        if (Format.Flag(page, "hasMore"))
        {
            var next = Format.Text(page, "nextCursor");
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.load_earlier"), ActionIcon.History,
                async (_, _) => await ShowChatAsync(target, title, computer, next)));
        }
        if (_history.Truncated) Note(L10n.Text("common.teams.shared_history_window"));
        foreach (var block in transcript) _body.Children.Add(TranscriptRow(target, block));
        var chat = details["chat"];
        var comment = Format.Flag(chat, "allowsComments") ? await AddCommentComposerAsync(target, title, computer, view) : null;
        if (!IsLoaded || _view != view) return false;
        if (comment is { } written) _dockStack.Children.Insert(0, written.Panel);
        var runs = Format.Flag(chat, "allowsAgentRuns");
        if (askControls is { } controls)
        {
            // One well, one thing to write at a time, as on the Mac: a switch
            // picks Comment or Ask agent when the chat allows both. A running
            // agent or a request or comment waiting on delivery keeps its own
            // side in view, so Stop and Check are never behind the switch.
            if (comment is { } both && runs && askModel!.Fence is null && !askModel.Pending && !both.Model.Pending)
            {
                var mode = _composerMode;
                void Apply() { both.Panel.Visibility = mode == "comment" ? Visibility.Visible : Visibility.Collapsed; controls.Allow(mode == "ask"); }
                _dockStack.Children.Insert(0, TeamTabs([("comment", L10n.Text("common.teams.composer_comment")), ("ask", L10n.Text("common.teams.composer_ask"))], mode,
                    choice => { mode = choice; _composerMode = choice; Apply(); return Task.CompletedTask; }));
                Apply();
            }
            else controls.Allow(runs);
        }
        if (_dockStack.Children.Count > 0 && _dock is not null) _dock.Visibility = Visibility.Visible;
        loading = false;
        if (!_readingEarlier && askModel?.Fence is null) _ = KeepCurrentAsync(target, title, computer, view, _body.Children.OfType<TextBox>().ToList(), askModel);
        return true;
    }

    /// New comments and agent output appear while the chat is open. Stops
    /// when another screen is drawn, and waits while someone is typing.
    private async Task KeepCurrentAsync(JsonObject target, string title, string computer, int view, List<TextBox> inputs, TeamAskModel? ask)
    {
        while (true)
        {
            await Task.Delay(10_000);
            if (!IsLoaded || _view != view) return;
            if (CommentIdle && (ask is null || !ask.Busy && !ask.Pending && ask.Text.Length == 0) && inputs.All(box => box.Text.Length == 0))
            {
                await ShowChatAsync(target, title, computer);
                return;
            }
        }
    }

}
