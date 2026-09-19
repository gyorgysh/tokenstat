// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Tokenstat.Navigation;

internal static class NavigationRows
{
    /// <summary>Update live content while retaining navigation containers and scroll anchors.</summary>
    public static void Reconcile(IList<object> items, IReadOnlyList<NavigationViewItem> desired, string prefix, int start = -1)
    {
        var tags = desired.Select(row => row.Tag as string).ToHashSet();
        for (var i = items.Count - 1; i >= 0; i--)
            if (items[i] is NavigationViewItem old && (old.Tag as string)?.StartsWith(prefix, StringComparison.Ordinal) == true && !tags.Contains(old.Tag as string)) items.RemoveAt(i);
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
                var index = items.IndexOf(existing);
                if (index == at) { at++; continue; }
                items.RemoveAt(index);
                if (index < at) at--;
            }
            items.Insert(Math.Min(at++, items.Count), existing ?? fresh);
        }
    }

}
