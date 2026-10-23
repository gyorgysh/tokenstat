// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using System.Runtime.CompilerServices;

namespace Tokenstat.Navigation;

internal static class NavigationRows
{
    // WinUI #10757/#12235: the shipped SDK calls removed items through raw
    // SplitView callbacks after reference-tracker GC disconnects their XAML
    // weak references. Reuse those native containers while their view lives.
    // This pool grows only to the largest simultaneously populated sidebar,
    // rather than retaining a new set of containers on every refresh.
    private static readonly ConditionalWeakTable<NavigationView, Stack<NavigationViewItem>> Retired = new();
    public static event Action<NavigationViewItem>? Retiring;

    public static int RetiredCount(NavigationView owner) => Retired.GetValue(owner, static _ => new()).Count;

    public static void Retire(NavigationView owner, NavigationViewItem row)
    {
        Retired.GetValue(owner, static _ => new()).Push(row);
        foreach (var child in row.MenuItems.OfType<NavigationViewItem>().ToArray()) Retire(owner, child);
        row.MenuItems.Clear();
        Retiring?.Invoke(row);
        row.Content = null;
        row.Icon = null;
        row.InfoBadge = null;
        row.ContextFlyout = null;
        ToolTipService.SetToolTip(row, null);
        row.Tag = null;
        AutomationProperties.SetName(row, "");
        AutomationProperties.SetAutomationId(row, "");
    }

    public static NavigationViewItem Reuse(NavigationView owner, NavigationViewItem fresh)
    {
        var pool = Retired.GetValue(owner, static _ => new());
        if (!pool.TryPop(out var row)) return fresh;
        if (ReferenceEquals(owner.SelectedItem, row)) owner.SelectedItem = null;
        row.Tag = fresh.Tag;
        var content = fresh.Content; fresh.Content = null; row.Content = content;
        var icon = fresh.Icon; fresh.Icon = null; row.Icon = icon;
        var menu = fresh.ContextFlyout; fresh.ContextFlyout = null; row.ContextFlyout = menu;
        row.Style = fresh.Style;
        row.IsSelected = false;
        row.IsChildSelected = false;
        row.IsExpanded = fresh.IsExpanded;
        row.SelectsOnInvoked = fresh.SelectsOnInvoked;
        row.IsEnabled = fresh.IsEnabled;
        row.IsTabStop = fresh.IsTabStop;
        row.Visibility = fresh.Visibility;
        row.Opacity = fresh.Opacity;
        row.HorizontalAlignment = fresh.HorizontalAlignment;
        row.VerticalAlignment = fresh.VerticalAlignment;
        row.HorizontalContentAlignment = fresh.HorizontalContentAlignment;
        row.VerticalContentAlignment = fresh.VerticalContentAlignment;
        row.Margin = fresh.Margin; row.Padding = fresh.Padding;
        row.Width = fresh.Width; row.Height = fresh.Height;
        row.MinWidth = fresh.MinWidth; row.MinHeight = fresh.MinHeight;
        row.MaxWidth = fresh.MaxWidth; row.MaxHeight = fresh.MaxHeight;
        row.FontSize = fresh.FontSize; row.FontWeight = fresh.FontWeight;
        row.FontFamily = fresh.FontFamily;
        row.RequestedTheme = fresh.RequestedTheme;
        var badge = fresh.InfoBadge; fresh.InfoBadge = null; row.InfoBadge = badge;
        ToolTipService.SetToolTip(row, ToolTipService.GetToolTip(fresh));
        ToolTipService.SetToolTip(fresh, null);
        AutomationProperties.SetName(row, AutomationProperties.GetName(fresh));
        AutomationProperties.SetAutomationId(row, AutomationProperties.GetAutomationId(fresh));
        var children = fresh.MenuItems.ToArray(); fresh.MenuItems.Clear();
        foreach (var child in children) row.MenuItems.Add(child is NavigationViewItem item ? Reuse(owner, item) : child);
        Reconciled?.Invoke(fresh, row);
        return row;
    }

    /// <summary>Refresh row-owned behavior when its navigation container is retained.</summary>
    public static event Action<NavigationViewItem, NavigationViewItem>? Reconciled;
    /// <summary>Update live content while retaining navigation containers and scroll anchors.</summary>
    public static void Reconcile(IList<object> items, IReadOnlyList<NavigationViewItem> desired, string prefix, int start = -1, NavigationView? owner = null)
    {
        var tags = desired.Select(row => row.Tag as string).ToHashSet();
        for (var i = items.Count - 1; i >= 0; i--)
            if (items[i] is NavigationViewItem old && (old.Tag as string)?.StartsWith(prefix, StringComparison.Ordinal) == true && !tags.Contains(old.Tag as string))
            {
                items.RemoveAt(i);
                if (owner is not null) Retire(owner, old);
            }
        var first = items.OfType<NavigationViewItem>().FirstOrDefault(row => (row.Tag as string)?.StartsWith(prefix, StringComparison.Ordinal) == true);
        var at = start < 0 ? (first is null ? items.Count : items.IndexOf(first)) : start;
        foreach (var fresh in desired)
        {
            var existing = items.OfType<NavigationViewItem>().FirstOrDefault(row => Equals(row.Tag, fresh.Tag));
            if (existing is not null)
            {
                // Keep the navigation container and its scroll anchor alive.
                var unchanged = existing.Content is FrameworkElement { Tag: not null } oldView
                    && fresh.Content is FrameworkElement newView && Equals(oldView.Tag, newView.Tag);
                if (!unchanged)
                {
                    var content = fresh.Content;
                    fresh.Content = null;
                    existing.Content = content;
                }
                AutomationProperties.SetName(existing, AutomationProperties.GetName(fresh));
                existing.ContextFlyout = fresh.ContextFlyout;
                fresh.ContextFlyout = null;
                Reconciled?.Invoke(fresh, existing);
                var index = items.IndexOf(existing);
                if (index == at) { at++; continue; }
                items.RemoveAt(index);
                if (index < at) at--;
            }
            items.Insert(Math.Min(at++, items.Count), existing ?? (owner is null ? fresh : Reuse(owner, fresh)));
        }
    }

}
