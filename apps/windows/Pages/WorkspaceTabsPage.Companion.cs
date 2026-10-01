// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed partial class WorkspaceTabsPage
{
    private readonly Grid _inspectorTabs = new() { Margin = new Thickness(8) };
    private readonly Grid _companionHeader = new() { Margin = new Thickness(8), ColumnSpacing = 8 };
    private string? _companion;
    private BrowserPage? _companionBrowser;
    private TerminalPage? _companionTerminal;
    private BrowserPage CompanionBrowser => _companionBrowser ??= new BrowserPage("", "127.0.0.1", 0, false,
        RemoteWorkspaces.TrySplit(WorkspaceId, out var peer, out _) ? peer : null, workspaceId: WorkspaceId);
    private TerminalPage CompanionTerminal => _companionTerminal ??= new TerminalPage(WorkspaceId, null);
    public event Action? DetailsRequested;
    private void InitializeCompanion()
    {
        _companionHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _companionHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var caption = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
        _companionHeader.Children.Add(caption);
        var close = Buttons.ToolbarIcon(ActionIcon.Dismiss, "Close companion pane", (_, _) => { _companion = null; RefreshChrome(); });
        Grid.SetColumn(close, 1); _companionHeader.Children.Add(close);
        _companionHeader.Tag = caption;
        _inspector.Children.Add(_companionHeader);
    }
    private void ShowCompanion(string kind)
    {
        _companion = kind;
        if (_companionHeader.Tag is TextBlock caption) caption.Text = kind;
        RefreshChrome();
        DetailsRequested?.Invoke();
    }
    private IList<UIElement> CompanionActions(IList<UIElement> actions)
    {
        if (ActivePage is not ChatPage) return actions;
        actions.Add(Buttons.ToolbarIcon(ActionIcon.Browser, "Browser beside chat", (_, _) => ShowCompanion("Browser"), _companion == "Browser"));
        var terminal = Buttons.ToolbarIcon(ActionIcon.Source, "Terminal beside chat", (_, _) => ShowCompanion("Terminal"), _companion == "Terminal");
        terminal.Content = new FontIcon { Glyph = "\uE756", FontSize = 16 };
        actions.Add(terminal);
        return actions;
    }
}
