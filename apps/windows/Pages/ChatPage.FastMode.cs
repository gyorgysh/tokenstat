// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Text.Json.Nodes;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal sealed partial class ChatPage
{
    private Button? _fastModeButton;
    private bool _savingFastMode;

    private Button FastModeButton()
    {
        var button = Buttons.ToolbarIcon(ActionIcon.FastMode, "", async (_, _) =>
        {
            if (FastModeLocked() || _savingFastMode || _opening) return;
            _savingFastMode = true;
            RefreshFastModeButton();
            try
            {
                await UpdateAsync(new JsonObject
                {
                    ["fastMode"] = !Format.Flag(_openChat, "fastMode"),
                    ["expectedRevision"] = Format.Long(_openChat, "sendRevision"),
                });
            }
            finally { _savingFastMode = false; RefreshFastModeButton(); }
        });
        _fastModeButton = button;
        AutomationProperties.SetAutomationId(button, "chat.fastMode");
        button.PointerExited += (_, _) => RefreshFastModeButton();
        button.PointerEntered += (_, _) =>
        {
            if (Format.Flag(_openChat, "fastMode")) button.Foreground = Theme.AccentBrush;
        };
        RefreshFastModeButton();
        return button;
    }

    private bool FastModeLocked() => Busy() && !(Format.Flag(_openChat, "running")
        && Format.Flag(Backend(Format.Text(_openChat, "backend")), "fastModeLive"));

    private void RefreshFastModeButton()
    {
        if (_fastModeButton is not { } button) return;
        var backend = Backend(Format.Text(_openChat, "backend"));
        var models = backend?["fastModeModels"] as JsonArray;
        var available = ChatFastMode.Available(Format.Text(_openChat, "model"), models);
        var fast = Format.Flag(_openChat, "fastMode");
        var title = fast ? L10n.Text("common.chat.fast_mode_priority") : L10n.Text("common.chat.fast_mode_default");
        var help = available
            ? title + ". " + (Format.Text(_openChat, "backend") == "claude" ? L10n.Text("common.chat.fast_mode_claude_help") : L10n.Text("common.chat.fast_mode_codex_help"))
                + " " + (Format.Flag(backend, "fastModeLive") ? L10n.Text("common.chat.fast_mode_live_help") : L10n.Text("common.chat.fast_mode_next_turn_help"))
            : L10n.Text("common.chat.fast_mode_select_opus");
        button.Visibility = models is null ? Visibility.Collapsed : Visibility.Visible;
        button.IsEnabled = available && !FastModeLocked() && !_savingFastMode && !_opening;
        button.Background = fast ? Theme.AccentSoftBrush : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        button.Foreground = fast ? Theme.AccentBrush : Theme.Brush(static () => Theme.ControlGlyph);
        ToolTipService.SetToolTip(button, help);
        AutomationProperties.SetName(button, title);
        AutomationProperties.SetHelpText(button, help);
    }
}
