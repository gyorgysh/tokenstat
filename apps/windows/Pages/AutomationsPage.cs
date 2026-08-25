// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>
/// Scheduled jobs on this host. Enable, disable, and Run. The editor is on the Mac.
/// </summary>
internal sealed class AutomationsPage : Page
{
    private readonly string? _workspaceId;
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };

    public AutomationsPage(string? workspaceId = null)
    {
        _workspaceId = workspaceId;
        _root.Children.Add(ActionIconGlyph.Button(
            "Refresh", ActionIcon.Refresh, async (_, _) => await LoadAsync()));
        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL),
            Content = _root,
        };
        Loaded += async (_, _) => await LoadAsync();
    }

    private async Task LoadAsync()
    {
        while (_root.Children.Count > 1)
        {
            _root.Children.RemoveAt(1);
        }
        JsonNode listed;
        try
        {
            listed = await AppServices.Host.CallAsync("automation.list");
        }
        catch (Exception ex)
        {
            _root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }

        var array = Format.Items(listed);
        var list = new StackPanel { Spacing = Theme.SpaceS };
        if (array is not null)
        {
            foreach (var job in array)
            {
                if (!Format.InWorkspace(job, _workspaceId, includeUnscoped: false))
                {
                    continue;
                }
                var id = Format.Text(job, "id");
                if (string.IsNullOrEmpty(id))
                {
                    continue;
                }
                var name = Format.Text(job, "name", Format.Text(job, "label", "Automation"));
                var enabled = Format.Flag(job, "enabled");
                var cadence = Format.Cadence(job);

                var body = new StackPanel { Spacing = Theme.SpaceS };
                body.Children.Add(new TextBlock
                {
                    Text = name,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    TextWrapping = TextWrapping.Wrap,
                });
                body.Children.Add(new TextBlock
                {
                    Text = (enabled ? "on" : "off") + " · " + cadence,
                    Opacity = 0.7,
                    TextWrapping = TextWrapping.Wrap,
                });
                var actions = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = Theme.SpaceS,
                };
                var jobId = id;
                var jobOn = enabled;
                actions.Children.Add(ActionIconGlyph.Button(
                    jobOn ? "Disable" : "Enable",
                    jobOn ? ActionIcon.Dismiss : ActionIcon.Approve,
                    async (_, _) => await SetEnabledAsync(jobId, !jobOn)));
                actions.Children.Add(ActionIconGlyph.Button("Run", ActionIcon.Run, async (_, _) =>
                {
                    await RunAsync(jobId);
                }));
                body.Children.Add(actions);
                list.Children.Add(body);
            }
        }
        if (list.Children.Count == 0)
        {
            _root.Children.Add(Chrome.Empty(
                "No automations yet",
                "Scheduled jobs run on this host when Always-on is on.",
                Symbol.Flag));
            return;
        }
        _root.Children.Add(Chrome.Card("Automations", list));
    }

    private async Task SetEnabledAsync(string id, bool enabled)
    {
        try
        {
            await AppServices.Host.CallAsync(
                enabled ? "automation.enable" : "automation.disable",
                new JsonObject { ["id"] = id });
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private async Task RunAsync(string id)
    {
        try
        {
            await AppServices.Host.CallAsync("automation.run", new JsonObject { ["id"] = id });
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private void Banner(string text)
    {
        _root.Children.Insert(1, Chrome.Banner(text, Theme.Danger, Symbol.Important));
    }
}
