// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>One persistent desktop workbench per local or remote workspace.</summary>
internal sealed partial class WorkspaceTabsPage : Page, IInspectorContent, IToolbarItems, IInspectorRequest
{
    private readonly WorkspaceTabStrip _tabStrip = new();
    private TabView _tabs => _tabStrip.View;
    private readonly Func<WorkspaceSection, Page> _create;
    private readonly EditorPage _editor;
    private readonly BrowserPage _browser;
    private readonly Grid _inspector = new();
    private readonly ContentControl _details = new();
    private string _inspectorTab = "Files";
    private readonly Dictionary<string, Button> _inspectorButtons = new();
    private readonly Dictionary<string, Page> _inspectorPages = new();
    private IToolbarItems? _toolbar;
    private readonly WorkspaceTerminalController _terminalController;
    private WorkspaceTerminalPane? _terminalPane;
    private WorkspaceTerminalPane TerminalPane => _terminalPane ??= new WorkspaceTerminalPane(_terminalController);
    public string WorkspaceId { get; }
    public Page? ActivePage => (_tabs.SelectedItem as TabViewItem)?.Content as Page;

    public WorkspaceTabsPage(string workspaceId, Func<WorkspaceSection, Page> create)
    {
        WorkspaceId = workspaceId;
        _terminalController = new(workspaceId);
        _terminalController.Changed += Changed;
        _create = section => { var page = create(section); page.Tag = this; return page; };
        _editor = new EditorPage(workspaceId, _tabs);
        _browser = new BrowserPage("", "127.0.0.1", 0, false,
            RemoteWorkspaces.TrySplit(workspaceId, out var peer, out _) ? peer : null, _tabs, workspaceId);
        _inspector.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _inspector.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var inspectorTabs = _inspectorTabs;
        foreach (var (label, title) in new[] {
            ("Files", L10n.Text("common.files")),
            ("Changes", L10n.Text("windows.workspacetabspage.changes.bbd4b6a8")),
            ("History", L10n.Text("common.history")),
            ("Details", L10n.Text("windows.workspacetabspage.details.45989de4")),
        })
        {
            inspectorTabs.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var button = new Button
            {
                Content = title, Padding = new Thickness(3, 6, 3, 6), FontSize = 11,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Center,
                BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(6),
            };
            button.Click += (_, _) => { _inspectorTab = label; RefreshChrome(); };
            Grid.SetColumn(button, _inspectorButtons.Count);
            _inspectorButtons.Add(label, button);
            inspectorTabs.Children.Add(button);
        }
        InitializeCompanion();
        _details.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _details.VerticalContentAlignment = VerticalAlignment.Stretch;
        _inspector.Children.Add(inspectorTabs);
        Grid.SetRow(_editor.FileTree, 1);
        Grid.SetRow(_details, 1);
        _inspector.Children.Add(_editor.FileTree);
        _inspector.Children.Add(_details);
        Loaded += async (_, _) => await _editor.InitializeAsync();
        _tabs.SelectionChanged += (_, _) => RefreshChrome();
        _tabStrip.CloseRequested = item =>
        {
            if (!item.IsClosable) return;
            if (item.Content is TerminalPage terminal) terminal.Release();
            _tabStrip.Forget(item);
        };
        _tabs.TabCloseRequested += (_, e) =>
        {
            if (e.Item is not TabViewItem item || _editor.Owns(item) || _browser.Owns(item)) return;
            if (item.Content is TerminalPage terminal) terminal.Release();
            _tabStrip.Forget(item);
        };
        Content = _tabs;
        Open(WorkspaceSection.Launcher);
    }

    public void Open(WorkspaceSection section)
    {
        if (section == WorkspaceSection.Browser)
        {
            if (_browser.ShowLastTab()) return;
            _browser.AddTab("", "127.0.0.1", 0, false,
                RemoteWorkspaces.TrySplit(WorkspaceId, out var peer, out _) ? peer : null);
            return;
        }
        if (section == WorkspaceSection.Files) _inspectorTab = "Files";
        if (section == WorkspaceSection.Sessions) section = WorkspaceSection.Launcher;
        OpenSurface("section:" + section, section.Label(),
            () => section == WorkspaceSection.Files ? _editor : Created(section),
            section != WorkspaceSection.Launcher);
    }

