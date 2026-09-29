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
    private static string PreferencePath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "activity-scope");
    public static DeviceScope Restore()
    {
        try { return FromWire(System.IO.File.ReadAllText(PreferencePath).Trim()); }
        catch { return DeviceScope.AllDevices; }
    }
    public static void Remember(this DeviceScope scope)
    {
        try
        {
            System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(PreferencePath)!);
            System.IO.File.WriteAllText(PreferencePath, scope.Wire());
        }
        catch (System.IO.IOException) { }
        catch (UnauthorizedAccessException) { }
    }

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
    /// Content areas narrower than this hide the inspector rather than squeezing the
    /// content for its sake. The user's open choice stands, so widening brings
    /// the column back.
    /// </summary>
    public const double FitEdge = 700;

    private readonly Border _rule;
    private readonly ResizeHandle _resizeHandle;
    private double _inspectorWidth = InspectorWidth;
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
        _rule = new Border { Background = Theme.BorderBrush, Width = 1, HorizontalAlignment = HorizontalAlignment.Center };
        Grid.SetColumn(_rule, 1);
        Children.Add(_rule);
        _resizeHandle = new ResizeHandle
        {
            Width = 6, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_resizeHandle, "Resize details panel");
        _resizeHandle.DragDelta += (_, drag) =>
        {
            _inspectorWidth = Math.Clamp(_inspectorWidth - drag.HorizontalChange, 240, Math.Min(480, Math.Max(240, ActualWidth - 420)));
            Refresh();
        };
        _resizeHandle.DoubleTapped += (_, _) => { _inspectorWidth = InspectorWidth; Refresh(); };
        _resizeHandle.KeyDown += (_, key) =>
        {
            if (key.Key is not (Windows.System.VirtualKey.Left or Windows.System.VirtualKey.Right)) return;
            _inspectorWidth = Math.Clamp(_inspectorWidth + (key.Key == Windows.System.VirtualKey.Left ? 16 : -16), 240, 480);
            Refresh();
            key.Handled = true;
        };
        Grid.SetColumn(_resizeHandle, 1);
        Children.Add(_resizeHandle);
        _scroller = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        _pane = new Border { Background = Theme.BackgroundBrush, Child = _scroller };
        SizeChanged += (_, _) => Refresh();
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
    public void SetInspector(UIElement? inspector, bool ownsScrolling = false)
    {
        _scroller.VerticalScrollBarVisibility = ownsScrolling ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Auto;
        _scroller.VerticalScrollMode = ownsScrolling ? ScrollMode.Disabled : ScrollMode.Enabled;
        _scroller.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _scroller.VerticalContentAlignment = VerticalAlignment.Stretch;
        _scroller.Content = inspector;
        Refresh();
    }

    /// <summary>Reapply the gates after a toggle, a route change, or a resize.</summary>
    public void Refresh()
    {
        bool show = IsOpen && RouteAllowsInspector && FitsWidth && _scroller.Content is not null;
        IsInspectorVisible = show;
        ColumnDefinitions[1].Width = new GridLength(show ? 6 : 0);
        var fittedWidth = ActualWidth > 0 ? Math.Min(_inspectorWidth, Math.Max(240, ActualWidth - 426)) : _inspectorWidth;
        ColumnDefinitions[2].Width = new GridLength(show ? fittedWidth : 0);
        _resizeHandle.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        _rule.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        _pane.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Repaint the rule and the pane from the theme tokens.</summary>
    public void ApplyTheme()
    {
        _rule.Background = Theme.BorderBrush;
        _pane.Background = Theme.BackgroundBrush;
    }
}
