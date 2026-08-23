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

internal sealed class HomePage : Page
{
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly TextBlock _status = new() { Opacity = 0.7, TextWrapping = TextWrapping.Wrap };

    public HomePage()
    {
        var chrome = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            Children =
            {
                ActionIconGlyph.Button("Scan", ActionIcon.Refresh, async (_, _) => await ScanAsync()),
                ActionIconGlyph.Button("Refresh", ActionIcon.Refresh, async (_, _) => await LoadAsync()),
            },
        };
        _root.Children.Add(chrome);
        _root.Children.Add(_status);
        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL),
            Content = _root,
        };
        Loaded += async (_, _) => await LoadAsync();
    }

    private async Task ScanAsync()
    {
        _status.Text = "Scanning local logs…";
        try
        {
            await AppServices.Host.CallAsync("scan", patience: TimeSpan.FromMinutes(10));
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
            return;
        }
        await LoadAsync();
    }

    private async Task LoadAsync()
    {
        _status.Text = "Loading…";
        JsonNode calendar;
        JsonNode totals;
        JsonNode limits;
        try
        {
            calendar = await AppServices.Host.CallAsync(
                "activity.calendar",
                new JsonObject { ["weeks"] = 53, ["scope"] = "account" });
            totals = await AppServices.Host.CallAsync("totals");
            try
            {
                limits = await AppServices.Host.CallAsync("usage.limits");
            }
            catch
            {
                limits = new JsonArray();
            }
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
            return;
        }

        while (_root.Children.Count > 2)
        {
            _root.Children.RemoveAt(2);
        }

        var notice = Format.Text(calendar, "notice");
        var scope = Format.Text(calendar, "scope", "local");
        _status.Text = string.IsNullOrEmpty(notice)
            ? (scope == "account" ? "Every device on the account." : "This device.")
            : notice;

        var counters = totals["counters"];
        var stats = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceL };
        stats.Children.Add(Chrome.Stat("Events", Format.Tokens(Format.Long(totals, "events"))));
        stats.Children.Add(Chrome.Stat("Tokens", Format.Tokens(Format.Long(counters, "total"))));
        stats.Children.Add(Chrome.Stat("Days", Format.Long(totals, "days").ToString()));
        _root.Children.Add(Chrome.Card("This archive", stats));

        _root.Children.Add(Chrome.Card("Activity", BuildHeatmap(calendar), subtitle: StreakLine(calendar)));
        _root.Children.Add(LimitsCard(limits));
    }

    private static string StreakLine(JsonNode calendar)
    {
        var current = Format.Long(calendar, "streakCurrent");
        var best = Format.Long(calendar, "streakBest");
        var active = Format.Long(calendar, "activeDays");
        return $"{active} active days · streak {current} (best {best})";
    }

    private static UIElement BuildHeatmap(JsonNode calendar)
    {
        var rows = calendar["rows"] as JsonArray;
        if (rows is null || rows.Count == 0)
        {
            return Chrome.Empty("No activity yet", "Scan local logs to fill the year.", Symbol.FourBars);
        }

        // Host sends seven weekday rows, Monday first, each cell a week column.
        var weekCount = 0;
        foreach (var row in rows)
        {
            if (row is JsonArray cells)
            {
                weekCount = Math.Max(weekCount, cells.Count);
            }
        }
        if (weekCount == 0)
        {
            return Chrome.Empty("No activity yet", "Scan local logs to fill the year.", Symbol.FourBars);
        }

        var grid = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        for (var week = 0; week < weekCount; week++)
        {
            var col = new StackPanel { Spacing = 2 };
            foreach (var row in rows)
            {
                JsonNode? cell = null;
                if (row is JsonArray cells && week < cells.Count)
                {
                    cell = cells[week];
                }
                var level = 0;
                if (cell is not null && cell.GetValueKind() != System.Text.Json.JsonValueKind.Null)
                {
                    level = (int)Format.Long(cell, "level");
                }
                col.Children.Add(Chrome.HeatCell(level, 11));
            }
            grid.Children.Add(col);
        }
        return new ScrollViewer
        {
            HorizontalScrollMode = ScrollMode.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollMode = ScrollMode.Disabled,
            Content = grid,
        };
    }

    private static UIElement LimitsCard(JsonNode limits)
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        if (limits is JsonArray { Count: > 0 } list)
        {
            foreach (var item in list)
            {
                var source = Format.Text(item, "source", "Plan");
                var plan = Format.Text(item, "plan");
                var note = Format.Text(item, "note");
                var stale = Format.Flag(item, "stale");
                var title = string.IsNullOrEmpty(plan) ? source : $"{source} · {plan}";
                if (stale)
                {
                    title += " (cached)";
                }
                body.Children.Add(new TextBlock
                {
                    Text = title,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                });
                if (item?["windows"] is JsonArray { Count: > 0 } windows)
                {
                    foreach (var window in windows)
                    {
                        var label = Format.Text(window, "label", "window");
                        var percent = Format.Number(window, "percent");
                        body.Children.Add(new TextBlock
                        {
                            Text = $"{label}: {percent:0}% used",
                            Opacity = 0.8,
                        });
                    }
                }
                else if (!string.IsNullOrEmpty(note))
                {
                    body.Children.Add(new TextBlock
                    {
                        Text = note,
                        Opacity = 0.7,
                        TextWrapping = TextWrapping.Wrap,
                    });
                }
            }
        }
        else
        {
            body.Children.Add(new TextBlock
            {
                Text = "No vendor plan figures on this machine. That is not the same as zero.",
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        return Chrome.Card("What is left", body, "Vendor quotas, not a tokenstat charge.");
    }
}
