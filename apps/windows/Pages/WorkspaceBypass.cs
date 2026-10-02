// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>
/// Whether tools launched in a project skip their permission prompts, per
/// project, like the Mac's Bypass switch. Off unless somebody turned it on:
/// an agent that asks before acting is the default everywhere.
///
/// A plain file, not LocalSettings: this app is unpackaged, and
/// ApplicationData.Current throws there.
/// </summary>
internal static class WorkspaceBypass
{
    private static readonly object Gate = new();

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "tokenstat",
        "workspace-bypass.json");

    public static bool IsOn(string workspaceId)
    {
        lock (Gate)
        {
            return Read()[workspaceId] is JsonValue value
                && value.TryGetValue<bool>(out var on) && on;
        }
    }

    public static void Set(string workspaceId, bool on)
    {
        lock (Gate)
        {
            var all = Read();
            if (on) all[workspaceId] = true;
            else all.Remove(workspaceId);
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                File.WriteAllText(FilePath, all.ToJsonString());
            }
            catch
            {
                // Not remembered, so the next launch asks first. The safe way
                // to lose this setting.
            }
        }
    }

    private static JsonObject Read()
    {
        try
        {
            return File.Exists(FilePath) && JsonNode.Parse(File.ReadAllText(FilePath)) is JsonObject all
                ? all
                : new JsonObject();
        }
        catch
        {
            return new JsonObject();
        }
    }

    /// <summary>
    /// The Mac's Bypass switch, for the bar over a project's launcher and
    /// terminals: a lock and a word, amber while on, so what it turns off
    /// stays visible for as long as it is off. Read again at every launch.
    /// </summary>
    public static Button Control(string workspaceId, Action changed)
    {
        var on = IsOn(workspaceId);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(new FontIcon { Glyph = on ? "\uE785" : "\uE72E", FontSize = 12 }); // Unlock, Lock
        row.Children.Add(new TextBlock
        {
            Text = on ? L10n.Text("windows.workspacepage.bypass_on.57526f50") : L10n.Text("windows.workspacepage.bypass_off.bd6707b9"),
            FontSize = 12,
        });
        var tip = on
            ? L10n.Text("windows.workspacepage.launches_here_skip_permission_prompts_shel.b6b1d520")
            : L10n.Text("windows.workspacepage.launches_here_ask_before_acting_turn_on_to.7f74555d");
        var button = new Button
        {
            Content = row,
            Foreground = on ? Theme.Brush(static () => Theme.Warning) : Theme.Brush(static () => Theme.ControlGlyph),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(8, 0, 8, 0),
            Height = 30,
            MinHeight = 0,
            MinWidth = 0,
            VerticalAlignment = VerticalAlignment.Center,
        };
        // The template's hover and pressed states repaint the text in the
        // default colour, which turned the amber "on" grey under the pointer.
        button.Resources["ButtonForegroundPointerOver"] = button.Foreground;
        button.Resources["ButtonForegroundPressed"] = button.Foreground;
        button.Resources["ButtonBackgroundPointerOver"] = Theme.Brush(static () => Theme.RowHighlight);
        ToolTipService.SetToolTip(button, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(button, "workspace.bypass");
        button.Click += (_, _) =>
        {
            Set(workspaceId, !on);
            changed();
        };
        return button;
    }
}
