// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Text;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Tokenstat.Navigation;
using System.Text.Json.Nodes;
using Windows.Storage.Pickers;
using Windows.System;
using Windows.UI.Core;
using Windows.ApplicationModel.DataTransfer;
using WinRT.Interop;

namespace Tokenstat.Pages;

internal sealed record NewChatRepository(string Id, string Name, string Machine, string Path, bool IsLocal)
{
    public override string ToString() => Name + " · " + Machine;
}

/// <summary>
/// An unsent, account-owned draft. Choosing or adding a folder never creates a
/// conversation. Laid out as the Mac's ChatStartPage: a short introduction,
/// then one card holding the repository choice above the ordinary composer,
/// whose agent field is the same control a running chat uses.
/// </summary>
internal sealed class NewChatPage : Page
{
    private readonly long _account = AppServices.AccountGeneration;
    private readonly Func<IReadOnlyList<NewChatRepository>> _repositories;
    private readonly Func<Task<string?>> _add;
    private readonly Func<NewChatRepository, Task<JsonNode>> _loadAgents;
    private readonly Func<NewChatRepository, string, NewChatSetup, IReadOnlyList<NewChatFile>, Func<bool>, Action, Task> _send;

    private IReadOnlyList<NewChatRepository> _list = [];
    private NewChatRepository? _selected;
    /// <summary>The draft's agent choice, shaped like a chat so the shared agent field can read it.</summary>
    private JsonObject _setup = new();
    private JsonNode[] _available = [];

