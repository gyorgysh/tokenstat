// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml.Controls;

namespace Tokenstat.Navigation;

internal static class NavigationExpansion
{
    public static Dictionary<string, bool> Capture(IEnumerable<NavigationViewItem> items) => items
        .Where(item => item.MenuItems.Count > 0 && item.Tag is string)
        .ToDictionary(item => (string)item.Tag, item => item.IsExpanded, StringComparer.Ordinal);
}
