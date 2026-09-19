// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>One persistent desktop workbench per local or remote workspace.</summary>
internal sealed class WorkspaceTabsPage : Page, IInspectorContent, IToolbarItems
{
    private readonly WorkspaceTabStrip _tabs = new();
    private readonly Func<WorkspaceSection, Page> _create;
    private readonly EditorPage _editor;
    private readonly BrowserPage _browser;
    private readonly Grid _inspector = new();
    private readonly ContentControl _details = new();
    private bool _showDetails;
    private IToolbarItems? _toolbar;
    public string WorkspaceId { get; }
    public Page? ActivePage => (_tabs.SelectedItem as TabViewItem)?.Content as Page;

    public WorkspaceTabsPage(string workspaceId, Func<WorkspaceSection, Page> create)
    {
        WorkspaceId = workspaceId;
        _create = create;
        _editor = new EditorPage(workspaceId, _tabs);
        _browser = new BrowserPage("", "127.0.0.1", 0, false,
            RemoteWorkspaces.TrySplit(workspaceId, out var peer, out _) ? peer : null, _tabs);
        _inspector.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _inspector.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var inspectorTabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(8) };
        foreach (var label in new[] { "Files", "Details" })
        {
            var button = Buttons.Secondary(label, label == "Files" ? ActionIcon.Source : ActionIcon.Preview,
                (_, _) => { _showDetails = label == "Details"; RefreshChrome(); }, small: true);
            inspectorTabs.Children.Add(button);
        }
        _inspector.Children.Add(inspectorTabs);
        Grid.SetRow(_editor.FileTree, 1);
        Grid.SetRow(_details, 1);
        _inspector.Children.Add(_editor.FileTree);
        _inspector.Children.Add(_details);
        Loaded += async (_, _) => await _editor.InitializeAsync();
        _tabs.SelectionChanged += (_, _) => RefreshChrome();
        _tabs.TabCloseRequested += (_, e) =>
        {
            if (e.Item is not TabViewItem item || _editor.Owns(item) || _browser.Owns(item)) return;
            if (item.Content is TerminalPage terminal) terminal.Release();
            _tabs.Forget(item);
        };
        Content = _tabs;
        Open(WorkspaceSection.Launcher);
    }

    public void Open(WorkspaceSection section)
    {
        if (section == WorkspaceSection.Browser)
        {
            _browser.AddTab("", "127.0.0.1", 0, false,
                RemoteWorkspaces.TrySplit(WorkspaceId, out var peer, out _) ? peer : null);
            return;
        }
        if (section == WorkspaceSection.Files) _showDetails = false;
        if (section == WorkspaceSection.Sessions) section = WorkspaceSection.Launcher;
        var label = section switch
        {
            WorkspaceSection.Pulls => "Pull requests", WorkspaceSection.Todo => "Tasks",
            _ => section.ToString(),
        };
        OpenSurface("section:" + section, label,
            () => section == WorkspaceSection.Files ? _editor : _create(section),
            section != WorkspaceSection.Launcher);
    }

    public void OpenTerminal(string? sessionId)
    {
        var key = "terminal:" + (sessionId ?? Guid.NewGuid().ToString());
        OpenSurface(key, "Terminal", () => new TerminalPage(WorkspaceId, sessionId));
    }

    public void OpenBrowser(string url, string host, int port, bool unlisten, string? peer) =>
        _browser.AddTab(url, host, port, unlisten, peer);

    private void OpenSurface(string key, string label, Func<Page> create, bool closable = true)
    {
        var tab = _tabs.Open(key, label, () => create(), closable);
        tab.IconSource ??= new FontIconSource { Glyph = key.StartsWith("terminal:") ? "\uE756" : "\uE80A" };
        RefreshChrome();
    }

    private object? ActiveSource => _tabs.SelectedItem is TabViewItem item
        ? _editor.Owns(item) ? _editor : _browser.Owns(item) ? _browser : ActivePage : null;
    public UIElement? Inspector => _inspector;
    public UIElement? ToolbarScope => (ActiveSource as IToolbarItems)?.ToolbarScope;
    public IList<UIElement> ToolbarActions() => (ActiveSource as IToolbarItems)?.ToolbarActions() ?? new List<UIElement>();
    public event Action? ToolbarChanged;
    private void Changed()
    {
        if (_tabs.SelectedItem is TabViewItem tab && tab.Content is TerminalPage terminal)
            tab.Header = terminal.TabTitle;
        ToolbarChanged?.Invoke();
    }
    private void RefreshChrome()
    {
        if (_toolbar is not null) _toolbar.ToolbarChanged -= Changed;
        _toolbar = ActiveSource as IToolbarItems;
        if (_toolbar is not null) _toolbar.ToolbarChanged += Changed;
        _details.Content = (ActiveSource as IInspectorContent)?.Inspector;
        _details.Visibility = _showDetails ? Visibility.Visible : Visibility.Collapsed;
        _editor.FileTree.Visibility = _showDetails ? Visibility.Collapsed : Visibility.Visible;
        Changed();
    }
}
