// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Windows.Foundation;

namespace NativeUiTests;

internal static class ShellChromeSmoke
{
    private static async Task Settled(Func<bool> condition, string message)
    {
        // Native focus notifications settle through the dispatcher. A fixed
        // 30ms pause is not reliable on a loaded Windows runner.
        for (var attempt = 0; attempt < 100; attempt++)
        {
            if (condition()) return;
            await Task.Delay(20);
        }
        throw new Exception(message);
    }

    internal static async Task Run(StackPanel host)
    {
        var removed = FriendlyError.From("remote reach registration failed (403 Forbidden): {\"error\":\"machine_unlinked\"}");
        if (!removed.RequiresSignIn || removed.OpensPlans || removed.ActionIcon != ActionIcon.SignIn)
            throw new Exception("An unlinked device must offer fresh sign-in, rather than retrying or changing plans");
        var connecting = FriendlyError.From("the connection credential was refused");
        if (connecting.RequiresSignIn || connecting.ActionIcon != ActionIcon.Refresh)
            throw new Exception("A reconnecting credential must retain automatic recovery");
        Program.Log("PASS: removed devices require sign-in and transient tunnel credentials retain retry");
        var setup = ActionIconGlyph.Button("Setup", ActionIcon.Settings, (_, _) => { });
        if (Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(setup) != "Setup")
            throw new Exception("Icon-and-text actions must expose their label to accessibility and automation");
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
            await Settled(() => firstAction.Opacity == 1 && nextAction.Opacity == 1,
                "Focusing a project action did not reveal the row's actions");
            if (!nextAction.Focus(FocusState.Keyboard)) throw new Exception("The next project action could not receive focus");
            await Settled(() => nextAction.FocusState == FocusState.Keyboard && firstAction.Opacity == 1 && nextAction.Opacity == 1,
                "Moving keyboard focus within a project row hid its actions");
            if (!outside.Focus(FocusState.Keyboard)) throw new Exception("The search row could not receive focus");
            await Settled(() => firstAction.Opacity == 0 && nextAction.Opacity == 0,
                "Leaving a project row kept its actions visible");
            host.Children.Remove(row);
            host.Children.Remove(outside);
            var navigation = new NavigationView
            {
                Width = 320, Height = 360, OpenPaneLength = 272, CompactPaneLength = 0,
                PaneDisplayMode = NavigationViewPaneDisplayMode.Left, IsPaneOpen = true,
                IsPaneToggleButtonVisible = false, IsSettingsVisible = false,
                IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            };
            navigation.Resources["NavigationViewBorderThickness"] = new Thickness(0);
            var projectRow = new NavigationViewItem { IsExpanded = true, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            var heading = SidebarChrome.ProjectContent(projectRow, new TextBlock { Text = "tokenstat", FontSize = 13 }, false);
            projectRow.Content = heading;
            var footer = SidebarChrome.ChatFooter("wschatmore:fixture", "Show 5 more", () => { }, () => { });
            projectRow.MenuItems.Add(footer);
            navigation.MenuItems.Add(projectRow);
            host.Children.Add(navigation);
            mounted.Add(navigation);
            host.UpdateLayout();
            await Task.Delay(50);
            SidebarChrome.AlignProject(projectRow);
            host.UpdateLayout();
            var folderGlyph = heading.Children.OfType<Viewbox>().Single();
            if (folderGlyph.ActualWidth != 16 || folderGlyph.ActualHeight != 16)
                throw new Exception("The project folder icon disappeared with the native compact pane disabled");
            var footerGrid = (Grid)footer.Content;
            var links = footerGrid.Children.OfType<Button>().ToArray();
            if (links.Length != 2 || links.Any(link => link.ActualWidth <= 0))
                throw new Exception("Chat history footer does not render both actions");
            var left = links[0].TransformToVisual(footerGrid).TransformPoint(new Point());
            var right = links[1].TransformToVisual(footerGrid).TransformPoint(new Point());
            if (left.X + links[0].ActualWidth > right.X + 0.5 || right.X + links[1].ActualWidth > footerGrid.ActualWidth + 0.5)
                throw new Exception("Show more and See all chats overlap inside the sidebar");
            var firstProject = EmptyState.FirstProject(Buttons.Primary("Add project", ActionIcon.Create, (_, _) => { }), compact: true);
            firstProject.Width = 240;
            host.Children.Add(firstProject);
            mounted.Add(firstProject);
            host.UpdateLayout();
            if (firstProject.ActualHeight <= 100 || firstProject.ActualWidth != 240)
                throw new Exception("The first-project illustration and action did not render in the sidebar width");
            Program.Log("PASS: project icon survives a zero-width compact pane; chat footer actions fit together; first-project prompt renders");
            Program.Log("PASS: desktop chrome aligns, wraps without overlap, retains picker state and safely rebuilds; rail selection uses desktop metrics");
            Program.Log("PASS: project actions remain visible through keyboard navigation and hide after focus leaves");
        }
        finally { foreach (var control in mounted) host.Children.Remove(control); }
    }
}
