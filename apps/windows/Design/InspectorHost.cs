// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Tokenstat.Design;

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
        DeviceScope.ThisDevice => L10n.Text("windows.inspectorhost.this_device.d052579c"),
        DeviceScope.AllDevices => L10n.Text("windows.inspectorhost.all_devices.0594fe82"),
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

internal interface IInspectorContent
{
    UIElement? Inspector { get; }
    double MinimumContentWidth => ShellWidths.ContentMinimum;
    double MinimumInspectorWidth => ShellWidths.Minimum;
}

internal interface IInspectorRequest
{
    event Action? DetailsRequested;
}

internal interface IInspectorDismissRequest
{
    event Action? DetailsDismissRequested;
}

internal interface IScopeAware
{
    void ApplyScope(DeviceScope scope);
}

internal sealed class InspectorHost : Grid
{
    public const double InspectorWidth = ShellWidths.InspectorDefault;

    public const double FitEdge = ShellWidths.ContentMinimum + 6 + InspectorWidth;

    private readonly Border _rule;
    private readonly ResizeHandle _resizeHandle;
    private double _inspectorWidth = InspectorWidth;
    private readonly ShellWidths _widths;
    public double MinimumContentWidth { get; set; } = ShellWidths.ContentMinimum;
    public double MinimumInspectorWidth { get; set; } = ShellWidths.Minimum;
    public double RequiredWidth => MinimumContentWidth + 6 + Math.Max(MinimumInspectorWidth, _inspectorWidth);
    public event Action? WidthChanged;
    private readonly Border _pane;
    private readonly ScrollViewer _scroller;

    public bool IsOpen { get; set; } = true;

    public bool RouteAllowsInspector { get; set; }

    public bool FitsWidth { get; set; } = true;

    public bool IsInspectorVisible { get; private set; }

    public InspectorHost(ShellWidths? widths = null)
    {
        _widths = widths ?? ShellWidths.Shared;
        _inspectorWidth = _widths.Inspector;
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0) });
        _rule = new Border { Background = Theme.BorderBrush, Width = 1, HorizontalAlignment = HorizontalAlignment.Center };
        Grid.SetColumn(_rule, 1);
        Children.Add(_rule);
        _resizeHandle = new ResizeHandle
        {
            Width = 6, Background = Theme.ClearBrush,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_resizeHandle, L10n.Text("windows.inspectorhost.resize_details_panel.e84be123"));
        _resizeHandle.DragDelta += (_, drag) =>
        {
            _inspectorWidth = Math.Clamp(_inspectorWidth - drag.HorizontalChange, MinimumInspectorWidth,
                Math.Min(ShellWidths.InspectorMaximum, Math.Max(MinimumInspectorWidth, ActualWidth - MinimumContentWidth - 6)));
            Refresh();
        };
        _resizeHandle.DragCompleted += (_, _) => RememberWidth();
        _resizeHandle.DoubleTapped += (_, _) => { _inspectorWidth = InspectorWidth; RememberWidth(); };
        _resizeHandle.KeyDown += (_, key) =>
        {
            if (key.Key is not (Windows.System.VirtualKey.Left or Windows.System.VirtualKey.Right)) return;
            _inspectorWidth = Math.Clamp(_inspectorWidth + (key.Key == Windows.System.VirtualKey.Left ? 20 : -20),
                MinimumInspectorWidth, ShellWidths.InspectorMaximum);
            Refresh();
            RememberWidth();
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

    private void RememberWidth()
    {
        _widths.RememberInspector(_inspectorWidth);
        WidthChanged?.Invoke();
        Refresh();
    }

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

    public void SetInspector(UIElement? inspector, bool ownsScrolling = false)
    {
        _scroller.VerticalScrollBarVisibility = ownsScrolling ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Auto;
        _scroller.VerticalScrollMode = ownsScrolling ? ScrollMode.Disabled : ScrollMode.Enabled;
        _scroller.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _scroller.VerticalContentAlignment = VerticalAlignment.Stretch;
        _scroller.Content = inspector;
        Refresh();
    }

    public void Refresh()
    {
        bool show = IsOpen && RouteAllowsInspector && FitsWidth && _scroller.Content is not null;
        IsInspectorVisible = show;
        ColumnDefinitions[1].Width = new GridLength(show ? 6 : 0);
        var fittedWidth = ActualWidth > 0 ? Math.Min(Math.Max(MinimumInspectorWidth, _inspectorWidth), Math.Max(MinimumInspectorWidth, ActualWidth - MinimumContentWidth - 6)) : Math.Max(MinimumInspectorWidth, _inspectorWidth);
        ColumnDefinitions[2].Width = new GridLength(show ? fittedWidth : 0);
        _resizeHandle.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        _rule.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        _pane.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
    }

    public void ApplyTheme()
    {
        _rule.Background = Theme.BorderBrush;
        _pane.Background = Theme.BackgroundBrush;
    }
}
