// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace NativeUiTests;

internal static class SidebarAdaptiveSmoke
{
    internal static async Task Run(StackPanel host)
    {
        var view = new NavigationView { Width = 900, Height = 180, CompactPaneLength = 0,
            PaneDisplayMode = NavigationViewPaneDisplayMode.Auto, IsPaneToggleButtonVisible = false };
        // Production resource lookup and native focus states must be present:
        // an unstyled, unfocused item does not exercise the shell's transitions.
        Theme.InstallControlResources();
        view.OpenPaneLength = ShellWidths.Shared.Sidebar;
        view.Resources["NavigationViewDefaultPaneBackground"] = Theme.SidebarBrush;
        view.Resources["NavigationViewExpandedPaneBackground"] = Theme.SidebarBrush;
        view.Resources["NavigationViewContentBackground"] = Theme.BackgroundBrush;
        view.Resources["NavigationViewContentGridBorderBrush"] = Theme.BorderBrush;
        view.Resources["NavigationViewPaneContentGridMargin"] = new Thickness(0);
        view.Resources["NavigationViewContentGridBorderThickness"] = new Thickness(1, 0, 0, 0);
        view.Resources["NavigationViewBorderThickness"] = new Thickness(0);
        view.Resources["NavigationViewMinimalContentGridBorderThickness"] = new Thickness(0);
        view.Resources["NavigationViewContentGridCornerRadius"] = new CornerRadius(0);
        view.Resources["NavigationViewItemOnLeftMinHeight"] = 32d;
        view.Resources["NavigationViewItemContentPresenterMargin"] = new Thickness(4, 0, 4, 0);
        var project = new NavigationViewItem { Content = "Fictional project", IsExpanded = true };
        for (var i = 0; i < 13; i++) project.MenuItems.Add(new NavigationViewItem { Content = "Fictional chat " + i });
        project.Content = SidebarChrome.ProjectContent(project, new TextBlock { Text = "Fictional project" }, false,
            new Button { Content = "Fictional action" });
        SidebarChrome.AlignProject(project); // Unmounted rows must not force a native template.
        var selectedChat = (NavigationViewItem)project.MenuItems[1];
        view.MenuItems.Add(project);
        view.PaneHeader = new TextBlock { Text = "Fictional header" };
        view.PaneFooter = new TextBlock { Text = "Fictional account" };
        var insideNativeCallback = false;
        var paneUpdates = 0;
        view.RegisterPropertyChangedCallback(NavigationView.IsPaneOpenProperty, (_, _) => insideNativeCallback = true);
        SidebarChrome.FollowPaneState(view, () =>
        {
            if (insideNativeCallback) throw new Exception("Pane content changed inside the native pane callback");
            paneUpdates++;
            project.IsExpanded = view.IsPaneOpen;
            view.PaneHeader = view.IsPaneOpen ? new TextBlock { Text = "Fictional refreshed header" } : null;
            view.PaneFooter = view.IsPaneOpen ? new TextBlock { Text = "Fictional refreshed account" } : null;
        });
        view.RegisterPropertyChangedCallback(NavigationView.IsPaneOpenProperty, (_, _) => insideNativeCallback = false);
        SidebarChrome.SetAdaptiveThreshold(view, 692);
        var modes = new List<NavigationViewDisplayMode>();
        view.DisplayModeChanged += (_, args) => modes.Add(args.DisplayMode);
        async Task Settle(NavigationViewDisplayMode expected)
        {
            for (var i = 0; i < 150; i++)
            {
                host.UpdateLayout();
                await Task.Delay(20);
                if (view.IsLoaded && view.ActualWidth > 0 && view.DisplayMode == expected) return;
            }
            throw new Exception("Native adaptive sidebar did not reach its expected mode");
        }
        host.Children.Add(view);
        try
        {
            await Settle(NavigationViewDisplayMode.Expanded);
            view.SelectedItem = selectedChat;
            if (!selectedChat.Focus(FocusState.Keyboard))
                throw new Exception("Native sidebar could not focus its selected chat");
            await Task.Delay(250);
            modes.Clear();
            // A chat adds its companion width. Returning to an ordinary page
            // removes it while the window remains between the two thresholds.
            foreach (var width in new[] { 1098d, 692d, 1098d, 692d })
            {
                SidebarChrome.SetAdaptiveThreshold(view, width);
                await Settle(width > view.ActualWidth ? NavigationViewDisplayMode.Minimal : NavigationViewDisplayMode.Expanded);
                if (view.ExpandedModeThresholdWidth != width || view.CompactModeThresholdWidth != width
                    || modes.Contains(NavigationViewDisplayMode.Compact))
                    throw new Exception("Sidebar sizing entered an unintended compact mode");
            }
            view.Width = 600;
            await Settle(NavigationViewDisplayMode.Minimal);
            view.Width = 1200;
            await Settle(NavigationViewDisplayMode.Expanded);
            if (modes.Contains(NavigationViewDisplayMode.Compact)) throw new Exception("Sidebar resizing entered compact mode");
            for (var i = 0; i < 100 && paneUpdates == 0; i++) await Task.Delay(20);
            if (paneUpdates == 0) throw new Exception("Sidebar pane content never followed its open state");
            if (!ReferenceEquals(view.SelectedItem, selectedChat)) throw new Exception("Sidebar layout lost the selected chat");
            Program.Log("PASS: native sidebar threshold growth, shrink and resize preserve expanded/minimal modes");
        }
        finally { host.Children.Remove(view); }
        await RemovedItems(host);
    }

    // Matches microsoft/microsoft-ui-xaml#12235: removed XAML items must not
    // receive SplitView callbacks after reference-tracker GC disconnects them.
    private static async Task RemovedItems(StackPanel host)
    {
        var view = new NavigationView { Width = 900, Height = 300, PaneDisplayMode = NavigationViewPaneDisplayMode.Left, IsPaneOpen = true };
        var parent = new NavigationViewItem { Content = "Fictional changing project", IsExpanded = true };
        view.MenuItems.Add(parent);
        host.Children.Add(view);
        try
        {
            for (var cycle = 0; cycle < 40; cycle++)
            {
                ReplaceChildren(parent, cycle * 2, 6);
                parent.IsExpanded = true;
                host.UpdateLayout();
                await Task.Delay(20);
                ReplaceChildren(parent, cycle * 2 + 1, 1);
                GC.Collect();
                view.IsPaneOpen = false;
                view.IsPaneOpen = true;
                view.PaneDisplayMode = NavigationViewPaneDisplayMode.Top;
                view.PaneDisplayMode = NavigationViewPaneDisplayMode.Left;
                view.CompactPaneLength = 48 + cycle % 2;
                host.UpdateLayout();
                await Task.Delay(20);
            }
            Program.Log("PASS: removed sidebar items survive GC before pane, display-mode and compact-width changes");
        }
        finally { host.Children.Remove(view); }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void ReplaceChildren(NavigationViewItem parent, int generation, int count)
    {
        var desired = Enumerable.Range(0, count).Select(index => new NavigationViewItem
            { Tag = $"lifetime:{generation}:{index}", Content = $"Fictional chat {index}" }).ToArray();
        NavigationRows.Reconcile(parent.MenuItems, desired, "lifetime:", 0);
    }
}
