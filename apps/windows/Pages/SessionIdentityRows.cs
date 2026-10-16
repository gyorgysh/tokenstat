// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Windows.ApplicationModel.DataTransfer;

namespace Tokenstat.Pages;

internal static class SessionIdentityRows
{
    internal static StackPanel Build(string localId, string localLabel, SessionIdentities sessions, bool showTitle = true,
        bool historyExpanded = false, Action<bool>? historyChanged = null)
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        if (showTitle) body.Children.Add(new TextBlock { Text = L10n.Text("common.session_identity.title"), FontWeight = FontWeights.SemiBold });
        if (!string.IsNullOrEmpty(localId) && !localId.StartsWith("pending-", StringComparison.Ordinal)) body.Children.Add(Row(L10n.Text(localLabel), localId));
        var history = new StackPanel { Spacing = Theme.SpaceS };
        foreach (var entry in sessions.Entries)
        {
            var state = entry.Status switch { "current" => "common.session_identity.current", "saved" => "common.session_identity.saved", _ => "common.session_identity.previous" };
            (entry.Status == "current" ? body : history).Children.Add(Row(L10n.Text(state, BackendLabel(entry.Backend)), entry.Id));
        }
        foreach (var source in sessions.SourceConversationIds.Where(source => source != localId))
            history.Children.Add(Row(L10n.Text("common.session_identity.previous", L10n.Text("common.session_identity.conversation")), source));
        if (history.Children.Count > 0)
        {
            var previous = new Expander { Header = L10n.Text("common.history"),
                Content = new ScrollViewer { Content = history, MaxHeight = 280 }, IsExpanded = historyExpanded,
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            previous.Expanding += (_, _) => historyChanged?.Invoke(true);
            previous.Collapsed += (_, _) => historyChanged?.Invoke(false);
            body.Children.Add(previous);
        }
        if (sessions.Entries.Count == 0) body.Children.Add(Help(L10n.Text("common.session_identity.not_reported")));
        if (sessions.Truncated) body.Children.Add(Help(L10n.Text("common.session_identity.truncated", $"{sessions.Entries.Count}", $"{sessions.Total}")));
        body.Children.Add(Help(L10n.Text("common.session_identity.history_help")));
        return body;
    }

    private static string BackendLabel(string backend) => backend switch {
        "claude" => "Claude", "codex" => "Codex", "grok" => "Grok", "muse" => "Muse",
        "cursor" => "Cursor", "opencode" or "opencode2" => "OpenCode", "agy" => "Antigravity", _ => backend,
    };

    private static TextBlock Help(string text) => new() { Text = text, FontSize = 11, Opacity = .65, TextWrapping = TextWrapping.Wrap };

    private static Button Row(string label, string id)
    {
        var row = new Grid { ColumnSpacing = Theme.SpaceS };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var text = new StackPanel { Spacing = 2 };
        text.Children.Add(Help(label));
        text.Children.Add(new TextBlock { Text = id, FontFamily = Fonts.Mono, FontSize = 11,
            TextWrapping = TextWrapping.Wrap, MaxLines = 2, TextTrimming = TextTrimming.CharacterEllipsis });
        row.Children.Add(text);
        var icon = new ContentControl { Content = ActionIcon.Copy.Icon(), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(icon, 1); row.Children.Add(icon);
        var copy = new Button { Content = row, MinHeight = 40, HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch };
        copy.Click += (_, _) => {
            try {
                var data = new DataPackage(); data.SetText(id); Clipboard.SetContent(data);
                icon.Content = ActionIcon.Done.Icon();
                ToolTipService.SetToolTip(copy, L10n.Text("common.session_identity.copied"));
                AutomationProperties.SetHelpText(copy, L10n.Text("common.session_identity.copied"));
            } catch { }
        };
        var help = L10n.Text("common.session_identity.copy", label);
        AutomationProperties.SetName(copy, help + ": " + id);
        ToolTipService.SetToolTip(copy, help + "\n" + id);
        return copy;
    }
}
