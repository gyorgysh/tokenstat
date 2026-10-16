// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Text;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using Tokenstat.Design;
using Tokenstat.Navigation;
using Windows.Foundation;
using System.Text.Json.Nodes;
using Windows.Storage.Pickers;
using Windows.System;
using Windows.UI.Core;
using Windows.ApplicationModel.DataTransfer;
using WinRT.Interop;

namespace Tokenstat.Pages;

internal sealed record NewChatRepository(string Id, string Name, string Machine, string Path)
{
    public override string ToString() => Name + " · " + Machine;
}

/// <summary>An unsent, account-owned draft. Choosing or adding a folder never creates a conversation.</summary>
internal sealed class NewChatPage : Page
{
    private readonly long _account = AppServices.AccountGeneration;
    private readonly Func<IReadOnlyList<NewChatRepository>> _repositories;
    private readonly Func<Task<string?>> _add;
    private readonly Func<NewChatRepository, Task<JsonNode>> _loadAgents;
    private readonly Func<NewChatRepository, string, NewChatSetup, IReadOnlyList<NewChatFile>, Func<bool>, Action, Task> _send;
    private readonly ComboBox _repository = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBox _draft = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 160, MaxHeight = 360 };
    private readonly TextBlock _notice = new() { TextWrapping = TextWrapping.Wrap, Opacity = .7 };
    private readonly ComboBox _agent = new() { Header = L10n.Text("windows.chatpage.agent.11b39c93"),
        PlaceholderText = L10n.Text("common.chat.select_agent"), HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox _model = new() { Header = L10n.Text("windows.chatpage.model.5e2c614c"), HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox _effort = new() { Header = L10n.Text("windows.chatpage.effort.4387e5d3"), HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly FlowPanel _workingStyle = new() { Spacing = Theme.SpaceS };
    private readonly FlowPanel _filesView = new() { Spacing = Theme.SpaceS };
    private readonly List<NewChatFile> _files = [];
    private readonly NewChatDraftStore _drafts = new();
    private string? _draftRepository => _drafts.Repository;
    private long _draftGeneration => _drafts.Revision;
    private long _lifetime;
    private string _mode = "execute", _autonomy = ChatLaunchChoice.Load()?.Autonomy ?? "bypass";
    private bool _fastMode;
    private bool _restoringDraft;
    private readonly Button _attach;
    private readonly Button _fast;
    private readonly ProgressRing _copyProgress = new() { Width = 20, Height = 20, Visibility = Visibility.Collapsed, IsActive = false };
    private readonly Button _cancelStaging;
    private readonly Button _submit;
    private readonly Button _addButton;
    private readonly Button _retry;
    private readonly Storyboard _ambient = new();
    private bool _sending;
    private bool _pickingFiles, _addingRepository;
    private bool _stagingFiles;
    private CancellationTokenSource? _stagingCancellation;
    private long _request;
    private long _catalogRevision;
    private bool _handoff;
    private bool _refreshingRepositories;
    private string? _catalogRepository;
    private string? _requestedRepository;
    private NewChatSetup? _preferredSetup;
    private static string Copy(string key) { var resource = "common.new_chat." + key; return L10n.Text(resource); }

    internal NewChatPage(Func<IReadOnlyList<NewChatRepository>> repositories, Func<Task<string?>> add,
        Func<NewChatRepository, Task<JsonNode>> loadAgents, Func<NewChatRepository, string, NewChatSetup, IReadOnlyList<NewChatFile>, Func<bool>, Action, Task> send)
    {
        _repositories = repositories; _add = add; _loadAgents = loadAgents; _send = send;
        var root = new Grid { Background = Theme.BackgroundBrush, AllowDrop = true };
        var halo = new Ellipse { Width = 600, Height = 420, Opacity = .45, IsHitTestVisible = false,
            Fill = new RadialGradientBrush { Center = new Point(.5, .5), RadiusX = .5, RadiusY = .5,
                GradientStops = { new GradientStop { Color = Theme.Accent, Offset = 0 }, new GradientStop { Color = Microsoft.UI.Colors.Transparent, Offset = 1 } } },
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        root.Children.Add(halo);
        var content = new StackPanel { Spacing = 18, MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(32, 40, 32, 40) };
        var bars = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, Height = 40, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var height in new[] { 21d, 34, 27 }) bars.Children.Add(new Border { Width = 7, Height = height,
            CornerRadius = new CornerRadius(3), Background = Theme.AccentBrush, VerticalAlignment = VerticalAlignment.Center });
        content.Children.Add(bars);
        content.Children.Add(new TextBlock { Text = Copy("title"), FontSize = 34, FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center });
        content.Children.Add(new TextBlock { Text = Copy("subtitle"), FontSize = 14, Opacity = .7,
            TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 0, 0, 8) });
        _repository.Header = Copy("repository"); _repository.PlaceholderText = Copy("choose_repository");
        AutomationProperties.SetAutomationId(_repository, "newChat.repository");
        _addButton = ActionIconGlyph.Button(Copy("add_repository"), ActionIcon.Create, async (_, _) => await AddAsync());
        var choice = new Grid { ColumnSpacing = 8 };
        choice.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); choice.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        choice.Children.Add(_repository); Grid.SetColumn(_addButton, 1); _addButton.VerticalAlignment = VerticalAlignment.Bottom; choice.Children.Add(_addButton);
        content.Children.Add(choice);
        var setup = new FlowPanel { Spacing = Theme.SpaceS, MinimumItemWidth = 180 };
        setup.Children.Add(_agent); setup.Children.Add(_model); setup.Children.Add(_effort); content.Children.Add(setup); content.Children.Add(_workingStyle);
        _draft.PlaceholderText = Copy("prompt"); AutomationProperties.SetName(_draft, Copy("prompt")); AutomationProperties.SetAutomationId(_draft, "newChat.composer");
        var well = new Border { Background = Theme.PanelBrush, BorderBrush = Theme.BorderBrush, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(16), Padding = new Thickness(10) };
        var writing = new StackPanel { Spacing = Theme.SpaceS }; writing.Children.Add(_draft); writing.Children.Add(_filesView);
        _draft.Background = Theme.PanelBrush; _draft.BorderThickness = new Thickness(0);
        _attach = Buttons.ToolbarIcon(ActionIcon.Attach, L10n.Text("windows.chatpage.attach_a_file.21298c62"), async (_, _) => await AttachAsync());
        AutomationProperties.SetAutomationId(_attach, "newChat.attach");
        _fast = Buttons.ToolbarIcon(ActionIcon.FastMode, "", (_, _) => { _fastMode = !_fastMode; RememberDraft(); RefreshFastMode(); });
        AutomationProperties.SetAutomationId(_fast, "newChat.fastMode");
        var fileTools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS }; fileTools.Children.Add(_attach); fileTools.Children.Add(_fast);
        _cancelStaging = Buttons.ToolbarIcon(ActionIcon.Stop, L10n.Text("common.cancel"), (_, _) => _stagingCancellation?.Cancel());
        _cancelStaging.Visibility = Visibility.Collapsed;
        AutomationProperties.SetName(_copyProgress, L10n.Text("common.chat.files_preparing"));
        ToolTipService.SetToolTip(_copyProgress, L10n.Text("common.chat.files_preparing"));
        fileTools.Children.Add(_copyProgress); fileTools.Children.Add(_cancelStaging);
        writing.Children.Add(fileTools); well.Child = writing; content.Children.Add(well);
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
            catch (Exception error) { if (OwnsFiles(repository, generation, lifetime)) _notice.Text = error.Message; }
            finally { deferral.Complete(); }
        };
        _submit = ActionIconGlyph.PrimaryButton(Copy("send"), ActionIcon.Send, async (_, _) => await SubmitAsync());
        _submit.HorizontalAlignment = HorizontalAlignment.Right; AutomationProperties.SetAutomationId(_submit, "newChat.send");
        content.Children.Add(_submit); content.Children.Add(_notice);
        _retry = ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => { _catalogRepository = null; await LoadAgentsAsync(); });
        _retry.Visibility = Visibility.Collapsed; content.Children.Add(_retry);
        root.Children.Add(new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Center });
        var waves = new Canvas { IsHitTestVisible = false }; root.Children.Add(waves);
        root.SizeChanged += (_, args) => waves.Clip = new RectangleGeometry { Rect = new Rect(0, 0, args.NewSize.Width, args.NewSize.Height) };
        root.PointerPressed += (_, args) => {
            if (args.Handled || !Motion.AnimationsEnabled() || !args.GetCurrentPoint(root).Properties.IsLeftButtonPressed) return;
            var point = args.GetCurrentPoint(root).Position;
            var occupied = content.TransformToVisual(root).TransformBounds(new Rect(0, 0, content.ActualWidth, content.ActualHeight));
            if (occupied.Contains(point) || waves.Children.Count >= 3) return;
            var ring = new Ellipse { Width = 180, Height = 180, Stroke = Theme.AccentBrush, StrokeThickness = 1, Opacity = .12,
                RenderTransformOrigin = new Point(.5, .5), RenderTransform = new ScaleTransform { ScaleX = .2, ScaleY = .2 } };
            Canvas.SetLeft(ring, point.X - 90); Canvas.SetTop(ring, point.Y - 90); waves.Children.Add(ring);
            var animation = new Storyboard();
            foreach (var property in new[] { "(UIElement.RenderTransform).(ScaleTransform.ScaleX)", "(UIElement.RenderTransform).(ScaleTransform.ScaleY)", "Opacity" }) {
                var motion = new DoubleAnimation { From = property == "Opacity" ? .12 : .2, To = property == "Opacity" ? 0 : 2.5, Duration = new Duration(TimeSpan.FromMilliseconds(650)), EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
                Storyboard.SetTarget(motion, ring); Storyboard.SetTargetProperty(motion, property); animation.Children.Add(motion);
            }
            animation.Completed += (_, _) => waves.Children.Remove(ring); animation.Begin();
        };
        Content = root;
        AppServices.AccountChanged += AccountRetired;
        _draft.TextChanged += (_, _) => RefreshActions();
        _draft.PreviewKeyDown += (_, args) => {
            if (args.Key != VirtualKey.Enter || InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down) || !_submit.IsEnabled) return;
            args.Handled = true; _ = SubmitAsync();
        };
        _repository.SelectionChanged += async (_, _) => { if (_refreshingRepositories) return; _requestedRepository = null; BindRepository((_repository.SelectedItem as NewChatRepository)?.Id); RefreshActions(); await LoadAgentsAsync(); };
        _agent.SelectionChanged += (_, _) => { if (_restoringDraft) return; FillModels(); RefreshWorkingStyle(); RememberDraft(); RefreshActions(); };
        _model.SelectionChanged += (_, _) => { if (!_restoringDraft) { NormalizeFastMode(); RememberDraft(); RefreshFastMode(); } };
        _effort.SelectionChanged += (_, _) => RememberDraft();
        AutomationProperties.SetAutomationId(_agent, "newChat.agent"); AutomationProperties.SetAutomationId(_model, "newChat.model"); AutomationProperties.SetAutomationId(_effort, "newChat.effort");
        _draft.TextChanged += (_, _) => RememberDraft();
        Loaded += (_, _) => {
            RemoteWorkspaces.Changed -= RepositoriesChanged; RemoteWorkspaces.Changed += RepositoriesChanged;
            RefreshRepositories();
            if (Motion.AnimationsEnabled()) {
                var breath = new DoubleAnimation { From = .08, To = .16, Duration = new Duration(TimeSpan.FromSeconds(7)), AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever };
                Storyboard.SetTarget(breath, halo); Storyboard.SetTargetProperty(breath, "Opacity"); _ambient.Children.Clear(); _ambient.Children.Add(breath); _ambient.Begin();
            } else halo.Opacity = .1;
        };
        Unloaded += (_, _) => { RememberDraft(); _lifetime++; _stagingCancellation?.Cancel(); waves.Children.Clear(); RemoteWorkspaces.Changed -= RepositoriesChanged; _ambient.Stop(); _catalogRevision++; if (!_handoff) _request++; };
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
        var prior = (_repository.SelectedItem as NewChatRepository)?.Id;
        var repositories = _repositories(); _refreshingRepositories = true; _repository.ItemsSource = repositories;
        _repository.SelectedItem = repositories.FirstOrDefault(repository => repository.Id == _requestedRepository)
            ?? repositories.FirstOrDefault(repository => repository.Id == prior);
        var chosen = (_repository.SelectedItem as NewChatRepository)?.Id;
        var requestedThisPass = _requestedRepository is not null && chosen == _requestedRepository;
        if (requestedThisPass) _requestedRepository = null;
        _refreshingRepositories = false;
        // Filling the combo is not a choice. An explicit open, or a folder the
        // person already selected, may adopt. An automatic first folder must
        // leave the unbound draft on screen.
        BindRepository(chosen, adoptUnbound: requestedThisPass || _drafts.Repository is not null);
        _notice.Text = repositories.Count == 0 ? Copy("empty") : "";
        RefreshActions();
        _ = LoadAgentsAsync();
    }
    private void RefreshActions()
    {
        _submit.IsEnabled = !_sending && !_pickingFiles && !_stagingFiles && !_addingRepository && _account == AppServices.AccountGeneration && _repository.SelectedItem is NewChatRepository repository
            && _catalogRepository == repository.Id && _agent.SelectedItem is ComboBoxItem;
        var current = _account == AppServices.AccountGeneration;
        _repository.IsEnabled = _draft.IsEnabled = !_sending && current;
        _addButton.IsEnabled = !_sending && !_addingRepository && current;
        _attach.IsEnabled = !_sending && !_pickingFiles && !_stagingFiles && current;
        _agent.IsEnabled = _model.IsEnabled = _effort.IsEnabled = !_sending && current;
        _copyProgress.IsActive = _stagingFiles; _copyProgress.Visibility = _cancelStaging.Visibility = _stagingFiles ? Visibility.Visible : Visibility.Collapsed;
        _workingStyle.IsHitTestVisible = !_sending && current; RefreshWorkingStyle();
        RefreshFastMode();
        var action = Copy(_sending ? "preparing" : NewChatSetup.ShouldSend(_draft.Text, _files.Count) ? "send" : "open_chat");
        _submit.Content = action; AutomationProperties.SetName(_submit, action);
    }
    private async Task LoadAgentsAsync()
    {
        var revision = ++_catalogRevision;
        if (_repository.SelectedItem is not NewChatRepository repository) { _catalogRepository = null; ClearCatalog(); RefreshActions(); return; }
        if (_catalogRepository == repository.Id && _agent.Items.Count > 0) return;
        _catalogRepository = null; ClearCatalog(); RefreshActions();
        _retry.Visibility = Visibility.Collapsed;
        try {
            var result = await _loadAgents(repository);
            if (revision != _catalogRevision || _account != AppServices.AccountGeneration || !IsLoaded || (_repository.SelectedItem as NewChatRepository)?.Id != repository.Id) return;
            var available = (result as JsonArray ?? result["backends"] as JsonArray)?.OfType<JsonObject>()
                .Where(backend => Format.Text(backend, "id") is { Length: > 0 } id && id != "sh" && backend["installed"]?.ToString() != "false").ToArray() ?? [];
            var saved = ChatLaunchChoice.Load();
            foreach (var backend in available) _agent.Items.Add(new ComboBoxItem { Content = Format.Text(backend, "label", Format.Text(backend, "id")), Tag = backend });
            _catalogRepository = repository.Id;
            _restoringDraft = true;
            _agent.SelectedItem = _agent.Items.OfType<ComboBoxItem>().FirstOrDefault(item => Format.Text(item.Tag as JsonNode, "id") == _preferredSetup?.Backend)
                ?? _agent.Items.OfType<ComboBoxItem>().FirstOrDefault(item => Format.Text(item.Tag as JsonNode, "id") == saved?.Backend)
                ?? _agent.Items.OfType<ComboBoxItem>().FirstOrDefault(item => Format.Text(item.Tag as JsonNode, "id") == "codex") ?? _agent.Items.FirstOrDefault();
            if (_agent.Items.Count == 0) { _notice.Text = Copy("setup_changed"); _retry.Visibility = Visibility.Visible; }
            FillModels(); _restoringDraft = false; NormalizeFastMode(); RememberDraft(); RefreshActions();
        } catch (Exception error) { _restoringDraft = false; if (revision == _catalogRevision && _account == AppServices.AccountGeneration) { _notice.Text = error.Message; _retry.Visibility = Visibility.Visible; } }
    }
    private void FillModels()
    {
        var restoring = _restoringDraft; _restoringDraft = true;
        try {
            _model.Items.Clear();
            if ((_agent.SelectedItem as ComboBoxItem)?.Tag is not JsonObject backend) return;
            _model.Items.Add(new ComboBoxItem { Content = L10n.Text("windows.chatpage.default.21b111cb"), Tag = "" });
            foreach (var name in (backend["models"] as JsonArray ?? []).Select(value => value?.ToString()).OfType<string>())
                _model.Items.Add(new ComboBoxItem { Content = name, Tag = name });
            _effort.Items.Clear();
            _effort.Items.Add(new ComboBoxItem { Content = L10n.Text("windows.chatpage.default.21b111cb"), Tag = "" });
            foreach (var name in (backend["efforts"] as JsonArray ?? []).Select(value => value?.ToString()).OfType<string>()) _effort.Items.Add(new ComboBoxItem { Content = name, Tag = name });
            _effort.Visibility = _effort.Items.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
            var saved = ChatLaunchChoice.Load();
            var preferredEffort = _preferredSetup?.Backend == Format.Text(backend, "id") ? _preferredSetup.Effort : saved?.Backend == Format.Text(backend, "id") ? saved.Effort : null;
            _effort.SelectedItem = _effort.Items.OfType<ComboBoxItem>().FirstOrDefault(item => item.Tag as string == preferredEffort) ?? _effort.Items[0];
            var preferredModel = _preferredSetup?.Backend == Format.Text(backend, "id") ? _preferredSetup.Model ?? "" : saved?.Backend == Format.Text(backend, "id") ? saved.Model : "";
            _model.SelectedItem = _model.Items.OfType<ComboBoxItem>().FirstOrDefault(item => item.Tag as string == preferredModel) ?? _model.Items[0];
        } finally { _restoringDraft = restoring; }
        NormalizeFastMode(); RefreshFastMode();
    }
    private void ClearCatalog()
    {
        var restoring = _restoringDraft; _restoringDraft = true;
        try { _agent.Items.Clear(); _model.Items.Clear(); _effort.Items.Clear(); }
        finally { _restoringDraft = restoring; }
    }
    private NewChatSetup? CurrentSetup()
    {
        if ((_agent.SelectedItem as ComboBoxItem)?.Tag is not JsonNode backend)
            return (_preferredSetup ?? new NewChatSetup("", null, null)) with { Mode = _mode, Autonomy = _autonomy, FastMode = _fastMode };
        string? Choice(ComboBox box) => (box.SelectedItem as ComboBoxItem)?.Tag is string value && value.Length > 0 ? value : null;
        return new NewChatSetup(Format.Text(backend, "id"), Choice(_model), Choice(_effort), _mode,
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
        _mode = restored.Setup?.Mode ?? "execute"; _autonomy = restored.Setup?.Autonomy ?? ChatLaunchChoice.Load()?.Autonomy ?? "bypass";
        _fastMode = restored.Setup?.FastMode ?? false;
        _restoringDraft = false; RenderFiles();
    }
    private void RefreshWorkingStyle()
    {
        _workingStyle.Children.Clear();
        _workingStyle.Children.Add(Chrome.Segmented([("plan", L10n.Text("windows.chatpage.plan.fa8ed0bd")), ("execute", L10n.Text("windows.chatpage.execute.e3a67d95"))], _mode,
            value => { _mode = value; RememberDraft(); RefreshWorkingStyle(); return Task.CompletedTask; }, enabled: !_sending && _account == AppServices.AccountGeneration));
        var bypassOnly = Format.Text((_agent.SelectedItem as ComboBoxItem)?.Tag as JsonNode, "gateTier") == "bypassOnly";
        var choices = bypassOnly ? new[] { ("bypass", L10n.Text("windows.chatpage.don_t_ask.15dae980")) }
            : new[] { ("standard", L10n.Text("windows.chatpage.ask_first.4a9e8cf3")), ("bypass", L10n.Text("windows.chatpage.don_t_ask.15dae980")) };
        _workingStyle.Children.Add(Chrome.Segmented(choices, bypassOnly ? "bypass" : _autonomy,
            value => { _autonomy = value; RememberDraft(); RefreshWorkingStyle(); return Task.CompletedTask; }, enabled: !_sending && _account == AppServices.AccountGeneration));
    }
    private void NormalizeFastMode()
    {
        if ((_agent.SelectedItem as ComboBoxItem)?.Tag is not JsonNode backend) return;
        var model = (_model.SelectedItem as ComboBoxItem)?.Tag as string;
        if (!ChatFastMode.Available(model, backend["fastModeModels"] as JsonArray, Format.Text(backend, "id"))) _fastMode = false;
    }
    private void RefreshFastMode()
    {
        if (_fast is null) return;
        var backend = (_agent.SelectedItem as ComboBoxItem)?.Tag as JsonNode;
        var models = backend?["fastModeModels"] as JsonArray;
        var id = Format.Text(backend, "id");
        var available = ChatFastMode.Available((_model.SelectedItem as ComboBoxItem)?.Tag as string, models, id);
        var title = _fastMode ? id == "grok" ? L10n.Text("common.chat.fast_mode_fast") : L10n.Text("common.chat.fast_mode_priority") : L10n.Text("common.chat.fast_mode_default");
        _fast.Visibility = models is null ? Visibility.Collapsed : Visibility.Visible;
        _fast.IsEnabled = available && !_sending && _account == AppServices.AccountGeneration;
        _fast.Background = _fastMode ? Theme.AccentSoftBrush : Theme.PanelBrush;
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
        catch (Exception error) { if (OwnsFiles(repository, generation, lifetime)) _notice.Text = error.Message; }
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
                if (_files.Count >= NewChatFile.MaximumCount) { _notice.Text = L10n.Text("common.chat_files_busy"); break; }
                var selected = await NewChatFile.CaptureAsync(path, cancellation.Token);
                selected = selected.RetainIfOwned(OwnsFiles(repository, generation, lifetime));
                if (selected is null) return;
                _files.Add(selected); RenderFiles(); RememberDraft();
            }
        } catch (OperationCanceledException) { }
        catch (Exception error) { if (OwnsFiles(repository, generation, lifetime)) _notice.Text = error.Message; }
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
    }
    private async Task AddAsync()
    {
        if (_addingRepository || _sending || !IsLoaded || _account != AppServices.AccountGeneration) return;
        var repository = _draftRepository; var generation = _draftGeneration; var lifetime = _lifetime;
        _addingRepository = true; RefreshActions();
        try { var added = await _add(); if (OwnsDraft(repository, generation, lifetime)) RefreshRepositories(added); }
        catch (Exception error) { if (OwnsDraft(repository, generation, lifetime)) _notice.Text = error.Message; }
        finally { _addingRepository = false; RefreshActions(); }
    }
    private async Task SubmitAsync()
    {
        if (_sending || _pickingFiles || _stagingFiles || _addingRepository || !IsLoaded || _account != AppServices.AccountGeneration || _repository.SelectedItem is not NewChatRepository repository || _catalogRepository != repository.Id
            || (_agent.SelectedItem as ComboBoxItem)?.Tag is not JsonObject backend) return;
        if (!_repositories().Any(candidate => candidate.Id == repository.Id)) { RefreshRepositories(); return; }
        var text = _draft.Text; var ticket = ++_request; _sending = true; _notice.Text = ""; RefreshActions();
        var setup = CurrentSetup()!; var files = _files.ToArray(); RememberDraft();
        var revision = _draftGeneration;
        bool Owns() => _account == AppServices.AccountGeneration && _request == ticket && _draftGeneration == revision
            && (_draftRepository == repository.Id || _draftRepository is null)
            && (_repository.SelectedItem as NewChatRepository)?.Id == repository.Id
            && _draft.Text == text && _files.SequenceEqual(files) && CurrentSetup() == setup;
        _handoff = true;
        try { await _send(repository, text, setup, files, Owns, () => {
            if (Owns() && _draft.Text == text && _files.SequenceEqual(files)) {
                _draft.Text = ""; _files.Clear(); RenderFiles(); RememberDraft();
            }
        }); }
        catch (Exception error) { if (Owns()) _notice.Text = error.Message; }
        finally { _handoff = false; _sending = false; RefreshActions(); if (IsLoaded) RefreshRepositories(); }
    }
}