    /// <summary>A section's page, with a chat's Review wired to the Changes inspector.</summary>
    private Page Created(WorkspaceSection section)
    {
        var page = _create(section);
        if (page is ChatPage chat) chat.ReviewChangesRequested += ShowChangesInspector;
        return page;
    }

    /// <summary>
    /// Open Changes beside the chat, where a turn's files can be read,
    /// committed, pushed and pulled. A companion pane steps aside for it.
    /// </summary>
    public void ShowChangesInspector(string? path = null)
    {
        _companion = null;
        _inspectorTab = "Changes";
        RefreshChrome();
        DetailsRequested?.Invoke();
        if (_inspectorPages.GetValueOrDefault("Changes") is WorkspacePage changes)
            changes.RevealChangedFile(path);
    }

    public void OpenTerminal(string? sessionId)
    {
        OpenSurface("section:Terminals", L10n.Text("windows.terminalpane.terminals"), () => TerminalPane);
        if (sessionId?.StartsWith("ssh:", StringComparison.Ordinal) == true) _ = _terminalController.OpenSSHAsync(sessionId[4..]);
        else if (sessionId is not null) _terminalController.AddLocal(sessionId);
        else _ = _terminalController.StartShellAsync();
    }

    internal async Task OpenServerAsync(System.Text.Json.Nodes.JsonNode host)
    {
        if (ActivePage is ChatPage) ShowCompanion("Terminal");
        else OpenSurface("section:Terminals", L10n.Text("windows.terminalpane.terminals"), () => TerminalPane);
        await _terminalController.OpenServerAsync(host);
    }

    internal void OpenTerminalInSplit(string sessionId)
    {
        OpenSurface("section:Terminals", L10n.Text("windows.terminalpane.terminals"), () => TerminalPane);
        if (sessionId.StartsWith("ssh:", StringComparison.Ordinal)) _ = _terminalController.OpenSSHAsync(sessionId[4..], inSplit: true);
        else { _terminalController.AddLocal(sessionId, select: false); _terminalController.OpenInSplit(sessionId); }
    }

    public void OpenBrowser(string url, string host, int port, bool unlisten, string? peer)
    {
        if (ActivePage is ChatPage)
        {
            CompanionBrowser.AddTab(url, host, port, unlisten, peer);
            ShowCompanion("Browser");
        }
        else _browser.AddTab(url, host, port, unlisten, peer);
    }

    public void OpenReview(string title, UIElement content)
    {
        var tab = _tabStrip.Open("review:" + title, title, () => content);
        tab.Content = content;
        tab.IconSource = new FontIconSource { Glyph = "\uE8A5" };
        RefreshChrome();
    }

