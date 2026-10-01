// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed partial class HomePage
{
    private readonly StackPanel _pinsHost = new();
    private string? _pinScope;
    private int _pinsGeneration;
    private void PinsChanged() => DispatcherQueue.TryEnqueue(RenderPins);
    private void PinsAccountChanged()
    {
        _pinScope = null;
        _pinsHost.Children.Clear();
        _ = RefreshPinsAsync();
    }
    private async Task RefreshPinsAsync()
    {
        var generation = ++_pinsGeneration;
        try
        {
            var status = await AppServices.Host.CallAsync("account.status");
            if (generation != _pinsGeneration) return;
            _pinScope = BrowserProjectMemory.Scope(status);
        }
        catch { if (generation == _pinsGeneration) _pinScope = null; }
        if (generation == _pinsGeneration) RenderPins();
    }
    private void RenderPins()
    {
        _pinsHost.Children.Clear();
        if (_pinScope is null) return;
        var pins = PinnedWorkStore.Shared.Read(_pinScope);
        if (pins.Count == 0) return;
        var list = new StackPanel { Spacing = Theme.SpaceXs };
        foreach (var pin in pins)
        {
            var text = new StackPanel { Spacing = 2 };
            text.Children.Add(new TextBlock { Text = pin.Label, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            text.Children.Add(new TextBlock { Text = pin.ChatId.Length == 0 ? L10n.Text("windows.homepage_pins.project.98595978") : pin.FolderName + L10n.Text("windows.homepage_pins.chat.4ff6f16b"), TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1, FontSize = 11, Opacity = 0.65 });
            var button = new Button { Content = text, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            button.Click += async (_, _) =>
            {
                var current = await BrowserProjectMemory.ForAsync(pin.WorkspaceId);
                if (current?.Owner != pin.Owner || current.AccountScope != pin.AccountScope) return;
                if (pin.ChatId.Length == 0) AppServices.OpenWorkspace?.Invoke(pin.WorkspaceId, WorkspaceSection.Launcher);
                else AppServices.OpenConversation?.Invoke(pin.WorkspaceId, pin.ChatId);
            };
            ContextMenus.Add(ContextMenus.Menu(button), L10n.Text("windows.homepage_pins.unpin_from_home.df00f5de"), () => PinnedWorkStore.Shared.Remove(pin.Owner, pin.ChatId));
            list.Children.Add(button);
        }
        _pinsHost.Children.Add(Chrome.Card(L10n.Text("windows.homepage_pins.pinned_work.23dd8f45"), list, mark: Chrome.CardMark(ActionIcon.Pin)));
    }
}
