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
/// The screen the window opens on. Answers what is left before starting:
/// who is signed in, today and this week at list rates, the year grid, the
/// devices on the account, and what each vendor reports is left.
/// </summary>
internal sealed class HomePage : Page
{
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _signSlot = new() { Spacing = Theme.SpaceL };
    private readonly TextBlock _status = new() { Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
    private string _scope = "account";
    private bool _scanning;

    public HomePage()
    {
        var chrome = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            Children =
            {
                ActionIconGlyph.Button("Scan", ActionIcon.Run, async (_, _) => await ScanAsync()),
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
        if (_scanning)
        {
            return;
        }
        _scanning = true;
        _status.Text = "Scanning local logs…";
        try
        {
            await AppServices.Host.CallAsync("scan", patience: TimeSpan.FromMinutes(10));
        }
        catch (Exception ex)
        {
            _status.Text = FriendlyError.Display(ex.Message);
            _scanning = false;
            return;
        }
        _scanning = false;
        await LoadAsync();
    }

    private async Task LoadAsync()
    {
        while (_root.Children.Count > 2)
        {
            _root.Children.RemoveAt(2);
        }
        _status.Text = "Loading…";
        // A wireframe shaped like the cards coming, with a light pulse so the
        // wait does not feel frozen. Real content replaces it with an arrival.
        var skeleton = Motion.SkeletonCard();
        _root.Children.Add(skeleton);

        JsonNode? account = null;
        JsonNode? calendar = null;
        string? calendarError = null;
        JsonNode? totals = null;
        JsonNode limits = new JsonArray();
        JsonNode? limitsSync = null;
        try
        {
            account = await AppServices.Host.CallAsync("account.status");
        }
        catch (Exception ex)
        {
            _root.Children.Remove(skeleton);
            _status.Text = "";
            _root.Children.Add(Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            return;
        }
        try
        {
            calendar = await AppServices.Host.CallAsync(
                "activity.calendar",
                new JsonObject { ["weeks"] = 53, ["scope"] = _scope });
        }
        catch (Exception ex)
        {
            calendarError = FriendlyError.Display(ex.Message);
        }
        try
        {
            totals = await AppServices.Host.CallAsync("totals");
        }
        catch
        {
            // The archive totals are a footnote. The grid is the screen.
        }
        try
        {
            limits = await AppServices.Host.CallAsync("usage.limits");
        }
        catch
        {
            limits = new JsonArray();
        }
        try
        {
            limitsSync = await AppServices.Host.CallAsync(
                "config.limitsSync", new JsonObject());
        }
        catch
        {
            // Sharing stays unoffered rather than wrong.
        }
        _root.Children.Remove(skeleton);
        _status.Text = "";

        if (calendar is not JsonObject)
        {
            calendar = null;
        }
        var noticeCode = calendar is null ? "" : Format.Text(calendar, "noticeCode");
        var signedIn = account?["signedIn"]?.GetValue<bool>() ?? false;

        _root.Children.Add(_signSlot);
        _root.Children.Add(ScopeRow());
        if (!string.IsNullOrEmpty(calendarError))
        {
            _root.Children.Add(Chrome.Banner(calendarError, Theme.Danger, Symbol.Important));
        }
        if (noticeCode == "auth")
        {
            _root.Children.Add(SignInPrompt(signedIn));
        }
        _root.Children.Add(ProfileCard(account, calendar));
        _root.Children.Add(UsageSummary(calendar, calendarError));
        _root.Children.Add(ActivityCard(calendar, calendarError, signedIn));
        // The year is already on screen. This says why the older squares are
        // muted and offers the page that unlocks them.
        if (calendar is not null && Format.Flag(calendar, "historyLocked"))
        {
            var days = Format.Long(calendar, "historyDays");
            _root.Children.Add(EmptyState.HistoryLockBanner(days <= 0 ? 30 : (int)days));
        }
        if (signedIn)
        {
            _root.Children.Add(DevicesCard(account));
        }
        _root.Children.Add(LimitsCard(limits));
        if (signedIn
            && limits is JsonArray { Count: > 0 }
            && !(limitsSync?["enabled"]?.GetValue<bool>() ?? false))
        {
            _root.Children.Add(LimitsSyncHint());
        }
        if (totals is not null)
        {
            _root.Children.Add(ArchiveFootnote(totals));
        }
    }

    /// <summary>What the grid counts: this PC, or every device on the account.</summary>
    private UIElement ScopeRow()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        var scope = _scope;
        row.Children.Add(Chrome.ChoiceChip("This device", scope == "local", async () =>
        {
            _scope = "local";
            await LoadAsync();
        }));
        row.Children.Add(Chrome.ChoiceChip("All devices", scope == "account", async () =>
        {
            _scope = "account";
            await LoadAsync();
        }));
        return row;
    }

    /// <summary>
    /// The account grid fell back because a sign-in is missing or stale. The
    /// heatmap below is this PC's own year, so offer the fix where the failure
    /// is rather than quoting a command at somebody already in the app.
    /// </summary>
    private UIElement SignInPrompt(bool signedIn)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        row.Children.Add(new TextBlock
        {
            Text = "All devices needs your tokenstat.ai account.",
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
        });
        row.Children.Add(ActionIconGlyph.Button(
            signedIn ? "Reconnect" : "Sign in",
            ActionIcon.SignIn,
            async (_, _) => await SignInFlow.RunAsync(this, _signSlot, LoadAsync)));
        var banner = new Border
        {
            Background = Theme.AccentSoftBrush,
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.SpaceM),
            Child = row,
        };
        return banner;
    }

