// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed partial class WorkspaceTabsPage
{
    private readonly Grid _inspectorTabs = new() { Margin = new Thickness(8) };
    private readonly Grid _companionHeader = new() { ColumnSpacing = 4 };
    private readonly WorkspaceTabStrip _companionStrip = new();
    private readonly DesktopWorkbenchState _workbench = new();
    private readonly Dictionary<DesktopWorkbenchTool, TabViewItem> _toolTabs = new();
    private bool _refreshingTools;
    private TabViewMount? _toolMount;
    private BrowserPage? _companionBrowser;
    private WorkspaceTerminalPane? _companionTerminal;
    private Page? _companionChanges;
    private UIElement? _companionReview;
    private WorkspaceLiveReviewPage? _liveReview;
    private bool _showsLiveReview;
    private string? _lastChangesStatus;

    internal void ResetReviewScope()
    {
        _companionReview = null;
        _companionChanges = null;
        _liveReview = null;
        _showsLiveReview = false;
        _lastChangesStatus = null;
        _inspectorPages.Clear();
        if (IsLoaded) RefreshChrome();
    }

    private void RefreshLiveChanges(string status, bool force)
    {
        var changed = status != _lastChangesStatus;
        if ((!changed && !force) || _companionReview is not null
            || _workbench.Selected != DesktopWorkbenchTool.Changes) return;
        for (DependencyObject? node = _inspector; node is not null; node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node))
            if (node is UIElement { Visibility: Visibility.Collapsed }) return;
        if (_showsLiveReview) _liveReview?.Refresh();
        else (_companionChanges as WorkspacePage)?.RefreshChanges();
        _lastChangesStatus = status;
    }
    private BrowserPage CompanionBrowser => _companionBrowser ??= new BrowserPage("", "127.0.0.1", 0, false,
        RemoteWorkspaces.TrySplit(WorkspaceId, out var peer, out _) ? peer : null, workspaceId: WorkspaceId);
    private WorkspaceTerminalPane CompanionTerminal => _companionTerminal ??= new WorkspaceTerminalPane(_terminalController);
    public event Action? DetailsRequested;
    public event Action? DetailsDismissRequested;

    private static string ToolTitle(DesktopWorkbenchTool tool) => tool switch
    {
        DesktopWorkbenchTool.Changes => L10n.Text("windows.workspacetabspage.changes.bbd4b6a8"),
        DesktopWorkbenchTool.Browser => L10n.Text("common.browser"),
        DesktopWorkbenchTool.Terminal => L10n.Text("windows.workspacetabspage_companion.terminal.e0926fda"),
        _ => L10n.Text("windows.workbench.inspector"),
    };
    private static ActionIcon ToolIcon(DesktopWorkbenchTool tool) => tool switch
    {
        DesktopWorkbenchTool.Changes => ActionIcon.Compare,
        DesktopWorkbenchTool.Browser => ActionIcon.Browser,
        DesktopWorkbenchTool.Terminal => ActionIcon.Source,
        _ => ActionIcon.Sidebar,
    };
    private void InitializeCompanion()
    {
        _workbench.Open(DesktopWorkbenchTool.Inspector);
        _companionHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _companionHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tabs = _companionStrip.View;
        _toolMount = new TabViewMount(tabs);
        _toolMount.Ready += () => { if (ActivePage is ChatPage) RefreshChrome(); };
        tabs.Height = 44;
        tabs.IsAddTabButtonVisible = true;
        tabs.AddTabButtonClick += (_, _) =>
        {
            var menu = new MenuFlyout();
            foreach (var tool in Enum.GetValues<DesktopWorkbenchTool>())
            {
                var item = new MenuFlyoutItem { Text = ToolTitle(tool), Icon = ToolIcon(tool).Icon() };
                item.Click += (_, _) => ShowCompanion(tool);
                menu.Items.Add(item);
            }
            menu.ShowAt(tabs);
        };
        tabs.SelectionChanged += (_, _) =>
        {
            if (_refreshingTools || (tabs.SelectedItem as TabViewItem)?.Tag is not DesktopWorkbenchTool tool) return;
            _workbench.Open(tool);
            RefreshChrome();
        };
        tabs.TabCloseRequested += (_, e) =>
        {
            if (e.Item is not TabViewItem { Tag: DesktopWorkbenchTool tool }) return;
            CloseCompanion(tool);
        };
        _companionStrip.CloseRequested = item =>
        {
            if (item.Tag is not DesktopWorkbenchTool tool) return;
            CloseCompanion(tool);
        };
        _companionHeader.Children.Add(tabs);
        var close = Buttons.ToolbarIcon(ActionIcon.Sidebar,
            L10n.Text("windows.workspacetabspage_companion.close_companion_pane.319641bf"), (_, _) =>
            {
                _workbench.Hide();
                DetailsDismissRequested?.Invoke();
            });
        Grid.SetColumn(close, 1); _companionHeader.Children.Add(close);
        _inspector.Children.Add(_companionHeader);
    }
    private void ShowCompanion(DesktopWorkbenchTool tool)
    {
        _workbench.Open(tool);
        RefreshChrome();
        DetailsRequested?.Invoke();
    }

    private void CloseCompanion(DesktopWorkbenchTool tool)
    {
        _workbench.Close(tool);
        if (tool == DesktopWorkbenchTool.Browser)
        {
            _companionBrowser?.Release();
            _companionBrowser = null;
        }
        if (tool == DesktopWorkbenchTool.Changes)
        {
            _companionReview = null;
            _showsLiveReview = false;
            _liveReview = null;
        }
        RefreshChrome();
        if (_workbench.Tabs.Count == 0) DetailsDismissRequested?.Invoke();
    }
    private void RefreshCompanion()
    {
        _refreshingTools = true;
        try
        {
            if (_toolMount?.IsReady == true)
            {
                foreach (var tool in _toolTabs.Keys.Except(_workbench.Tabs).ToArray())
                {
                    _companionStrip.Forget(_toolTabs[tool]);
                    _toolTabs.Remove(tool);
                }
                foreach (var tool in _workbench.Tabs)
                {
                    if (_toolTabs.ContainsKey(tool)) continue;
                    var tab = _companionStrip.Open(tool.ToString(), ToolTitle(tool), () => new Grid());
                    tab.Tag = tool;
                    _toolTabs.Add(tool, tab);
                }
                _companionStrip.View.SelectedItem = _workbench.Selected is { } selected ? _toolTabs.GetValueOrDefault(selected) : null;
            }
        }
        finally { _refreshingTools = false; }
        var inspector = _workbench.Selected == DesktopWorkbenchTool.Inspector;
        _inspectorTabs.Visibility = inspector ? Visibility.Visible : Visibility.Collapsed;
        if (inspector) SetInspectorDetails();
        else _details.Content = _workbench.Selected switch
        {
            DesktopWorkbenchTool.Browser => CompanionBrowser,
            DesktopWorkbenchTool.Terminal => CompanionTerminal,
            DesktopWorkbenchTool.Changes => _companionReview ?? (_showsLiveReview
                ? _liveReview : (_companionChanges ??= _create(WorkspaceSection.Changes))),
            _ => null,
        };
        _editor.FileTree.Visibility = inspector && _inspectorTab == "Files" ? Visibility.Visible : Visibility.Collapsed;
        _details.Visibility = inspector && _inspectorTab == "Files" ? Visibility.Collapsed : Visibility.Visible;
    }
    private IList<UIElement> CompanionActions(IList<UIElement> actions)
    {
        if (ActivePage is not ChatPage) return actions;
        actions.Add(Buttons.ToolbarIcon(ActionIcon.Compare, L10n.Text("windows.workbench.review_beside_chat"),
            (_, _) => ShowChangesInspector(), _workbench.Selected == DesktopWorkbenchTool.Changes));
        actions.Add(Buttons.ToolbarIcon(ActionIcon.Browser, L10n.Text("windows.workspacetabspage_companion.browser_beside_chat.84f3340a"),
            (_, _) => ShowCompanion(DesktopWorkbenchTool.Browser), _workbench.Selected == DesktopWorkbenchTool.Browser));
        var terminal = Buttons.ToolbarIcon(ActionIcon.Source, L10n.Text("windows.workspacetabspage_companion.terminal_beside_chat.40991a3f"),
            (_, _) => ShowCompanion(DesktopWorkbenchTool.Terminal), _workbench.Selected == DesktopWorkbenchTool.Terminal);
        terminal.Content = new FontIcon { Glyph = "\uE756", FontSize = 16 };
        actions.Add(terminal);
        if (_workbench.Selected == DesktopWorkbenchTool.Terminal)
            foreach (var action in _terminalController.ToolbarActions()) actions.Add(action);
        return actions;
    }
    private void ShowTurnReview(IReadOnlyList<ChangedFile> files, string? path)
    {
        var stack = new StackPanel { Spacing = Theme.SpaceM, Padding = new Thickness(Theme.SpaceM) };
        stack.Children.Add(Buttons.Secondary(L10n.Text("windows.workbench.working_tree"), ActionIcon.Compare,
            (_, _) => ShowChangesInspector(), small: true));
        stack.Children.Add(new TextBlock { Text = L10n.Text("windows.workbench.turn_changes"), FontSize = 18 });
        if (ActivePage is ChatPage chat)
            stack.Children.Add(new TextBlock { Text = chat.ReviewTitle, TextWrapping = TextWrapping.Wrap });
        stack.Children.Add(new TextBlock { Text = L10n.Text("windows.workbench.recorded_edits"),
            TextWrapping = TextWrapping.Wrap, Opacity = .7 });
        foreach (var file in files.OrderByDescending(file => file.Path == path))
        {
            var content = new StackPanel { Spacing = Theme.SpaceS };
            content.Children.Add(new TextBlock { Text = file.Path, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap });
            var totals = new TextBlock { FontFamily = Fonts.Mono, FontSize = 12 };
            totals.Inlines.Add(new Run { Text = $"+{file.Added} ", Foreground = Theme.Brush(static () => Theme.DiffAdded) });
            totals.Inlines.Add(new Run { Text = $"−{file.Removed}", Foreground = Theme.Brush(static () => Theme.DiffRemoved) });
            content.Children.Add(totals);
            var patches = file.Patches.Count == 0 ? new[] { "" } : file.Patches;
            var edit = 0;
            foreach (var patch in patches)
            {
                if (patches.Count > 1)
                    content.Children.Add(new TextBlock { Text = L10n.Text("windows.workbench.edit_number", $"{++edit}"), FontSize = 11, Opacity = .7 });
                var block = new TextBlock { FontFamily = Fonts.Mono, FontSize = 12,
                    IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
                if (string.IsNullOrEmpty(patch)) block.Text = L10n.Text("windows.workbench.patch_unavailable");
                else
                {
                    var lines = patch.Split('\n');
                    for (var index = 0; index < lines.Length; index++)
                    {
                        var line = lines[index];
                        var brush = line.StartsWith('+') && !line.StartsWith("+++") ? Theme.Brush(static () => Theme.DiffAdded)
                            : line.StartsWith('-') && !line.StartsWith("---") ? Theme.Brush(static () => Theme.DiffRemoved) : Theme.Brush(static () => Theme.DefaultText);
                        foreach (var chunk in DiffTextChunks.Split(line + (index + 1 < lines.Length ? "\n" : "")))
                            block.Inlines.Add(new Run { Text = chunk, Foreground = brush });
                    }
                }
                content.Children.Add(block);
            }
            stack.Children.Add(Chrome.Card(file.FileName, content));
        }
        _companionReview = new ScrollViewer { Content = stack };
        ShowCompanion(DesktopWorkbenchTool.Changes);
    }

    internal bool ShowWorkingTreeReview(string? path = null)
    {
        if (ActivePage is not ChatPage) return false;
        _companionReview = null;
        _showsLiveReview = true;
        _liveReview ??= new WorkspaceLiveReviewPage(WorkspaceId, () => ShowChangesInspector()) { Tag = this };
        _liveReview.Review(path);
        ShowCompanion(DesktopWorkbenchTool.Changes);
        return true;
    }
}
