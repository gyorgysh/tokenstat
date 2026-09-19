// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml.Controls;

namespace Tokenstat.Navigation;

internal static class NavigationExpansion
{
    public static Dictionary<string, bool> Capture(IEnumerable<NavigationViewItem> items) => items
        // Groups share their landing route with a leaf (SSH/Hosts and
        // workspace/Files). Leaves do not own expansion state.
        .Where(item => item.MenuItems.Count > 0 && item.Tag is string)
        .ToDictionary(item => (string)item.Tag, item => item.IsExpanded, StringComparer.Ordinal);
}
