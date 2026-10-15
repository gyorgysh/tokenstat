// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Text;
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
    private readonly Func<NewChatRepository, string, NewChatSetup, Func<bool>, Action, Task> _send;
    private readonly ComboBox _repository = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBox _draft = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 160, MaxHeight = 360 };
    private readonly TextBlock _notice = new() { TextWrapping = TextWrapping.Wrap, Opacity = .7 };
    private readonly ComboBox _agent = new() { Header = L10n.Text("windows.chatpage.agent.11b39c93"), HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox _model = new() { Header = L10n.Text("windows.chatpage.model.5e2c614c"), HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly Button _submit;
    private readonly Button _addButton;
    private readonly Button _retry;
    private readonly Storyboard _ambient = new();
    private bool _sending;
    private long _request;
    private long _catalogRevision;
    private bool _handoff;
    private bool _refreshingRepositories;
    private string? _catalogRepository;
    private string? _requestedRepository;
    private NewChatSetup? _preferredSetup;
    private static string Copy(string key) { var resource = "common.new_chat." + key; return L10n.Text(resource); }

    internal NewChatPage(Func<IReadOnlyList<NewChatRepository>> repositories, Func<Task<string?>> add,
        Func<NewChatRepository, Task<JsonNode>> loadAgents, Func<NewChatRepository, string, NewChatSetup, Func<bool>, Action, Task> send)
    {
        _repositories = repositories; _add = add; _loadAgents = loadAgents; _send = send;
        var root = new Grid();
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
        var setup = new Grid { ColumnSpacing = 8 };
        setup.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); setup.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        setup.Children.Add(_agent); Grid.SetColumn(_model, 1); setup.Children.Add(_model); content.Children.Add(setup);
        _draft.PlaceholderText = Copy("prompt"); AutomationProperties.SetName(_draft, Copy("prompt")); AutomationProperties.SetAutomationId(_draft, "newChat.composer");
        content.Children.Add(_draft);
        _submit = ActionIconGlyph.PrimaryButton(Copy("send"), ActionIcon.Send, async (_, _) => await SubmitAsync());
        _submit.HorizontalAlignment = HorizontalAlignment.Right; AutomationProperties.SetAutomationId(_submit, "newChat.send");
        content.Children.Add(_submit); content.Children.Add(_notice);
        _retry = ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => { _catalogRepository = null; await LoadAgentsAsync(); });
        _retry.Visibility = Visibility.Collapsed; content.Children.Add(_retry);
        root.Children.Add(new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Center });
        Content = root;
        _draft.TextChanged += (_, _) => RefreshActions();
        _repository.SelectionChanged += async (_, _) => { if (_refreshingRepositories) return; _requestedRepository = null; RefreshActions(); await LoadAgentsAsync(); };
        _agent.SelectionChanged += (_, _) => { FillModels(); RefreshActions(); };
        Loaded += (_, _) => {
            RemoteWorkspaces.Changed -= RepositoriesChanged; RemoteWorkspaces.Changed += RepositoriesChanged;
            RefreshRepositories();
            if (Motion.AnimationsEnabled()) {
                var breath = new DoubleAnimation { From = .08, To = .16, Duration = new Duration(TimeSpan.FromSeconds(7)), AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever };
                Storyboard.SetTarget(breath, halo); Storyboard.SetTargetProperty(breath, "Opacity"); _ambient.Children.Clear(); _ambient.Children.Add(breath); _ambient.Begin();
            } else halo.Opacity = .1;
        };
        Unloaded += (_, _) => { RemoteWorkspaces.Changed -= RepositoriesChanged; _ambient.Stop(); _catalogRevision++; if (!_handoff) _request++; };
    }
    private void RepositoriesChanged() => DispatcherQueue.TryEnqueue(() => { if (IsLoaded && _account == AppServices.AccountGeneration) RefreshRepositories(); });
    internal void RefreshRepositories(string? select = null)
    {
        if (select is not null) _requestedRepository = select;
        var prior = _requestedRepository ?? (_repository.SelectedItem as NewChatRepository)?.Id;
        var repositories = _repositories(); _refreshingRepositories = true; _repository.ItemsSource = repositories;
        _repository.SelectedItem = repositories.FirstOrDefault(repository => repository.Id == prior);
        if (_repository.SelectedItem is NewChatRepository) _requestedRepository = null;
        _refreshingRepositories = false;
        _notice.Text = repositories.Count == 0 ? Copy("empty") : "";
        RefreshActions();
        _ = LoadAgentsAsync();
    }
    private void RefreshActions()
    {
        _submit.IsEnabled = !_sending && _account == AppServices.AccountGeneration && _repository.SelectedItem is NewChatRepository repository
            && _catalogRepository == repository.Id && _agent.SelectedItem is ComboBoxItem;
        _repository.IsEnabled = _draft.IsEnabled = _addButton.IsEnabled = !_sending;
        _agent.IsEnabled = _model.IsEnabled = !_sending;
        _submit.Content = Copy(_sending ? "preparing" : NewChatSetup.ShouldSend(_draft.Text) ? "send" : "open_chat");
    }
    private async Task LoadAgentsAsync()
    {
        var revision = ++_catalogRevision;
        if (_repository.SelectedItem is not NewChatRepository repository) { _catalogRepository = null; _agent.Items.Clear(); _model.Items.Clear(); RefreshActions(); return; }
        if (_catalogRepository == repository.Id && _agent.Items.Count > 0) return;
        if ((_agent.SelectedItem as ComboBoxItem)?.Tag is JsonNode prior) {
            var priorModel = (_model.SelectedItem as ComboBoxItem)?.Tag as string;
            _preferredSetup = new NewChatSetup(Format.Text(prior, "id"), string.IsNullOrEmpty(priorModel) ? null : priorModel, null);
        }
        _catalogRepository = null; _agent.Items.Clear(); _model.Items.Clear(); RefreshActions();
        _retry.Visibility = Visibility.Collapsed;
        try {
            var result = await _loadAgents(repository);
            if (revision != _catalogRevision || _account != AppServices.AccountGeneration || !IsLoaded || (_repository.SelectedItem as NewChatRepository)?.Id != repository.Id) return;
            var available = (result as JsonArray ?? result["backends"] as JsonArray)?.OfType<JsonObject>()
                .Where(backend => Format.Text(backend, "id") != "sh" && backend["installed"]?.ToString() != "false").ToArray() ?? [];
            var saved = ChatLaunchChoice.Load();
            foreach (var backend in available) _agent.Items.Add(new ComboBoxItem { Content = Format.Text(backend, "label", Format.Text(backend, "id")), Tag = backend });
            _catalogRepository = repository.Id;
            _agent.SelectedItem = _agent.Items.OfType<ComboBoxItem>().FirstOrDefault(item => Format.Text(item.Tag as JsonNode, "id") == _preferredSetup?.Backend)
                ?? _agent.Items.OfType<ComboBoxItem>().FirstOrDefault(item => Format.Text(item.Tag as JsonNode, "id") == saved?.Backend)
                ?? _agent.Items.OfType<ComboBoxItem>().FirstOrDefault(item => Format.Text(item.Tag as JsonNode, "id") == "codex") ?? _agent.Items.FirstOrDefault();
            if (_agent.Items.Count == 0) { _notice.Text = Copy("setup_changed"); _retry.Visibility = Visibility.Visible; }
            FillModels(); RefreshActions();
        } catch (Exception error) { if (revision == _catalogRevision && _account == AppServices.AccountGeneration) { _notice.Text = error.Message; _retry.Visibility = Visibility.Visible; } }
    }
    private void FillModels()
    {
        _model.Items.Clear();
        if ((_agent.SelectedItem as ComboBoxItem)?.Tag is not JsonObject backend) return;
        _model.Items.Add(new ComboBoxItem { Content = L10n.Text("windows.chatpage.default.21b111cb"), Tag = "" });
        foreach (var name in (backend["models"] as JsonArray ?? []).Select(value => value?.ToString()).OfType<string>())
            _model.Items.Add(new ComboBoxItem { Content = name, Tag = name });
        var saved = ChatLaunchChoice.Load();
        var preferredModel = _preferredSetup?.Backend == Format.Text(backend, "id") ? _preferredSetup.Model ?? "" : saved?.Backend == Format.Text(backend, "id") ? saved.Model : "";
        _model.SelectedItem = _model.Items.OfType<ComboBoxItem>().FirstOrDefault(item => item.Tag as string == preferredModel) ?? _model.Items[0];
    }
    private async Task AddAsync()
    {
        var added = await _add();
        if (_account == AppServices.AccountGeneration && IsLoaded) RefreshRepositories(added);
    }
    private async Task SubmitAsync()
    {
        if (_sending || !IsLoaded || _account != AppServices.AccountGeneration || _repository.SelectedItem is not NewChatRepository repository || _catalogRepository != repository.Id
            || (_agent.SelectedItem as ComboBoxItem)?.Tag is not JsonObject backend) return;
        if (!_repositories().Any(candidate => candidate.Id == repository.Id)) { RefreshRepositories(); return; }
        var text = _draft.Text; var ticket = ++_request; _sending = true; _notice.Text = ""; RefreshActions();
        bool Owns() => _account == AppServices.AccountGeneration && _request == ticket;
        var saved = ChatLaunchChoice.Load(); var backendId = Format.Text(backend, "id");
        var model = (_model.SelectedItem as ComboBoxItem)?.Tag as string;
        var effort = saved?.Backend == backendId && (backend["efforts"] as JsonArray)?.Any(value => value?.ToString() == saved.Effort) == true ? saved.Effort : null;
        var setup = new NewChatSetup(backendId, string.IsNullOrEmpty(model) ? null : model, effort);
        _handoff = true;
        try { await _send(repository, text, setup, Owns, () => { if (Owns() && _draft.Text == text) _draft.Text = ""; }); }
        catch (Exception error) { if (Owns()) _notice.Text = error.Message; }
        finally { _handoff = false; _sending = false; RefreshActions(); }
    }
}
