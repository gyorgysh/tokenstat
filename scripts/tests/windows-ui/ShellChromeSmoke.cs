// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Windows.Foundation;

namespace NativeUiTests;

internal static class ShellChromeSmoke
{
    internal static async Task Run(StackPanel host)
    {
        var sidebar = Buttons.ToolbarIcon(ActionIcon.Sidebar, "Projects", (_, _) => { });
        var scope = SegmentedCapsule.View(new List<(string Value, string Label, ActionIcon? Glyph)>
        {
            ("local", "This device", ActionIcon.Computer), ("account", "All devices", ActionIcon.Browser),
        }, "account", _ => Task.CompletedTask);
        scope.Width = 280;
        var project = new ComboBox { Width = 160, ItemsSource = new[] { "All projects", "tokenstat" }, SelectedIndex = 1 };
        var sort = new TextBox { Width = 220, Text = "Retained filter" };
        var refresh = Buttons.ToolbarIcon(ActionIcon.Refresh, "Refresh", (_, _) => { });
        var inspector = Buttons.ToolbarIcon(ActionIcon.Collapse, "Inspector", (_, _) => { });
        var controls = new FrameworkElement[] { sidebar, scope, project, sort, refresh, inspector };
        var bar = DetailBar.View(new List<UIElement> { sidebar, scope }, trailing: new List<UIElement> { project, sort, refresh, inspector });
        // Startup can rebuild controls before the first strip ever loads.
        bar = DetailBar.View(new List<UIElement> { sidebar, scope }, trailing: new List<UIElement> { project, sort, refresh, inspector });
        bar.Width = 1000;
        host.Children.Add(bar);
        var mounted = new List<UIElement> { bar };
        try
        {
            foreach (var width in new[] { 1000d, 420d, 600d, 1000d })
            {
                bar.Width = width;
                host.UpdateLayout();
                await Task.Delay(50);
                if (width == 1000 && Math.Abs(bar.ActualHeight - DetailBar.Height) > 0.5)
                    throw new Exception("Wide chrome does not retain the shared 40px baseline");
                if (width == 420 && bar.ActualHeight < 80)
                    throw new Exception("Narrow chrome clipped its controls instead of wrapping");
                var rects = controls.Select(control =>
                {
                    var at = control.TransformToVisual(bar).TransformPoint(new Point());
                    return new Rect(at.X, at.Y, control.ActualWidth, control.ActualHeight);
                }).ToArray();
                foreach (var rect in rects)
                    if (rect.X < -0.5 || rect.Right > width + 0.5 || rect.Y < -0.5 || rect.Bottom > bar.ActualHeight + 0.5)
                        throw new Exception($"Chrome action escaped its {width}px surface: {rect}");
                for (var i = 0; i < rects.Length; i++)
                    for (var j = i + 1; j < rects.Length; j++)
                        if (Math.Min(rects[i].Right, rects[j].Right) - Math.Max(rects[i].Left, rects[j].Left) > 0.5
                            && Math.Min(rects[i].Bottom, rects[j].Bottom) - Math.Max(rects[i].Top, rects[j].Top) > 0.5)
                            throw new Exception("Leading and trailing chrome controls overlap");
            }
            if (project.SelectedIndex != 1 || sort.Text != "Retained filter")
                throw new Exception("Resizing chrome lost its picker or text state");
            var empty = DetailBar.View();
            empty.Width = 420;
            host.Children.Add(empty);
            mounted.Add(empty);
            host.UpdateLayout();
            if (Math.Abs(empty.ActualHeight - DetailBar.Height) > 0.5)
                throw new Exception("Empty chrome does not retain the shared 40px baseline");
            host.Children.Remove(empty);
            // Rebuilding an unmounted toolbar must release logical parents too.
            host.Children.Remove(bar);
            var rebuilt = DetailBar.View(new List<UIElement> { sidebar, scope }, trailing: new List<UIElement> { project, sort, refresh, inspector });
            rebuilt.Width = 1000;
            host.Children.Add(rebuilt);
            mounted.Add(rebuilt);
            host.UpdateLayout();
            await Task.Delay(50);
            if (project.SelectedIndex != 1 || sort.Text != "Retained filter" || project.ActualWidth <= 0)
                throw new Exception("Rebuilding chrome reparented or replaced a stateful picker incorrectly");
            host.Children.Remove(rebuilt);
            var rail = SidebarChrome.RailButton(ActionIcon.Home.Icon(), "Home", (_, _) => { });
            host.Children.Add(rail);
            mounted.Add(rail);
            host.UpdateLayout();
            if (rail.ActualWidth != 40 || rail.ActualHeight != 36 || sidebar.Width != 30 || sidebar.Height != 30)
                throw new Exception("Rail and toolbar marks no longer use the desktop metrics");
            var normal = ((SolidColorBrush)rail.Foreground).Color;
            SidebarChrome.Select(rail, true);
            if (((SolidColorBrush)rail.Foreground).Color != Theme.Accent || ((SolidColorBrush)rail.Foreground).Color == normal)
                throw new Exception("Selecting a rail destination did not accent its mark");
            SidebarChrome.Select(rail, false);
            if (((SolidColorBrush)rail.Foreground).Color != normal)
                throw new Exception("Leaving a rail destination kept its mark selected");
            host.Children.Remove(rail);
            var firstAction = Buttons.ToolbarIcon(ActionIcon.Edit, "New chat", (_, _) => { });
            var nextAction = Buttons.ToolbarIcon(ActionIcon.Settings, "Project settings", (_, _) => { });
            var row = new UserControl { Content = new StackPanel
            {
                Orientation = Orientation.Horizontal, Children = { firstAction, nextAction },
            } };
            SidebarChrome.RevealActions(row, firstAction, nextAction);
            var outside = SidebarChrome.Row("Search", ActionIcon.Search, (_, _) => { });
            host.Children.Add(row);
            host.Children.Add(outside);
            mounted.Add(row);
            mounted.Add(outside);
            host.UpdateLayout();
            await Task.Delay(50);
            if (firstAction.Opacity != 0 || !firstAction.Focus(FocusState.Keyboard))
                throw new Exception("Project row actions are not quietly keyboard reachable");
            await Task.Delay(30);
            if (firstAction.Opacity != 1 || nextAction.Opacity != 1 || !nextAction.Focus(FocusState.Keyboard))
                throw new Exception("Focusing a project action did not reveal the row's actions");
            await Task.Delay(30);
            if (firstAction.Opacity != 1 || nextAction.Opacity != 1 || !outside.Focus(FocusState.Keyboard))
                throw new Exception("Moving keyboard focus within a project row hid its actions");
            await Task.Delay(30);
            if (firstAction.Opacity != 0 || nextAction.Opacity != 0)
                throw new Exception("Leaving a project row kept its actions visible");
            Program.Log("PASS: desktop chrome aligns, wraps without overlap, retains picker state and safely rebuilds; rail selection uses desktop metrics");
            Program.Log("PASS: project actions remain visible through keyboard navigation and hide after focus leaves");
        }
        finally { foreach (var control in mounted) host.Children.Remove(control); }
    }
}
