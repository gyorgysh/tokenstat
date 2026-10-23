// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace NativeUiTests;

internal static class SidebarAdaptiveSmoke
{
    internal static async Task Run(StackPanel host)
    {
        var view = new NavigationView { Width = 900, Height = 180, CompactPaneLength = 0,
            PaneDisplayMode = NavigationViewPaneDisplayMode.Auto, IsPaneToggleButtonVisible = false };
        var project = new NavigationViewItem { Content = "Fictional project", IsExpanded = true };
        for (var i = 0; i < 13; i++) project.MenuItems.Add(new NavigationViewItem { Content = "Fictional chat " + i });
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
            Program.Log("PASS: native sidebar threshold growth, shrink and resize preserve expanded/minimal modes");
        }
        finally { host.Children.Remove(view); }
    }
}
