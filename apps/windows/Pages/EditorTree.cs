// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;

namespace Tokenstat.Pages;

internal static class EditorTree
{
    public static TreeView Create() => new()
    {
        SelectionMode = TreeViewSelectionMode.Single,
        CanDragItems = false, CanReorderItems = false, AllowDrop = false,
        ItemTemplate = (DataTemplate)XamlReader.Load(
            """<DataTemplate xmlns="http:
    };
}
