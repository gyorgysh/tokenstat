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
    public WorkspaceTabStrip()
    {
        View.IsAddTabButtonVisible = false;
        View.TabWidthMode = TabViewWidthMode.SizeToContent;
        View.Resources["TabViewBackground"] = Theme.TabStripBrush;
        View.Resources["TabViewItemHeaderBackground"] = Theme.PanelBrush;
        View.Resources["TabViewItemHeaderBackgroundSelected"] = Theme.Brush(static () => Theme.RowSelected);
        View.Resources["TabViewItemHeaderBackgroundPressed"] = Theme.Brush(static () => Theme.RowHighlight);
        View.Resources["TabViewItemHeaderDragBackground"] = Theme.PanelBrush;
        View.Resources["TabViewItemHeaderBackgroundPointerOver"] = Theme.Brush(static () => Theme.RowHighlight);
    }

    public TabViewItem Open(string key, string label, Func<UIElement> create, bool closable = true)
    {
        if (!_surfaces.TryGetValue(key, out var tab))
        {
            tab = new TabViewItem { Header = label, Content = create(), IsClosable = closable };
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
