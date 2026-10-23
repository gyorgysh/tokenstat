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
        view.MenuItems.Add(new NavigationViewItem { Content = "Fictional project" });
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
            Program.Log("PASS: native sidebar threshold growth, shrink and resize preserve expanded/minimal modes");
        }
        finally { host.Children.Remove(view); }
    }
}
