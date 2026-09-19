// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>Stable surfaces: opening an existing tab selects its existing document.</summary>
internal sealed class WorkspaceTabStrip
{
    // WinUI must see an actual TabView when applying its native template.
    // A managed subclass is projected as Control and fails style validation.
    public TabView View { get; } = new();
    private readonly Dictionary<string, TabViewItem> _surfaces = new();
    public Action<TabViewItem>? CloseRequested { get; set; }
    public WorkspaceTabStrip()
    {
        // WinUI's DefaultTabViewStyle sets VerticalAlignment=Top. Content
        // alignment alone cannot make the tab control fill its parent's slot.
        View.HorizontalAlignment = HorizontalAlignment.Stretch;
        View.VerticalAlignment = VerticalAlignment.Stretch;
        View.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        View.VerticalContentAlignment = VerticalAlignment.Stretch;
        View.Loaded += (_, _) => StretchContentPresenter();
        View.ActualThemeChanged += (_, _) => StretchContentPresenter();
        View.IsAddTabButtonVisible = false;
        View.TabWidthMode = TabViewWidthMode.SizeToContent;
        View.Resources["TabViewBackground"] = Theme.TabStripBrush;
        View.Resources["TabViewItemHeaderBackground"] = Theme.PanelBrush;
        View.Resources["TabViewItemHeaderBackgroundSelected"] = Theme.Brush(static () => Theme.RowSelected);
        View.Resources["TabViewItemHeaderBackgroundPressed"] = Theme.Brush(static () => Theme.RowHighlight);
        View.Resources["TabViewItemHeaderDragBackground"] = Theme.PanelBrush;
        View.Resources["TabViewItemHeaderBackgroundPointerOver"] = Theme.Brush(static () => Theme.RowHighlight);
    }

    // The native template's presenter does not bind the control's content
    // alignment. Set it explicitly without replacing or subclassing TabView.
    private void StretchContentPresenter()
    {
        View.ApplyTemplate();
        void Visit(DependencyObject node)
        {
            if (node is ContentPresenter { Name: "TabContentPresenter" } presenter)
            {
                presenter.HorizontalContentAlignment = HorizontalAlignment.Stretch;
                presenter.VerticalContentAlignment = VerticalAlignment.Stretch;
                return;
            }
            for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(node); i++)
                Visit(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(node, i));
        }
        Visit(View);
    }

    public TabViewItem Open(string key, string label, Func<UIElement> create, bool closable = true)
    {
        if (!_surfaces.TryGetValue(key, out var tab))
        {
            tab = new TabViewItem { Header = label, Content = create(), IsClosable = closable,
                HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
            var menu = ContextMenus.Menu(tab);
            ContextMenus.Add(menu, "Close", () => CloseRequested?.Invoke(tab), () => tab.IsClosable);
            _surfaces.Add(key, tab);
            View.TabItems.Add(tab);
        }
        View.SelectedItem = tab;
        return tab;
    }

    public void Forget(TabViewItem tab)
    {
        var key = _surfaces.FirstOrDefault(pair => ReferenceEquals(pair.Value, tab)).Key;
        if (key is not null) _surfaces.Remove(key);
        View.TabItems.Remove(tab);
        if (View.SelectedItem is null && View.TabItems.Count > 0) View.SelectedIndex = 0;
    }
}