    /// <summary>
    /// Local-clock person, first. Signed out stays literal: the handle, and
    /// nothing else. Streaks sit beside the name because they are about the
    /// person, and the card below is about the data.
    /// </summary>
    private static UIElement ProfileCard(JsonNode? account, JsonNode? calendar)
    {
        var title = Format.Text(account, "displayName", Format.Text(account, "handle"));
        if (string.IsNullOrEmpty(title))
        {
            title = "Not signed in";
        }
        var handle = Format.Text(account, "handle");
        var tier = Format.Text(account, "tier");
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceM };
        var who = new StackPanel { Spacing = 3 };
        var nameRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        nameRow.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 20,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        if (!string.IsNullOrEmpty(tier))
        {
            nameRow.Children.Add(Chrome.TierBadge(tier));
        }
        who.Children.Add(nameRow);
        if (!string.IsNullOrEmpty(handle) && handle != title)
        {
            who.Children.Add(new TextBlock { Text = "@" + handle, Opacity = 0.7 });
        }
        else if (!(account?["signedIn"]?.GetValue<bool>() ?? false))
        {
            who.Children.Add(new TextBlock { Text = "Working locally", Opacity = 0.7 });
        }
        head.Children.Add(who);
        if (calendar is not null)
        {
            var spacer = new Border { Width = Theme.SpaceL };
            head.Children.Add(spacer);
            head.Children.Add(Chrome.Stat(
                "Streak", Format.Long(calendar, "streakCurrent").ToString(), "days"));
            head.Children.Add(Chrome.Stat(
                "Best", Format.Long(calendar, "streakBest").ToString(), "days"));
            head.Children.Add(Chrome.Stat(
                "Active", Format.Long(calendar, "activeDays").ToString(), "days"));
        }
        return Chrome.Card("Today", head);
    }

    /// <summary>
    /// One figure per stat, like the phone's tiles. Built from the same series
    /// as the heatmap, so the two cannot disagree.
    /// </summary>
    private static UIElement UsageSummary(JsonNode? calendar, string? error)
    {
        if (calendar is not null)
        {
            var cells = DatedCells(calendar);
            var last = Format.Text(calendar, "last");
            var today = cells.FindLast(c => c.Date == last);
            var week = 0L;
            for (var i = Math.Max(0, cells.Count - 7); i < cells.Count; i++)
            {
                week += cells[i].Value;
            }
            var busiest = calendar["busiest"];
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceL };
            row.Children.Add(Chrome.Stat("Today", Format.ListRate(today?.Value ?? 0)));
            row.Children.Add(Chrome.Stat("Last 7 days", Format.ListRate(week)));
            if (busiest is not null)
            {
                row.Children.Add(Chrome.Stat(
                    "Busiest",
                    Format.ListRate(Format.Long(busiest, "value")),
                    Format.Text(busiest, "date")));
            }
            return Chrome.Card("Today and this week", row);
        }
        var body = new TextBlock
        {
            Text = error is null
                ? "Nothing counted yet. Run the first scan below."
                : "Usage could not be read. See the message above.",
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        };
        return Chrome.Card("Today and this week", body);
    }

    private sealed record DatedCell(string Date, long Value);

    private static List<DatedCell> DatedCells(JsonNode calendar)
    {
        var outCells = new List<DatedCell>();
        if (calendar["rows"] is JsonArray rows)
        {
            foreach (var row in rows)
            {
                if (row is not JsonArray cells)
                {
                    continue;
                }
                foreach (var cell in cells)
                {
                    if (cell is null
                        || cell.GetValueKind() == System.Text.Json.JsonValueKind.Null)
                    {
                        continue;
                    }
                    var date = Format.Text(cell, "date");
                    if (string.IsNullOrEmpty(date))
                    {
                        continue;
                    }
                    outCells.Add(new DatedCell(date, Format.Long(cell, "value")));
                }
            }
        }
        outCells.Sort((a, b) => string.Compare(a.Date, b.Date, StringComparison.Ordinal));
        return outCells;
    }

    /// <summary>
    /// What the figures under the title are counting, said plainly. Asked for
    /// and got are not the same grid, and a grid that quietly fell back to
    /// local while the control still says All devices would report one PC's
    /// spend as everybody's.
    /// </summary>
    private UIElement ActivityCard(JsonNode? calendar, string? error, bool signedIn)
    {
        if (calendar is null)
        {
            if (error is null)
            {
                return GettingStarted(signedIn);
            }
            return Chrome.Card(
                "Activity",
                new TextBlock
                {
                    Text = "The activity could not be read. See the message above.",
                    Opacity = 0.7,
                    TextWrapping = TextWrapping.Wrap,
                },
                "What each day was worth at list rates");
        }
        var total = Format.ListRate(Format.Long(calendar, "total"));
        var active = Format.Long(calendar, "activeDays");
        var delivered = Format.Text(calendar, "scope", "local");
        var source = delivered == "account"
            ? ", across every device on your account"
            : ", on this device";
        var subtitle = $"{total} at list rates over {active} active days" + source;
        var notice = Format.Text(calendar, "notice");
        if (!string.IsNullOrEmpty(notice) && Format.Text(calendar, "noticeCode") != "auth")
        {
            subtitle += ". " + notice;
        }
        return Chrome.Card("Activity", BuildHeatmap(calendar), subtitle);
    }

    /// <summary>
    /// The first thing Home shows on a PC that has never scanned. Three steps,
    /// and the first one arrives done: installing is behind you, you are
    /// looking at the app. Signing in is step three and it is not a wall.
    /// </summary>
    private UIElement GettingStarted(bool signedIn)
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(new TextBlock
        {
            Text = "It reads the logs the tools you already use leave on this PC, and turns them into a year you can read.",
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(new TextBlock
        {
            Text = "1. Installed. You are looking at it. Nothing else to put on this PC.",
            TextWrapping = TextWrapping.Wrap,
        });
        var scanRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        scanRow.Children.Add(new TextBlock
        {
            Text = "2. Run the first scan. It reads what is already on disk, so the first grid covers the work you have done, not the work you do next.",
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        });
        scanRow.Children.Add(ActionIconGlyph.Button(
            _scanning ? "Scanning…" : "Scan now", ActionIcon.Run, async (_, _) => await ScanAsync()));
        body.Children.Add(scanRow);
        var signRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        signRow.Children.Add(new TextBlock
        {
            Text = signedIn
                ? "3. Connected to your account. Your devices share one account, so they show these numbers with the lid shut."
                : "3. Add your other devices, if you want them. Optional, and this PC counts either way. Free includes two devices.",
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (!signedIn)
        {
            signRow.Children.Add(ActionIconGlyph.Button(
                "Sign in", ActionIcon.SignIn,
                async (_, _) => await SignInFlow.RunAsync(this, _signSlot, LoadAsync)));
        }
        body.Children.Add(signRow);
        return Chrome.Card("Get tokenstat counting", body);
    }

    private static UIElement DevicesCard(JsonNode? account)
    {
        var machines = account?["machines"] as JsonArray;
        var limit = Format.Long(account, "machineLimit");
        var count = machines?.Count ?? 0;
        string subtitle = machines is null || count == 0
            ? "Every device that has synced to this account"
            : limit > 0 ? $"{count} of {limit} devices" : $"{count} linked";
        var list = new StackPanel { Spacing = Theme.SpaceS };
        if (machines is not null)
        {
            var thisId = Format.Text(account, "thisMachineId");
            foreach (var machine in machines)
            {
                var id = Format.Text(machine, "id");
                if (string.IsNullOrEmpty(id))
                {
                    continue;
                }
                var name = Format.Text(machine, "label", id);
                var mine = id == thisId;
                var row = new StackPanel { Spacing = 2 };
                var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
                title.Children.Add(new TextBlock
                {
                    Text = name,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    TextWrapping = TextWrapping.Wrap,
                });
                if (mine)
                {
                    title.Children.Add(new TextBlock { Text = "THIS PC", Opacity = 0.6, FontSize = 11 });
                }
                row.Children.Add(title);
                row.Children.Add(new TextBlock
                {
                    Text = StatusLine(machine, mine),
                    Opacity = 0.7,
                    FontSize = 12,
                });
                list.Children.Add(row);
            }
        }
        if (list.Children.Count == 0)
        {
            list.Children.Add(new TextBlock
            {
                Text = "Nothing linked yet. Sync from Account to put this PC on the account.",
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        return Chrome.Card("Devices", list, subtitle);
    }

    /// <summary>
    /// One caption line under a device's name. The name is the quick read;
    /// this is the answer to when it was last heard from.
    /// </summary>
    internal static string StatusLine(JsonNode? machine, bool isSelf)
    {
        if (isSelf)
        {
            return "This device";
        }
        var kind = Format.Text(machine, "kind");
        if (kind == "client")
        {
            if (Format.Flag(machine, "online"))
            {
                return "Phone · in the app now";
            }
            var seen = Format.Text(machine, "lastSeenAt");
            if (!string.IsNullOrEmpty(seen))
            {
                return "Phone · last used " + Format.Relative(seen);
            }
            return "Phone · signed in on this account";
        }
        if (string.IsNullOrEmpty(Format.Text(machine, "publicIdentity")))
        {
            return "No connection key yet";
        }
        if (!Format.Flag(machine, "online") && machine?["online"] is not null)
        {
            var seen = Format.Text(machine, "lastSeenAt");
            return string.IsNullOrEmpty(seen)
                ? "Offline"
                : "Offline · last seen " + Format.Relative(seen);
        }
        var synced = Format.Text(machine, "lastSyncAt");
        if (!string.IsNullOrEmpty(synced))
        {
            return "Last synced " + Format.Relative(synced);
        }
        return "No sync recorded";
    }

    /// <summary>
    /// A line offering the setting that would put these numbers on your other
    /// devices. It says what the other devices show today rather than naming
    /// the switch, because the reason to want this is the other screen being
    /// empty. The switch itself lives on Account.
    /// </summary>
    private static UIElement LimitsSyncHint()
    {
        var body = new StackPanel { Spacing = 2 };
        body.Children.Add(new TextBlock
        {
            Text = "Your other devices cannot see these numbers",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(new TextBlock
        {
            Text = "Account has a Plan limits card that posts how full each window is, "
                + "so they still show what is left while this PC is asleep. "
                + "Turn a vendor off there if you do not want it shared.",
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        return Chrome.Card("Share plan usage", body);
    }

    private static UIElement ArchiveFootnote(JsonNode totals)
    {
        var counters = totals["counters"];
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceL };
        row.Children.Add(Chrome.Stat("Events", Format.Tokens(Format.Long(totals, "events"))));
        row.Children.Add(Chrome.Stat("Tokens", Format.Tokens(Format.Long(counters, "total"))));
        row.Children.Add(Chrome.Stat("Days", Format.Long(totals, "days").ToString()));
        return Chrome.Card("This archive", row);
    }

    private static UIElement BuildHeatmap(JsonNode calendar)
    {
        var rows = calendar["rows"] as JsonArray;
        if (rows is null || rows.Count == 0)
        {
            return EmptyState.View("No activity yet", "Scan local logs to fill the year.", EmptyArtKind.FirstBars);
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
            return EmptyState.View("No activity yet", "Scan local logs to fill the year.", EmptyArtKind.FirstBars);
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
                        // Codex reports the account's own allowance beside the
                        // running model's, and both are weekly. Without the
                        // scope the two rows read as one limit stated twice.
                        var scope = Format.Text(window, "scope", "");
                        if (!string.IsNullOrEmpty(scope) && scope != "primary")
                        {
                            if (scope == "secondary")
                            {
                                label = $"{label} (all models)";
                            }
                            else if (scope == "current model")
                            {
                                label = $"{label} (secondary)";
                            }
                            else
                            {
                                label = $"{label} ({scope})";
                            }
                        }
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
