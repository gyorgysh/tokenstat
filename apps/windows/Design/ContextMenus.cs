// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace Tokenstat.Design;

/// <summary>Native pointer and keyboard context menus, sharing the existing action handlers.</summary>
internal static class ContextMenus
{
    public static MenuFlyout Menu(FrameworkElement target)
    {
        var menu = new MenuFlyout();
        target.ContextFlyout = menu;
        return menu;
    }

    public static MenuFlyoutItem Add(MenuFlyout menu, string title, Action action, Func<bool>? enabled = null)
    {
        var item = new MenuFlyoutItem { Text = title, IsEnabled = enabled?.Invoke() ?? true };
        item.Click += (_, _) => action();
        if (enabled is not null) menu.Opening += (_, _) => item.IsEnabled = enabled();
        menu.Items.Add(item);
        return item;
    }

    public static MenuFlyoutItem AddAsync(MenuFlyout menu, string title, Func<Task> action, Func<bool>? enabled = null)
    {
        XamlRoot? ownerRoot = null;
        menu.Opening += (_, _) => ownerRoot = menu.Target?.XamlRoot;
        return Add(menu, title, async () =>
        {
            var root = ownerRoot ?? menu.Target?.XamlRoot;
            try { await action(); }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine(ex);
                if (root is null) return;
                try
                {
                    await new ContentDialog { XamlRoot = root, Title = "Action could not finish", Content = ex.Message, CloseButtonText = "Close" }.ShowAsync();
                }
                catch { /* The owning window may have closed while the action was running. */ }
            }
        }, enabled);
    }

    public static void Copy(MenuFlyout menu, string title, Func<string> text) =>
        Add(menu, title, () => { var data = new DataPackage(); data.SetText(text()); Clipboard.SetContent(data); });

    public static void Invoke(Button button)
    {
        if (!button.IsEnabled) return;
        var peer = FrameworkElementAutomationPeer.FromElement(button) ?? new ButtonAutomationPeer(button);
        (peer.GetPattern(PatternInterface.Invoke) as IInvokeProvider)?.Invoke();
    }

    public static void AddButton(MenuFlyout menu, Button button, string? title = null)
    {
        title ??= AutomationProperties.GetName(button);
        if (string.IsNullOrEmpty(title) && button.Content is string label) title = label;
        if (string.IsNullOrEmpty(title) && button.Content is Panel panel)
            title = string.Join(" ", panel.Children.OfType<TextBlock>().Select(t => t.Text));
        if (!string.IsNullOrEmpty(title)) Add(menu, title, () => Invoke(button), () => button.IsEnabled);
    }

    public static void AddButtons(MenuFlyout menu, Panel actions)
    {
        foreach (var button in actions.Children.OfType<Button>()) AddButton(menu, button);
    }
}
