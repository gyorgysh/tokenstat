// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>Stable surfaces: opening an existing tab selects its existing document.</summary>
internal sealed class WorkspaceTabStrip : TabView
{
    private readonly Dictionary<string, TabViewItem> _surfaces = new();
    public WorkspaceTabStrip()
    {
        IsAddTabButtonVisible = false;
        TabWidthMode = TabViewWidthMode.SizeToContent;
        Resources["TabViewBackground"] = Theme.TabStripBrush;
        Resources["TabViewItemHeaderBackground"] = Theme.PanelBrush;
        Resources["TabViewItemHeaderBackgroundSelected"] = Theme.Brush(static () => Theme.RowSelected);
        Resources["TabViewItemHeaderBackgroundPressed"] = Theme.Brush(static () => Theme.RowHighlight);
        Resources["TabViewItemHeaderDragBackground"] = Theme.PanelBrush;
        Resources["TabViewItemHeaderBackgroundPointerOver"] = Theme.Brush(static () => Theme.RowHighlight);
    }

    public TabViewItem Open(string key, string label, Func<UIElement> create, bool closable = true)
    {
        if (!_surfaces.TryGetValue(key, out var tab))
        {
            tab = new TabViewItem { Header = label, Content = create(), IsClosable = closable };
            _surfaces.Add(key, tab);
            TabItems.Add(tab);
        }
        SelectedItem = tab;
        return tab;
    }

    public void Forget(TabViewItem tab)
    {
        var key = _surfaces.FirstOrDefault(pair => ReferenceEquals(pair.Value, tab)).Key;
        if (key is not null) _surfaces.Remove(key);
        TabItems.Remove(tab);
        if (SelectedItem is null && TabItems.Count > 0) SelectedIndex = 0;
    }
}
