// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml.Controls;

namespace Tokenstat.Pages;

internal static class WorkPinMenu
{
    public static void Add(MenuFlyout menu, string workspaceId, string chatId, string name, string folderName)
    {
        var item = new MenuFlyoutItem { Text = L10n.Text("windows.workpinmenu.pin_to_home.db029e6f"), IsEnabled = false };
        menu.Items.Add(item);
        menu.Opening += async (_, _) =>
        {
            item.IsEnabled = false;
            var memory = await BrowserProjectMemory.ForAsync(workspaceId);
            if (memory is null) return;
            var pinned = PinnedWorkStore.Shared.Contains(memory.Owner, chatId);
            var full = !pinned && PinnedWorkStore.Shared.Read(memory.AccountScope).Count >= PinnedWorkStore.Capacity;
            item.Text = pinned ? L10n.Text("windows.workpinmenu.unpin_from_home.df00f5de") : full ? L10n.Text("windows.workpinmenu.home_holds_eight_pins.a965e95c") : L10n.Text("windows.workpinmenu.pin_to_home.db029e6f");
            item.IsEnabled = !full;
        };
        item.Click += async (_, _) =>
        {
            var memory = await BrowserProjectMemory.ForAsync(workspaceId);
            if (memory is null) return;
            if (PinnedWorkStore.Shared.Contains(memory.Owner, chatId)) PinnedWorkStore.Shared.Remove(memory.Owner, chatId);
            else PinnedWorkStore.Shared.Pin(new(memory.AccountScope, memory.Owner, workspaceId, chatId, name, folderName));
        };
    }
}
