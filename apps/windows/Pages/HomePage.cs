// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Globalization;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>
/// The screen the window opens on. Answers what is left before starting:
/// who is signed in, the conversations worth going back to, today and this
/// week at list rates, the year grid, what each vendor reports is left, and
/// the devices on the account. Mirrors the Mac Home: the toolbar owns the
/// scope picker, Refresh sits beside it, and a pinned day opens in
/// the inspector column.
/// </summary>
internal sealed class HomePage : Page, IScopeAware, IInspectorContent, IToolbarItems
{
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _signSlot = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _inspectorRoot = new()
    {
        Spacing = Theme.SpaceM,
        Padding = new Thickness(Theme.SpaceM),
    };
    private readonly TextBlock _status = new() { Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
    private HeatmapView? _heatmap;
    private string _scope = "account";
    private string _delivered = "local";
    private bool _scanning;
    private bool _loading;
    private bool _hasContent;
    private bool _reloadRequested;
    private bool _forceNext;

    private JsonNode? _calendar;
    private JsonArray _planLimits = new();
    private JsonArray _planBySource = new();
    private JsonArray _recent = new();
    private string? _planError;

    private string? _hoverDate;
    private string? _selectedDate;
    private readonly Dictionary<string, JsonNode?> _dayCache = new();
    private readonly Dictionary<string, DayOverview> _overviewCache = new();
    private string? _loadingDetailFor;
    private string? _loadingOverviewFor;

    /// <summary>One pinned day's local breakdown, the Mac DayOverview shape.</summary>
    private sealed record DayOverview(
        JsonNode? Totals,
        JsonArray ByModel,
        JsonArray BySource,
        JsonArray ByProject,
        JsonArray BySession);

    /// <summary>One row in an inspector group card.</summary>
    private sealed record DayGroupRow(
        string Key, string Label, long Tokens, string? Value, bool Monospaced);

    public HomePage()
    {
        _root.Children.Add(_status);
        // One spacing unit off the sidebar, like the Mac Home gutter: a card
        // already carries its own padding, so the stack needs only a gutter.
        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceS),
            Content = _root,
        };
        RefreshInspector();
        Loaded += async (_, _) =>
        {
            if (!_hasContent && !_loading)
            {
                await LoadAsync();
            }
        };
    }

    public event Action? ToolbarChanged;

    /// <summary>Global screen: no folder to name.</summary>
    public UIElement? ToolbarScope => null;

    public IList<UIElement> ToolbarActions()
    {
        return new List<UIElement>
        {
            Buttons.ToolbarIcon(
                ActionIcon.Refresh,
                "Re-read the archive for this device's activity and plan usage",
                async (_, _) => await RefreshAsync()),
        };
    }

    /// <summary>
    /// The shell reads this once, at navigation, and keeps the element. Day
    /// changes replace its children, so the column stays live without the
    /// shell ever asking again.
    /// </summary>
    public UIElement? Inspector => _inspectorRoot;

    /// <summary>
    /// The toolbar scope picker pushes here, on navigation and on every
    /// change. The page never reads the toolbar directly.
    /// </summary>
    public void ApplyScope(DeviceScope scope)
    {
        var wire = scope.Wire();
        if (wire == _scope)
        {
            if (!_hasContent && !_loading)
            {
                _ = LoadAsync();
            }
            return;
        }
        _scope = wire;
        // The new grid is a different set of numbers. A cached day from the
        // old one would describe the wrong scope.
        InvalidateDayCaches();
        _ = LoadAsync();
    }

    /// <summary>
    /// Explicit re-read, for the toolbar button and for the shell if it ever
    /// wants its own refresh affordance. Always hits the host, drops the
    /// per-day caches, and re-pins the selected day fresh.
    /// </summary>
    public async Task RefreshAsync()
    {
        LogoRefresh.Began();
        var pinned = _selectedDate;
        InvalidateDayCaches();
        _selectedDate = pinned;
        await LoadAsync(force: true);
        if (pinned is not null && _calendar is not null)
        {
            var fresh = FindDay(_calendar, pinned);
            if (fresh is not null)
            {
                SelectDay(fresh);
                return;
            }
        }
        EnsureSelection();
    }

    private void InvalidateDayCaches()
    {
        _dayCache.Clear();
        _overviewCache.Clear();
        _hoverDate = null;
        _loadingDetailFor = null;
        _loadingOverviewFor = null;
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

    private async Task LoadAsync(bool force = false)
    {
        if (_loading)
        {
            _reloadRequested = true;
            _forceNext |= force;
            return;
        }
        _loading = true;
        try
        {
            do
            {
                _reloadRequested = false;
                force |= _forceNext;
                _forceNext = false;
                await LoadOnceAsync(force);
                force = false;
            }
            while (_reloadRequested);
        }
        finally
        {
            _loading = false;
        }
    }

    private async Task LoadOnceAsync(bool force)
    {
        while (_root.Children.Count > 1)
        {
            _root.Children.RemoveAt(1);
        }
        _status.Text = "Loading…";
        // A wireframe shaped like the cards coming, with a light pulse so the
        // wait does not feel frozen. Real content replaces it with an arrival.
        var skeleton = Motion.SkeletonCard();
        _root.Children.Add(skeleton);

        JsonNode? account;
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
        JsonNode? calendar = null;
        string? calendarError = null;
        try
        {
            calendar = await AppServices.Host.CallAsync(
                "activity.calendar",
                new JsonObject { ["weeks"] = 53, ["scope"] = _scope, ["force"] = force });
        }
        catch (Exception ex)
        {
            calendarError = FriendlyError.Display(ex.Message);
        }
        if (calendar is not JsonObject)
        {
            calendar = null;
        }
        _calendar = calendar;
        // What came back, not what was asked for.
        _delivered = Format.Text(calendar, "scope", "local");
        if (_delivered != "account")
        {
            _delivered = "local";
        }

        JsonNode? totals = null;
        try
        {
            totals = await AppServices.Host.CallAsync("totals");
        }
        catch
        {
            // The archive totals are a footnote. The grid is the screen.
        }

        _planError = null;
        JsonArray limits = new();
        JsonNode? limitsSync = null;
        try
        {
            limitsSync = await AppServices.Host.CallAsync(
                "config.limitsSync", new JsonObject());
        }
        catch
        {
            // Sharing stays unoffered rather than wrong.
        }
        try
        {
            if (await AppServices.Host.CallAsync("usage.limits") is JsonArray list)
            {
                limits = list;
            }
        }
        catch (Exception ex)
        {
            _planError = FriendlyError.Display(ex.Message);
        }
        var skip = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (limitsSync?["skip"] is JsonArray skipped)
        {
            foreach (var item in skipped)
            {
                if (item is JsonValue value
                    && value.TryGetValue<string>(out var source)
                    && !string.IsNullOrEmpty(source))
                {
                    skip.Add(source);
                }
            }
        }
        _planLimits = new JsonArray();
        foreach (var item in limits)
        {
            if (!skip.Contains(Format.Text(item, "source")))
            {
                // Clone out of the host answer. A node keeps its parent, and
                // the filtered list must stand on its own.
                _planLimits.Add(item?.DeepClone());
            }
        }

        _planBySource = new JsonArray();
        try
        {
            var plan = await AppServices.Host.CallAsync(
                "report",
                new JsonObject
                {
                    ["group"] = "source",
                    ["query"] = new JsonObject { ["billing"] = "plan" },
                });
            if (plan is JsonArray rows)
            {
                _planBySource = rows;
            }
        }
        catch (Exception ex)
        {
            _planError ??= FriendlyError.Display(ex.Message);
        }

        _recent = new JsonArray();
        try
        {
            var recent = await AppServices.Host.CallAsync(
                "chat.recent", new JsonObject { ["limit"] = 8 });
            if (recent is JsonArray rows)
            {
                _recent = rows;
            }
        }
        catch
        {
            // Continue is a shortcut, not the screen. An older host that does
            // not report recents simply shows no section.
        }

        _root.Children.Remove(skeleton);
        _status.Text = "";
        _hasContent = true;

        var noticeCode = calendar is null ? "" : Format.Text(calendar, "noticeCode");
        var signedIn = account?["signedIn"]?.GetValue<bool>() ?? false;

        _root.Children.Add(_signSlot);
        if (noticeCode == "auth")
        {
            _root.Children.Add(SignInPrompt(signedIn));
        }
        _root.Children.Add(ProfileCard(account, calendar));
        if (_recent.Count > 0)
        {
            _root.Children.Add(ContinueCard(_recent));
        }
        _root.Children.Add(UsageSummary(calendar, calendarError));
        _root.Children.Add(ActivityCard(calendar, calendarError, signedIn));
        if (_planError is not null)
        {
            _root.Children.Add(Chrome.Banner(_planError, Theme.Danger, Symbol.Important));
        }
        foreach (var panel in PlanPanels(_planLimits, _planBySource))
        {
            _root.Children.Add(panel);
        }
        if (signedIn)
        {
            _root.Children.Add(MachinesCard(account));
        }
        if (signedIn
            && VisibleLimits(_planLimits).Count > 0
            && !(limitsSync?["enabled"]?.GetValue<bool>() ?? false))
        {
            _root.Children.Add(LimitsSyncHint());
        }
        if (totals is not null)
        {
            _root.Children.Add(ArchiveFootnote(totals));
        }
        EnsureSelection();
        RefreshInspector();
    }

    /// <summary>
    /// The inspector is empty until a day is pinned. Open today on first load
    /// so Home is not "pick a day" when the grid is already about this year. A
    /// later click is left alone, including across a quiet refresh. A scope
    /// change re-selects: the cell is the same date, the numbers are not.
    /// </summary>
    private void EnsureSelection()
    {
        if (_calendar is null)
        {
            return;
        }
        if (_selectedDate is not null)
        {
            var same = FindDay(_calendar, _selectedDate);
            if (same is not null)
            {
                SelectDay(same);
                return;
            }
        }
        var last = Format.Text(_calendar, "last");
        if (!string.IsNullOrEmpty(last))
        {
            var today = FindDay(_calendar, last);
            if (today is not null && !today.Locked)
            {
                SelectDay(today);
            }
        }
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
            async (_, _) => await SignInFlow.RunAsync(this, _signSlot, async () => await LoadAsync())));
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
    /// Local-clock greeting plus the first name. Signed out stays literal:
    /// the handle, and nothing else. Streaks sit beside the name because they
    /// are about the person, and the card below is about the data.
    /// </summary>
    private static UIElement ProfileCard(JsonNode? account, JsonNode? calendar)
    {
        var head = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceM,
            VerticalAlignment = VerticalAlignment.Center,
        };
        head.Children.Add(Marks.Avatar(
            url: Format.Text(account, "avatar"),
            name: Format.Text(account, "displayName", Format.Text(account, "handle")),
            handle: Format.Text(account, "handle"),
            size: 52));
        var who = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        var nameRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            VerticalAlignment = VerticalAlignment.Center,
        };
        nameRow.Children.Add(new TextBlock
        {
            Text = GreetingTitle(account, calendar),
            FontSize = 20,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        var tier = Format.Text(account, "tier");
        if (!string.IsNullOrEmpty(tier))
        {
            // The glyph the profile page uses, not the written pill. Beside a
            // 20pt name a crown reads as a mark on the person; a word in a
            // capsule reads as a label stuck to them.
            nameRow.Children.Add(Marks.TierMark(tier, 16) ?? Chrome.TierBadge(tier));
        }
        who.Children.Add(nameRow);
        var handle = Format.Text(account, "handle");
        var title = Format.Text(account, "displayName", handle);
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
        return new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.CardPadding),
            Child = head,
        };
    }

    private static string GreetingTitle(JsonNode? account, JsonNode? calendar)
    {
        var hasHistory = Format.Long(calendar, "activeDays") > 0;
        var title = Format.Text(account, "displayName", Format.Text(account, "handle"));
        if (string.IsNullOrEmpty(title))
        {
            var signedIn = account?["signedIn"]?.GetValue<bool>() ?? false;
            return signedIn ? GreetingPhrase(hasHistory) : "Not signed in";
        }
        return GreetingPhrase(hasHistory) + ", " + FirstName(title);
    }

    /// <summary>
    /// A short greeting from the device clock, stable for the rest of the
    /// local day so a refresh does not swap one phrase for another. Ports the
    /// Mac HomeGreeting pool.
    /// </summary>
    private static string GreetingPhrase(bool hasHistory)
    {
        var now = DateTime.Now;
        string timed = now.Hour switch
        {
            >= 5 and < 12 => "Good morning",
            >= 12 and < 17 => "Good afternoon",
            >= 17 and < 22 => "Good evening",
            _ => "Hello",
        };
        string[] pool =
        [
            timed,
            "Hello",
            "What's up",
            hasHistory ? "Welcome back" : "Welcome",
            hasHistory ? "Back at it" : timed,
        ];
        return pool[now.DayOfYear % pool.Length];
    }

    private static string FirstName(string name)
    {
        var trimmed = name.Trim();
        var cut = trimmed.IndexOfAny([' ', '\t', '\n', '\r']);
        return cut < 0 ? trimmed : trimmed[..cut];
    }

    /// <summary>
    /// The work worth going back to: recent conversations the host reports,
    /// newest first. A shortcut, so it only renders when there is somewhere
    /// to go back to. Each row opens its conversation in the folder's chat,
    /// like the Mac.
    /// </summary>
    private static UIElement ContinueCard(JsonArray recent)
    {
        var list = new StackPanel { Spacing = Theme.SpaceS };
        foreach (var item in recent)
        {
            var title = Format.Text(item, "title", "Conversation");
            var texts = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
            texts.Children.Add(new TextBlock
            {
                Text = title,
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            texts.Children.Add(new TextBlock
            {
                Text = ContinueSubtitle(item),
                Opacity = 0.7,
                FontSize = 12,
            });
            var workspaceId = Format.Text(item, "workspaceId");
            var id = Format.Text(item, "id");
            if (string.IsNullOrEmpty(workspaceId) || string.IsNullOrEmpty(id))
            {
                list.Children.Add(texts);
                continue;
            }
            var mark = ActionIcon.History.Icon();
            mark.VerticalAlignment = VerticalAlignment.Center;
            var chevron = ActionIcon.Next.Icon();
            chevron.VerticalAlignment = VerticalAlignment.Center;
            var content = new Grid { ColumnSpacing = Theme.SpaceM };
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            content.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            content.Children.Add(mark);
            Grid.SetColumn(texts, 1);
            content.Children.Add(texts);
            Grid.SetColumn(chevron, 2);
            content.Children.Add(chevron);
            var open = new Button
            {
                Content = content,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Background = Theme.Brush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
                Padding = new Thickness(Theme.SpaceS),
            };
            open.Click += (_, _) => AppServices.OpenConversation?.Invoke(workspaceId, id);
            list.Children.Add(open);
        }
        return Chrome.Card("Continue", list, "The conversations you last opened");
    }

    private static string ContinueSubtitle(JsonNode? item)
    {
        var parts = new List<string>();
        var backend = Format.Text(item, "backend");
        if (!string.IsNullOrEmpty(backend))
        {
            parts.Add(backend);
        }
        var at = OptLong(item, "lastMessageAtMs");
        if (at is > 0)
        {
            parts.Add("last message " + Ago(at.Value));
        }
        if (Format.Flag(item, "running"))
        {
            parts.Add("running now");
        }
        else if (Format.Flag(item, "needsAttention"))
        {
            parts.Add("waiting on you");
        }
        return parts.Count == 0 ? "Recently active" : string.Join(" · ", parts);
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

    /// <summary>One cell of the delivered grid, for pinning by date.</summary>
    private static HeatDay? FindDay(JsonNode calendar, string date)
    {
        if (calendar["rows"] is not JsonArray rows)
        {
            return null;
        }
        foreach (var row in rows)
        {
            if (row is not JsonArray cells)
            {
                continue;
            }
            foreach (var cell in cells)
            {
                if (cell is null
                    || cell.GetValueKind() == System.Text.Json.JsonValueKind.Null
                    || Format.Text(cell, "date") != date)
                {
                    continue;
                }
                return new HeatDay(
                    date,
                    Format.Long(cell, "value"),
                    (int)Format.Long(cell, "level"),
                    Format.Flag(cell, "locked"));
            }
        }
        return null;
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
        var source = _delivered == "account"
            ? ", across every device on your account"
            : ", on this device";
        var subtitle = $"{total} at list rates over {active} active days" + source;
        var notice = Format.Text(calendar, "notice");
        if (!string.IsNullOrEmpty(notice) && Format.Text(calendar, "noticeCode") != "auth")
        {
            subtitle += ". " + notice;
        }
        _heatmap = Heatmap.View(
            calendar,
            _selectedDate,
            onSelect: day => SelectDay(day),
            onHover: day => HoverDay(day));
        return Chrome.Card("Activity", _heatmap, subtitle);
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
                async (_, _) => await SignInFlow.RunAsync(this, _signSlot, async () => await LoadAsync())));
        }
        body.Children.Add(signRow);
        return Chrome.Card("Get tokenstat counting", body);
    }

    /// <summary>
    /// One panel per vendor that reported numbers, plus the archive's own
    /// plan usage. A vendor with nothing to say is left out entirely: the
    /// panels on screen are the tools actually installed.
    /// </summary>
    private static List<UIElement> PlanPanels(JsonArray limits, JsonArray planBySource)
    {
        var panels = new List<UIElement>();
        foreach (var provider in VisibleLimits(limits))
        {
            panels.Add(PlanLimitPanel(provider));
        }
        if (planBySource.Count > 0)
        {
            panels.Add(PlanUsageCard(planBySource));
        }
        return panels;
    }

    /// <summary>
    /// Vendors worth a panel: anything that reported numbers, plus anything
    /// whose failure is worth reading. A tool that is simply not installed is
    /// not a failure and does not get one.
    /// </summary>
    private static List<JsonNode?> VisibleLimits(JsonArray limits)
    {
        var visible = new List<JsonNode?>();
        foreach (var provider in limits)
        {
            if (provider?["windows"] is JsonArray { Count: > 0 })
            {
                visible.Add(provider);
                continue;
            }
            var note = Format.Text(provider, "note");
            if (!string.IsNullOrEmpty(note) && !IsAbsentNote(note))
            {
                visible.Add(provider);
            }
        }
        return visible;
    }

    /// <summary>
    /// Do not turn an absent tool into an error card. Once a tool is present,
    /// authentication, network, and rate-limit failures remain visible.
    /// </summary>
    private static bool IsAbsentNote(string note)
    {
        var lower = note.ToLowerInvariant();
        string[] absent =
        [
            "not found",
            "not running",
            "no sessions",
            "no cursor session",
            "no opencode",
            "no antigravity",
            "no codex",
            "not signed in",
            "no claude code",
            "no home directory",
        ];
        foreach (var marker in absent)
        {
            if (lower.Contains(marker, StringComparison.Ordinal))
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>
    /// One vendor's quota, in its own panel. Quota windows, and the numbers
    /// are the vendor's own. Nothing here is derived from the archive.
    /// </summary>
    private static UIElement PlanLimitPanel(JsonNode? provider)
    {
        var source = Format.Text(provider, "source", "Plan");
        var body = new StackPanel { Spacing = Theme.SpaceS };
        if (provider?["windows"] is JsonArray { Count: > 0 } windows)
        {
            foreach (var window in windows)
            {
                body.Children.Add(WindowBar(window));
            }
            if (Format.Flag(provider, "stale"))
            {
                var note = Format.Text(provider, "note");
                if (!string.IsNullOrEmpty(note))
                {
                    // Why the numbers stopped moving, under the numbers
                    // themselves. A refresh that fails is not a reason to hide
                    // what was true an hour ago, and it is not a reason to
                    // pass that off as current either.
                    body.Children.Add(new TextBlock
                    {
                        Text = note,
                        FontSize = 11,
                        Opacity = 0.6,
                        TextWrapping = TextWrapping.Wrap,
                    });
                }
            }
        }
        else
        {
            // Words, not a zero bar. "We could not look" and "nothing used"
            // are different answers and must not look the same.
            body.Children.Add(new TextBlock
            {
                Text = Format.Text(provider, "note", "The vendor could not be read."),
                FontSize = 12,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        return Chrome.Card(HarnessName(source), body, ProviderSubtitle(provider));
    }

    /// <summary>
    /// The plan name when the vendor gave one, and always how old the reading
    /// is. "As of" rather than a bare timestamp, because with a stale panel
    /// the age is the point.
    /// </summary>
    private static string? ProviderSubtitle(JsonNode? provider)
    {
        var parts = new List<string>();
        var plan = Format.Text(provider, "plan");
        if (!string.IsNullOrEmpty(plan))
        {
            parts.Add(char.ToUpperInvariant(plan[0]) + plan[1..]);
        }
        var observed = OptLong(provider, "observedAtMs");
        if (observed is > 0)
        {
            var age = Ago(observed.Value);
            parts.Add(Format.Flag(provider, "stale") ? "last read " + age : "read " + age);
        }
        var next = long.MaxValue;
        if (provider?["windows"] is JsonArray windows)
        {
            foreach (var window in windows)
            {
                var reset = OptLong(window, "resetsAtMs");
                if (reset is > 0 && reset < next)
                {
                    next = reset.Value;
                }
            }
        }
        if (next != long.MaxValue
            && DateTimeOffset.FromUnixTimeMilliseconds(next) > DateTimeOffset.Now)
        {
            parts.Add("next window " + FutureIn(next));
        }
        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }

    private static UIElement WindowBar(JsonNode? window)
    {
        var percent = Format.Number(window, "percent");
        var tint = SeverityColor(Format.Text(window, "severity"));
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(1, GridUnitType.Star),
        });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = new TextBlock
        {
            Text = WindowDisplayLabel(window),
            FontSize = 12,
            Opacity = 0.7,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        head.Children.Add(label);
        var figure = Fonts.Numeric($"{percent:0}%", 12, Microsoft.UI.Text.FontWeights.Medium);
        figure.Foreground = Theme.Brush(tint);
        figure.Margin = new Thickness(Theme.SpaceS, 0, 0, 0);
        Grid.SetColumn(figure, 1);
        head.Children.Add(figure);
        var reset = OptLong(window, "resetsAtMs");
        if (reset is > 0
            && DateTimeOffset.FromUnixTimeMilliseconds(reset.Value) > DateTimeOffset.Now)
        {
            var when = new TextBlock
            {
                Text = "· resets " + FutureIn(reset.Value),
                FontSize = 11,
                Opacity = 0.6,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(Theme.SpaceS, 0, 0, 0),
            };
            Grid.SetColumn(when, 2);
            head.Children.Add(when);
        }
        // Clamped for drawing. A vendor reporting 104% is telling you it is
        // over, not asking for a bar that runs off the edge.
        var bar = new ProgressBar
        {
            Value = Math.Clamp(percent, 0, 100),
            Maximum = 100,
            Height = 6,
            Foreground = Theme.Brush(tint),
            Background = Theme.Brush(Theme.RowHighlight),
        };
        var stack = new StackPanel { Spacing = 3 };
        stack.Children.Add(head);
        stack.Children.Add(bar);
        return stack;
    }

    private static Windows.UI.Color SeverityColor(string severity) => severity switch
    {
        "warning" => Theme.Warning,
        "critical" => Theme.Danger,
        _ => Theme.Accent,
    };

    /// <summary>
    /// Codex reports the account's own allowance beside the running model's,
    /// and both are weekly. Without the scope the two rows read as one limit
    /// stated twice.
    /// </summary>
    private static string WindowDisplayLabel(JsonNode? window)
    {
        var label = Format.Text(window, "label", "window");
        var scope = Format.Text(window, "scope");
        if (string.IsNullOrEmpty(scope))
        {
            return label;
        }
        return scope.ToLowerInvariant() switch
        {
            "secondary" => $"{label} (all models)",
            "primary" => $"{label} (primary)",
            // A small model's own allowance: secondary, never bare beside the
            // account's week.
            "current model" => $"{label} (secondary)",
            // The account's own allowance reads as written. Anything else
            // vendor-named stays qualified rather than translated, which is
            // what hid an exhausted account limit.
            _ => $"{label} ({scope})",
        };
    }

    /// <summary>
    /// Archive usage that the source marked as covered by a subscription.
    /// Separate from the limit panels above: vendor quota windows answer what
    /// is left, this answers what the archive has already seen.
    /// </summary>
    private static UIElement PlanUsageCard(JsonArray rows)
    {
        var list = new StackPanel { Spacing = 0 };
        foreach (var row in rows)
        {
            var line = new Grid();
            line.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var name = new TextBlock
            {
                Text = HarnessName(Format.Text(row, "key")),
                FontSize = 13,
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            };
            line.Children.Add(name);
            var tokens = Fonts.Numeric(
                Format.Tokens(Format.Long(row?["counters"], "total")),
                13,
                Microsoft.UI.Text.FontWeights.Medium);
            tokens.Margin = new Thickness(Theme.SpaceS, 0, 0, 0);
            Grid.SetColumn(tokens, 1);
            line.Children.Add(tokens);
            var unit = new TextBlock
            {
                Text = "tokens",
                FontSize = 11,
                Opacity = 0.6,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(Theme.SpaceS, 0, 0, 0),
            };
            Grid.SetColumn(unit, 2);
            line.Children.Add(unit);
            line.Margin = new Thickness(0, 4, 0, 4);
            list.Children.Add(line);
        }
        return Chrome.Card(
            "Plan usage",
            list,
            "Subscription-covered usage recorded in the archive");
    }

    private static UIElement MachinesCard(JsonNode? account)
    {
        var machines = account?["machines"] as JsonArray;
        var limit = Format.Long(account, "machineLimit");
        var count = machines?.Count ?? 0;
        string subtitle = machines is null || count == 0
            ? "Devices linked to your account"
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
        return Chrome.Card("Machines", list, subtitle);
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

    /// <summary>
    /// The pointer moved over (or off) a heatmap day. Hover only glances: the
    /// inspector previews the day under the pointer and falls back to the
    /// pinned one. A quiet cell asks for nothing: the grid only lights priced
    /// days, and a day with no value has nothing to show.
    /// </summary>
    private void HoverDay(HeatDay? day)
    {
        string? date = day is not null && day.Value > 0 && !day.Locked ? day.Date : null;
        if (date == _hoverDate)
        {
            return;
        }
        _hoverDate = date;
        RefreshInspector();
        if (date is not null && !_dayCache.ContainsKey(date) && _loadingDetailFor != date)
        {
            _ = FetchDayAsync(date);
        }
    }

    /// <summary>Pin a day in the inspector. Hover still only glances.</summary>
    private void SelectDay(HeatDay? day)
    {
        if (day is null || day.Locked)
        {
            return;
        }
        _heatmap?.SetSelectedDate(day.Date);
        _selectedDate = day.Date;
        RefreshInspector();
        if (!_dayCache.ContainsKey(day.Date) && _loadingDetailFor != day.Date)
        {
            _ = FetchDayAsync(day.Date);
        }
        if (_delivered == "local"
            && !_overviewCache.ContainsKey(day.Date)
            && _loadingOverviewFor != day.Date)
        {
            _ = FetchOverviewAsync(day.Date);
        }
    }

    private async Task FetchDayAsync(string date)
    {
        _loadingDetailFor = date;
        RefreshInspector();
        try
        {
            var detail = await AppServices.Host.CallAsync(
                "activity.day",
                new JsonObject { ["date"] = date, ["weeks"] = 53, ["scope"] = _delivered });
            _dayCache[date] = detail is JsonObject ? detail : null;
        }
        catch
        {
            // A day that cannot be read leaves no entry, so a later hover
            // tries again instead of showing a cached failure.
        }
        finally
        {
            if (_loadingDetailFor == date)
            {
                _loadingDetailFor = null;
            }
        }
        RefreshInspector();
    }

    /// <summary>
    /// Local reports for the pinned day: models, harnesses, projects,
    /// sessions. The account series has no project or session keys, so this
    /// stays off when the grid is counting every device.
    /// </summary>
    private async Task FetchOverviewAsync(string date)
    {
        _loadingOverviewFor = date;
        RefreshInspector();
        JsonNode? totals = null;
        try
        {
            totals = await AppServices.Host.CallAsync(
                "totals", new JsonObject { ["query"] = DayQuery(date) });
        }
        catch
        {
        }
        var byModel = await FetchReportAsync("model", date);
        var bySource = await FetchReportAsync("source", date);
        var byProject = await FetchReportAsync("project", date);
        var bySession = await FetchReportAsync("session", date, limit: 80);
        _overviewCache[date] = new DayOverview(totals, byModel, bySource, byProject, bySession);
        if (_loadingOverviewFor == date)
        {
            _loadingOverviewFor = null;
        }
        RefreshInspector();
    }

    private static async Task<JsonArray> FetchReportAsync(string group, string date, int? limit = null)
    {
        try
        {
            var rows = await AppServices.Host.CallAsync(
                "report",
                new JsonObject { ["group"] = group, ["query"] = DayQuery(date, limit) });
            if (rows is JsonArray array)
            {
                return array;
            }
        }
        catch
        {
        }
        return new JsonArray();
    }

    /// <summary>
    /// A fresh single-day query. Built new for every call: a node keeps its
    /// parent, so one shared object cannot sit in five payloads.
    /// </summary>
    private static JsonObject DayQuery(string date, int? limit = null)
    {
        var query = new JsonObject { ["since"] = date, ["until"] = date };
        if (limit is not null)
        {
            query["limit"] = limit.Value;
        }
        return query;
    }

    /// <summary>
    /// The day pinned from the heatmap: an Insights-shaped overview in the
    /// shell's inspector column. Today is pinned when Home first loads.
    /// </summary>
    private void RefreshInspector()
    {
        _inspectorRoot.Children.Clear();
        _inspectorRoot.Children.Add(Fonts.Text(
            "Day", 15, Microsoft.UI.Text.FontWeights.SemiBold));
        var date = _hoverDate ?? _selectedDate;
        if (date is null)
        {
            _inspectorRoot.Children.Add(new TextBlock
            {
                Text = "Today opens here.",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            _inspectorRoot.Children.Add(new TextBlock
            {
                Text = "The heatmap is still loading. Hover a day for a glance, or click another day to pin it.",
                Opacity = 0.7,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
            });
            return;
        }
        if (!_dayCache.TryGetValue(date, out var detail))
        {
            if (_loadingDetailFor == date)
            {
                _inspectorRoot.Children.Add(new TextBlock
                {
                    Text = "Loading day…",
                    Opacity = 0.7,
                    FontSize = 12,
                });
            }
            else
            {
                _ = FetchDayAsync(date);
            }
            return;
        }
        if (detail is null)
        {
            _inspectorRoot.Children.Add(new TextBlock
            {
                Text = "Nothing recorded on this day.",
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
            return;
        }
        DayOverview? extra = null;
        if (date == _selectedDate
            && _delivered == "local"
            && _overviewCache.TryGetValue(date, out var cached))
        {
            extra = cached;
        }
        foreach (var child in DayBody(detail, extra, date))
        {
            _inspectorRoot.Children.Add(child);
        }
        // The footer action, like the Mac: the pinned day opened as a full
        // report in Insights.
        var open = ActionIconGlyph.PrimaryButton(
            "Open in Insights",
            ActionIcon.Next,
            (_, _) => AppServices.OpenInsightsDay?.Invoke(date));
        open.HorizontalAlignment = HorizontalAlignment.Stretch;
        open.HorizontalContentAlignment = HorizontalAlignment.Center;
        _inspectorRoot.Children.Add(open);
    }

    private List<UIElement> DayBody(JsonNode detail, DayOverview? extra, string date)
    {
        var children = new List<UIElement>();
        children.Add(new TextBlock
        {
            Text = FriendlyDate(Format.Text(detail, "date", date)),
            FontSize = 15,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        var value = (Format.Flag(detail, "estimated") ? "~" : "")
            + Format.ListRate(Format.Long(detail, "valueMicros"));
        children.Add(Chrome.Stat(
            "Value at list rates",
            value,
            Format.Flag(detail, "estimated") ? "estimated" : "not billed"));
        var sessions = OptLong(extra?.Totals, "sessions");
        var headline = $"{Format.Tokens(Format.Long(detail, "tokens"))} tokens · "
            + $"{Format.Long(detail, "events").ToString("N0")} requests";
        if (sessions is not null)
        {
            headline += $" · {sessions.Value.ToString("N0")} sessions";
        }
        children.Add(new TextBlock
        {
            Text = headline,
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        children.Add(DayCounters(detail));
        var split = DaySplit(detail);
        if (split is not null)
        {
            children.Add(split);
        }
        children.Add(GroupCard(
            "Models", "List-rate value", PricedModelRows(detail, extra), showsValue: true));
        children.Add(GroupCard(
            "Harnesses",
            "Which agent produced the tokens",
            HarnessRows(detail, extra),
            showsValue: false));
        if (extra?.ByProject is { Count: > 0 } projects)
        {
            var rows = new List<DayGroupRow>();
            foreach (var bucket in projects)
            {
                rows.Add(BucketRow(bucket, Format.Text(bucket, "key"), monospaced: true));
            }
            children.Add(GroupCard(
                "Projects", "Where the work happened", rows, showsValue: false));
        }
        if (extra?.BySession is { Count: > 0 } bySession)
        {
            var rows = new List<DayGroupRow>();
            foreach (var bucket in bySession)
            {
                rows.Add(BucketRow(bucket, Format.Text(bucket, "key"), monospaced: true));
            }
            children.Add(GroupCard(
                "Sessions", "This device", rows, showsValue: false));
        }
        var unpriced = UnpricedModelRows(detail, extra);
        if (unpriced.Count > 0)
        {
            children.Add(GroupCard(
                "Unpriced / local models",
                "No list rate. Tokens still counted.",
                unpriced,
                showsValue: false));
        }
        if (_loadingOverviewFor == date)
        {
            children.Add(new TextBlock
            {
                Text = "Loading breakdown…",
                Opacity = 0.6,
                FontSize = 12,
            });
        }
        return children;
    }

    private static UIElement DayCounters(JsonNode detail)
    {
        var rows = detail["rows"] as JsonArray;
        var stack = new StackPanel { Spacing = 2 };
        stack.Children.Add(CounterRow("Fresh input", SumCounter(rows, "fresh")));
        stack.Children.Add(CounterRow("Cache read", SumCounter(rows, "cacheRead")));
        stack.Children.Add(CounterRow("Cache write 5m", SumCounter(rows, "cacheWrite5m")));
        stack.Children.Add(CounterRow("Cache write 1h", SumCounter(rows, "cacheWrite1h")));
        stack.Children.Add(CounterRow("Output", SumCounter(rows, "output")));
        return stack;
    }

    /// <summary>
    /// "This tool does not report cache writes" and "this tool reported zero
    /// cache writes" are different facts. No value anywhere is n/a, not zero.
    /// </summary>
    private static long? SumCounter(JsonArray? rows, string name)
    {
        long sum = 0;
        var any = false;
        if (rows is not null)
        {
            foreach (var row in rows)
            {
                var value = OptLong(row, name);
                if (value is not null)
                {
                    any = true;
                    sum += value.Value;
                }
            }
        }
        return any ? sum : null;
    }

    private static UIElement CounterRow(string label, long? value)
    {
        var line = new Grid();
        line.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(1, GridUnitType.Star),
        });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 12,
            Opacity = 0.7,
        });
        var figure = Fonts.Numeric(
            value is null ? "n/a" : Format.Tokens(value.Value),
            11,
            Microsoft.UI.Text.FontWeights.Normal);
        if (value is null)
        {
            figure.Opacity = 0.6;
        }
        Grid.SetColumn(figure, 1);
        line.Children.Add(figure);
        return line;
    }

    private static UIElement? DaySplit(JsonNode detail)
    {
        long fresh = 0, read = 0, write = 0, output = 0;
        if (detail["rows"] is JsonArray rows)
        {
            foreach (var row in rows)
            {
                fresh += OptLong(row, "fresh") ?? 0;
                read += OptLong(row, "cacheRead") ?? 0;
                write += (OptLong(row, "cacheWrite5m") ?? 0) + (OptLong(row, "cacheWrite1h") ?? 0);
                output += OptLong(row, "output") ?? 0;
            }
        }
        var grand = fresh + read + write + output;
        if (grand <= 0)
        {
            return null;
        }
        (string Label, long Value, Windows.UI.Color Tint)[] segments =
        [
            ("cache read", read, Theme.HeatLevel(1)),
            ("cache write", write, Theme.HeatLevel(2)),
            ("output", output, Theme.HeatLevel(4)),
            ("fresh in", fresh, Theme.Accent),
        ];
        var stack = new StackPanel { Spacing = 2 };
        var bar = new Grid { Height = 4, ColumnSpacing = 2 };
        var legend = new List<string>();
        foreach (var segment in segments)
        {
            if (segment.Value <= 0)
            {
                continue;
            }
            bar.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(segment.Value, GridUnitType.Star),
            });
            var block = new Border
            {
                Background = Theme.Brush(segment.Tint),
                CornerRadius = new CornerRadius(2),
            };
            Grid.SetColumn(block, bar.ColumnDefinitions.Count - 1);
            bar.Children.Add(block);
            var share = (int)Math.Round(100.0 * segment.Value / grand);
            legend.Add($"{segment.Label} {share}%");
        }
        stack.Children.Add(bar);
        foreach (var line in legend)
        {
            stack.Children.Add(new TextBlock
            {
                Text = line,
                FontSize = 11,
                Opacity = 0.6,
            });
        }
        return stack;
    }

    private static UIElement GroupCard(
        string title, string subtitle, List<DayGroupRow> rows, bool showsValue)
    {
        const int listLimit = 8;
        var body = new StackPanel { Spacing = Theme.SpaceS };
        if (rows.Count == 0)
        {
            body.Children.Add(new TextBlock
            {
                Text = "Nothing recorded yet.",
                FontSize = 12,
                Opacity = 0.6,
            });
        }
        else
        {
            foreach (var row in rows.Take(listLimit))
            {
                var line = new Grid();
                line.ColumnDefinitions.Add(new ColumnDefinition
                {
                    Width = new GridLength(1, GridUnitType.Star),
                });
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                if (showsValue)
                {
                    line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                }
                TextBlock name = row.Monospaced ? Fonts.Code(row.Label, 12) : Fonts.Text(row.Label, 12);
                name.TextTrimming = TextTrimming.CharacterEllipsis;
                name.VerticalAlignment = VerticalAlignment.Center;
                line.Children.Add(name);
                var tokens = Fonts.Numeric(
                    Format.Tokens(row.Tokens), 11, Microsoft.UI.Text.FontWeights.Normal);
                tokens.Opacity = 0.7;
                tokens.Margin = new Thickness(Theme.SpaceS, 0, 0, 0);
                Grid.SetColumn(tokens, 1);
                line.Children.Add(tokens);
                if (showsValue && row.Value is not null)
                {
                    var money = Fonts.Numeric(
                        row.Value, 11, Microsoft.UI.Text.FontWeights.Normal);
                    money.Opacity = 0.7;
                    money.Margin = new Thickness(Theme.SpaceS, 0, 0, 0);
                    Grid.SetColumn(money, 2);
                    line.Children.Add(money);
                }
                body.Children.Add(line);
            }
            if (rows.Count > listLimit)
            {
                body.Children.Add(new TextBlock
                {
                    Text = $"and {rows.Count - listLimit} more",
                    FontSize = 12,
                    Opacity = 0.6,
                });
            }
        }
        return Chrome.Card(title, body, subtitle);
    }

    private static List<DayGroupRow> ModelRows(JsonNode detail, DayOverview? extra)
    {
        if (extra?.ByModel is { Count: > 0 } byModel)
        {
            var rows = new List<DayGroupRow>();
            foreach (var bucket in byModel)
            {
                var key = Format.Text(bucket, "key");
                rows.Add(BucketRow(bucket, ShortModel(key), monospaced: true));
            }
            return rows;
        }
        return FoldDetail(detail, part => Format.Text(part, "model"), ShortModel, monospaced: true);
    }

    /// <summary>
    /// Models that have a list rate. Unpriced and local ones belong in their
    /// own card, not mixed into a column that shows money.
    /// </summary>
    private static List<DayGroupRow> PricedModelRows(JsonNode detail, DayOverview? extra)
    {
        var unpriced = UnpricedNames(detail);
        return ModelRows(detail, extra)
            .Where(row => !unpriced.Any(name => MatchesUnpriced(row, name)))
            .ToList();
    }

    private static List<DayGroupRow> UnpricedModelRows(JsonNode detail, DayOverview? extra)
    {
        var names = UnpricedNames(detail);
        if (names.Count == 0)
        {
            return new List<DayGroupRow>();
        }
        var priced = ModelRows(detail, extra);
        var rows = new List<DayGroupRow>();
        foreach (var name in names)
        {
            var match = priced.FirstOrDefault(row => MatchesUnpriced(row, name));
            if (match is not null)
            {
                rows.Add(new DayGroupRow(name, match.Label, match.Tokens, null, true));
                continue;
            }
            long tokens = 0;
            if (detail["rows"] is JsonArray parts)
            {
                foreach (var part in parts)
                {
                    if (Format.Text(part, "model") == name)
                    {
                        tokens += Format.Long(part, "tokens");
                    }
                }
            }
            var shortName = ShortModel(name);
            rows.Add(new DayGroupRow(
                name, string.IsNullOrEmpty(shortName) ? name : shortName, tokens, null, true));
        }
        return rows;
    }

    private static List<string> UnpricedNames(JsonNode detail)
    {
        var names = new List<string>();
        if (detail["unpricedModels"] is JsonArray list)
        {
            foreach (var item in list)
            {
                if (item is JsonValue value
                    && value.TryGetValue<string>(out var name)
                    && !string.IsNullOrEmpty(name))
                {
                    names.Add(name);
                }
            }
        }
        return names;
    }

    private static bool MatchesUnpriced(DayGroupRow row, string name) =>
        row.Key == name || row.Label == name || row.Label == ShortModel(name);

    private static List<DayGroupRow> HarnessRows(JsonNode detail, DayOverview? extra)
    {
        if (extra?.BySource is { Count: > 0 } bySource)
        {
            var rows = new List<DayGroupRow>();
            foreach (var bucket in bySource)
            {
                var key = Format.Text(bucket, "key");
                rows.Add(BucketRow(bucket, HarnessName(key), monospaced: false));
            }
            return rows;
        }
        return FoldDetail(
            detail,
            part => HarnessToolKey(Format.Text(part, "src")),
            HarnessName,
            monospaced: false);
    }

    private static DayGroupRow BucketRow(JsonNode? bucket, string display, bool monospaced)
    {
        var value = (Format.Flag(bucket, "estimated") ? "~" : "")
            + Format.ListRate(Format.Long(bucket, "valueMicros"));
        return new DayGroupRow(
            Format.Text(bucket, "key"),
            string.IsNullOrEmpty(display) ? "unknown" : display,
            Format.Long(bucket?["counters"], "total"),
            value,
            monospaced);
    }

    private static List<DayGroupRow> FoldDetail(
        JsonNode detail, Func<JsonNode?, string> key, Func<string, string> display, bool monospaced)
    {
        var totals = new List<(string Raw, long Tokens)>();
        var index = new Dictionary<string, int>(StringComparer.Ordinal);
        if (detail["rows"] is JsonArray parts)
        {
            foreach (var part in parts)
            {
                var raw = key(part);
                var tokens = Format.Long(part, "tokens");
                if (index.TryGetValue(raw, out var at))
                {
                    totals[at] = (raw, totals[at].Tokens + tokens);
                }
                else
                {
                    index[raw] = totals.Count;
                    totals.Add((raw, tokens));
                }
            }
        }
        totals.Sort((a, b) => b.Tokens.CompareTo(a.Tokens));
        var rows = new List<DayGroupRow>();
        foreach (var (raw, tokens) in totals)
        {
            var label = display(raw);
            rows.Add(new DayGroupRow(
                raw, string.IsNullOrEmpty(label) ? "unknown" : label, tokens, null, monospaced));
        }
        return rows;
    }

    /// <summary>
    /// Display name for a harness, the agent CLI that produced the events.
    /// The archive stores source ids like `claude_code`. These are shown to
    /// people, so they get the same spelling tokenstat.ai uses.
    /// </summary>
    private static string HarnessName(string id)
    {
        if (id == "opencode2")
        {
            return "OpenCode 2";
        }
        return HarnessCanonicalId(id) switch
        {
            "claude_code" => "Claude Code",
            "claude_code_rollup" or "claude_code_estimate" => "Claude Code (recovered)",
            "codex" => "Codex",
            "grok" => "Grok Build",
            "opencode" => "OpenCode",
            "cline" => "Cline",
            "openclaw" => "OpenClaw",
            "muse" => "Muse",
            "devin" => "Devin CLI",
            "pi" => "Pi",
            "dsh" => "DeepSeek Harness",
            "zed" => "Zed",
            "copilot" => "Copilot CLI",
            "antigravity" => "Antigravity",
            "cursor" => "Cursor",
            "gemini" => "Gemini",
            "hermes" => "Hermes Agent",
            "kilo" => "Kilo Code",
            "kimi" => "Kimi Code",
            "qwen" => "Qwen Code",
            "" => "unknown",
            var canonical => canonical,
        };
    }

    private static string HarnessCanonicalId(string id)
    {
        if (id == "agy")
        {
            return "antigravity";
        }
        if (id.StartsWith("antigravity", StringComparison.Ordinal))
        {
            return "antigravity";
        }
        if (id == "claude")
        {
            return "claude_code";
        }
        if (id == "opencode2")
        {
            return "opencode";
        }
        return id;
    }

    /// <summary>
    /// The tool a stored source id belongs to. Recovery rows stay on disk as
    /// `claude_code_estimate` / `claude_code_rollup` and fold into Claude Code.
    /// </summary>
    private static string HarnessToolKey(string id) => id switch
    {
        "claude_code_estimate" or "claude_code_rollup" => "claude_code",
        _ => id,
    };

    /// <summary>
    /// Display label for a model id. Model ids are long and the useful part
    /// is at the end, and bare "default"/"auto" is the Cursor router.
    /// </summary>
    private static string ShortModel(string id)
    {
        var raw = id.Trim();
        var slash = raw.LastIndexOf('/');
        var leaf = slash >= 0 ? raw[(slash + 1)..] : raw;
        if (leaf.ToLowerInvariant() is "default" or "auto" or "cursor-auto"
            or "cursor-default" or "cursor-router-auto")
        {
            return "cursor-router-auto";
        }
        var colon = leaf.IndexOf(": ", StringComparison.Ordinal);
        if (colon >= 0)
        {
            var after = leaf[(colon + 2)..].Trim();
            if (!string.IsNullOrEmpty(after))
            {
                return after;
            }
        }
        return string.IsNullOrEmpty(leaf) ? "model" : leaf;
    }

    /// <summary>An optional counter that may be absent. Absent is null, not zero.</summary>
    private static long? OptLong(JsonNode? node, string name)
    {
        var value = node?[name];
        if (value is null || value.GetValueKind() == System.Text.Json.JsonValueKind.Null)
        {
            return null;
        }
        try
        {
            return value.GetValue<long>();
        }
        catch
        {
            return null;
        }
    }

    /// <summary>How long ago an epoch-millis instant was, in words.</summary>
    private static string Ago(long epochMs)
    {
        var moment = DateTimeOffset.FromUnixTimeMilliseconds(epochMs);
        var age = DateTimeOffset.Now - moment;
        if (age < TimeSpan.FromMinutes(1))
        {
            return "just now";
        }
        if (age < TimeSpan.FromHours(1))
        {
            var minutes = Math.Max(1, (int)age.TotalMinutes);
            return minutes == 1 ? "1 minute ago" : $"{minutes} minutes ago";
        }
        if (age < TimeSpan.FromDays(1))
        {
            var hours = Math.Max(1, (int)age.TotalHours);
            return hours == 1 ? "1 hour ago" : $"{hours} hours ago";
        }
        if (age < TimeSpan.FromDays(30))
        {
            var days = Math.Max(1, (int)age.TotalDays);
            return days == 1 ? "1 day ago" : $"{days} days ago";
        }
        return moment.LocalDateTime.ToString("d");
    }

    /// <summary>How far off a future epoch-millis instant is, in words.</summary>
    private static string FutureIn(long epochMs)
    {
        var wait = DateTimeOffset.FromUnixTimeMilliseconds(epochMs) - DateTimeOffset.Now;
        if (wait < TimeSpan.FromMinutes(1))
        {
            return "in a moment";
        }
        if (wait < TimeSpan.FromHours(1))
        {
            var minutes = Math.Max(1, (int)wait.TotalMinutes);
            return minutes == 1 ? "in 1 minute" : $"in {minutes} minutes";
        }
        if (wait < TimeSpan.FromDays(1))
        {
            var hours = Math.Max(1, (int)wait.TotalHours);
            return hours == 1 ? "in 1 hour" : $"in {hours} hours";
        }
        var days = Math.Max(1, (int)wait.TotalDays);
        return days == 1 ? "in 1 day" : $"in {days} days";
    }

    private static string FriendlyDate(string iso)
    {
        if (DateTime.TryParseExact(
                iso, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
        {
            return date.ToString("MMM d, yyyy", CultureInfo.CurrentCulture);
        }
        return iso;
    }
}