    private readonly TextBox _draft = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 42, MaxHeight = 160 };
    private readonly TextBlock _subtitle = new() { FontSize = 13, Opacity = .65, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
    private readonly TextBlock _notice = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
        Foreground = Theme.Brush(static () => Theme.Danger), Visibility = Visibility.Collapsed };
    private readonly Button _repositoryButton = new();
    private readonly Border _agentSlot = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _workingStyle = new() { Spacing = Theme.SpaceS };
    private readonly FlowPanel _filesView = new() { Spacing = Theme.SpaceS };
    private readonly FlowPanel _starters = new() { Spacing = 8, CentersLines = true };
    private readonly Border _card = new();
    private readonly Border _onboarding = new();
    private readonly ProgressRing _catalogProgress = new() { Width = 16, Height = 16, IsActive = false, Visibility = Visibility.Collapsed };
    private readonly List<NewChatFile> _files = [];
    private readonly NewChatDraftStore _drafts = new();
    private string? _draftRepository => _drafts.Repository;
    private long _draftGeneration => _drafts.Revision;
    private long _lifetime;
    private string _mode = "execute", _autonomy = "bypass";
    private bool _fastMode;
    private bool _restoringDraft;
    private readonly Button _attach;
    private readonly Button _fast;
    private readonly Button _setupButton;
    private readonly ProgressRing _copyProgress = new() { Width = 20, Height = 20, Visibility = Visibility.Collapsed, IsActive = false };
    private readonly Button _cancelStaging;
    private readonly Button _submit;
    private readonly Button _addButton;
    private readonly Button _retry;
    private bool _sending;
    private bool _pickingFiles, _addingRepository;
    private bool _stagingFiles;
    private bool _catalogFailed;
    private CancellationTokenSource? _stagingCancellation;
    private long _request;
    private long _catalogRevision;
    private bool _handoff;
    private string? _catalogRepository;
    private string? _requestedRepository;
    private NewChatSetup? _preferredSetup;
    private static string Copy(string key) { var resource = "common.new_chat." + key; return L10n.Text(resource); }

    internal NewChatPage(Func<IReadOnlyList<NewChatRepository>> repositories, Func<Task<string?>> add,
        Func<NewChatRepository, Task<JsonNode>> loadAgents, Func<NewChatRepository, string, NewChatSetup, IReadOnlyList<NewChatFile>, Func<bool>, Action, Task> send)
    {
        _repositories = repositories; _add = add; _loadAgents = loadAgents; _send = send;
        var root = new Grid { Background = Theme.BackgroundBrush, AllowDrop = true };
        var content = new StackPanel { Spacing = 26, MaxWidth = 620, HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(24, 48, 24, 96) };

        // Introduction: the mark, the title, and what is needed to begin.
        var intro = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center };
        var logo = Marks.LogoMark(36);
        logo.HorizontalAlignment = HorizontalAlignment.Center; logo.Margin = new Thickness(0, 5, 0, 5);
        AutomationProperties.SetAccessibilityView(logo, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        intro.Children.Add(logo);
        var title = new TextBlock { Text = Copy("title"), FontSize = 24, FontWeight = FontWeights.Medium, CharacterSpacing = -17,
            TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
        AutomationProperties.SetHeadingLevel(title, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        intro.Children.Add(title);
        intro.Children.Add(_subtitle);
        content.Children.Add(intro);

        // The blocking choice, first: the repository, styled like every other
        // control in the card. Lit until it is made.
        _repositoryButton.MinHeight = 30; _repositoryButton.Padding = new Thickness(10, 5, 10, 5);
        _repositoryButton.CornerRadius = new CornerRadius(10); _repositoryButton.BorderThickness = new Thickness(1);
        _repositoryButton.Background = Theme.PanelBrush; _repositoryButton.HorizontalAlignment = HorizontalAlignment.Left;
        _repositoryButton.MaxWidth = 360;
        AutomationProperties.SetAutomationId(_repositoryButton, "newChat.repository");
        var repositoryMenu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedLeft };
        // Read the list each time it opens: folders can load after this page.
        repositoryMenu.Opening += (_, _) => FillRepositoryMenu(repositoryMenu);
        _repositoryButton.Flyout = repositoryMenu;
        _retry = ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => { _catalogRepository = null; await LoadAgentsAsync(); });
        _retry.Visibility = Visibility.Collapsed; _retry.VerticalAlignment = VerticalAlignment.Center;
        var choice = new Grid { ColumnSpacing = 10 };
        choice.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        choice.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); choice.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        choice.Children.Add(_repositoryButton);
        _catalogProgress.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(_catalogProgress, 1); choice.Children.Add(_catalogProgress);
        Grid.SetColumn(_retry, 2); choice.Children.Add(_retry);

        // The field: plain text on the card, no box of its own.
        _draft.PlaceholderText = Copy("prompt"); AutomationProperties.SetName(_draft, Copy("prompt")); AutomationProperties.SetAutomationId(_draft, "newChat.composer");
        _draft.Background = Theme.PanelBrush; _draft.BorderThickness = new Thickness(0); _draft.Padding = new Thickness(2, 6, 2, 6);
        foreach (var key in new[] { "TextControlBackgroundFocused", "TextControlBackgroundPointerOver" }) _draft.Resources[key] = Theme.PanelBrush;
        _draft.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(0);

        // The utility row, as in a chat: attach and fast mode, the agent field
        // with the setup control beside it, then Send.
        _attach = Buttons.ToolbarIcon(ActionIcon.Attach, L10n.Text("windows.chatpage.attach_a_file.21298c62"), async (_, _) => await AttachAsync());
        _attach.Foreground = Theme.AccentBrush; _attach.Width = _attach.Height = 28;
        AutomationProperties.SetAutomationId(_attach, "newChat.attach");
        _fast = Buttons.ToolbarIcon(ActionIcon.FastMode, "", (_, _) => { _fastMode = !_fastMode; RememberDraft(); RefreshFastMode(); });
        _fast.Width = _fast.Height = 28;
        AutomationProperties.SetAutomationId(_fast, "newChat.fastMode");
        _setupButton = Buttons.ToolbarIcon(ActionIcon.Settings, L10n.Text("windows.chatpage.setup.7013af4c"), (_, _) => { });
        _setupButton.Width = _setupButton.Height = 32;
        AutomationProperties.SetAutomationId(_setupButton, "newChat.setup");
        var setupPanel = new StackPanel { Spacing = Theme.SpaceS, MinWidth = 240 };
        setupPanel.Children.Add(Chrome.SectionLabel(L10n.Text("common.chat_working_style")));
        setupPanel.Children.Add(_workingStyle);
        _setupButton.Flyout = new Flyout { Content = setupPanel, Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.Top };
        _cancelStaging = Buttons.ToolbarIcon(ActionIcon.Stop, L10n.Text("common.cancel"), (_, _) => _stagingCancellation?.Cancel());
        _cancelStaging.Visibility = Visibility.Collapsed;
        AutomationProperties.SetName(_copyProgress, L10n.Text("common.chat.files_preparing"));
        ToolTipService.SetToolTip(_copyProgress, L10n.Text("common.chat.files_preparing"));
        _submit = Buttons.Primary(Copy("send"), ActionIcon.Send, async (_, _) => await SubmitAsync(), small: true);
        _submit.Content = ActionIcon.Send.Mark(14); _submit.Width = _submit.Height = 32; _submit.MinWidth = 0; _submit.Padding = new Thickness(0);
        _submit.CornerRadius = new CornerRadius(8);
        AutomationProperties.SetAutomationId(_submit, "newChat.send");

        static StackPanel Group(params UIElement[] children)
        {
            var group = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS, VerticalAlignment = VerticalAlignment.Center };
            foreach (var child in children) { if (child is FrameworkElement element) element.VerticalAlignment = VerticalAlignment.Center; group.Children.Add(child); }
            return group;
        }
        var utility = new Grid { ColumnSpacing = Theme.SpaceM };
        utility.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        utility.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        utility.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        utility.Children.Add(Group(_attach, _fast));
        var setup = Group(_agentSlot, _setupButton); setup.Spacing = Theme.SpaceXs; Grid.SetColumn(setup, 1); utility.Children.Add(setup);
        var actions = Group(_copyProgress, _cancelStaging, _submit); Grid.SetColumn(actions, 2); utility.Children.Add(actions);

        var composer = new StackPanel { Spacing = Theme.SpaceM };
        composer.Children.Add(choice); composer.Children.Add(_filesView); composer.Children.Add(_draft); composer.Children.Add(utility);
        _card.Child = composer;
        StartCard(_card);
        content.Children.Add(_card);

        // First run: nothing to talk about yet, so the page teaches the first step.
        _addButton = Buttons.Primary(Copy("add_repository"), ActionIcon.Create, async (_, _) => await AddAsync(), small: true);
        _addButton.HorizontalAlignment = HorizontalAlignment.Left;
        var firstStep = new Grid { ColumnSpacing = Theme.SpaceM, RowSpacing = Theme.SpaceM };
        firstStep.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); firstStep.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        firstStep.RowDefinitions.Add(new() { Height = GridLength.Auto }); firstStep.RowDefinitions.Add(new() { Height = GridLength.Auto });
        firstStep.Children.Add(new Border { Width = 32, Height = 32, CornerRadius = new CornerRadius(9), Background = Theme.AccentSoftBrush, VerticalAlignment = VerticalAlignment.Top,
            Child = new FontIcon { Glyph = "", FontSize = 16, Foreground = Theme.AccentBrush } });
        var firstText = new StackPanel { Spacing = 4 };
        firstText.Children.Add(new TextBlock { Text = Copy("add_repository"), FontSize = 14, FontWeight = FontWeights.SemiBold });
        firstText.Children.Add(new TextBlock { Text = Copy("step_repository_message"), FontSize = 12, Opacity = .65, TextWrapping = TextWrapping.Wrap });
        Grid.SetColumn(firstText, 1); firstStep.Children.Add(firstText);
        Grid.SetRow(_addButton, 1); Grid.SetColumnSpan(_addButton, 2); firstStep.Children.Add(_addButton);
        _onboarding.Child = new Border { Padding = new Thickness(Theme.SpaceS), Child = firstStep };
        _onboarding.Visibility = Visibility.Collapsed;
        StartCard(_onboarding);
        content.Children.Add(_onboarding);

        // A few ways to begin. They go away the moment there is a draft.
        foreach (var (key, icon) in new[] { ("starter_tour", ActionIcon.Docs), ("starter_tests", ActionIcon.Run), ("starter_review", ActionIcon.Compare) })
            _starters.Children.Add(Starter(Copy(key), icon));
        _starters.Margin = new Thickness(0, -8, 0, 0);
        content.Children.Add(_starters);
        content.Children.Add(_notice);

        root.DragOver += (_, args) => {
            if (!_sending && !_stagingFiles && _account == AppServices.AccountGeneration && args.DataView.Contains(StandardDataFormats.StorageItems)) {
                args.AcceptedOperation = DataPackageOperation.Copy; args.Handled = true;
            }
        };
        root.Drop += async (_, args) => {
            if (_sending || _stagingFiles || !args.DataView.Contains(StandardDataFormats.StorageItems)) return;
            args.Handled = true;
            var generation = _draftGeneration; var repository = _draftRepository; var lifetime = _lifetime;
            var deferral = args.GetDeferral();
            try { var items = await args.DataView.GetStorageItemsAsync(); if (OwnsFiles(repository, generation, lifetime)) await StageFilesAsync(items.OfType<Windows.Storage.StorageFile>().Select(file => file.Path), repository, generation, lifetime); }
            catch (Exception error) { if (OwnsFiles(repository, generation, lifetime)) Notice(error.Message); }
            finally { deferral.Complete(); }
        };
        root.Children.Add(new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Center });
        Content = root;
        AppServices.AccountChanged += AccountRetired;
        _draft.TextChanged += (_, _) => { RememberDraft(); RefreshActions(); };
        _draft.PreviewKeyDown += (_, args) => {
            if (args.Key != VirtualKey.Enter || InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down) || !_submit.IsEnabled) return;
            args.Handled = true; _ = SubmitAsync();
        };
        RenderRepository(); RenderAgent(); RefreshWorkingStyle(); RefreshActions();
        Loaded += (_, _) => {
            RemoteWorkspaces.Changed -= RepositoriesChanged; RemoteWorkspaces.Changed += RepositoriesChanged;
            RefreshRepositories();
        };
        Unloaded += (_, _) => { RememberDraft(); _lifetime++; _stagingCancellation?.Cancel(); RemoteWorkspaces.Changed -= RepositoriesChanged; _catalogRevision++; if (!_handoff) _request++; };
    }

    /// <summary>The Mac's chatStartCard: a quiet panel with a hairline, lifted off the page.</summary>
    private static void StartCard(Border card)
    {
        card.Background = Theme.PanelBrush; card.BorderBrush = Theme.BorderBrush; card.BorderThickness = new Thickness(1);
        card.CornerRadius = new CornerRadius(16); card.Padding = new Thickness(12);
        card.Shadow = new ThemeShadow(); card.Translation = new System.Numerics.Vector3(0, 0, 16);
    }

    /// <summary>Lighter than a secondary button: a suggestion, not an action the page asks for.</summary>
    private Button Starter(string text, ActionIcon icon)
    {
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        label.Children.Add(icon.Mark(12));
        label.Children.Add(new TextBlock { Text = text, FontSize = 12, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center });
        var button = new Button { Content = label, Height = 28, MinHeight = 0, Padding = new Thickness(12, 0, 12, 0),
            CornerRadius = new CornerRadius(14), Background = Theme.PanelBrush, BorderBrush = Theme.BorderBrush, BorderThickness = new Thickness(1),
            Foreground = Theme.Brush(static () => Theme.ControlGlyph) };
        button.Resources["ButtonBorderBrushPointerOver"] = Theme.AccentBrush;
        AutomationProperties.SetName(button, text);
        button.Click += (_, _) => { _draft.Text = text; _draft.Focus(FocusState.Programmatic); _draft.SelectionStart = _draft.Text.Length; };
        return button;
    }

    private void AccountRetired()
    {
        if (_account == AppServices.AccountGeneration) return;
        DispatcherQueue.TryEnqueue(() => {
            _request++; _catalogRevision++; _lifetime++; _stagingCancellation?.Cancel();
            _drafts.DiscardFiles(); _files.Clear(); _draft.Text = ""; RenderFiles();
            AppServices.AccountChanged -= AccountRetired;
        });
    }
    private void RepositoriesChanged() => DispatcherQueue.TryEnqueue(() => { if (IsLoaded && _account == AppServices.AccountGeneration) RefreshRepositories(); });

    internal void RefreshRepositories(string? select = null)
    {
        if (_sending) return;
        if (select is not null) _requestedRepository = select;
        var prior = _selected?.Id;
        _list = _repositories();
        // An explicit request, then the current choice. With exactly one
        // repository there is nothing to choose, so the page chooses it.
        var chosen = _list.FirstOrDefault(repository => repository.Id == _requestedRepository)
            ?? _list.FirstOrDefault(repository => repository.Id == prior)
            ?? (_list.Count == 1 ? _list[0] : null);
        var requestedThisPass = _requestedRepository is not null && chosen?.Id == _requestedRepository;
        if (requestedThisPass) _requestedRepository = null;
        _selected = chosen;
        // Filling the list is not a choice. An explicit open, or a folder the
        // person already selected, may adopt. An automatic first folder must
        // leave the unbound draft on screen.
        BindRepository(chosen?.Id, adoptUnbound: requestedThisPass || _drafts.Repository is not null);
        RenderRepository(); RefreshActions();
        _ = LoadAgentsAsync();
    }

    private void FillRepositoryMenu(MenuFlyout menu)
    {
        menu.Items.Clear();
        if (!_sending && _account == AppServices.AccountGeneration)
        {
            var fresh = _repositories();
            if (!fresh.Select(item => item.Id).SequenceEqual(_list.Select(item => item.Id))) RefreshRepositories();
        }
        // This computer first, then each remote computer under its name.
        foreach (var group in _list.GroupBy(item => (item.IsLocal, item.Machine)).OrderBy(group => group.Key.IsLocal ? 0 : 1))
        {
            menu.Items.Add(new MenuFlyoutItem { Text = group.Key.Machine, IsEnabled = false, FontSize = 11 });
            foreach (var repository in group)
            {
                var item = new MenuFlyoutItem { Text = repository.Name,
                    Icon = new FontIcon { Glyph = repository.Id == _selected?.Id ? "" : repository.IsLocal ? "" : "" } };
                ToolTipService.SetToolTip(item, repository.Path);
                var target = repository;
                item.Click += async (_, _) => await SelectRepositoryAsync(target);
                menu.Items.Add(item);
            }
        }
        if (_list.Count > 0) menu.Items.Add(new MenuFlyoutSeparator());
        var add = new MenuFlyoutItem { Text = Copy("add_repository"), Icon = new FontIcon { Glyph = "" } };
        add.Click += async (_, _) => await AddAsync();
        menu.Items.Add(add);
    }

    private async Task SelectRepositoryAsync(NewChatRepository repository)
    {
        if (_sending || _account != AppServices.AccountGeneration) return;
        _requestedRepository = null;
        if (_selected?.Id == repository.Id && _draftRepository == repository.Id) return;
        _selected = repository;
        BindRepository(repository.Id);
        RenderRepository(); RefreshActions();
        await LoadAgentsAsync();
    }

    private void RenderRepository()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var local = _selected is null || _selected.IsLocal;
        row.Children.Add(new FontIcon { Glyph = local ? "" : "", FontSize = 11, VerticalAlignment = VerticalAlignment.Center,
            Foreground = _selected is null ? Theme.AccentBrush : Theme.Brush(static () => Theme.ControlGlyph) });
        row.Children.Add(new TextBlock { Text = _selected?.Name ?? Copy("choose_repository"), FontSize = 12, FontWeight = FontWeights.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(new FontIcon { Glyph = "", FontSize = 8, Opacity = .5, VerticalAlignment = VerticalAlignment.Center });
        _repositoryButton.Content = row;
        _repositoryButton.BorderBrush = _selected is null ? Theme.AccentBrush : Theme.BorderBrush;
        var value = _selected is null ? Copy("choose_repository") : _selected.Name + " · " + _selected.Machine;
        AutomationProperties.SetName(_repositoryButton, Copy("repository") + ", " + value);
        ToolTipService.SetToolTip(_repositoryButton, _selected?.Path ?? Copy("choose_repository"));
    }

    private JsonNode? CurrentBackend()
    {
        var id = Format.Text(_setup, "backend");
        return id.Length == 0 ? null : _available.FirstOrDefault(backend => Format.Text(backend, "id") == id);
    }

    /// <summary>The same agent field as a running chat, writing into this draft.</summary>
    private void RenderAgent()
    {
        var locked = _sending || _account != AppServices.AccountGeneration || _available.Length == 0;
        _agentSlot.Child = ChatAgentPicker.Build(new ChatAgentPickerSource(
            Chat: () => _setup,
            Backends: () => _available,
            Update: patch =>
            {
                foreach (var (key, value) in patch)
                {
                    var text = value?.ToString() ?? "";
                    if (key == "autonomy") { _autonomy = text; continue; }
                    _setup[key] = text;
                    // A new agent starts from its own defaults.
                    if (key == "backend") { _setup["model"] = ""; _setup["effort"] = ""; }
                }
                NormalizeFastMode(); RememberDraft(); RefreshWorkingStyle(); RefreshFastMode(); RefreshActions();
                return Task.FromResult(true);
            },
            Repaint: () => { RenderAgent(); RefreshActions(); }), locked);
        AutomationProperties.SetAutomationId(_agentSlot.Child, "newChat.agent");
    }

    private void Notice(string text)
    {
        _notice.Text = text;
        _notice.Visibility = text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>What Send says while it cannot be pressed, as on the Mac.</summary>
    private string? BlockReason()
    {
        if (_sending) return null;
        if (_selected is null) return Copy("needs_repository");
        if (_catalogRepository != _selected.Id && !_catalogFailed) return Copy("finding_agents");
        if (CurrentBackend() is null) return Copy("needs_agent");
        return null;
    }

    private void RefreshActions()
    {
        var current = _account == AppServices.AccountGeneration;
        var writing = _draft.Text.Trim().Length > 0 || _files.Count > 0;
        var needsRepository = _list.Count == 0 && !writing;
        _card.Visibility = needsRepository ? Visibility.Collapsed : Visibility.Visible;
        _onboarding.Visibility = needsRepository ? Visibility.Visible : Visibility.Collapsed;
        _subtitle.Text = needsRepository ? Copy("empty") : Copy("subtitle");
        _starters.Visibility = !needsRepository && _selected is not null && !writing && !_sending ? Visibility.Visible : Visibility.Collapsed;

        var blocked = BlockReason();
        _submit.IsEnabled = blocked is null && !_sending && !_pickingFiles && !_stagingFiles && !_addingRepository && current;
        var action = Copy(_sending ? "preparing" : NewChatSetup.ShouldSend(_draft.Text, _files.Count) ? "send" : "open_chat");
        AutomationProperties.SetName(_submit, action);
        ToolTipService.SetToolTip(_submit, blocked ?? action);

        var loading = _selected is not null && _catalogRepository != _selected.Id && !_catalogFailed;
        _catalogProgress.IsActive = loading; _catalogProgress.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
        _repositoryButton.IsEnabled = _draft.IsEnabled = !_sending && current;
        _addButton.IsEnabled = !_sending && !_addingRepository && current;
        _attach.IsEnabled = !_sending && !_pickingFiles && !_stagingFiles && current;
        _setupButton.IsEnabled = !_sending && current;
        if (_agentSlot.Child is Control agent) agent.IsEnabled = !_sending && current && _available.Length > 0;
        _copyProgress.IsActive = _stagingFiles; _copyProgress.Visibility = _cancelStaging.Visibility = _stagingFiles ? Visibility.Visible : Visibility.Collapsed;
        RefreshFastMode();
    }

    private async Task LoadAgentsAsync()
    {
        var revision = ++_catalogRevision;
        if (_selected is not NewChatRepository repository) { _catalogRepository = null; ClearCatalog(); RefreshActions(); return; }
        if (_catalogRepository == repository.Id && _available.Length > 0) return;
        _catalogRepository = null; _catalogFailed = false; ClearCatalog(); Notice(""); RefreshActions();
        _retry.Visibility = Visibility.Collapsed;
        try {
            var result = await _loadAgents(repository);
            if (revision != _catalogRevision || _account != AppServices.AccountGeneration || !IsLoaded || _selected?.Id != repository.Id) return;
            _available = ((result as JsonArray ?? result["backends"] as JsonArray)?.OfType<JsonObject>()
                .Where(backend => Format.Text(backend, "id") is { Length: > 0 } id && id != "sh" && ChatAgentPicker.Installed(backend)).ToArray() ?? []);
            _catalogRepository = repository.Id;
            var saved = ChatLaunchChoice.Load();
            JsonNode? Find(string? id) => id is null ? null : _available.FirstOrDefault(backend => Format.Text(backend, "id") == id);
            var backend = Find(_preferredSetup?.Backend) ?? Find(saved?.Backend) ?? Find("codex") ?? _available.FirstOrDefault();
            _restoringDraft = true;
            _setup = new JsonObject();
            if (backend is not null)
            {
                var id = Format.Text(backend, "id");
                string Offered(string list, string? wanted) => wanted is { Length: > 0 }
                    && (backend[list] as JsonArray ?? []).Any(value => value?.ToString() == wanted) ? wanted : "";
                var model = _preferredSetup?.Backend == id ? _preferredSetup.Model : saved?.Backend == id ? saved.Model : null;
                var effort = _preferredSetup?.Backend == id ? _preferredSetup.Effort : saved?.Backend == id ? saved.Effort : null;
                _setup = new JsonObject { ["backend"] = id, ["model"] = Offered("models", model), ["effort"] = Offered("efforts", effort) };
            }
            else { Notice(Copy("setup_changed")); _retry.Visibility = Visibility.Visible; }
            _restoringDraft = false;
            NormalizeFastMode(); RememberDraft(); RenderAgent(); RefreshWorkingStyle(); RefreshActions();
        } catch (Exception error) {
            _restoringDraft = false;
            if (revision == _catalogRevision && _account == AppServices.AccountGeneration) {
                // A failed catalog is unavailable, not evidence nothing is installed.
                _catalogFailed = true; Notice(error.Message); _retry.Visibility = Visibility.Visible; RefreshActions();
            }
        }
    }

    private void ClearCatalog()
    {
        _available = []; _setup = new JsonObject();
        RenderAgent();
    }

    private NewChatSetup? CurrentSetup()
    {
        if (CurrentBackend() is not JsonNode backend)
            return (_preferredSetup ?? new NewChatSetup("", null, null)) with { Mode = _mode, Autonomy = _autonomy, FastMode = _fastMode };
        string? Choice(string key) => Format.Text(_setup, key) is { Length: > 0 } value ? value : null;
        return new NewChatSetup(Format.Text(backend, "id"), Choice("model"), Choice("effort"), _mode,
            Format.Text(backend, "gateTier") == "bypassOnly" ? "bypass" : _autonomy, _fastMode);
    }

    private void RememberDraft()
    {
        if (_restoringDraft) return;
        _preferredSetup = CurrentSetup();
        _drafts.Remember(new NewChatDraft(_draft.Text, _files.ToArray(), _preferredSetup));
    }

    private void BindRepository(string? repository, bool adoptUnbound = true)
    {
        if (!adoptUnbound) return;
        if (_draftRepository == repository) return;
        if (!(_draftRepository is null && _draftGeneration == 0 && repository is not null)) _stagingCancellation?.Cancel();
        RememberDraft();
        var restored = _drafts.Select(repository, new NewChatDraft(_draft.Text, _files.ToArray(), _preferredSetup));
        _catalogRepository = null;
        _restoringDraft = true;
        _draft.Text = restored.Text; _files.Clear(); _files.AddRange(restored.Files); _preferredSetup = restored.Setup;
        _mode = restored.Setup?.Mode ?? "execute"; _autonomy = restored.Setup?.Autonomy ?? "bypass";
        _fastMode = restored.Setup?.FastMode ?? false;
        _restoringDraft = false; RenderFiles(); RefreshWorkingStyle();
    }

    private void RefreshWorkingStyle()
    {
        _workingStyle.Children.Clear();
        var enabled = !_sending && _account == AppServices.AccountGeneration;
        _workingStyle.Children.Add(Chrome.Segmented([("plan", L10n.Text("windows.chatpage.plan.fa8ed0bd")), ("execute", L10n.Text("windows.chatpage.execute.e3a67d95"))], _mode,
            value => { _mode = value; RememberDraft(); RefreshWorkingStyle(); return Task.CompletedTask; }, enabled: enabled));
        // One option, same block, when the agent decides it.
        var bypassOnly = Format.Text(CurrentBackend(), "gateTier") == "bypassOnly";
        var choices = bypassOnly ? new[] { ("bypass", L10n.Text("windows.chatpage.don_t_ask.15dae980")) }
            : new[] { ("standard", L10n.Text("windows.chatpage.ask_first.4a9e8cf3")), ("bypass", L10n.Text("windows.chatpage.don_t_ask.15dae980")) };
        _workingStyle.Children.Add(Chrome.Segmented(choices, bypassOnly ? "bypass" : _autonomy,
            value => { _autonomy = value; RememberDraft(); RefreshWorkingStyle(); return Task.CompletedTask; }, enabled: enabled && !bypassOnly));
        var summary = L10n.Text(_mode == "plan" ? "windows.chatpage.plan.fa8ed0bd" : "windows.chatpage.execute.e3a67d95") + " · "
            + L10n.Text(bypassOnly || _autonomy == "bypass" ? "windows.chatpage.don_t_ask.15dae980" : "windows.chatpage.ask_first.4a9e8cf3");
        if (_setupButton is not null)
        {
            AutomationProperties.SetName(_setupButton, L10n.Text("windows.chatpage.setup.7013af4c") + ", " + summary);
            ToolTipService.SetToolTip(_setupButton, L10n.Text("windows.chatpage.setup.7013af4c") + " · " + summary);
        }
    }

    private void NormalizeFastMode()
    {
        if (CurrentBackend() is not JsonNode backend) return;
        if (!ChatFastMode.Available(Format.Text(_setup, "model"), backend["fastModeModels"] as JsonArray, Format.Text(backend, "id"))) _fastMode = false;
    }

    private void RefreshFastMode()
    {
        if (_fast is null) return;
        var backend = CurrentBackend();
        var models = backend?["fastModeModels"] as JsonArray;
        var id = Format.Text(backend, "id");
        var available = ChatFastMode.Available(Format.Text(_setup, "model"), models, id);
        var title = _fastMode ? id == "grok" ? L10n.Text("common.chat.fast_mode_fast") : L10n.Text("common.chat.fast_mode_priority") : L10n.Text("common.chat.fast_mode_default");
        _fast.Visibility = models is null ? Visibility.Collapsed : Visibility.Visible;
        _fast.IsEnabled = available && !_sending && _account == AppServices.AccountGeneration;
        _fast.Background = _fastMode ? Theme.AccentSoftBrush : Theme.ClearBrush;
        _fast.Foreground = _fastMode ? Theme.AccentBrush : Theme.Brush(static () => Theme.ControlGlyph);
        AutomationProperties.SetName(_fast, title);
        ToolTipService.SetToolTip(_fast, available ? title : id == "grok" ? L10n.Text("common.chat.fast_mode_select_grok") : L10n.Text("common.chat.fast_mode_select_opus"));
    }

    private bool OwnsDraft(string? repository, long generation, long lifetime) => IsLoaded && !_sending && _account == AppServices.AccountGeneration && _draftRepository == repository && _draftGeneration == generation && _lifetime == lifetime;
    private bool OwnsFiles(string? repository, long generation, long lifetime) => IsLoaded && !_sending && _account == AppServices.AccountGeneration && _lifetime == lifetime && _drafts.AcceptsFiles(repository, generation);

    private async Task AttachAsync()
    {
        if (_pickingFiles || _stagingFiles || _sending || !IsLoaded || _account != AppServices.AccountGeneration) return;
        var generation = _draftGeneration; var repository = _draftRepository; var lifetime = _lifetime;
        _pickingFiles = true; RefreshActions();
        try {
            var picker = new FileOpenPicker(); picker.FileTypeFilter.Add("*");
            if (App.CurrentWindow is { } window) InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
            var files = await picker.PickMultipleFilesAsync();
            if (OwnsFiles(repository, generation, lifetime)) await StageFilesAsync(files.Select(file => file.Path), repository, generation, lifetime);
        }
        catch (Exception error) { if (OwnsFiles(repository, generation, lifetime)) Notice(error.Message); }
        finally { _pickingFiles = false; RefreshActions(); }
    }

    private async Task StageFilesAsync(IEnumerable<string> paths, string? repository, long generation, long lifetime)
    {
        if (_stagingFiles || !OwnsFiles(repository, generation, lifetime)) return;
        using var cancellation = new CancellationTokenSource();
        _stagingCancellation = cancellation; _stagingFiles = true; RefreshActions();
        try {
            foreach (var path in paths) {
                if (!OwnsFiles(repository, generation, lifetime)) return;
                if (_files.Count >= NewChatFile.MaximumCount) { Notice(L10n.Text("common.chat_files_busy")); break; }
                var selected = await NewChatFile.CaptureAsync(path, cancellation.Token);
                selected = selected.RetainIfOwned(OwnsFiles(repository, generation, lifetime));
                if (selected is null) return;
                _files.Add(selected); RenderFiles(); RememberDraft();
            }
        } catch (OperationCanceledException) { }
        catch (Exception error) { if (OwnsFiles(repository, generation, lifetime)) Notice(error.Message); }
        finally {
            if (ReferenceEquals(_stagingCancellation, cancellation)) _stagingCancellation = null;
            _stagingFiles = false; RefreshActions();
        }
    }

    private void RenderFiles()
    {
        _filesView.Children.Clear();
        foreach (var file in _files) {
            var remove = ActionIconGlyph.Button(file.Name, ActionIcon.Dismiss, (_, _) => { if (_sending) return; _files.Remove(file); RenderFiles(); RememberDraft(); file.Discard(); RefreshActions(); });
            AutomationProperties.SetName(remove, L10n.Text("windows.chatpage.remove_attachment_0.bea47ab0", file.Name));
            _filesView.Children.Add(remove);
        }
        _filesView.Visibility = _files.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task AddAsync()
    {
        if (_addingRepository || _sending || !IsLoaded || _account != AppServices.AccountGeneration) return;
        var repository = _draftRepository; var generation = _draftGeneration; var lifetime = _lifetime;
        _addingRepository = true; RefreshActions();
        try { var added = await _add(); if (OwnsDraft(repository, generation, lifetime)) RefreshRepositories(added); }
        catch (Exception error) { if (OwnsDraft(repository, generation, lifetime)) Notice(error.Message); }
        finally { _addingRepository = false; RefreshActions(); }
    }

    private async Task SubmitAsync()
    {
        if (_sending || _pickingFiles || _stagingFiles || _addingRepository || !IsLoaded || _account != AppServices.AccountGeneration || _selected is not NewChatRepository repository || _catalogRepository != repository.Id
            || CurrentBackend() is null) return;
        if (!_repositories().Any(candidate => candidate.Id == repository.Id)) { RefreshRepositories(); return; }
        var text = _draft.Text; var ticket = ++_request; _sending = true; Notice(""); RenderAgent(); RefreshWorkingStyle(); RefreshActions();
        var setup = CurrentSetup()!; var files = _files.ToArray(); RememberDraft();
        var revision = _draftGeneration;
        var transferred = false;
        bool Owns() => _account == AppServices.AccountGeneration && _request == ticket && _draftGeneration == revision
            && (_draftRepository == repository.Id || _draftRepository is null)
            && _selected?.Id == repository.Id
            && _draft.Text == text && _files.SequenceEqual(files) && CurrentSetup() == setup;
        _handoff = true;
        try { await _send(repository, text, setup, files, Owns, () => {
            if (Owns() && _draft.Text == text && _files.SequenceEqual(files)) {
                _draft.Text = ""; _files.Clear(); transferred = true; RenderFiles(); RememberDraft();
            }
        }); }
        catch (Exception error) { if (Owns()) Notice(error.Message); }
        finally {
            if (transferred && _account == AppServices.AccountGeneration && _request == ticket && _draft.Text.Length == 0 && _files.Count == 0 && CurrentSetup() == setup) {
                _autonomy = "bypass"; RememberDraft();
            }
            _handoff = false; _sending = false; RenderAgent(); RefreshWorkingStyle(); RefreshActions(); if (IsLoaded) RefreshRepositories();
        }
    }
}
