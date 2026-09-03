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

internal sealed class InsightsPage : Page
{
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly ComboBox _group = new();

    public InsightsPage()
    {
        _group.Items.Add("model");
        _group.Items.Add("source");
        _group.Items.Add("project");
        _group.Items.Add("day");
        _group.SelectedIndex = 0;
        _group.SelectionChanged += async (_, _) => await LoadAsync();

        var chrome = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            Children =
            {
                _group,
                ActionIconGlyph.Button("Refresh", ActionIcon.Refresh, async (_, _) => await LoadAsync()),
            },
        };
        _root.Children.Add(chrome);
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
        var group = _group.SelectedItem as string ?? "model";
        JsonNode rows;
        try
        {
            // Proto 5 coherent snapshot first (what the Mac uses); fall back
            // to the legacy report when the host is older.
            try
            {
                var snapshot = await AppServices.Host.CallAsync("insights.snapshot", new JsonObject());
                rows = PickSnapshotGroup(snapshot, group) ?? await AppServices.Host.CallAsync(
                    "report",
                    new JsonObject { ["group"] = group });
            }
            catch (HostException ex) when (ex.Code.Contains("unknown", StringComparison.OrdinalIgnoreCase))
            {
                rows = await AppServices.Host.CallAsync(
                    "report",
                    new JsonObject { ["group"] = group });
            }
        }
        catch (Exception ex)
        {
            _root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }

        if (rows is not JsonArray array || array.Count == 0)
        {
            _root.Children.Add(Chrome.Empty(
                "Nothing in this window",
                "Scan local logs, or pick a different grouping.",
                Symbol.FourBars));
            return;
        }

        var list = new StackPanel { Spacing = Theme.SpaceS };
        foreach (var row in array)
        {
            var key = Format.Text(row, "key", "(unknown)");
            var estimated = Format.Flag(row, "estimated");
            var value = (estimated ? "~" : "") + Format.ListRate(Format.Long(row, "valueMicros"));
            var tokens = Format.Tokens(Format.Long(row?["counters"], "total"));
            var line = new Grid();
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var name = new TextBlock { Text = key, TextTrimming = TextTrimming.CharacterEllipsis };
            var tok = new TextBlock { Text = tokens, Margin = new Thickness(12, 0, 12, 0), Opacity = 0.7 };
            var money = new TextBlock { Text = value, FontWeight = Microsoft.UI.Text.FontWeights.Medium };
            Grid.SetColumn(tok, 1);
            Grid.SetColumn(money, 2);
            line.Children.Add(name);
            line.Children.Add(tok);
            line.Children.Add(money);
            list.Children.Add(line);
        }
        _root.Children.Add(Chrome.Card(
            "By " + group,
            list,
            "List-rate equivalent, not a charge."));
    }

    private static JsonNode? PickSnapshotGroup(JsonNode? snapshot, string group)
    {
        if (snapshot is null) return null;
        return group switch
        {
            "model" => snapshot["byModel"] ?? snapshot["by_model"],
            "source" => snapshot["bySource"] ?? snapshot["by_source"],
            "project" => snapshot["byProject"] ?? snapshot["by_project"],
            "day" => snapshot["daily"],
            _ => null,
        };
    }
}
