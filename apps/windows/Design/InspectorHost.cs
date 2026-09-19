// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Tokenstat.Design;

/// <summary>
/// Which machines a report counts. Mirrors the Mac ActivityScope: this device
/// is the local archive on this disk, all devices is every machine on the
/// account. The wire values are what the host calls them.
/// </summary>
internal enum DeviceScope
{
    ThisDevice,
    AllDevices,
}

internal static class DeviceScopeNames
{
    public static string Label(this DeviceScope scope) => scope switch
    {
        DeviceScope.ThisDevice => "This device",
        DeviceScope.AllDevices => "All devices",
        _ => scope.ToString(),
    };

    public static string Wire(this DeviceScope scope) => scope switch
    {
        DeviceScope.ThisDevice => "local",
        DeviceScope.AllDevices => "account",
        _ => "local",
    };

    public static DeviceScope FromWire(string value) => value switch
    {
        "account" => DeviceScope.AllDevices,
        _ => DeviceScope.ThisDevice,
    };
}

/// <summary>
/// Per-page inspector content. A page that has something to say beside itself
/// implements this and the shell shows Inspector in the trailing column. Pages
/// that do not implement it, or return null, get no column: the default is
/// none, and the content keeps the full width.
/// </summary>
internal interface IInspectorContent
{
    UIElement? Inspector { get; }
}

/// <summary>
/// Pages whose numbers depend on the toolbar scope implement this. The shell
/// pushes the current scope on navigation and on every change, so the page
/// never reads the toolbar directly.
/// </summary>
internal interface IScopeAware
{
    void ApplyScope(DeviceScope scope);
}

/// <summary>
/// The content body: the page plus a trailing inspector column, mirroring the
/// Mac detail column. One star column for the content, a 1px rule, and a fixed
/// pane on the sidebar tone. The column shows only when every gate agrees: the
/// user has it open, the route allows one, the window fits it, and the page
/// offered content. Otherwise the content keeps the full width.
/// </summary>
internal sealed class InspectorHost : Grid
{
    /// <summary>How wide the inspector column is when it shows.</summary>
    public const double InspectorWidth = 280;

    /// <summary>
    /// Windows narrower than this hide the inspector rather than squeezing the
    /// content for its sake. The user's open choice stands, so widening brings
    /// the column back.
    /// </summary>
    public const double FitEdge = 900;

    private readonly Border _rule;
    private readonly Border _pane;
    private readonly ScrollViewer _scroller;

    /// <summary>What the user asked for with the toggle. Starts open, like the Mac.</summary>
    public bool IsOpen { get; set; } = true;

    /// <summary>Whether this route may show an inspector. Account never does.</summary>
    public bool RouteAllowsInspector { get; set; }

    /// <summary>Whether the window is wide enough to carry the column at all.</summary>
    public bool FitsWidth { get; set; } = true;

    /// <summary>Whether the column is on screen right now.</summary>
    public bool IsInspectorVisible { get; private set; }

    public InspectorHost()
    {
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0) });
        _rule = new Border { Background = Theme.BorderBrush };
        Grid.SetColumn(_rule, 1);
        Children.Add(_rule);
        _scroller = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        _pane = new Border { Background = Theme.SidebarBrush, Child = _scroller };
        Grid.SetColumn(_pane, 2);
        Children.Add(_pane);
        Refresh();
    }

    /// <summary>
    /// Mount the content element in the star column. Called once, by the
    /// shell; a second call replaces the old child rather than stacking a
    /// new one over it.
    /// </summary>
    public void SetContent(FrameworkElement content)
    {
        if (content.Parent == this)
        {
            return;
        }
        for (int i = Children.Count - 1; i >= 0; i--)
        {
            if (Children[i] is FrameworkElement child && Grid.GetColumn(child) == 0)
            {
                Children.RemoveAt(i);
            }
        }
        if (VisualTreeHelper.GetParent(content) is Panel panel)
        {
            panel.Children.Remove(content);
        }
        Grid.SetColumn(content, 0);
        Children.Add(content);
    }

    /// <summary>Show this in the inspector column, or hide the column when null.</summary>
    public void SetInspector(UIElement? inspector)
    {
        _scroller.Content = inspector;
        Refresh();
    }

    /// <summary>Reapply the gates after a toggle, a route change, or a resize.</summary>
    public void Refresh()
    {
        bool show = IsOpen && RouteAllowsInspector && FitsWidth && _scroller.Content is not null;
        IsInspectorVisible = show;
        ColumnDefinitions[1].Width = new GridLength(show ? 1 : 0);
        ColumnDefinitions[2].Width = new GridLength(show ? InspectorWidth : 0);
        _rule.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        _pane.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Repaint the rule and the pane from the theme tokens.</summary>
    public void ApplyTheme()
    {
        _rule.Background = Theme.BorderBrush;
        _pane.Background = Theme.SidebarBrush;
    }
}