    internal static WorkspaceTabsPage? Find(UIElement owner)
    {
        for (DependencyObject? node = owner; node is not null; node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node))
        {
            if (node is WorkspaceTabsPage workbench) return workbench;
            if (node is FrameworkElement { Tag: WorkspaceTabsPage tagged }) return tagged;
        }
        return null;
    }

    private void OpenSurface(string key, string label, Func<Page> create, bool closable = true)
    {
        var tab = _tabStrip.Open(key, label, () => create(), closable);
        if (tab.IconSource is null && !key.StartsWith("terminal:"))
        {
            if (key == "section:Launcher") tab.IconSource = new SymbolIconSource { Symbol = Symbol.AllApps };
            else if (key.StartsWith("section:") && Enum.TryParse<WorkspaceSection>(key[8..], out var section))
            {
                tab.IconSource = section.Action().Icon() switch
                {
                    FontIcon font => new FontIconSource { Glyph = font.Glyph, FontFamily = font.FontFamily },
                    SymbolIcon symbol => new SymbolIconSource { Symbol = symbol.Symbol },
                    _ => null,
                };
            }
        }
        RefreshChrome();
    }

    private object? ActiveSource => _tabs.SelectedItem is TabViewItem item
        ? _editor.Owns(item) ? _editor : _browser.Owns(item) ? _browser : ActivePage : null;
    public UIElement? Inspector => _inspector;
    public double MinimumContentWidth => (ActiveSource as IInspectorContent)?.MinimumContentWidth ?? ShellWidths.ContentMinimum;
    public UIElement? ToolbarScope => (ActiveSource as IToolbarItems)?.ToolbarScope;
    public double MinimumInspectorWidth => _companion is not null && ActivePage is ChatPage ? 320 : ShellWidths.Minimum;
    public IList<UIElement> ToolbarActions()
    {
        // A copy: the switch is inserted at the front, and a page is free to
        // hand back a fixed array or a list it keeps.
        var actions = new List<UIElement>(CompanionActions((ActiveSource as IToolbarItems)?.ToolbarActions() ?? new List<UIElement>()));
        // The bypass switch sits in the bar, where the Mac has it, on the
        // tabs that start agents. Chats have their own Don't ask.
        if (ActivePage is WorkspacePage { Section: WorkspaceSection.Launcher or WorkspaceSection.Sessions }
            or WorkspaceTerminalPane or TerminalPage)
        {
            actions.Insert(0, WorkspaceBypass.Control(WorkspaceId, Changed));
        }
        return actions;
    }
    public event Action? ToolbarChanged;
    private void Changed()
    {
        if (_tabs.SelectedItem is TabViewItem tab && tab.Content is TerminalPage terminal)
        {
            if (tab.Header is not StackPanel { Tag: string title } || title != terminal.TabTitle)
            {
                var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Tag = terminal.TabTitle };
                header.Children.Add(AgentMark.View(terminal.TabTitle, 22));
                header.Children.Add(new TextBlock { Text = terminal.TabTitle, MaxWidth = 150,
                    TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center });
                tab.IconSource = null;
                tab.Header = header;
            }
        }
        ToolbarChanged?.Invoke();
    }
    private void RefreshChrome()
    {
        var hasCompanion = _companion is not null && ActivePage is ChatPage;
        // One tree keeps expansion, selection and its loaded directory cache
        // while moving between the Files page and the workspace inspector.
        var filesPage = ReferenceEquals(ActivePage, _editor);
        if (filesPage && !ReferenceEquals(_editor.Content, _editor.FileTree))
        {
            _inspector.Children.Remove(_editor.FileTree);
            _editor.Content = _editor.FileTree;
        }
        else if (!filesPage && ReferenceEquals(_editor.Content, _editor.FileTree))
        {
            _editor.Content = null;
            _inspector.Children.Add(_editor.FileTree);
        }
        if (_toolbar is not null) _toolbar.ToolbarChanged -= Changed;
        _toolbar = ActiveSource as IToolbarItems;
        if (_toolbar is not null) _toolbar.ToolbarChanged += Changed;
        if (_details.Content is ScrollViewer previous) previous.Content = null;
        _inspectorTabs.Visibility = hasCompanion ? Visibility.Collapsed : Visibility.Visible;
        _companionHeader.Visibility = hasCompanion ? Visibility.Visible : Visibility.Collapsed;
        if (hasCompanion) _details.Content = _companion == "Browser" ? CompanionBrowser : CompanionTerminal;
        else if (_inspectorTab is "Changes" or "History")
        {
            if (!_inspectorPages.TryGetValue(_inspectorTab, out var page))
            {
                page = _create(_inspectorTab == "Changes" ? WorkspaceSection.Changes : WorkspaceSection.History);
                _inspectorPages.Add(_inspectorTab, page);
            }
            _details.Content = page;
        }
        else
        {
            _details.Content = _inspectorTab == "Details" || (filesPage && _inspectorTab == "Files")
                ? new ScrollViewer { Content = (ActiveSource as IInspectorContent)?.Inspector } : null;
        }
        _details.Visibility = !hasCompanion && _inspectorTab == "Files" && !filesPage ? Visibility.Collapsed : Visibility.Visible;
        _editor.FileTree.Visibility = filesPage || !hasCompanion && _inspectorTab == "Files" ? Visibility.Visible : Visibility.Collapsed;
        foreach (var (label, button) in _inspectorButtons)
        {
            button.Background = label == _inspectorTab ? Theme.Brush(static () => Theme.RowSelected) : Theme.PanelBrush;
        }
        Changed();
    }
}
