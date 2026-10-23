// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

using System.Globalization;
using System.Text.Json.Nodes;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Tokenstat.Design.Persona;
using Tokenstat.Navigation;
using Windows.Storage.Pickers;
using Windows.System;
using Windows.UI.Core;
using WinRT.Interop;

namespace Tokenstat.Pages;

/// <summary>
/// Conversations in a folder, over the same host methods the Mac uses.
/// The list comes first. One field picks agent, model and effort. Plan and
/// bypass sit as pills beside it. Enter sends, Shift+Enter inserts a
/// newline, Escape stops a running turn. Approvals sit in the transcript.
/// While the agent asks before each tool, a short note rides the next step
/// instead of waiting out the turn.
/// </summary>
internal sealed partial class ChatPage : Page, IInspectorContent, IToolbarItems
{
    private const int AttachmentCap = 12 * 1024 * 1024;

    private readonly string _workspaceId;
    public event Action? ToolbarChanged;
    private readonly StackPanel _inspector = new()
    {
        Spacing = Theme.SpaceM,
        Padding = new Thickness(Theme.SpaceM),
    };
    private readonly Border _composerDock = new() { Padding = new Thickness(Theme.SpaceL, Theme.SpaceS, Theme.SpaceL, Theme.SpaceL) };
    private readonly ScrollViewer _setupScroll = new()
    {
        HorizontalScrollMode = ScrollMode.Disabled,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
    };
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private string _folderName = "";
    private string _folderPath = "";
    private readonly StackPanel _transcript = new() { Spacing = Theme.SpaceM };
    private ScrollViewer? _scroll;
    private bool _followEnd = true;
    private readonly FlowPanel _attachStrip = new() { Spacing = Theme.SpaceS };
    // Keep the logical owners so a rebuild can release controls even after
    // the old composer has been removed from the visual tree.
    private StackPanel _composerWell = new();
    private StackPanel _composerContext = new();
    private Grid _composerRow = new();
    private readonly TextBox _draft = new()
    {
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        PlaceholderText = L10n.Text("windows.chatpage.ask_about_this_folder.33b8b41b"),
        MinHeight = 72,
        MaxHeight = 220,
    };
    private readonly StackPanel _composerActions = new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = Theme.SpaceS,
    };
    private readonly TextBox _titleBox = new()
    {
        FontSize = 20,
        FontWeight = FontWeights.SemiBold,
    };

    private CancellationTokenSource? _poll;
    private string? _openId;
    /// <summary>
    /// One conversation to open once the list loads, like the Mac pending
    /// reveal. A notification tap names a thread this page may not have read
    /// yet, so the id waits here rather than deciding on an empty list.
    /// </summary>
    private string? _pendingReveal;
    /// <summary>Whether the list load finished, so a reveal knows whether to wait for it or re-read it.</summary>
    private bool _listReady;
    private ulong _offset { get => _history.Offset; set => _history.Offset = value; }
    private bool _started;
    private bool _running;
    private bool _setupExpanded;
    private bool _suppress;
    private bool _composerSteering;
    private JsonArray _chats = new();
    private readonly ChatSteerOverlay _steerOverlay = new();
    private JsonArray _backends = new();
    private JsonArray _personas = new();
    private readonly ChatHistoryBuffer _history = new();
    private JsonArray _events { get => _history.Events; set => _history.Events = value; }
    private JsonArray _approvals = new();
    private readonly List<StagedFile> _attachments = [];
    private readonly Dictionary<string, (string Text, StagedFile[] Attachments)> _drafts = new();
    private readonly Dictionary<string, string> _instructionDrafts = new();
    private bool _savingInstructions, _updatingAllowed;

    private void RememberDraft()
    {
        if (_opening || _openId is null || _outboxKey is not string owner) return;
        if (_draft.Text.Length == 0 && _attachments.Count == 0) _drafts.Remove(owner);
        else _drafts[owner] = (_draft.Text, _attachments.ToArray());
    }
    private JsonNode? _openChat;

    /// <summary>
    /// A turn's changes card asked for the folder's changes. The workspace
    /// tabs answer it by opening the Changes inspector beside the chat.
    /// </summary>
    public event Action<string?>? ReviewChangesRequested;
    public event Action<IReadOnlyList<ChangedFile>, string?>? ReviewTurnChangesRequested;
    internal event Action<string, bool>? WorkspaceGitChanged;
    internal string ReviewTitle => Format.Text(_openChat, "title");

    /// <param name="chatId">One conversation to reveal on load, from a deep
    /// link. The list loads first and the thread opens on top of it, like
    /// the Mac opening the named conversation in its folder chat.</param>
    public ChatPage(string workspaceId, string? chatId = null)
    {
        _workspaceId = workspaceId;
        // The command menu has one retained logical owner. Rebuilding a
        // composer moves this viewer, never the Content between viewers.
        _commandScroll.Content = _commandMenu;
        if (!string.IsNullOrEmpty(chatId))
        {
            _pendingReveal = chatId;
        }
        _draft.PlaceholderText = L10n.Text("windows.chatpage.ask_about_this_folder.33b8b41b");
        _draft.TextChanged += (_, _) => {
            _commandIndex = 0; _commandsDismissed = false; RenderCommandMenu();
            if (Format.Flag(_openChat, "nativeSteer") && SteerKnownAvailable() != _composerSteering) RebuildComposerActions();
        };
        _draft.PreviewKeyDown += DraftOnPreviewKeyDown;
        PreviewKeyDown += PageOnPreviewKeyDown;
        _titleBox.LostFocus += async (_, _) =>
        {
            if (_opening) return;
            var next = _titleBox.Text.Trim();
            if (string.IsNullOrEmpty(next) || next == Format.Text(_openChat, "title")) return;
            await UpdateAsync(new JsonObject { ["title"] = next });
        };
        // The Mac reading lane: 1040 wide, leading, with the transcript
        // gutters. A centred lane puts the reader's eye somewhere different
        // at every window size and leaves two gutters saying nothing.
        _scroll = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL, Theme.SpaceXl, Theme.SpaceL, Theme.SpaceXl),
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = _root,
        };
        _scroll.ViewChanged += (_, _) => OnTranscriptViewChanged();
        // Growth is not a scroll: a reply streaming in below the fold, or the
        // composer taking height from the viewport, moves no offset and raises
        // no ViewChanged. Pin again once layout has the new size.
        _root.SizeChanged += (_, _) => KeepFollowing();
        _scroll.SizeChanged += (_, _) => KeepFollowing();
        var transcriptHost = new Grid();
        transcriptHost.Children.Add(_scroll);
        transcriptHost.Children.Add(_followPillHost);
        var layout = new Grid();
        layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(_composerDock, 1);
        layout.Children.Add(transcriptHost);
        layout.Children.Add(_composerDock);
        AttachChatDropSurface(layout);
        Content = layout;
        SizeChanged += (_, _) => FitSetupViewport();
        RenderInspector();
        Loaded += async (_, _) =>
        {
            AttachInspectionWindow();
            AppServices.AccountChanged -= ImagesAccountChanged;
            AppServices.AccountChanged += ImagesAccountChanged;
            RemoteWorkspaces.Changed -= ImagesPeerChanged;
            RemoteWorkspaces.Changed += ImagesPeerChanged;
            if (_openId is string id && _opening) await OpenAsync(id);
            else if (_openId is not null) StartPoll();
            else await ShowListAsync();
        };
        Unloaded += (_, _) => { DetachInspectionWindow(); AppServices.AccountChanged -= ImagesAccountChanged; RemoteWorkspaces.Changed -= ImagesPeerChanged; RememberDraft(); _openGeneration++; CancelDropImport(); ResetImagePreviews(); _poll?.Cancel(); _commandDialog?.Hide(); _inspection = null; _inspectionHost.Children.Clear(); };
        AutomationProperties.SetAutomationId(_draft, "chat.composer");
        AutomationProperties.SetAutomationId(_titleBox, "chat.title");
    }

    /// <summary>
    /// The folder this chat belongs to, like the Mac conversation scope.
    /// </summary>
    public UIElement? ToolbarScope =>
        Chrome.ScopeChip(string.IsNullOrEmpty(_folderName) ? L10n.Text("windows.chatpage.chat.460b3a7d") : _folderName);

    public IList<UIElement> ToolbarActions()
    {
        return new List<UIElement>
        {
            Buttons.ToolbarIcon(
                ActionIcon.Refresh,
                L10n.Text("windows.chatpage.reload_chats.fb6be0ad"),
                async (_, _) =>
                {
                    LogoRefresh.Began();
                    if (_openId is null)
                    {
                        await ShowListAsync();
                    }
                    else
                    {
                        await OpenAsync(_openId);
                    }
                }),
            Buttons.ToolbarIcon(
                ActionIcon.Create,
                L10n.Text("windows.chatpage.start_a_chat.d80b1888"),
                async (_, _) => await BeginNewChatAsync()),
        };
    }

    private void RaiseToolbarChanged() => ToolbarChanged?.Invoke();

    /// <summary>
    /// The inspector column content: the open conversation's setup and spend,
    /// like the Mac chat inspector. Selection and polls replace its children,
    /// so the column stays live without the shell asking again.
    /// </summary>
    public UIElement? Inspector => _inspector;

    private void RenderInspector()
    {
        try { RenderInspectorContent(); }
        catch (Exception error)
        {
            // Native UI Automation may receive a XAML exception directly
            // from a Click handler without the app's unhandled event firing.
            Program.LogStartup($"Chat inspector construction failed: {error}");
            throw;
        }
    }

    private void RenderInspectorContent()
    {
        // The nested body retains logical ownership after its outer card is
        // unmounted. Release this shared host through that body, including
        // when the inspector was hidden and WinUI has no visual parent.
        _sessionIdentityOwner?.Children.Remove(_sessionIdentityHost);
        _sessionIdentityOwner = null;
        _inspector.Children.Clear();
        if (_openChat is null)
        {
            _inspector.Children.Add(new TextBlock
            {
                Text = L10n.Text("common.chats"),
                FontWeight = FontWeights.SemiBold,
            });
            _inspector.Children.Add(new TextBlock
            {
                Text = _chats.Count == 0
                    ? L10n.Text("windows.chatpage.no_conversations_in_this_folder_yet.1cf8e78c")
                    : L10n.Text("windows.chatpage.0_1_in_this_folder.8b3dad5f", $"{_chats.Count}", $"{(_chats.Count == 1 ? L10n.Text("windows.chatpage.conversation.8b34dbc2") : L10n.Text("windows.chatpage.conversations.5c0dc939"))}"),
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
            return;
        }
        var chat = _openChat;
        var conversation = new StackPanel { Spacing = Theme.SpaceS };
        var backend = Backend(Format.Text(chat, "backend"));
        conversation.Children.Add(new TextBlock
        {
            Text = Format.Text(chat, "title", L10n.Text("windows.chatpage.new_chat.db18382a")),
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        conversation.Children.Add(new TextBlock
        {
            Text = Format.Flag(chat, "running") ? L10n.Text("common.running") : L10n.Text("common.idle"),
            Foreground = Format.Flag(chat, "running") ? Theme.AccentBrush : Theme.Brush(static () => Theme.StateIdle),
        });
        conversation.Children.Add(Chrome.InspectorField(
            L10n.Text("windows.chatpage.agent.11b39c93"), Format.Text(backend, "label", Format.Text(chat, "backend", L10n.Text("windows.chatpage.agent.11b39c93")))));
        var model = Format.Text(chat, "model");
        if (!string.IsNullOrEmpty(model))
        {
            conversation.Children.Add(Chrome.InspectorField(L10n.Text("windows.chatpage.model.5e2c614c"), model));
        }
        var effort = Format.Text(chat, "effort");
        if (!string.IsNullOrEmpty(effort))
        {
            conversation.Children.Add(Chrome.InspectorField(L10n.Text("windows.chatpage.effort.4387e5d3"), effort));
        }
        conversation.Children.Add(Chrome.InspectorField(
            L10n.Text("windows.chatpage.mode.5e23ec6a"), Format.Text(chat, "mode") == "plan" ? L10n.Text("windows.chatpage.plan.fa8ed0bd") : L10n.Text("windows.chatpage.execute.e3a67d95")));
        var personaId = Format.Text(chat, "personaId");
        if (!string.IsNullOrEmpty(personaId))
        {
            var persona = FindPersona(personaId);
            conversation.Children.Add(Chrome.InspectorField(
                L10n.Text("windows.chatpage.persona.31bdeef9"), Format.Text(persona, "name", L10n.Text("windows.chatpage.preset.7252e7ce"))));
        }
        if (_approvals.Count > 0)
        {
            conversation.Children.Add(Chrome.InspectorField(
                L10n.Text("windows.chatpage.approvals.2bfc3471"), L10n.Text("windows.chatpage.0_waiting.15f51b52", $"{_approvals.Count}"),
                L10n.Text("windows.chatpage.answer_them_in_the_transcript.fd152eae")));
        }
        _sessionIdentityOwner = conversation;
        conversation.Children.Add(_sessionIdentityHost);
        RenderSessionIdentities();
        _inspector.Children.Add(CollapsibleStatsCard(L10n.Text("windows.chatpage.conversation.8b34dbc2"), "conversation",
            new TextBlock { Text = Format.Text(chat, "title") + " · " + L10n.Text(Format.Flag(chat, "running") ? "common.running" : "common.idle"),
                FontSize = 11, Opacity = .7, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis }, conversation));
        Detach(_inspectionHost);
        _inspector.Children.Add(_inspectionHost);
        _ = RefreshInspectionAsync();
        var detailControls = new StackPanel { Spacing = Theme.SpaceS };
        detailControls.Children.Add(Muted(ChatDetailPreference.Level switch {
            ChatDetail.Minimal => L10n.Text("common.chat.detail.minimal_help"),
            ChatDetail.Compact => L10n.Text("common.chat.detail.compact_help"),
            ChatDetail.Detailed => L10n.Text("common.chat.detail.detailed_help"),
            _ => L10n.Text("common.chat.detail.standard_help"),
        }));
        var stepsOpen = AnyGroupOpen();
        detailControls.Children.Add(ActionIconGlyph.Button(L10n.Text(stepsOpen ? "windows.chatdetail.collapse_steps" : "windows.chatdetail.expand_steps"), ActionIcon.Visibility, (_, _) => SetAllGroups(!stepsOpen)));
        _inspector.Children.Add(CollapsibleStatsCard(L10n.Text("windows.chatdetail.title"), "chat-detail", DetailChoices(), detailControls));
        _inspector.Children.Add(RoutingControls());
        if (!SharedSource) _inspector.Children.Add(SetupCard(inspector: true));
        AddWorkingAccessCards(_inspector, chat);
    }

    /// <summary>
    /// One chat method against this folder, local or remote. A remote folder
    /// travels as remote.call with the peer's own folder id, the way the
    /// desktop Mac routes every chat read and write. Params are copied, never
    /// mutated, so a retry cannot forward an already rewritten id.
    /// </summary>
    private Task<JsonNode> CallChatAsync(string method, JsonNode? parameters = null)
    {
        if (!RemoteWorkspaces.TrySplit(_workspaceId, out var peer, out var inner))
        {
            return AppServices.Host.CallAsync(method, parameters);
        }
        var forwarded = parameters is null
            ? new JsonObject()
            : (JsonObject)JsonNode.Parse(parameters.ToJsonString())!;
        if (Format.Text(forwarded, "workspaceId") == _workspaceId)
        {
            forwarded["workspaceId"] = inner;
        }
        return RemoteWorkspaces.CallOnPeerAsync(peer, method, forwarded);
    }

    private async Task<string> FolderNameAsync()
    {
        var generation = _openGeneration; var account = AppServices.AccountGeneration;
        if (RemoteWorkspaces.CachedFolder(_workspaceId) is RemoteFolder cached)
        {
            _folderPath = cached.Path;
            return cached.DisplayName;
        }
        try
        {
            var listed = await AppServices.Host.CallAsync("workspace.list");
            var array = listed as JsonArray ?? listed["workspaces"] as JsonArray;
            if (array is not null)
            {
                foreach (var folder in array)
                {
                    if (Format.Text(folder, "id") == _workspaceId)
                    {
                        if (generation == _openGeneration && account == AppServices.AccountGeneration) _folderPath = Format.Text(folder, "path");
                        return Format.Text(folder, "name", Format.Text(folder, "path", _workspaceId));
                    }
                }
            }
        }
        catch
        {
        }
        return "";
    }

    public Task ShowChatsAsync()
    {
        _pendingReveal = null;
        return ShowListAsync();
    }

    private async Task ShowListAsync()
    {
        RememberDraft();
        _poll?.Cancel();
        var generation = ++_openGeneration;
        CancelDropImport();
        ResetImagePreviews();
        AbandonSteerDelivery();
        _opening = false;
        _openId = null;
        _listReady = false;
        _openChat = null;
        _attachments.Clear();
        _events = new JsonArray();
        _offset = 0;
        _transcript.Children.Clear();
        ResetTranscriptWindow();
        _composerDock.Child = null;
        _composerDock.Visibility = Visibility.Collapsed;
        _root.Children.Clear();
        var header = ListHeader();
        _root.Children.Add(header);
        // The archive is a new reading destination; retain drafts, but start
        // at its header rather than the previous transcript scroll offset.
        _scroll?.ChangeView(null, 0, null, true);
        var skeleton = Motion.SkeletonCard();
        _root.Children.Add(skeleton);
        _folderName = await FolderNameAsync();
        if (generation != _openGeneration || !IsLoaded) return;
        RaiseToolbarChanged();
        RenderInspector();
        try
        {
            await RefreshCatalogAsync();
            if (generation != _openGeneration || !IsLoaded) return;
            RenderInspector();
            _root.Children.Remove(skeleton);
            _listReady = true;
            if (!string.IsNullOrEmpty(_pendingReveal))
            {
                var reveal = _pendingReveal;
                _pendingReveal = null;
                if (HasChat(reveal))
                {
                    await OpenAsync(reveal);
                    return;
                }
                // The host just answered with the whole list and the named
                // conversation is not in it, so it was deleted. An explicit
                // destination must never fall back to a different thread.
                _root.Children.Add(Chrome.Banner(
                    L10n.Text("windows.chatpage.this_conversation_is_no_longer_available_i.357d50bd"),
                    Theme.Danger, Symbol.Important));
            }
            if (_chats.Count == 0)
            {
                _root.Children.Add(Chrome.Empty(
                    L10n.Text("windows.chatpage.start_a_chat.d80b1888"),
                    L10n.Text("windows.chatpage.ask_an_agent_to_explore_plan_or_work_in_th.ebcac953"),
                    ActionIcon.Comment,
                    ActionIconGlyph.PrimaryButton(L10n.Text("windows.chatpage.new_chat.db18382a"), ActionIcon.Create, async (_, _) => await BeginNewChatAsync())));
                return;
            }
            var list = new StackPanel { Spacing = Theme.SpaceS };
            foreach (var chat in _chats)
            {
                if (chat is null) continue;
                list.Children.Add(ChatCard(chat));
            }
            _root.Children.Add(list);
            DispatcherQueue.TryEnqueue(() =>
            {
                if (generation == _openGeneration && _openId is null && IsLoaded)
                    _scroll?.ChangeView(null, 0, null, true);
            });
        }
        catch (Exception ex)
        {
            if (generation != _openGeneration || !IsLoaded) return;
            _root.Children.Remove(skeleton);
            _root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
        }
    }

    private UIElement ListHeader()
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var mark = new Border
        {
            Width = 42,
            Height = 42,
            CornerRadius = new CornerRadius(12),
            Background = Theme.AccentSoftBrush,
            Child = new SymbolIcon
            {
                Symbol = ActionIcon.Comment.Symbol(),
                Foreground = Theme.AccentBrush,
            },
        };
        row.Children.Add(mark);
        var titles = new StackPanel { Spacing = 2, Margin = new Thickness(Theme.SpaceM, 0, 0, 0) };
        titles.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.chatpage.chat.460b3a7d"),
            FontSize = Fonts.PageTitle,
            FontWeight = FontWeights.SemiBold,
        });
        titles.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.chatpage.talk_to_an_agent_in_this_folder.df22c32f"),
            Opacity = 0.66,
            TextWrapping = TextWrapping.Wrap,
        });
        Grid.SetColumn(titles, 1);
        row.Children.Add(titles);
        var create = ActionIconGlyph.PrimaryButton(L10n.Text("windows.chatpage.new_chat.db18382a"), ActionIcon.Create, async (_, _) => await BeginNewChatAsync());
        AutomationProperties.SetAutomationId(create, "chat.list.create");
        Grid.SetColumn(create, 2);
        row.Children.Add(create);
        return row;
    }

    private UIElement ChatCard(JsonNode chat)
    {
        var id = Format.Text(chat, "id");
        var running = Format.Flag(chat, "running");
        var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        if (running)
        {
            heading.Children.Add(new Border
            {
                Width = 8,
                Height = 8,
                CornerRadius = new CornerRadius(4),
                Background = Theme.AccentBrush,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        heading.Children.Add(new TextBlock
        {
            Text = Format.Text(chat, "title", L10n.Text("windows.chatpage.new_chat.db18382a")),
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 640,
        });
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(heading);
        body.Children.Add(new TextBlock
        {
            Text = RowDetail(chat),
            FontSize = 12,
            Foreground = Theme.AccentBrush,
            TextWrapping = TextWrapping.Wrap,
        });
        var card = new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.CardPadding),
            Child = body,
        };
        var button = new Button
        {
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = card,
        };
        ChatPreviewCache.Attach(button, _workspaceId, id);
        button.Click += async (_, _) => await OpenAsync(id);
        var menu = ContextMenus.Menu(button);
        ContextMenus.AddAsync(menu, L10n.Text("windows.chatpage.open_chat.0600175a"), async () => await OpenAsync(id));
        ContextMenus.AddAsync(menu, L10n.Text("windows.chatpage.remove_chat.92fd2fb8"), async () => await ConfirmDeleteAsync(id));
        return button;
    }

    private string RowDetail(JsonNode chat)
    {
        var backend = Backend(Format.Text(chat, "backend"));
        var agent = Format.Text(backend, "label", Format.Text(chat, "backend"));
        var mode = Format.Text(chat, "mode") == "plan" ? L10n.Text("windows.chatpage.plan.fa8ed0bd") : L10n.Text("windows.chatpage.execute.e3a67d95");
        return agent + " · " + mode;
    }

    private bool _creatingChat;

    public Task BeginNewChatAsync()
    {
        AppServices.OpenNewChat?.Invoke(_workspaceId);
        return Task.CompletedTask;
    }

    internal async Task StartNewChatWithDraftAsync(string text, NewChatSetup setup, IReadOnlyList<NewChatFile> files, Func<bool> ownsRequest, Action accepted)
    {
        if (!IsLoaded || !ownsRequest()) return;
        var created = await CreateAsync(setup, ownsRequest);
        if (!IsLoaded || !ownsRequest() || created is null || _openId != created || _opening || _draft.Text.Length > 0 || _attachments.Count > 0) return;
        _draft.Text = text;
        _attachments.AddRange(files.Select(file => new StagedFile("local-" + Guid.NewGuid().ToString("N"), file.Name, file)));
        RememberDraft(); RebuildAttachStrip();
        accepted(); // The writing now belongs to the new conversation, including refused sends.
        if (NewChatSetup.ShouldSend(text, files.Count)) await SendAsync();
    }

    private async Task<string?> CreateAsync(NewChatSetup? setup = null, Func<bool>? ownsRequest = null)
    {
        if (_creatingChat || ownsRequest?.Invoke() == false) return null;
        _creatingChat = true;
        try
        {
            var generation = _openGeneration;
            var account = AppServices.AccountGeneration;
            // Choosing a new agent needs its catalog; opening history does not.
            var backends = CallChatAsync("chat.backends");
            var personas = CallChatAsync("chat.personas", new JsonObject { ["workspaceId"] = _workspaceId });
            await Task.WhenAll(backends, personas);
            if (generation != _openGeneration || account != AppServices.AccountGeneration || !IsLoaded || ownsRequest?.Invoke() == false) return null;
            _backends = AsArray(backends.Result);
            _personas = AsArray(personas.Result, "personas");
            await RefreshCatalogAsync(refreshMenus: false);
            if (generation != _openGeneration || account != AppServices.AccountGeneration || !IsLoaded || ownsRequest?.Invoke() == false) return null;
            var saved = ChatLaunchChoice.Load();
            var chosen = setup is null ? DefaultBackend(saved?.Backend) : _backends.FirstOrDefault(backend => Format.Text(backend, "id") == setup.Backend && Installed(backend));
            if (setup is not null && !setup.IsAvailable(chosen)) throw new InvalidOperationException(L10n.Text("common.new_chat.setup_changed"));
            var request = new JsonObject
            {
                ["workspaceId"] = _workspaceId,
                ["backend"] = Format.Text(chosen, "id", "claude"),
                ["title"] = "New chat",
                // Always Execute, like the Mac. Plan is a choice for one piece
                // of work, and carried over it left every later chat planning
                // at somebody who had asked for something to be done.
                ["mode"] = setup?.Mode ?? "execute",
                // Don't ask unless the last chat was set to ask first. The
                // remembered choice still wins once somebody has made one.
                ["autonomy"] = Format.Text(chosen, "gateTier") == "bypassOnly"
                    ? "bypass"
                    : setup?.Autonomy ?? saved?.Autonomy ?? "bypass",
            };
            // The rest of the last setup travels when this agent still
            // offers it. A model or effort it no longer lists is dropped.
            if (setup is not null)
            {
                if (setup.Model is not null) request["model"] = setup.Model;
                if (setup.Effort is not null) request["effort"] = setup.Effort;
                if (setup.FastMode) request["fastMode"] = true;
            }
            else if (saved is not null && Format.Text(chosen, "id") == saved.Backend)
            {
                if (Offers(chosen, "models", saved.Model)) request["model"] = saved.Model;
                if (Offers(chosen, "efforts", saved.Effort)) request["effort"] = saved.Effort;
            }
            if (RememberedPersona(saved) is string personaId) request["personaId"] = personaId;
            var created = await CallChatAsync("chat.create", request);
            if (generation != _openGeneration || account != AppServices.AccountGeneration || !IsLoaded || ownsRequest?.Invoke() == false) return null;
            ChatLaunchChoice.Save(created);
            AppServices.NotifyConversationsChanged();
            if (generation != _openGeneration || account != AppServices.AccountGeneration || !IsLoaded) return null;
            var id = Format.Text(created, "id");
            await OpenAsync(id, created);
            return account == AppServices.AccountGeneration && IsLoaded && _openId == id ? id : null;
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return null;
        }
        finally { _creatingChat = false; }
    }

    /// <summary>
    /// Open one conversation by id, from a notification or a pin. When the
    /// list already holds it the thread opens at once; otherwise the id
    /// waits for the list load, like the Mac pending reveal. A second tap
    /// while the list is up re-reads it rather than waiting on a load that
    /// already ran.
    /// </summary>
    public async Task RevealAsync(string chatId)
    {
        if (string.IsNullOrEmpty(chatId)) return;
        if (HasChat(chatId))
        {
            await OpenAsync(chatId);
            return;
        }
        _pendingReveal = chatId;
        if (_listReady)
        {
            await ShowListAsync();
        }
    }

    private bool HasChat(string id)
    {
        foreach (var chat in _chats)
        {
            if (Format.Text(chat, "id") == id) return true;
        }
        return false;
    }

    private int _openGeneration;
    private bool _opening;

    private async Task OpenAsync(string id, JsonNode? created = null)
    {
        if (string.IsNullOrEmpty(id)) return;
        RememberDraft();
        _poll?.Cancel();
        var generation = ++_openGeneration;
        CancelDropImport();
        ResetImagePreviews();
        AbandonSteerDelivery();
        _opening = true;
        // Remove the previous conversation's controls before changing its id.
        // A pending open must never let a click send or rename the new chat
        // using controls still showing the previous chat.
        _composerDock.Child = null;
        _composerDock.Visibility = Visibility.Collapsed;
        _root.Children.Clear();
        _root.Children.Add(ActionIconGlyph.Button(L10n.Text("common.chats"), ActionIcon.Back, async (_, _) => await ShowListAsync()));
        _root.Children.Add(Motion.SkeletonCard());
        _openChat = null;
        _approvals = new JsonArray();
        _openId = id;
        ResetWorkspaceGit();
        RenderInspector();
        _offset = 0;
        _events = new JsonArray();
        _attachments.Clear();
        _draft.Text = "";
        ResetTranscriptWindow();
        try
        {
            // These reads are independent. Do not serialize transcript reveal
            // behind backend discovery, outbox identity, and approvals.
            var catalog = RefreshCatalogAsync(refreshMenus: _backends.Count == 0);
            var identity = OutboxKeyAsync(id);
            var preview = ChatPreviewCache.Take(_workspaceId, id);
            var events = preview is null ? CallChatAsync("chat.eventPage", new JsonObject
                { ["id"] = id, ["limit"] = 160, ["stablePositions"] = true }) : Task.FromResult(preview);
            var approvals = CallChatAsync("chat.approvals", new JsonObject { ["id"] = id });
            await Task.WhenAll(catalog, identity, events, approvals);
            if (_openId != id || generation != _openGeneration || !IsLoaded) return;
            _openChat = _chats.FirstOrDefault(chat => Format.Text(chat, "id") == id) ?? created;
            if (_openChat is null) { await ShowListAsync(); return; }
            _outboxKey = identity.Result;
            _authorizedQueue.Clear();
            ApplyHistoryPage(events.Result, replace: true);
            _approvals = AsArray(approvals.Result);
            _started = _events.Count > 0 || !string.IsNullOrEmpty(Format.Text(_openChat, "resumeToken"));
            _running = Format.Flag(_openChat, "running");
            if (_drafts.TryGetValue(identity.Result, out var draft))
            {
                _draft.Text = draft.Text;
                _attachments.AddRange(draft.Attachments);
            }
            _opening = false;
            PaintConversation();
            _ = RefreshWorkspaceGitAsync();
            CheckSelectedSignIn();
            StartPoll();
            ProbeSteerIfNeeded(fromBusyLoop: false);
        }
        catch (Exception ex)
        {
            if (_openId == id && generation == _openGeneration && IsLoaded)
            {
                Program.LogStartup($"Chat open failed: {ex}");
                _root.Children.Clear();
                _root.Children.Add(ActionIconGlyph.Button(L10n.Text("common.chats"), ActionIcon.Back, async (_, _) => await ShowListAsync()));
                _root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
                _root.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.chatpage.try_again.d8b8392e"), ActionIcon.Refresh, async (_, _) => await OpenAsync(id)));
            }
        }
    }

    private void PaintConversation()
    {
        TraceComposition("detaching");
        _composerDock.Child = null;
        _composerWell.Children.Clear();
        _composerRow.Children.Clear();
        Detach(_transcript);
        Detach(_attachStrip);
        Detach(_draft);
        Detach(_composerActions);
        Detach(_titleBox);
        Detach(_gitStrip);
        _root.Children.Clear();
        var chrome = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        chrome.Children.Add(ActionIconGlyph.Button(L10n.Text("common.chats"), ActionIcon.Back, async (_, _) => await ShowListAsync()));
        if (!SharedSource) chrome.Children.Add(ActionIconGlyph.Button(L10n.Text("common.delete"), ActionIcon.Delete, async (_, _) => await ConfirmDeleteAsync()));
        chrome.Children.Add(DetailButton());
        _root.Children.Add(chrome);

        if (_titleBox.FocusState == FocusState.Unfocused)
        {
            _titleBox.Text = Format.Text(_openChat, "title", L10n.Text("windows.chatpage.new_chat.db18382a"));
        }
        var readOnly = SharedSource;
        if (_titleBox.IsReadOnly != readOnly) _titleBox.IsReadOnly = readOnly;
        _root.Children.Add(_titleBox);
        TraceComposition("title mounted");

        _transcript.Children.Clear();
        RebuildTranscript(full: true);
        _root.Children.Add(_transcript);
        TraceComposition("transcript mounted");
        RefreshCost();
        // Usage remains in the inspector; the transcript contains messages only.
        _composerDock.Visibility = Visibility.Visible;
        _composerDock.Child = Composer();
        TraceComposition("composer mounted");
    }

    private void TraceComposition(string stage)
    {
        if (Environment.GetEnvironmentVariable("TOKENSTAT_UI_STARTUP_TRACE") == "1")
            Program.LogStartup($"Chat layout: {stage}; shared={SharedSource}");
    }

    private UIElement SetupCard(bool inspector = false)
    {
        var chat = _openChat ?? new JsonObject();
        var backendId = Format.Text(chat, "backend");
        var backend = Backend(backendId);
        var gate = Format.Text(backend, "gateTier", "full");
        var bypassOnly = gate == "bypassOnly";
        var running = Format.Flag(chat, "running");
        var body = new StackPanel { Spacing = Theme.SpaceM };
        if (!inspector)
        {
            var done = ActionIconGlyph.Button(L10n.Text("common.done"), ActionIcon.Done, (_, _) =>
            {
                _setupExpanded = false;
                PaintConversation();
            });
            AutomationProperties.SetAutomationId(done, "chat.setup.done");
            body.Children.Add(done);
        }
        var help = new StackPanel { Spacing = Theme.SpaceS };
        help.Children.Add(Chrome.SectionLabel(L10n.Text("windows.chatpage.how_this_chat_should_work.b5eec3c8")));
        help.Children.Add(Muted(L10n.Text("windows.chatpage.agent_model_and_mode_also_live_on_the_comp.23ec79e1")));

        var agent = AgentPicker(backendId, running);
        if (!inspector) AutomationProperties.SetAutomationId(agent, "chat.setup.agent");
        body.Children.Add(Labeled(L10n.Text("windows.chatpage.agent.11b39c93"), agent));
        if (_personas.Count > 0)
        {
            body.Children.Add(Labeled(L10n.Text("windows.chatpage.persona.31bdeef9"), PersonaPicker(Format.Text(chat, "personaId"), running)));
        }
        var models = backend?["models"] as JsonArray;
        if (models is { Count: > 0 })
        {
            // The list beside the picker is what the host read from the agent
            // CLI, cached for ten minutes. Add an API key to that CLI and the
            // provider it unlocks is real everywhere except here until the
            // cache expires, so the picker carries its own way to ask again.
            var picker = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceS,
                VerticalAlignment = VerticalAlignment.Center,
            };
            picker.Children.Add(OptionPicker(
                models,
                Format.Text(chat, "model"),
                running,
                async value => await UpdateAsync(new JsonObject { ["model"] = value })));
            picker.Children.Add(ActionIconGlyph.Button(
                L10n.Text("common.refresh"),
                ActionIcon.Refresh,
                async (_, _) => await ReloadBackendsAsync()));
            body.Children.Add(Labeled(L10n.Text("windows.chatpage.model.5e2c614c"), picker));
        }
        var efforts = backend?["efforts"] as JsonArray;
        if (efforts is { Count: > 0 })
        {
            body.Children.Add(Labeled(L10n.Text("windows.chatpage.effort.4387e5d3"), OptionPicker(
                efforts,
                Format.Text(chat, "effort"),
                running,
                async value => await UpdateAsync(new JsonObject { ["effort"] = value }),
                includeDefault: true)));
        }

        body.Children.Add(new Border { Height = 1, Background = Theme.BorderBrush });
        body.Children.Add(Chrome.SectionLabel(L10n.Text("common.chat_working_style")));
        body.Children.Add(ModePills(Format.Text(chat, "mode", "plan"), !running));
        var bypass = new CheckBox
        {
            Content = L10n.Text("windows.chatpage.work_without_asking.dde89661"),
            IsChecked = Format.Text(chat, "autonomy") == "bypass" || bypassOnly,
            IsEnabled = !running && !bypassOnly,
            Foreground = Theme.AccentBrush,
        };
        bypass.Checked += async (_, _) => await UpdateAsync(new JsonObject { ["autonomy"] = "bypass" });
        bypass.Unchecked += async (_, _) =>
        {
            if (bypassOnly) return;
            await UpdateAsync(new JsonObject { ["autonomy"] = "standard" });
        };
        body.Children.Add(bypass);
        help.Children.Add(Muted(GateCopy(gate, Format.Text(chat, "autonomy") == "bypass")));
        if (!inspector && bypassOnly && Format.Text(chat, "autonomy") != "bypass" && !running)
        {
            _ = UpdateAsync(new JsonObject { ["autonomy"] = "bypass" });
        }
        var setup = new StackPanel { Spacing = Theme.SpaceM };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(setup, L10n.Text("windows.chatpage.setup.7013af4c"));
        body.Children.Add(help);
        setup.Children.Add(SetupSection(L10n.Text("common.chat_agent_behavior"), body, ActionIcon.Run,
            primary: CompactAgentMenu(running)));
        setup.Children.Add(InstructionsCard(
            Format.Text(chat, "systemPrompt"),
            Format.Text(backend, "label", L10n.Text("windows.chatpage.this_agent.15af7e1b")),
            running));
        return setup;
    }

    /// <summary>
    /// What a conversation tells its agent before it hears the person. The
    /// brief belongs to the person and is editable here; the one rule
    /// tokenstat adds is readable under it rather than described.
    /// </summary>
    private UIElement InstructionsCard(string systemPrompt, string agent, bool running)
    {
        var chatId = _openId;
        var generation = _openGeneration; var account = AppServices.AccountGeneration;
        var owner = $"{account}/{_workspaceId}/{chatId}";
        bool Current() => chatId is not null && OpenChatIs(chatId) && generation == _openGeneration && account == AppServices.AccountGeneration;
        var stack = new StackPanel { Spacing = Theme.SpaceS };

        var brief = new TextBox
        {
            PlaceholderText = L10n.Text("windows.chatpage.how_should_this_agent_behave.6cee0aaf"),
            Text = _instructionDrafts.GetValueOrDefault(owner, systemPrompt),
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 76,
            IsEnabled = !running,
        };
        stack.Children.Add(brief);
        var primary = new FlowPanel { Spacing = Theme.SpaceS };
        var edit = ActionIconGlyph.Button(L10n.Text("common.edit"), ActionIcon.Edit, (_, _) => { });
        edit.IsEnabled = !running; primary.Children.Add(edit);
        var note = Muted(L10n.Text("windows.chatpage.sent_as_an_instruction_never_as_part_of_yo.48abdbf3"));
        stack.Children.Add(note);
        // The handler is attached after creation so it can name the button
        // it hides. Declaring the handler inline would use save before it
        // exists.
        var save = ActionIconGlyph.PrimaryButton(L10n.Text("common.save"), ActionIcon.Save, (_, _) => { });
        save.Click += async (_, _) =>
        {
            if (!Current() || Busy() || _savingInstructions) return;
            var text = brief.Text;
            _savingInstructions = true; save.IsEnabled = false;
            try {
                await UpdateAsync(new JsonObject { ["systemPrompt"] = text });
                if (Current() && _instructionDrafts.TryGetValue(owner, out var latestDraft) && Format.Text(_openChat, "systemPrompt") == latestDraft)
                {
                    _instructionDrafts.Remove(owner);
                    save.Visibility = Visibility.Collapsed;
                }
            } finally {
                _savingInstructions = false;
                if (IsLoaded) RenderInspector();
            }
        };
        save.IsEnabled = !running && !_savingInstructions;
        save.Visibility = brief.Text != systemPrompt ? Visibility.Visible : Visibility.Collapsed;
        brief.TextChanged += (_, _) =>
        {
            if (!Current()) return;
            if (brief.Text == systemPrompt && !_savingInstructions) _instructionDrafts.Remove(owner);
            else _instructionDrafts[owner] = brief.Text;
            save.Visibility = brief.Text != systemPrompt ? Visibility.Visible : Visibility.Collapsed;
        };
        primary.Children.Add(save);
        var added = new TextBlock
        {
            FontFamily = Fonts.Mono,
            FontSize = 11,
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            Visibility = Visibility.Collapsed,
        };
        var toggle = ActionIconGlyph.Button(
            L10n.Text("windows.chatpage.what_tokenstat_adds.358d9a68"), ActionIcon.More, (_, _) =>
            {
                added.Visibility = added.Visibility == Visibility.Visible
                    ? Visibility.Collapsed
                    : Visibility.Visible;
            });
        stack.Children.Add(toggle);
        stack.Children.Add(added);
        var requested = false;
        void ReadInstructions() { if (!requested && chatId is not null && Current()) { requested = true; _ = LoadInstructionsAsync(chatId, agent, note, added); } }
        var section = SetupSection(L10n.Text("windows.chatpage.instructions.934652dc"), stack, ActionIcon.Docs,
            string.IsNullOrEmpty(brief.Text) ? L10n.Text("windows.chatpage.how_should_this_agent_behave.6cee0aaf") : brief.Text.Split('\n').FirstOrDefault(), primary, edit, ReadInstructions);
        edit.Click += (_, _) => brief.Focus(FocusState.Programmatic);
        return section;
    }

    private async Task LoadInstructionsAsync(string chatId, string agent, TextBlock note, TextBlock added)
    {
        JsonNode answer;
        try
        {
            answer = await CallChatAsync(
                "chat.instructions", new JsonObject { ["id"] = chatId });
        }
        catch
        {
            return;
        }
        if (_openId != chatId)
        {
            return;
        }
        var text = Format.Text(answer, "added");
        added.Text = string.IsNullOrEmpty(text) ? L10n.Text("windows.chatpage.not_available_on_this_computer.ffcbd9b9") : text;
        note.Text = Format.Text(answer, "channel") == "systemPrompt"
            ? L10n.Text("windows.chatpage.0_takes_this_as_a_system_prompt_so_it_is_n.dc332cd6", $"{agent}")
            : L10n.Text("windows.chatpage.0_has_no_system_prompt_flag_so_this_is_sen.01aa66c2", $"{agent}");
    }

    private UIElement AgentPicker(string current, bool disabled)
    {
        var box = new ComboBox { MinWidth = 220, IsEnabled = !disabled };
        foreach (var backend in _backends)
        {
            if (backend is null) continue;
            var id = Format.Text(backend, "id");
            if (id == "sh" && id != current) continue;
            // Installed agents only. The current one stays listed so the
            // picker can still name it.
            if (!Installed(backend) && id != current) continue;
            box.Items.Add(new ComboBoxItem
            {
                Content = Format.Text(backend, "label", id),
                Tag = id,
            });
            if (id == current) box.SelectedIndex = box.Items.Count - 1;
        }
        if (box.SelectedIndex < 0 && box.Items.Count > 0) box.SelectedIndex = 0;
        box.SelectionChanged += async (_, _) =>
        {
            if (_suppress || box.SelectedItem is not ComboBoxItem item) return;
            var next = item.Tag as string ?? "";
            var gate = Format.Text(Backend(next), "gateTier");
            var patch = new JsonObject { ["backend"] = next };
            if (gate == "bypassOnly") patch["autonomy"] = "bypass";
            await UpdateAsync(patch);
            PaintConversation();
        };
        return box;
    }

    private UIElement PersonaPicker(string current, bool disabled)
    {
        // A live likeness beside the picker, seeded by the persona id like the
        // Mac mark. It wanders through its leisure repertoire while the person
        // reads the setup card.
        var face = new PersonaPastime(
            string.IsNullOrEmpty(current) ? 0 : PersonaSeed.For(current), 40);
        face.VerticalAlignment = VerticalAlignment.Center;
        var box = new ComboBox { MinWidth = 220, IsEnabled = !disabled };
        box.Items.Add(new ComboBoxItem { Content = L10n.Text("windows.chatpage.no_preset.396e7b77"), Tag = "" });
        box.SelectedIndex = 0;
        foreach (var persona in _personas)
        {
            if (persona is null) continue;
            var id = Format.Text(persona, "id");
            var mark = Format.Text(persona, "mark");
            var name = Format.Text(persona, "name", L10n.Text("windows.chatpage.persona.31bdeef9"));
            box.Items.Add(new ComboBoxItem
            {
                Content = string.IsNullOrEmpty(mark) ? name : mark + "  " + name,
                Tag = id,
            });
            if (id == current) box.SelectedIndex = box.Items.Count - 1;
        }
        box.SelectionChanged += async (_, _) =>
        {
            if (_suppress || box.SelectedItem is not ComboBoxItem item) return;
            var id = item.Tag as string ?? "";
            face.Seed = string.IsNullOrEmpty(id) ? 0 : PersonaSeed.For(id);
            if (string.IsNullOrEmpty(id))
            {
                await UpdateAsync(new JsonObject { ["personaId"] = "", ["systemPrompt"] = "" });
                return;
            }
            var persona = FindPersona(id);
            if (persona is null) return;
            // Like the Mac: a persona is a name and a brief. It leaves the
            // agent, model, mode and autonomy as the person set them.
            await UpdateAsync(new JsonObject
            {
                ["personaId"] = id,
                ["systemPrompt"] = Format.Text(persona, "systemPrompt"),
            });
            PaintConversation();
        };
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(face);
        row.Children.Add(box);
        return row;
    }

    private UIElement OptionPicker(
        JsonArray options,
        string current,
        bool disabled,
        Func<string, Task> onChange,
        bool includeDefault = false)
    {
        var box = new ComboBox { MinWidth = 180, IsEnabled = !disabled };
        if (includeDefault)
        {
            box.Items.Add(new ComboBoxItem { Content = L10n.Text("windows.chatpage.default.21b111cb"), Tag = "" });
            if (string.IsNullOrEmpty(current)) box.SelectedIndex = 0;
        }
        foreach (var option in options)
        {
            var value = option is JsonValue v && v.TryGetValue<string>(out var text) ? text : option?.ToString() ?? "";
            if (string.IsNullOrEmpty(value)) continue;
            box.Items.Add(new ComboBoxItem { Content = value, Tag = value });
            if (value == current) box.SelectedIndex = box.Items.Count - 1;
        }
        if (current.Length > 0 && box.SelectedIndex < 0)
        {
            box.Items.Add(new ComboBoxItem { Content = current, Tag = current });
            box.SelectedIndex = box.Items.Count - 1;
        }
        if (box.SelectedIndex < 0 && box.Items.Count > 0) box.SelectedIndex = 0;
        box.SelectionChanged += async (_, _) =>
        {
            if (_suppress || box.SelectedItem is not ComboBoxItem item) return;
            await onChange(item.Tag as string ?? "");
        };
        return box;
    }

    private UIElement ModePills(string mode, bool enabled)
    {
        return Chrome.Segmented(
            [("plan", L10n.Text("windows.chatpage.plan.fa8ed0bd")), ("execute", L10n.Text("windows.chatpage.execute.e3a67d95"))],
            mode,
            async value =>
            {
                await UpdateAsync(new JsonObject { ["mode"] = value });
                PaintConversation();
            },
            enabled: enabled);
    }

    private string ItemContentKey(DisplayItem item) => item.GroupId + "|" + item.Plain + "|" + (item.Kind switch
    {
        ItemKind.Group => $"{item.Id}|{StepGroupKey(item.Group)}",
        ItemKind.Question => $"{item.Id}|{item.Question?.Answer}|{item.Question?.Delivery}|{_answering.Contains(item.Question?.Id ?? "")}",
        ItemKind.User => $"{item.Id}|{item.IsSteer}|{item.Text}",
        ItemKind.Assistant => $"{item.Id}|{item.Text}",
        ItemKind.Thinking => $"{item.Id}|{item.Text}",
        ItemKind.Tool => $"{item.Id}|{item.Verb}|{item.Target}|{item.Running}|{item.Failed}|{item.Duration}|{item.Detail}|{CardExpanded(item)}",
        ItemKind.Edit => $"{item.Id}|{item.Path}|{item.Added}|{item.Removed}|{item.Patch}|{item.Running}|{item.Failed}|{item.Duration}|{CardExpanded(item)}",
        ItemKind.Approval => $"{item.Id}|{item.Pending}|{item.Approval?.ToJsonString()}",
        ItemKind.Attachment => $"{item.Id}|{item.Name}|{item.MediaType}|{item.Size}",
        ItemKind.Gallery => $"{item.Id}|{string.Join(";", item.Images?.Select(image => image.Id + ":" + image.Name + ":" + image.Size) ?? [])}",
        ItemKind.Usage => $"{item.Id}|{item.Input}|{item.Output}|{item.Cost}",
        ItemKind.Failed => $"{item.Id}|{item.Text}",
        ItemKind.Changes => $"{item.Id}|{string.Join(",", item.Changes?.Select(file => $"{file.Path}:{file.Added}:{file.Removed}") ?? Enumerable.Empty<string>())}|{_expandedCards.GetValueOrDefault(item.Id)}",
        _ => item.Id,
    });

    private void RebuildTranscript(bool full = false)
    {
        if (full)
        {
            _transcript.Children.Clear();
        }
        // `raw` is every row, for the seat line, which must see a running
        // step whether or not it is folded away. `items` is what is drawn.
        var raw = Coalesce(_events);
        var busy = Busy(raw);
        var items = ChatImageGallery.Compose(ChatDetailFold.Fold(raw, ChatDetailPreference.Level, _running, IsGroupOpen));
        // Reused count cards resolve their review at click time. A late patch
        // can change without changing the card's file names or line counts.
        _turnReviews.Clear();
        foreach (var item in items)
            if (item.Kind == ItemKind.Changes && item.Changes is { } files) _turnReviews[item.Id] = files;
        _sliceOlder = SliceClamp(_sliceOlder, items.Count);
        var start = SliceStart(items.Count, _sliceOlder);
        var end = SliceEnd(items.Count, _sliceOlder);
        var prefix = start > 0 || _hasEarlier ? 1 : 0;
        var visible = end - start;
        var activity = _sliceOlder == 0 ? ChatActivityData.Read(CurrentInspection, _openChat) : null;
        var planCount = activity?.PlanReported == true && activity.Plan.Length > 0 ? 1 : 0;
        var desiredCount = prefix + visible + planCount + (busy ? 1 : 0);

        if (prefix == 1)
        {
            var earlierKey = "__earlier__:" + start + ":" + _historyLoading;
            var current = _transcript.Children.Count > 0
                ? _transcript.Children[0] as FrameworkElement
                : null;
            if (current?.Tag as string != earlierKey)
            {
                var earlier = ShowEarlierButton(start);
                earlier.Tag = earlierKey;
                if (_transcript.Children.Count > 0)
                {
                    _transcript.Children.RemoveAt(0);
                    _transcript.Children.Insert(0, earlier);
                }
                else
                {
                    _transcript.Children.Add(earlier);
                }
            }
        }

        for (int i = 0; i < visible; i++)
        {
            var item = items[start + i];
            var key = ItemContentKey(item);
            var index = prefix + i;

            if (index < _transcript.Children.Count)
            {
                var existing = _transcript.Children[index] as FrameworkElement;
                if (existing?.Tag as string == key)
                {
                    continue;
                }
                var updated = Render(item);
                if (updated is FrameworkElement fe) fe.Tag = key;
                _transcript.Children.RemoveAt(index);
                _transcript.Children.Insert(index, updated);
            }
            else
            {
                var created = Render(item);
                if (created is FrameworkElement fe) fe.Tag = key;
                _transcript.Children.Add(created);
            }
        }

        if (planCount > 0 && activity is not null)
        {
            var index = prefix + visible;
            var key = "__activity_plan__:" + System.Text.Json.JsonSerializer.Serialize(new { activity.Plan, activity.Live });
            var current = index < _transcript.Children.Count ? _transcript.Children[index] as FrameworkElement : null;
            if (current?.Tag as string != key)
            {
                var checklist = ActivityPlanChecklist(activity); checklist.Tag = key;
                if (index < _transcript.Children.Count) _transcript.Children.RemoveAt(index);
                _transcript.Children.Insert(index, checklist);
            }
        }

        if (busy)
        {
            var workingIdx = prefix + visible + planCount;
            var mood = LiveMood(raw);
            var words = mood == PersonaMood.Working ? WorkingWords(raw) : mood.Label();
            // The words are part of the key, so thinking turning into reading
            // a file rebuilds the row instead of leaving the old sentence.
            var workingKey = "__working__:" + words;
            if (workingIdx < _transcript.Children.Count)
            {
                var existing = _transcript.Children[workingIdx] as FrameworkElement;
                if (existing?.Tag as string != workingKey)
                {
                    var workingBlock = WorkingRow(mood, words);
                    workingBlock.Tag = workingKey;
                    _transcript.Children.RemoveAt(workingIdx);
                    _transcript.Children.Insert(workingIdx, workingBlock);
                }
            }
            else
            {
                var working = WorkingRow(mood, words);
                working.Tag = workingKey;
                _transcript.Children.Add(working);
            }
        }

        while (_transcript.Children.Count > desiredCount)
        {
            _transcript.Children.RemoveAt(_transcript.Children.Count - 1);
        }

        if (_followEnd && _sliceOlder == 0)
        {
            _scroll?.ChangeView(null, _scroll.ScrollableHeight, null, true);
        }
        UpdateFollowPill();
    }

    private UIElement Render(DisplayItem item)
    {
        UIElement view = item.Kind switch
        {
        ItemKind.Tool or ItemKind.Edit when item.Plain == PlainStep.Detail => PlainStepDetail(item),
        ItemKind.Tool or ItemKind.Edit when item.Plain == PlainStep.Line => PlainStepRow(item),
        ItemKind.User => UserBubble(item.Text, item.IsSteer),
        ItemKind.Assistant => AssistantBubble(item.Text),
        ItemKind.Thinking => ThinkingRow(item.Text),
        ItemKind.Tool => ToolRow(item),
        ItemKind.Edit => EditRow(item),
        ItemKind.Approval => ApprovalCard(item),
        ItemKind.Attachment => AttachmentRow(item),
        ItemKind.Gallery => ImageGalleryRow(item),
        ItemKind.Usage => UsageLine(item),
        ItemKind.Failed => FailedRow(item),
        ItemKind.Group when item.Group is { } group => StepGroupRow(item.Id, group),
        ItemKind.Question when item.Question is { } question => QuestionCard(question),
        ItemKind.Changes when item.Changes is { } files => ChangesCard(item.Id, files),
        _ => new Border(),
        };
        if (!string.IsNullOrEmpty(item.GroupId)) view = GroupStepInset(view);
        if (view is FrameworkElement element && !string.IsNullOrEmpty(item.Text))
        {
            var title = item.Kind == ItemKind.Assistant ? L10n.Text("windows.chatpage.copy_response.f0f755af") : item.Kind == ItemKind.Thinking ? L10n.Text("windows.chatpage.copy_reasoning.5d2976d8") : L10n.Text("common.copy");
            ContextMenus.Copy(ContextMenus.Menu(element), title, () => item.Text);
        }
        return view;
    }

    /// <summary>
    /// A failed turn: the same character that was thinking is the one that
    /// droops, like the Mac failed row.
    /// </summary>
    private UIElement FailedRow(DisplayItem item)
    {
        var grid = new Grid { ColumnSpacing = Theme.SpaceS };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(1, GridUnitType.Star),
        });
        var face = new PersonaMark(FaceSeed(), 26, PersonaMood.Failed);
        face.VerticalAlignment = VerticalAlignment.Top;
        grid.Children.Add(face);
        var text = new TextBlock
        {
            Text = item.Text,
            Foreground = Theme.Brush(static () => Theme.Danger),
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        return grid;
    }

    /// <summary>
    /// The turn still being written: the conversation's own face beside what
    /// it is doing, like the Mac working indicator. Thinking pastimes rather
    /// than holding a pose, because one loop held for a minute reads as a
    /// hang. The face is the motion, so the label beside it stays still.
    /// </summary>
    private FrameworkElement WorkingRow(PersonaMood mood, string words)
    {
        FrameworkElement face = mood == PersonaMood.Thinking
            ? new PersonaPastime(FaceSeed(), 26, PersonaPastime.Repertoire.Thought)
            : new PersonaMark(FaceSeed(), 26, mood);
        face.VerticalAlignment = VerticalAlignment.Center;
        var grid = new Grid { ColumnSpacing = Theme.SpaceS };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(1, GridUnitType.Star),
        });
        grid.Children.Add(face);
        var label = new TextBlock
        {
            Text = words,
            FontSize = 12,
            Opacity = 0.7,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            MaxLines = 1,
        };
        AutomationProperties.SetName(label, words);
        Grid.SetColumn(label, 1);
        grid.Children.Add(label);
        var seat = new Border
        {
            Height = WorkingSeatHeight,
            Padding = new Thickness(Theme.SpaceM, 0, Theme.SpaceM, 0),
            Child = grid,
        };
        AutomationProperties.SetName(seat, words);
        return seat;
    }

    /// <summary>
    /// What the working row says it is doing. An approval waiting on the
    /// person wins over everything, then a running tool or edit, then growing
    /// prose, like the Mac live mood.
    /// </summary>
    private PersonaMood LiveMood(List<DisplayItem> items)
    {
        if (HasPendingApproval()) return PersonaMood.Waiting;
        foreach (var item in items)
        {
            if (item.Running && (item.Kind == ItemKind.Tool || item.Kind == ItemKind.Edit))
            {
                return PersonaMood.Working;
            }
        }
        if (items.Count > 0)
        {
            var last = items[^1];
            if (last.Kind == ItemKind.Assistant && !string.IsNullOrEmpty(last.Text))
            {
                return PersonaMood.Speaking;
            }
        }
        return PersonaMood.Thinking;
    }

    /// <summary>
    /// The newest running tool or edit, in the words the seat shows.
    /// Other running rows are skipped, so a later tool stays visible.
    /// With none left, the sentence is the same word the mood already uses.
    /// </summary>
    private static string WorkingWords(List<DisplayItem> items)
    {
        for (var index = items.Count - 1; index >= 0; index--)
        {
            var item = items[index];
            if (!item.Running) continue;
            if (item.Kind == ItemKind.Tool) return SeatStep.Phrase(item.Verb, item.Target);
            if (item.Kind == ItemKind.Edit) return SeatStep.Phrase("Edit", item.Path);
        }
        return L10n.Text("common.working");
    }

    private bool HasPendingApproval()
    {
        foreach (var live in _approvals)
        {
            if (string.IsNullOrEmpty(Format.Text(live, "decision"))) return true;
        }
        return false;
    }

    /// <summary>
    /// The face of the conversation on screen. Its persona's, when it has
    /// one, so the same character follows a persona between chats. Otherwise
    /// the chat's own, derived from its id, like the Mac face seed.
    /// </summary>
    private ulong FaceSeed()
    {
        var personaId = Format.Text(_openChat, "personaId");
        if (!string.IsNullOrEmpty(personaId)) return PersonaSeed.For(personaId);
        if (!string.IsNullOrEmpty(_openId)) return PersonaSeed.For(_openId);
        return PersonaSeed.For("chat");
    }

    private static UIElement UserBubble(string text, bool steer = false)
    {
        var body = new StackPanel { Spacing = 4 };
        if (steer) body.Children.Add(new TextBlock { Text = L10n.Text("common.chat.steer"), FontSize = 12, Foreground = Theme.AccentBrush });
        body.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        var bubble = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Right,
            MaxWidth = 560,
            Background = Theme.AccentSoftBrush,
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(Theme.SpaceM),
            Child = body,
        };
        if (steer) ToolTipService.SetToolTip(bubble, L10n.Text("common.chat.steer_help"));
        return bubble;
    }

    /// <summary>
    /// The reply side of the conversation, like the Mac row: full width,
    /// panel fill and a hairline, the same radius as the user bubble.
    /// </summary>
    private static UIElement AssistantBubble(string text) => new Border
    {
        HorizontalAlignment = HorizontalAlignment.Stretch,
        Background = Theme.PanelBrush,
        BorderBrush = Theme.BorderBrush,
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(16),
        Padding = new Thickness(Theme.SpaceM),
        Child = AssistantBody(text),
    };

    /// <summary>
    /// The reply as markdown, like the Mac. Fenced code keeps this page's
    /// code block, with its copy menu and horizontal scrolling.
    /// </summary>
    private static UIElement AssistantBody(string text) => ChatMarkdown.Create(text, CodeBlock);

    private static UIElement CodeBlock(string code)
    {
        var block = new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(Theme.SpaceM),
            Child = new ScrollViewer
            {
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Content = new TextBlock
                {
                    Text = code,
                    FontFamily = Fonts.Mono,
                    FontSize = 12,
                    IsTextSelectionEnabled = true,
                },
            },
        };
        ContextMenus.Copy(ContextMenus.Menu(block), L10n.Text("windows.chatpage.copy_code.49a0053f"), () => code);
        return block;
    }

    private UIElement ApprovalCard(DisplayItem item)
    {
        var approval = item.Approval ?? new JsonObject();
        var pending = item.Pending;
        var verb = Format.Text(approval, "verb");
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock
        {
            Text = pending ? L10n.Text("windows.chatpage.permission_needed.4e25d34a") : L10n.Text("windows.chatpage.permission_answered.82fb2221"),
            FontWeight = FontWeights.SemiBold,
        });
        body.Children.Add(Chip(SeatStep.ApprovalWord(verb, pending)));
        body.Children.Add(new TextBlock
        {
            Text = Format.Text(approval, "preview"),
            FontFamily = Fonts.Mono,
            FontSize = 12,
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.Wrap,
        });
        if (pending)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            var id = Format.Text(approval, "id");
            actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.chatpage.allow.e213c161"), ActionIcon.Allow, async (_, _) => await ResolveAsync(id, "allow")));
            actions.Children.Add(ActionIconGlyph.PrimaryButton(L10n.Text("windows.chatpage.always_allow.977618bd"), ActionIcon.Allow, async (_, _) => await ResolveAsync(id, "allowAlways")));
            actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.chatpage.deny.05a2d733"), ActionIcon.Deny, async (_, _) => await ResolveAsync(id, "deny")));
            body.Children.Add(actions);
            var note = SeatStep.AllowAlwaysNote(verb, Format.Text(approval, "shellPrefix"));
            if (!string.IsNullOrEmpty(note)) body.Children.Add(Muted(note));
        }
        else
        {
            body.Children.Add(Muted(L10n.Text("windows.chatpage.this_request_is_no_longer_waiting.b64fd4de")));
        }
        var border = (Border)Card(L10n.Text("windows.chatpage.permission.229efc8f"), body);
        border.BorderBrush = pending ? Theme.Brush(static () => Theme.Accent) : Theme.BorderBrush;
        return border;
    }

    private UIElement AttachmentRow(DisplayItem item)
    {
        var detail = item.MediaType;
        if (item.Size > 0)
        {
            var size = item.Size >= 1024 * 1024
                ? string.Format(CultureInfo.InvariantCulture, "{0:0.#} MB", item.Size / (1024.0 * 1024.0))
                : item.Size >= 1024
                    ? string.Format(CultureInfo.InvariantCulture, "{0:0.#} KB", item.Size / 1024.0)
                    : item.Size + " B";
            detail = string.IsNullOrEmpty(detail) ? size : detail + " · " + size;
        }
        var body = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        body.Children.Add(new SymbolIcon(ActionIcon.Attach.Symbol())
        {
            Foreground = Theme.AccentBrush,
        });
        var text = new StackPanel { Spacing = 2 };
        text.Children.Add(new TextBlock
        {
            Text = item.Name,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        if (!string.IsNullOrEmpty(detail))
        {
            text.Children.Add(new TextBlock
            {
                Text = detail,
                FontSize = 12,
                Opacity = 0.78,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            });
        }
        body.Children.Add(text);
        body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.download"), ActionIcon.Download, async (_, _) => await DownloadFileAsync(item)));
        return Card(L10n.Text("windows.chatpage.attachment.040d2b36"), body);
    }

    private static UIElement UsageLine(DisplayItem item)
    {
        var text = string.Format(
            CultureInfo.InvariantCulture,
            L10n.Text("windows.chatpage.0_n0_in_1_n0_out.bcfb97ef"),
            item.Input,
            item.Output);
        if (item.Cost > 0)
        {
            text += "  ·  " + item.Cost.ToString("C2", CultureInfo.GetCultureInfo("en-US"));
        }
        return new TextBlock
        {
            Text = text,
            FontSize = 12,
            Opacity = 0.66,
        };
    }

    private void RefreshCost()
    {
        RenderInspector();
    }

    /// <summary>
    /// The chat's agent is not on this computer. Like the Mac notice: say so
    /// above the draft, keep the draft, and offer the way out. Send stays off
    /// until another agent is chosen, rather than failing a turn.
    /// </summary>
    private UIElement MissingAgentNotice()
    {
        var backendId = Format.Text(_openChat, "backend");
        var label = Format.Text(Backend(backendId), "label", backendId);
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.chatpage.0_isn_t_installed_on_this_computer.27bea130", $"{label}"),
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(ActionIconGlyph.Button(
            L10n.Text("windows.chatpage.set_up_or_choose_another_agent.f544267b"), ActionIcon.Create, (_, _) =>
            {
                _setupExpanded = true;
                PaintConversation();
            }));
        return new Border
        {
            Background = Theme.Brush(static () => Windows.UI.Color.FromArgb(20, Theme.Warning.R, Theme.Warning.G, Theme.Warning.B)),
            BorderBrush = Theme.Brush(static () => Windows.UI.Color.FromArgb(89, Theme.Warning.R, Theme.Warning.G, Theme.Warning.B)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(Theme.SpaceM, Theme.SpaceS, Theme.SpaceM, Theme.SpaceS),
            Child = body,
        };
    }

    private UIElement AgentSetupNotice(JsonNode backend)
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock { Text = L10n.Text("windows.agentsetup.check_setup", Format.Text(backend, "label")), TextWrapping = TextWrapping.Wrap });
        body.Children.Add(new TextBlock { Text = RemoteWorkspaces.IsRemote(_workspaceId)
            ? L10n.Text("windows.agentsetup.remote") : L10n.Text("windows.agentsetup.local"), TextWrapping = TextWrapping.Wrap });
        if (AgentSignInDialog.Supported(backend))
        {
            var signIn = ActionIconGlyph.Button(L10n.Text("windows.agentsetup.open_terminal"), ActionIcon.SignIn, async (_, _) => await OpenAgentSignInAsync(backend));
            signIn.IsEnabled = !Busy();
            body.Children.Add(signIn);
        }
        else body.Children.Add(new TextBlock { Text = L10n.Text("windows.agentsetup.legacy", Format.Text(backend, "label")), TextWrapping = TextWrapping.Wrap });
        var check = ActionIconGlyph.Button(L10n.Text("windows.agentsetup.check_again"), ActionIcon.Refresh, async (_, _) =>
        {
            var chat = _openId;
            var generation = _openGeneration;
            try
            {
                var readiness = await AgentSignInDialog.CheckAsync(backend, CallChatAsync);
                if (chat == _openId && generation == _openGeneration) backend["readiness"] = readiness;
            }
            catch (Exception ex) { if (chat == _openId && generation == _openGeneration) Banner(ex.Message); }
            if (chat == _openId && generation == _openGeneration) PaintConversation();
        });
        check.IsEnabled = !Busy();
        body.Children.Add(check);
        return Chrome.Card(L10n.Text("windows.agentsetup.setup_title", Format.Text(backend, "label")), body);
    }

    private async Task OpenAgentSignInAsync(JsonNode backend)
    {
        if (Busy()) return;
        var chat = _openId;
        var generation = _openGeneration;
        try
        {
            var readiness = await AgentSignInDialog.ShowAsync(this, _workspaceId, backend, CallChatAsync);
            if (chat == _openId && generation == _openGeneration && readiness is not null) backend["readiness"] = readiness;
        }
        catch (Exception ex) { if (chat == _openId && generation == _openGeneration) Banner(ex.Message); }
        if (chat == _openId && generation == _openGeneration) PaintConversation();
    }

    private UIElement Composer()
    {
        try { return ComposerContent(); }
        catch (Exception error)
        {
            Program.LogStartup($"Chat composer construction failed: {error}");
            throw;
        }
    }

    private UIElement ComposerContent()
    {
        var well = _composerWell = new StackPanel { Spacing = Theme.SpaceS };
        // Setup and notices can grow independently of the draft. Keep their
        // combined height bounded so Send stays reachable on short windows.
        // Once the dock is unmounted, WinUI may no longer report the strip's
        // parent. Release it through its logical owner before moving it.
        _setupScroll.Content = null;
        _composerContext.Children.Clear();
        var context = _composerContext = new StackPanel { Spacing = Theme.SpaceS };
        if (SharedSource) context.Children.Add(SharedSourceNotice());
        var placeholder = L10n.Text(SharedSource ? "common.teams.private_draft_placeholder" : "windows.chatpage.ask_about_this_folder.33b8b41b");
        if (_draft.PlaceholderText != placeholder) _draft.PlaceholderText = placeholder;
        TraceComposition("composer context prepared");
        RenderGitStrip();
        context.Children.Add(_gitStrip);
        if (_setupExpanded && !SharedSource)
        {
            context.Children.Add(SetupCard());
        }
        _draft.Background = Theme.PanelBrush;
        _draft.BorderThickness = new Thickness(0);
        _draft.MinHeight = 76;
        var steerNote = PendingSteerText(_openChat);
        if (steerNote.Length > 0) context.Children.Add(SteerNoteBanner(steerNote));
        context.Children.Add(PendingMessages());
        if (OpenBackendMissing()) context.Children.Add(MissingAgentNotice());
        var setupBackend = Backend(Format.Text(_openChat, "backend"));
        if (setupBackend is not null && Installed(setupBackend) && Format.Text(setupBackend, "id") != "sh"
            // Only a state with a next step. Agents whose login nothing can
            // read are always "unknown", and a notice on all of them is noise.
            && Format.Text(setupBackend, "readiness") is "needsSignIn" or "expired") context.Children.Add(AgentSetupNotice(setupBackend));
        _setupScroll.Content = context;
        FitSetupViewport();
        well.Children.Add(_setupScroll);
        Detach(_activitySummaryHost);
        RenderActivitySummary();
        well.Children.Add(_activitySummaryHost);
        well.Children.Add(_draft);
        TraceComposition("draft mounted");
        RebuildAttachStrip();
        well.Children.Add(_attachStrip);
        context.Children.Add(_commandScroll);
        RenderCommandMenu();
        var row = _composerRow = new Grid { ColumnSpacing = Theme.SpaceS };
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var attach = Buttons.ToolbarIcon(ActionIcon.Attach, L10n.Text("windows.chatpage.attach_a_file.21298c62"), async (_, _) => await AttachAsync());
        attach.IsEnabled = !_queueing && !_sending && !_pickingAttachment && _fileTransfer is null && _dropImport is null;
        var attachmentTools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        attachmentTools.Children.Add(attach);
        attachmentTools.Children.Add(FastModeButton());
        var options = CompactSetup();
        Grid.SetColumn((FrameworkElement)options, 1);
        RebuildComposerActions();
        Grid.SetColumn(_composerActions, 2);
        row.Children.Add(attachmentTools);
        row.Children.Add(options);
        row.Children.Add(_composerActions);
        // Keep the same draft, menu and action controls mounted across a
        // resize. Compact settings get the full width above Attach and Send.
        bool? compact = null;
        void FitControls(double width)
        {
            var next = width < 640;
            if (compact == next) return;
            compact = next;
            Grid.SetColumn((FrameworkElement)options, next ? 0 : 1);
            Grid.SetColumnSpan((FrameworkElement)options, next ? 3 : 1);
            Grid.SetRow(attachmentTools, next ? 1 : 0);
            Grid.SetRow(_composerActions, next ? 1 : 0);
            row.RowSpacing = next ? Theme.SpaceS : 0;
        }
        FitControls(_composerDock.ActualWidth);
        row.SizeChanged += (_, args) => FitControls(args.NewSize.Width);
        well.Children.Add(row);
        return new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(10),
            Child = well,
        };
    }

    private void FitSetupViewport()
    {
        // Leave room for the draft, wrapped controls and transcript even on a
        // short window. Bound setup and all notices together rather than
        // allowing their combined height to push Send outside the page.
        _setupScroll.MaxHeight = Math.Max(0, Math.Min(280, ActualHeight - 280));
    }

    private void DraftOnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var matches = CommandMatches();
        if (matches.Length > 0 && e.Key is VirtualKey.Up or VirtualKey.Down)
        {
            _commandIndex = (_commandIndex + (e.Key == VirtualKey.Down ? 1 : matches.Length - 1)) % matches.Length;
            RenderCommandMenu();
            if (_commandMenu.Children[_commandIndex] is FrameworkElement selected) selected.StartBringIntoView();
            e.Handled = true; return;
        }
        if (matches.Length > 0 && e.Key == VirtualKey.Escape) { _commandsDismissed = true; RenderCommandMenu(); e.Handled = true; return; }
        if (matches.Length > 0 && e.Key == VirtualKey.Enter && _draft.Text.Trim() != matches[_commandIndex].Name)
        { _draft.Text = matches[_commandIndex].Name; _draft.SelectionStart = _draft.Text.Length; e.Handled = true; return; }
        if (e.Key == VirtualKey.Escape)
        {
            if (!Busy()) return;
            e.Handled = true;
            _ = StopAsync();
            return;
        }
        if (e.Key != VirtualKey.Enter) return;
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift);
        if (shift.HasFlag(CoreVirtualKeyStates.Down)) return;
        e.Handled = true;
        _ = SendAsync();
    }

    private void PageOnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Escape || !Busy()) return;
        e.Handled = true;
        _ = StopAsync();
    }

    private UIElement CompactSetup()
    {
        var chat = _openChat ?? new JsonObject();
        var locked = Busy();
        var row = new FlowPanel { Spacing = Theme.SpaceS };
        row.Children.Add(CompactAgentMenu(locked));
        row.Children.Add(ModePills(Format.Text(chat, "mode", "plan"), !locked));
        var gate = Format.Text(Backend(Format.Text(chat, "backend")), "gateTier", "full");
        row.Children.Add(AutonomyPills(Format.Text(chat, "autonomy", "standard"), !locked, gate == "bypassOnly"));
        var setup = ActionIconGlyph.Button(L10n.Text("windows.chatpage.setup.7013af4c"), ActionIcon.Settings, (_, _) =>
        {
            _setupExpanded = true;
            // Setup reveals its native agent and working-style controls.
            _statsExpanded["setup/" + L10n.Text("common.chat_agent_behavior")] = true;
            PaintConversation();
        });
        AutomationProperties.SetAutomationId(setup, "chat.setup");
        row.Children.Add(setup);
        return row;
    }

    /// <summary>
    /// The agent, then a model or an effort only when one was chosen.
    /// The panel this opens is where the defaults are named.
    /// </summary>
    private static string ComposerSummary(JsonNode? backend, string backendId, string model, string effort)
    {
        var parts = new List<string> { Format.Text(backend, "label", backendId) };
        if (!string.IsNullOrEmpty(model))
        {
            parts.Add(model);
        }
        var efforts = backend?["efforts"] as JsonArray;
        if (efforts is { Count: > 0 } && !string.IsNullOrEmpty(effort))
        {
            parts.Add(effort + " effort");
        }
        return string.Join(" · ", parts);
    }

    private UIElement CompactAgentMenu(bool locked)
    {
        var chat = _openChat ?? new JsonObject();
        var backendId = Format.Text(chat, "backend");
        var backend = Backend(backendId);
        var model = Format.Text(chat, "model");
        var effort = Format.Text(chat, "effort");
        var label = ComposerSummary(backend, backendId, model, effort);

        var flyout = new Flyout();
        var panel = new StackPanel { Spacing = Theme.SpaceS, Width = 360 };
        panel.Children.Add(new TextBlock { Text = L10n.Text("windows.chatpage.agent_model_and_effort.217ff8ae"), FontSize = 16, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        var search = new TextBox { PlaceholderText = L10n.Text("windows.chatpage.filter_agents_models_and_efforts.315032da") };
        panel.Children.Add(search);
        var choices = new StackPanel { Spacing = 4 };
        panel.Children.Add(new ScrollViewer { MaxHeight = 360, Content = choices, HorizontalScrollMode = ScrollMode.Disabled });
        void RenderChoices()
        {
            choices.Children.Clear();
            void Group(string heading, IEnumerable<(string Value, string Label)> values, string field, string current)
            {
                var matches = values.Where(item => string.IsNullOrWhiteSpace(search.Text) || item.Label.Contains(search.Text, StringComparison.OrdinalIgnoreCase)).ToList();
                if (matches.Count == 0) return;
                choices.Children.Add(new TextBlock { Text = heading, Foreground = Theme.AccentBrush, Margin = new Thickness(0, 10, 0, 4), FontSize = 11 });
                foreach (var item in matches)
                {
                    var text = new TextBlock { Text = item.Label, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
                    FrameworkElement label = text;
                    if (field == "backend" && Readiness(Backend(item.Value)) is string note)
                    {
                        var lines = new StackPanel { Spacing = 1 };
                        lines.Children.Add(text);
                        lines.Children.Add(new TextBlock { Text = note, FontSize = 11, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis });
                        label = lines;
                    }
                    var pick = new Button
                    {
                        Content = field == "backend" ? AgentMark.Row(item.Value, label) : label,
                        HorizontalAlignment = HorizontalAlignment.Stretch,
                        HorizontalContentAlignment = HorizontalAlignment.Stretch,
                        Background = item.Value == current ? Theme.AccentSoftBrush : Theme.PanelBrush,
                        BorderThickness = new Thickness(0), Padding = new Thickness(8),
                    };
                    pick.Click += async (_, _) =>
                    {
                        if (_suppress) return;
                        flyout.Hide();
                        var patch = new JsonObject { [field] = item.Value };
                        if (field == "backend" && Format.Text(Backend(item.Value), "gateTier") == "bypassOnly") patch["autonomy"] = "bypass";
                        await UpdateAsync(patch);
                        PaintConversation();
                    };
                    choices.Children.Add(pick);
                }
            }
            // Installed agents only, like the Mac. The shell appears only on
            // the chat that already uses it.
            Group(L10n.Text("windows.chatpage.agent.b62db7d0"), _backends.Where(item => item is not null
                    && (Format.Text(item, "id") != "sh" || backendId == "sh") && Installed(item))
                .Select(item => (Format.Text(item, "id"), Format.Text(item, "label", Format.Text(item, "id")))), "backend", backendId);
            foreach (var field in new[] { "model", "effort" })
            {
                if (!Installed(backend)) break;
                if (backend?[field + "s"] is not JsonArray values || values.Count == 0) continue;
                var options = new List<(string, string)> { ("", L10n.Text("windows.chatpage.default.21b111cb")) };
                foreach (var value in values)
                {
                    var text = value?.ToString() ?? "";
                    if (text.Length > 0) options.Add((text, text));
                }
                Group(field.ToUpperInvariant(), options, field, field == "model" ? model : effort);
            }
        }
        search.TextChanged += (_, _) => RenderChoices();
        RenderChoices();
        if (backend is not null && Installed(backend) && AgentSignInDialog.Supported(backend))
        {
            var signIn = ActionIconGlyph.Button(L10n.Text("windows.agentsetup.open_terminal"), ActionIcon.SignIn, async (_, _) =>
            {
                flyout.Hide();
                await OpenAgentSignInAsync(backend);
            });
            signIn.IsEnabled = !locked;
            panel.Children.Add(signIn);
        }
        flyout.Content = new Border { Background = Theme.PanelBrush, Child = panel };
        flyout.Opened += (_, _) => search.Focus(FocusState.Programmatic);

        var button = new Button
        {
            Content = new TextBlock
            {
                Text = label, TextTrimming = TextTrimming.CharacterEllipsis,
                MaxWidth = 280,
            },
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Flyout = flyout,
            IsEnabled = !locked,
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 6, 10, 6),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, label);
        return button;
    }

    /// <summary>
    /// The same segmented strip as Plan and Execute, so the two choices read
    /// as one row. A backend with no approval gate offers only "Don't ask",
    /// shown as a strip of one rather than a different kind of chip.
    /// </summary>
    private UIElement AutonomyPills(string current, bool enabled, bool bypassOnly)
    {
        var dontAsk = ("bypass", L10n.Text("windows.chatpage.don_t_ask.15dae980"));
        if (bypassOnly)
        {
            return Chrome.Segmented([dontAsk], "bypass", _ => Task.CompletedTask);
        }
        return Chrome.Segmented(
            [("standard", L10n.Text("windows.chatpage.ask_first.4a9e8cf3")), dontAsk],
            current,
            async value =>
            {
                await UpdateAsync(new JsonObject { ["autonomy"] = value });
                PaintConversation();
            },
            enabled: enabled);
    }

    private void RebuildAttachStrip()
    {
        _attachStrip.Children.Clear();
        foreach (var file in _attachments)
        {
            var chip = Chip(file.Name);
            var name = (TextBlock)chip.Child;
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            name.MaxWidth = 240;
            chip.Child = null;
            var content = new Grid { ColumnSpacing = Theme.SpaceS };
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var dismiss = ActionIcon.Dismiss.Icon();
            dismiss.Width = dismiss.Height = 12;
            Grid.SetColumn(dismiss, 1);
            content.Children.Add(name);
            content.Children.Add(dismiss);
            chip.Child = content;
            var remove = file;
            var button = new Button
            {
                Content = chip, IsEnabled = !_queueing && !_sending && _fileTransfer is null,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Background = new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0),
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, L10n.Text("windows.chatpage.remove_attachment_0.bea47ab0", $"{file.Name}"));
            ToolTipService.SetToolTip(button, L10n.Text("windows.chatpage.remove_attachment_0.bea47ab0", $"{file.Name}"));
            button.Click += (_, _) =>
            {
                _attachments.Remove(remove);
                RememberDraft(); RebuildAttachStrip();
                remove.LocalFile?.Discard();
                if (Busy()) RebuildComposerActions();
            };
            _attachStrip.Children.Add(button);
        }
        if (_attachStrip.Children.Count == 0)
        {
            _attachStrip.Children.Add(new Border { Height = 0 });
        }
    }

    private void RebuildComposerActions()
    {
        if (SharedSource) { _composerActions.Children.Clear(); _composerSteering = false; return; }
        if (_dropImport is not null) {
            _composerActions.Children.Clear();
            _composerActions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.cancel"), ActionIcon.Stop, (_, _) => CancelDropImport()));
            return;
        }
        if (_fileTransfer is not null) {
            _composerActions.Children.Clear();
            _composerActions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.cancel"), ActionIcon.Stop, (_, _) => _fileTransfer?.Cancel()));
            return;
        }

        RefreshFastModeButton();
        RefreshComposerHint();
        _composerActions.Children.Clear();
        _composerSteering = false;
        if (Busy())
        {
            var steering = _composerSteering = SteerKnownAvailable();
            var queue = ActionIconGlyph.PrimaryButton(steering && Format.Flag(_openChat, "nativeSteer") ? L10n.Text("common.chat.steer") : steering ? L10n.Text("windows.chatpage.next_step.298a9207") : L10n.Text("windows.chatpage.queue.3b2fe03e"), ActionIcon.Send, async (_, _) => await SendAsync());
            var tip = steering
                ? L10n.Text("windows.chatpage.the_agent_reads_this_on_its_next_step.aab7b1c7")
                : L10n.Text("windows.chatpage.waits_until_this_turn_finishes_stop_and_se.2df81427");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(queue, steering ? L10n.Text("windows.chatpage.add_a_note_for_the_next_step.4778177a") : L10n.Text("windows.chatpage.queue.3b2fe03e"));
            AutomationProperties.SetAutomationId(queue, "chat.send");
            ToolTipService.SetToolTip(queue, tip);
            ContextMenus.AddAsync(ContextMenus.Menu(queue), L10n.Text("windows.chatpage.stop_and_send_now.8ad0a50d"), async () =>
            {
                if (_openId is not string chat) return;
                var noteRevision = _steerOverlay.Revision(chat);
                try
                {
                    await CallChatAsync("chat.stop", new JsonObject { ["id"] = chat });
                    var cleared = _steerOverlay.RememberIfCurrent(chat, null, noteRevision);
                    if (!OpenChatIs(chat)) return;
                    if (cleared) ClearLocalSteer();
                    await SendAsync(sendNext: true);
                    StartPoll();
                }
                catch (Exception ex) { Banner(ex.Message); }
            });
            _composerActions.Children.Add(queue);
            _composerActions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.stop"), ActionIcon.Stop, async (_, _) => await StopAsync()));
        }
        else
        {
            var send = ActionIconGlyph.PrimaryButton(L10n.Text("windows.chatpage.send.f6f4688f"), ActionIcon.Send, async (_, _) => await SendAsync());
            send.IsEnabled = true;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(send, L10n.Text("windows.chatpage.send.f6f4688f"));
            AutomationProperties.SetAutomationId(send, "chat.send");
            ToolTipService.SetToolTip(send, L10n.Text("windows.chatpage.send.f6f4688f"));
            _composerActions.Children.Add(send);
        }
    }

    private bool _pickingAttachment;

    private async Task AttachAsync()
    {
        if (_openId is not string chat || _queueing || _sending || _pickingAttachment || _fileTransfer is not null || _dropImport is not null) return;
        var generation = _openGeneration;
        var accountGeneration = AppServices.AccountGeneration;
        bool Current() => OpenChatIs(chat) && generation == _openGeneration && accountGeneration == AppServices.AccountGeneration;
        _pickingAttachment = true;
        try
        {
            var picker = new FileOpenPicker();
            picker.FileTypeFilter.Add("*");
            if (App.CurrentWindow is { } window)
            {
                InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
            }
            var file = await picker.PickSingleFileAsync();
            if (file is null || !Current() || _queueing || _sending || _fileTransfer is not null) return;
            if (_attachments.Count >= NewChatFile.MaximumCount) throw new IOException(L10n.Text("common.chat_files_busy"));
            var attached = await UploadFileAsync(chat, file, Current);
            if (!Current()) return;
            var id = Format.Text(attached, "id");
            if (id.Length == 0) throw new IOException(L10n.Text("windows.chatpage.attachment_was_rejected.c3b4db65"));
            _attachments.Add(new StagedFile(id, file.Name));
            RememberDraft(); RebuildAttachStrip(); RebuildComposerActions();
        }
        catch (Exception ex) { if (Current()) Banner(ex.Message); }
        finally { _pickingAttachment = false; }
    }

    /// A send is in flight. Set synchronously before the first await so a
    /// second Enter or Send click cannot slip through `Busy()` mid-flight
    /// and double-send the turn.
    private bool _sending;
    private bool _queueing;

    private async Task SendAsync(bool sendNext = false)
    {
        if (_opening || SharedSource) return;
        if (_openId is not string chat || _sending || _queueing || _fileTransfer is not null) return;
        if (await ConsumeCommandAsync()) return;
        var liveInput = !sendNext && Busy() && Format.Flag(_openChat, "nativeSteer")
            && ChatCommandRules.CanSteer(_draft.Text, _attachments.Count > 0, Format.Flag(_openChat, "nativeSteerAttachments"));
        if (!liveInput && OpenBackendMissing()) return;
        var backend = Backend(Format.Text(_openChat, "backend"));
        // Only the CLI's own answer stops a send. A stored token past its
        // expiry is routine (the CLI renews it), and an agent signed in with an
        // environment key has no login file at all.
        if (!liveInput && Format.Flag(backend, "signInVerified") && Format.Text(backend, "readiness") is "needsSignIn" or "expired")
        {
            Banner(L10n.Text("windows.agentsetup.draft_kept", Format.Text(backend, "label")));
            return;
        }
        var generation = _openGeneration;
        var accountGeneration = AppServices.AccountGeneration;
        bool Current() => OpenChatIs(chat) && generation == _openGeneration && accountGeneration == AppServices.AccountGeneration;
        var text = _draft.Text.Trim();
        if (text.Length == 0 && _attachments.Count == 0) return;
        _queueing = true; RebuildAttachStrip();
        try
        {
            var key = await OutboxKeyAsync(chat);
            if (!Current()) return;
            if (_outboxKey != key)
                throw new InvalidOperationException(L10n.Text("windows.chatpage_queue.reopen_this_conversation_with_its_original.bb0e73dd"));
            await UploadPendingAttachmentsAsync(chat, Current);
            if (!Current()) return;
            var attachmentIds = _attachments.Select(file => file.Id).ToArray();
            // The turn can finish while the files upload. Steer only if it is
            // still running. Drain sends an ordinary message when it is not.
            liveInput = !sendNext && Busy() && Format.Flag(_openChat, "nativeSteer")
                && ChatCommandRules.CanSteer(text, attachmentIds.Length > 0, Format.Flag(_openChat, "nativeSteerAttachments"));
            if (text != "/compact" && await TryParkSteerAsync(chat, text, sendNext, attachmentIds)) return;
            if (!Current()) return;
            if (_openChat?["sendRevision"] is null) throw new InvalidOperationException(L10n.Text("windows.chatpage.update_the_host_to_use_reliable_message_de.fcb58190"));
            var item = new QueuedChatMessage(Guid.NewGuid().ToString("N"), text, attachmentIds, Format.Long(_openChat, "sendRevision"));
            ChatOutbox.Shared.Update(key, rows =>
            {
                if (sendNext)
                {
                    if (rows.Any(row => row.AttemptedAt.HasValue))
                        throw new InvalidOperationException(L10n.Text("windows.chatpage.check_delivery_of_the_pending_message_befo.a75b6c73"));
                    rows.Insert(0, item);
                }
                else rows.Add(item);
            });
            _outboxKey = key; _authorizedQueue.Add(item.Id);
            if (_draft.Text.Trim() == text) _draft.Text = "";
            _attachments.RemoveAll(file => attachmentIds.Contains(file.Id));
            await DrainQueueAsync(messageId: item.Id, steerCurrent: liveInput);
            if (Current()) { PaintConversation(); StartPoll(); }
        }
        catch (Exception ex) { if (Current()) Banner(ex.Message); }
        finally { _queueing = false; if (Current()) { RememberDraft(); RebuildAttachStrip(); RebuildComposerActions(); } }
    }

    private async Task StopAsync()
    {
        if (SharedSource) return;
        if (_openId is not string chat) return;
        var generation = _openGeneration;
        var revision = _openChat?["sendRevision"] is null ? (long?)null : Format.Long(_openChat, "sendRevision");
        var noteRevision = _steerOverlay.Revision(chat);
        try
        {
            var protocol = RemoteFeatureGate.ProtocolOf(await CallChatAsync("protocol", new JsonObject()));
            if (!OpenChatIs(chat) || generation != _openGeneration) return;
            if (protocol >= 34 && revision.HasValue)
                await CallChatAsync("chat.recover", new JsonObject { ["id"] = chat,
                    ["expectedRevision"] = revision.Value, ["stopActive"] = true });
            else await CallChatAsync("chat.stop", new JsonObject { ["id"] = chat });
            var cleared = _steerOverlay.RememberIfCurrent(chat, null, noteRevision);
            if (!OpenChatIs(chat) || generation != _openGeneration) return;
            if (cleared) ClearLocalSteer();
            PaintConversation();
            StartPoll();
        }
        catch (Exception ex)
        {
            if (OpenChatIs(chat) && generation == _openGeneration) Banner(ex.Message);
        }
    }

    private async Task ResolveAsync(string id, string choice)
    {
        try
        {
            await CallChatAsync("chat.resolveApproval", new JsonObject
            {
                ["id"] = id,
                ["choice"] = choice,
            });
            _approvals = AsArray(await CallChatAsync(
                "chat.approvals", new JsonObject { ["id"] = _openId }));
            RebuildTranscript();
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
    }

    private async Task ConfirmDeleteAsync(string? chatId = null)
    {
        var id = chatId ?? _openId;
        if (id is null) return;
        if (ChatLocalSharingModel.Paused(_chats.FirstOrDefault(row => Format.Text(row, "id") == id)) || id == _openId && SharedSource) return;
        var dialog = new ContentDialog
        {
            Title = L10n.Text("windows.chatpage.delete_this_chat.848dad9b"),
            Content = L10n.Text("windows.chatpage.the_transcript_stays_on_this_computer_unti.46662c93"),
            PrimaryButtonText = L10n.Text("windows.chatpage.delete_chat.93291d9c"),
            CloseButtonText = L10n.Text("windows.chatpage.keep_it.fdce5da2"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary) return;
        try
        {
            await CallChatAsync("chat.remove", new JsonObject { ["id"] = id });
            AppServices.NotifyConversationsChanged();
            await ShowListAsync();
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
    }

    private async Task UpdateAsync(JsonObject patch)
    {
        if (_opening || SharedSource) return;
        if (_openId is not string chat) return;
        var generation = _openGeneration;
        patch["id"] = chat;
        try
        {
            _suppress = true;
            var updated = await CallChatAsync("chat.update", patch);
            AppServices.NotifyConversationsChanged();
            if (!OpenChatIs(chat) || generation != _openGeneration) return;
            // chat.update returns the saved record, which has no parked note.
            // Preserve the current note, which may have changed while awaiting.
            _openChat = ChatSteerOverlay.MergeRecord(updated, _openChat);
            _ = RefreshInspectionAsync();
            RefreshFastModeButton();
            ChatLaunchChoice.Save(_openChat);
            if (patch.ContainsKey("backend")) CheckSelectedSignIn();
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
        finally
        {
            _suppress = false;
        }
    }

    private void StartPoll()
    {
        _poll?.Cancel();
        var cts = new CancellationTokenSource();
        _poll = cts;
        _ = PollLoop(cts.Token);
    }

    private async Task PollLoop(CancellationToken token)
    {
        var chatId = _openId;
        if (chatId is null) return;
        while (!token.IsCancellationRequested && _openId == chatId)
        {
            try
            {
                await Task.Delay(Busy() ? 400 : 2000, token);
                _ = RefreshInspectionAsync();
                var wasBusy = Busy();
                var historyGeneration = _historyGeneration;
                var chunk = await CallChatAsync("chat.events", new JsonObject
                {
                    ["id"] = chatId,
                    ["offset"] = _offset,
                    ["tailCursor"] = _tailCursor,
                    ["stablePositions"] = true,
                });
                if (token.IsCancellationRequested || _openId != chatId) return;
                if (historyGeneration != _historyGeneration) continue;
                if (Format.Flag(chunk, "reset"))
                {
                    var reset = await CallChatAsync("chat.eventPage", new JsonObject
                        { ["id"] = chatId, ["limit"] = 160, ["stablePositions"] = true });
                    if (token.IsCancellationRequested || _openId != chatId) return;
                    ApplyHistoryPage(reset, replace: true);
                    RebuildTranscript(full: true);
                    RefreshCost();
                    continue;
                }
                var next = AsArray(chunk, "events");
                // Host calls run on the thread pool via Task.Run; the await
                // captures the UI SynchronizationContext so the continuation
                // resumes on the UI thread. Still, guard the UI mutations
                // explicitly so a future ConfigureAwait(false) or a call from a
                // non-UI context cannot trigger RPC_E_WRONG_THREAD.
                void ApplyPoll(JsonArray approvals)
                {
                    if (!_history.ApplyTail(chunk, historyGeneration)) return;
                    _approvals = approvals;
                }
                var approvals = AsArray(await CallChatAsync(
                    "chat.approvals", new JsonObject { ["id"] = chatId }));
                if (token.IsCancellationRequested || _openId != chatId) return;
                await RefreshCatalogAsync(refreshMenus: false);
                if (token.IsCancellationRequested || _openId != chatId) return;

                if (historyGeneration != _historyGeneration) continue;
                var transcriptChanged = next.Count > 0 || !JsonNode.DeepEquals(_approvals, approvals);

                // All UI state is mutated on the DispatcherQueue regardless of
                // which thread the awaits resumed on.
                if (!DispatcherQueue.HasThreadAccess)
                {
                    var tcs = new TaskCompletionSource();
                    DispatcherQueue.TryEnqueue(() =>
                    {
                        ApplyPoll(approvals);
                        ApplyOpenChat(chatId, wasBusy, transcriptChanged);
                        tcs.SetResult();
                    });
                    await tcs.Task;
                }
                else
                {
                    ApplyPoll(approvals);
                    ApplyOpenChat(chatId, wasBusy, transcriptChanged);
                }
                if (!Busy())
                {
                    if (!await DrainQueueOnUiAsync(chatId)) return;
                }
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch
            {
                // A dropped poll is retried on the next tick.
            }
        }
    }

    /// <summary>
    /// Ask the host to read the agent CLIs' model lists again instead of
    /// serving the ones it cached. See the comment beside the Model picker.
    /// </summary>
    private async Task ReloadBackendsAsync()
    {
        // Old hosts ignore the unknown `refresh` field and answer from cache
        // (protocol 6). That silent no-op is acceptable; a failure is not, so
        // banner it like every other host call from this page.
        try
        {
            var backends = await CallChatAsync(
                "chat.backends",
                new JsonObject { ["refresh"] = true });
            _backends = AsArray(backends);
            PaintConversation();
            CheckSelectedSignIn();
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
    }

    private async Task RefreshCatalogAsync(bool refreshMenus = true)
    {
        var generation = _openGeneration;
        var request = _steerOverlay.BeginRead();
        var chats = CallChatAsync("chat.list", new JsonObject { ["workspaceId"] = _workspaceId });
        if (!refreshMenus)
        {
            var listed = await chats;
            if (generation == _openGeneration) _chats = _steerOverlay.Apply(AsArray(listed), request, _chats);
            return;
        }
        // Secondary menus must never hide a successful conversation list.
        _ = RefreshBackendCatalogAsync(generation);
        _ = RefreshPersonaCatalogAsync(generation);
        var loaded = await chats;
        if (generation == _openGeneration)
            _chats = _steerOverlay.Apply(AsArray(loaded), request, _chats);
    }

    private async Task RefreshBackendCatalogAsync(int generation)
    {
        try
        {
            var loaded = await CallChatAsync("chat.backends");
            if (generation != _openGeneration) return;
            _backends = AsArray(loaded);
            RefreshCatalogPresentation();
            CheckSelectedSignIn();
        }
        catch (Exception ex) { if (generation == _openGeneration) Banner(ex.Message); }
    }

    private async Task RefreshPersonaCatalogAsync(int generation)
    {
        try
        {
            var loaded = await CallChatAsync("chat.personas", new JsonObject { ["workspaceId"] = _workspaceId });
            if (generation != _openGeneration) return;
            _personas = AsArray(loaded, "personas");
            RefreshCatalogPresentation();
        }
        catch (Exception ex) { if (generation == _openGeneration) Banner(ex.Message); }
    }

    private void RefreshCatalogPresentation()
    {
        if (!IsLoaded) return;
        RenderInspector();
        if (_openChat is null || _composerDock.Child is null) return;
        // Refresh menus without clearing transcript rows or their scroll position.
        var focus = _draft.FocusState;
        _composerDock.Child = null;
        _composerWell.Children.Clear();
        _composerRow.Children.Clear();
        _composerDock.Child = Composer();
        if (focus != FocusState.Unfocused) _draft.Focus(focus);
    }

    private void CheckSelectedSignIn()
    {
        var selectedBackend = Backend(Format.Text(_openChat, "backend"));
        if (selectedBackend is not null && Format.Flag(selectedBackend, "canCheckSignIn") && Format.Text(selectedBackend, "id") is "claude" or "claude_code" or "codex" or "cursor" or "cursor_agent" or "muse")
        {
            // In the background. The CLI can take seconds to answer, and the
            // chat, its menus and its personas are ready without it.
            _ = CheckSignInAsync(selectedBackend, _openGeneration);
        }
    }

    private readonly ChatSignInChecks _signInChecks = new();

    /// <summary>
    /// Ask the agent's own CLI whether it is signed in, once per open backend,
    /// and repaint only when the answer changes what the chat shows.
    /// </summary>
    private async Task CheckSignInAsync(JsonNode backend, int generation)
    {
        try
        {
            if (await _signInChecks.CheckAsync(backend, generation,
                id => CallChatAsync("launcher.checkSignIn", new JsonObject { ["id"] = id }),
                () => _openGeneration, Backend)) PaintConversation();
        }
        catch { /* Older hosts retain their file-based, three-valued answer. */ }
    }

    private JsonNode? FindChat(string id)
    {
        foreach (var chat in _chats)
        {
            if (Format.Text(chat, "id") == id) return chat;
        }
        return _openChat;
    }

    private JsonNode? Backend(string id)
    {
        foreach (var backend in _backends)
        {
            if (Format.Text(backend, "id") == id) return backend;
        }
        return null;
    }

    private JsonNode? FindPersona(string id)
    {
        foreach (var persona in _personas)
        {
            if (Format.Text(persona, "id") == id) return persona;
        }
        return null;
    }

    /// <summary>
    /// The agent a new chat starts with, like the Mac: the last one used if it
    /// is still installed, then Codex, then the first installed agent. The
    /// shell is never a default.
    /// </summary>
    private JsonNode? DefaultBackend(string? remembered)
    {
        var available = _backends
            .Where(backend => backend is not null && Format.Text(backend, "id") != "sh" && Installed(backend))
            .ToList();
        return available.FirstOrDefault(backend => Format.Text(backend, "id") == remembered)
            ?? available.FirstOrDefault(backend => Format.Text(backend, "id") == "codex")
            ?? available.FirstOrDefault()
            ?? _backends.FirstOrDefault(backend => backend is not null && Format.Text(backend, "id") != "sh");
    }

    /// <summary>
    /// Whether an agent is on this computer. Missing means the host did not
    /// say, which is not the same as absent: only an explicit false hides it.
    /// </summary>
    private static bool Installed(JsonNode? backend) =>
        backend?["installed"] is not JsonValue flag
        || flag.GetValueKind() != System.Text.Json.JsonValueKind.False;

    private static bool Offers(JsonNode? backend, string list, string value) =>
        !string.IsNullOrEmpty(value)
        && backend?[list] is JsonArray values
        && values.Any(item => item?.ToString() == value);

    /// <summary>
    /// The persona a new chat should start with, or null to take the
    /// workspace default. "No persona" travels as an empty id. A persona from
    /// another folder is not available here, so an unknown id falls back to
    /// this folder's own default.
    /// </summary>
    private string? RememberedPersona(ChatLaunchChoice? saved)
    {
        if (saved?.PersonaId is not string remembered) return null;
        if (remembered.Length == 0) return "";
        return FindPersona(remembered) is null ? null : remembered;
    }

    /// <summary>A short note on an agent row when it may not run as is.</summary>
    private static string? Readiness(JsonNode? backend) => Format.Text(backend, "readiness") switch
    {
        "needsSignIn" => L10n.Text("windows.chatpage.sign_in_may_be_needed.c3dde98c"),
        "expired" => L10n.Text("windows.chatpage.stored_login_has_expired.bf189dae"),
        _ => null,
    };

    /// <summary>The open chat's agent is known to the host and not installed.</summary>
    private bool OpenBackendMissing()
    {
        var backend = Backend(Format.Text(_openChat, "backend"));
        return backend is not null && !Installed(backend);
    }

    private List<DisplayItem> Coalesce(JsonArray events)
    {
        var items = new List<DisplayItem>();
        var tools = new ChatToolCalls();
        var questions = new Dictionary<string, int>();
        var text = "";
        var textId = "";
        var thinking = "";
        var thinkingId = "";
        var attachmentTurn = "prefix";

        void FlushText()
        {
            // The question block is drawn as its own card below the reply.
            var body = ChatQuestionText.Strip(text, streaming: _running).Trim();
            if (body.Length > 0)
            {
                items.Add(new DisplayItem { Id = textId, Kind = ItemKind.Assistant, Text = body });
            }
            text = "";
            textId = "";
        }

        void FlushThinking()
        {
            var body = thinking.Trim();
            if (body.Length > 0)
            {
                items.Add(new DisplayItem { Id = thinkingId, Kind = ItemKind.Thinking, Text = body });
            }
            thinking = "";
            thinkingId = "";
        }

        foreach (var row in events)
        {
            if (row is null) continue;
            var kind = Format.Text(row, "kind");
            if (kind == "user")
            {
                FlushText();
                FlushThinking();
                if (!Format.Flag(row, "steer")) {
                    tools.CloseRunning(items, failed: false, detail: "");
                    attachmentTurn = "user-" + Format.Text(row, "seq", Format.Long(row, "atMs").ToString(CultureInfo.InvariantCulture) + ":" + items.Count);
                    tools.Clear();
                }
                items.Add(new DisplayItem
                {
                    Id = "user-" + Format.Long(row, "atMs") + "-" + items.Count,
                    Kind = ItemKind.User,
                    IsSteer = Format.Flag(row, "steer"),
                    Text = Format.Text(row, "text"),
                });
                continue;
            }
            if (kind == "question")
            {
                var questionId = Format.Text(row, "id");
                var asked = Format.Text(row, "question");
                if (questionId.Length > 0 && asked.Length > 0)
                {
                    FlushText();
                    FlushThinking();
                    var fallback = row["default"] is null ? null : Format.Text(row, "default");
                    var options = (row["options"] as JsonArray)?
                        .Select(option => option?.GetValueKind() == System.Text.Json.JsonValueKind.String ? option.GetValue<string>() : null)
                        .OfType<string>().ToList() ?? [];
                    questions[questionId] = items.Count;
                    items.Add(new DisplayItem
                    {
                        Id = "question-" + questionId,
                        Kind = ItemKind.Question,
                        Question = new ChatQuestionItem(questionId, asked, options, Format.Flag(row, "multiple"),
                            string.IsNullOrEmpty(fallback) ? null : fallback,
                            row["blocking"] is null ? string.IsNullOrEmpty(fallback) : Format.Flag(row, "blocking")),
                    });
                }
                continue;
            }
            if (kind is "answer" or "answerWithdrawn")
            {
                // Lands on its question's card. One whose question is on an
                // older page waits for that page. A withdrawn answer never
                // reached the agent, so the card opens again.
                if (questions.TryGetValue(Format.Text(row, "questionId"), out var at) && items[at].Question is { } asked)
                {
                    var card = items[at];
                    card.Question = kind == "answer"
                        ? asked with { Answer = Format.Text(row, "text"), Delivery = Format.Text(row, "delivery") }
                        : asked with { Answer = null, Delivery = null };
                    items[at] = card;
                }
                continue;
            }
            if (kind == "approval" || row["approval"] is not null)
            {
                FlushText();
                FlushThinking();
                var approval = row["approval"] ?? row;
                var id = Format.Text(approval, "id");
                var pending = false;
                foreach (var live in _approvals)
                {
                    if (Format.Text(live, "id") == id && string.IsNullOrEmpty(Format.Text(live, "decision")))
                    {
                        pending = true;
                        break;
                    }
                }
                items.Add(new DisplayItem
                {
                    Id = "approval-" + id,
                    Kind = ItemKind.Approval,
                    Approval = approval,
                    Pending = pending,
                });
                continue;
            }
            var ev = row["event"];
            if (ev is null) continue;
            switch (Format.Text(ev, "kind"))
            {
                case "text":
                    FlushThinking();
                    if (text.Length == 0) textId = "text-" + Format.Long(row, "atMs") + "-" + items.Count;
                    text += Format.Text(ev, "delta");
                    break;
                case "thinking":
                    FlushText();
                    if (thinking.Length == 0) thinkingId = "think-" + Format.Long(row, "atMs") + "-" + items.Count;
                    thinking += Format.Text(ev, "delta");
                    break;
                case "toolStart":
                    FlushText();
                    FlushThinking();
                    var callId = Format.Text(ev, "callId");
                    if (string.IsNullOrEmpty(callId)) callId = "tool-" + items.Count;
                    var toolScope = attachmentTurn + "/" + Format.Text(row, "backend", Format.Text(_openChat, "backend"));
                    var occurrence = tools.Remember(toolScope, Format.Text(row, "backend", Format.Text(_openChat, "backend")), callId, items.Count);
                    items.Add(new DisplayItem
                    {
                        Id = "tool-" + toolScope + "/" + callId + (occurrence > 1 ? "#" + occurrence : ""),
                        ToolCallId = callId,
                        AttachmentScope = toolScope,
                        Kind = ItemKind.Tool,
                        // Empty when the event named no tool. The row then says Working.
                        Verb = Format.Text(ev, "verb"),
                        Target = Format.Text(ev, "target"),
                        Running = true,
                        StartedAt = Format.Long(row, "atMs"),
                    });
                    break;
                case "toolEnd":
                    FlushText();
                    FlushThinking();
                    var endId = Format.Text(ev, "callId");
                    if (tools.TryResolve(attachmentTurn + "/" + Format.Text(row, "backend", Format.Text(_openChat, "backend")), endId, out var owner,
                        index => index >= 0 && index < items.Count && items[index].Running))
                    {
                        var index = owner.Index;
                        var tool = items[index];
                        tool.Running = false;
                        if (ev["ok"] is not null)
                        {
                            tool.Failed = !Format.Flag(ev, "ok");
                        }
                        tool.Detail = Format.Text(ev, "detail");
                        var presentation = MuseToolPresentation.Refine(
                            owner.Backend,
                            tool.Verb, tool.Target, tool.Detail);
                        tool.Verb = presentation.Verb;
                        tool.Target = presentation.Target;
                        var ended = Format.Long(row, "atMs");
                        tool.Duration = Duration(tool.StartedAt, ended);
                        tool.EndedAt = ended;
                        items[index] = tool;
                    }
                    break;
                case "edit":
                    FlushText();
                    FlushThinking();
                    var edit = new DisplayItem
                    {
                        // A single Codex call can report several files. The
                        // event sequence keeps each row's identity distinct.
                        Id = "edit-" + Format.Text(row, "seq", items.Count.ToString()),
                        Kind = ItemKind.Edit,
                        Path = Format.Text(ev, "path", L10n.Text("windows.chatpage.file.50009ce1")),
                        Added = Format.Long(ev, "added"),
                        Removed = Format.Long(ev, "removed"),
                        Patch = Format.Text(ev, "patch"),
                    };
                    // An edit announced as a tool call becomes that row, as on
                    // the Mac, rather than a second row for one change.
                    if (tools.TryResolve(attachmentTurn + "/" + Format.Text(row, "backend", Format.Text(_openChat, "backend")), Format.Text(ev, "callId"), out var announced)
                        && items[announced.Index] is { Kind: ItemKind.Tool, Verb: "Edit" or "NotebookEdit" } call
                        && (call.Target == edit.Path || string.IsNullOrEmpty(call.Target)))
                    {
                        edit.Id = call.Id;
                        edit.ToolCallId = call.ToolCallId;
                        edit.AttachmentScope = call.AttachmentScope;
                        edit.Running = call.Running;
                        edit.Failed = call.Failed;
                        edit.StartedAt = call.StartedAt;
                        edit.EndedAt = call.EndedAt;
                        edit.Duration = call.Duration;
                        items[announced.Index] = edit;
                    }
                    else
                    {
                        items.Add(edit);
                    }
                    break;
                case "usage":
                    FlushText();
                    FlushThinking();
                    items.Add(new DisplayItem
                    {
                        Id = "usage-" + Format.Long(row, "atMs") + "-" + items.Count,
                        Kind = ItemKind.Usage,
                        Input = Format.Long(ev, "input"),
                        Output = Format.Long(ev, "output"),
                        Cost = Format.Number(ev, "costUsd"),
                    });
                    break;
                case "attachment":
                    FlushText();
                    FlushThinking();
                    var attachmentName = Format.Text(ev, "name", L10n.Text("windows.chatpage.attachment.040d2b36"));
                    items.Add(new DisplayItem
                    {
                        Id = "attachment-" + Format.Text(ev, "id", items.Count.ToString()),
                        Kind = ItemKind.Attachment,
                        Name = string.IsNullOrEmpty(attachmentName) ? L10n.Text("windows.chatpage.attachment.040d2b36") : attachmentName,
                        MediaType = Format.Text(ev, "mediaType"),
                        Size = Format.Long(ev, "size"),
                        ToolCallId = Format.Text(ev, "callId", Format.Text(ev, "call_id")),
                        AttachmentScope = attachmentTurn + "/" + Format.Text(row, "backend", Format.Text(_openChat, "backend")),
                    });
                    break;
                case "failed":
                    FlushText();
                    FlushThinking();
                    tools.CloseRunning(items, true, Format.Text(ev, "text"));
                    items.Add(new DisplayItem
                    {
                        Id = "failed-" + items.Count,
                        Kind = ItemKind.Failed,
                        Text = Format.Text(ev, "text", L10n.Text("windows.chatpage.the_turn_failed.45783181")),
                    });
                    break;
                case "done":
                {
                    FlushText();
                    FlushThinking();
                    var status = Format.Text(ev, "status");
                    var failed = status is "cancelled" or "canceled" or "error";
                    tools.CloseRunning(items, failed, failed ? status : "");
                    break;
                }
            }
        }
        FlushText();
        FlushThinking();
        return items;
    }

    // History rows are append-only until the page array is replaced. Busy
    // checks happen on every composer/key/follow update, so retain this small
    // result rather than projecting the entire transcript for each control.
    private JsonArray? _busyEvents;
    private int _busyEventCount;
    private string? _busyBackend;
    private bool _busyValue;
    private bool Busy(List<DisplayItem>? rows = null)
    {
        if (_running) return true;
        var backend = Format.Text(_openChat, "backend");
        if (rows is null && ReferenceEquals(_busyEvents, _events) && _busyEventCount == _events.Count && _busyBackend == backend)
            return _busyValue;
        _busyValue = (rows ?? Coalesce(_events)).Any(item => item.Kind is (ItemKind.Tool or ItemKind.Edit) && item.Running);
        _busyEvents = _events;
        _busyEventCount = _events.Count;
        _busyBackend = backend;
        return _busyValue;
    }

    private static string Duration(long start, long end)
    {
        var ms = Math.Max(0, end - start);
        if (ms < 1000) return ms + "ms";
        var seconds = ms / 1000d;
        return seconds < 10 ? seconds.ToString("0.0", CultureInfo.InvariantCulture) + "s" : ((int)Math.Round(seconds)) + "s";
    }

    private static string GateChip(string tier) => tier switch
    {
        "full" => L10n.Text("windows.chatpage.approvals.2bfc3471"),
        "rules" => L10n.Text("windows.chatpage.rules.4228aeb0"),
        "bypassOnly" => L10n.Text("windows.chatpage.bypass_only.6110acbf"),
        _ => L10n.Text("windows.chatpage.checking.0dfe1d63"),
    };

    private static string GateCopy(string tier, bool bypass)
    {
        if (bypass) return L10n.Text("windows.chatpage.this_agent_can_use_its_backend_s_bypass_mo.620f4900");
        return tier switch
        {
            "full" => L10n.Text("windows.chatpage.tokenstat_asks_before_every_tool_action.a67dbd55"),
            "rules" => L10n.Text("windows.chatpage.saved_permission_rules_run_anything_else_i.ef7fb8c5"),
            "bypassOnly" => L10n.Text("windows.chatpage.this_backend_has_no_tokenstat_approval_gat.a3ae2978"),
            _ => L10n.Text("windows.chatpage.checking_this_backend_s_permission_support.13f013cf"),
        };
    }

    private static Border Chip(string text) => new()
    {
        Background = Theme.AccentSoftBrush,
        CornerRadius = new CornerRadius(10),
        Padding = new Thickness(8, 4, 8, 4),
        Child = new TextBlock
        {
            Text = text,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = Theme.AccentBrush,
        },
    };

    private static UIElement Labeled(string label, UIElement control)
    {
        var stack = new StackPanel { Spacing = Theme.SpaceXs };
        stack.Children.Add(Chrome.SectionLabel(label));
        stack.Children.Add(control);
        return stack;
    }

    private static TextBlock Muted(string text) => new()
    {
        Text = text,
        FontSize = 12,
        Opacity = 0.7,
        TextWrapping = TextWrapping.Wrap,
    };

    /// Compact summary and a full-width disclosure, shared with context cards.
    private Border SetupSection(string title, UIElement body, ActionIcon icon, string? subtitle = null, UIElement? primary = null, Button? reveal = null, Action? opened = null)
    {
        var summary = new StackPanel { Spacing = Theme.SpaceS };
        if (!string.IsNullOrEmpty(subtitle)) summary.Children.Add(new TextBlock { Text = subtitle, FontSize = 11, Opacity = .7, TextTrimming = TextTrimming.CharacterEllipsis });
        if (primary is not null) summary.Children.Add(primary);
        return CollapsibleStatsCard(title, "setup/" + title, summary, (FrameworkElement)body, reveal, opened);
    }

    private void AddWorkingAccessCards(StackPanel target, JsonNode chat)
    {
        var chatId = _openId; var generation = _openGeneration; var account = AppServices.AccountGeneration;
        bool Current() => chatId is not null && OpenChatIs(chatId) && generation == _openGeneration && account == AppServices.AccountGeneration;
        var folder = new StackPanel { Spacing = Theme.SpaceS }; folder.Children.Add(Muted(_folderName));
        var folderActions = new FlowPanel { Spacing = Theme.SpaceS };
        folderActions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.files"), ActionIcon.Reveal, (_, _) => AppServices.OpenWorkspace?.Invoke(_workspaceId, WorkspaceSection.Files)));
        var path = RemoteWorkspaces.CachedFolder(_workspaceId)?.Path ?? _folderPath;
        var copyPath = ActionIconGlyph.Button(L10n.Text("common.chat.inspector.copy_path"), ActionIcon.Copy, (_, _) => {
            try { var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(path); Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); }
            catch (Exception error) { Banner(error.Message); }
        });
        copyPath.IsEnabled = path.Length > 0; folderActions.Children.Add(copyPath);
        folder.Children.Add(folderActions);
        target.Children.Add(CollapsibleStatsCard(L10n.Text("common.chat.inspector.folder"), "folder", folder, Muted(path)));
        var tools = AsArray(chat, "allowedTools"); var commands = AsArray(chat, "allowedShellPrefixes");
        var allowlist = new StackPanel { Spacing = Theme.SpaceS };
        allowlist.Children.Add(Muted(tools.Count + commands.Count == 0 ? L10n.Text("common.chat.inspector.allowed_empty")
            : L10n.Text("common.chat.inspector.allowed_summary", tools.Count.ToString(), commands.Count.ToString())));
        var chips = new FlowPanel { Spacing = Theme.SpaceS };
        foreach (var (field, values) in new[] { ("allowedTools", tools), ("allowedShellPrefixes", commands) })
            foreach (var entry in values) {
                var value = entry?.ToString() ?? "";
                var remove = ActionIconGlyph.Button(value, ActionIcon.Dismiss, async (_, _) => {
                    if (!Current() || Busy() || _updatingAllowed) return;
                    _updatingAllowed = true;
                    foreach (var control in chips.Children.OfType<Button>()) control.IsEnabled = false;
                    try {
                        var latest = AsArray(_openChat, field);
                        await UpdateAsync(new JsonObject { [field] = new JsonArray(latest.Where(item => item?.ToString() != value).Select(item => item?.DeepClone()).ToArray()) });
                    } finally {
                        _updatingAllowed = false;
                        if (IsLoaded) RenderInspector();
                    }
                });
                remove.IsEnabled = !Busy() && !_updatingAllowed; chips.Children.Add(remove);
            }
        var allowedDetails = new StackPanel { Spacing = Theme.SpaceS }; allowedDetails.Children.Add(chips); allowedDetails.Children.Add(Muted(L10n.Text("common.chat.inspector.allowed_help")));
        target.Children.Add(CollapsibleStatsCard(L10n.Text("common.chat.inspector.always_allowed"), "allowed", allowlist, allowedDetails));
    }

    private static Border Card(string title, UIElement body) => Chrome.Card(title, body);

    private static JsonArray AsArray(JsonNode? node, string? key = null)
    {
        if (key is not null && node is JsonObject)
        {
            if (node[key] is JsonArray named) return named;
        }
        if (node is JsonArray array) return array;
        return Format.Items(node) ?? new JsonArray();
    }

    private static void Detach(UIElement element)
    {
        if (((element as FrameworkElement)?.Parent ?? VisualTreeHelper.GetParent(element)) is Panel panel)
        {
            panel.Children.Remove(element);
        }
    }

    private void Banner(string text)
    {
        if (_root.Children.Count == 0)
        {
            _root.Children.Add(Chrome.Banner(text, Theme.Danger, Symbol.Important));
            return;
        }
        _root.Children.Insert(1, Chrome.Banner(text, Theme.Danger, Symbol.Important));
    }

    private readonly record struct StagedFile(string Id, string Name, NewChatFile? LocalFile = null);
}
