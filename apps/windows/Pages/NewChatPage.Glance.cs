// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Globalization;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed partial class NewChatPage
{
    private readonly Grid _glance = new() { ColumnSpacing = Theme.SpaceS, RowSpacing = Theme.SpaceS };
    private readonly StackPanel _glanceRepository = new() { Spacing = 4 };
    private readonly StackPanel _glanceSpend = new() { Spacing = 4 };
    private readonly StackPanel _glanceLimits = new() { Spacing = 4 };
    private JsonArray? _glanceProviders;
    private string? _glanceId;
    private int _glanceGeneration;

    private void BuildGlance()
    {
        var cards = new[]
        {
            Chrome.Card(Copy("repository"), _glanceRepository),
            Chrome.Card(L10n.Text("windows.newchatglance.last_week"), _glanceSpend),
            Chrome.Card(L10n.Text("windows.accountpage.plan_limits.925788cd"), _glanceLimits),
        };
        for (var i = 0; i < cards.Length; i++)
        {
            _glance.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            _glance.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetColumn(cards[i], i);
            _glance.Children.Add(cards[i]);
        }
        _glance.SizeChanged += (_, args) =>
        {
            var narrow = args.NewSize.Width < 505;
            for (var i = 0; i < cards.Length; i++)
            {
                Grid.SetColumn(cards[i], narrow ? 0 : i);
                Grid.SetColumnSpan(cards[i], narrow ? cards.Length : 1);
                Grid.SetRow(cards[i], narrow ? i : 0);
            }
        };
    }

    private void RetireGlance()
    {
        ++_glanceGeneration;
        _glanceId = null;
        _glanceProviders = null;
        _glance.Visibility = Visibility.Collapsed;
    }

    private async Task RefreshGlanceAsync()
    {
        if (!IsLoaded || _account != AppServices.AccountGeneration || _selected?.Id == _glanceId) return;
        var repository = _selected;
        _glanceId = repository?.Id;
        var generation = ++_glanceGeneration;
        _glance.Visibility = repository is null ? Visibility.Collapsed : Visibility.Visible;
        if (repository is null) return;
        bool Current() => IsLoaded && generation == _glanceGeneration && _account == AppServices.AccountGeneration;
        var general = repository.IsGeneral;
        FillGlance(_glanceRepository, repository.Name, repository.Machine);
        FillGlance(_glanceSpend, L10n.Text("common.loading"));
        RenderGlanceLimits();
        await Task.WhenAll(RepositoryAsync(), SpendAsync(), LimitsAsync());

        async Task RepositoryAsync()
        {
            if (general) return;
            var status = await GlanceReadAsync(() => RemoteWorkspaces.CallWorkspaceAsync(repository.Id,
                "workspace.status", new JsonObject { ["id"] = repository.Id }));
            if (!Current() || status is null) return;
            var git = status["git"];
            var branch = Format.Text(git, "branch", Format.Text(status, "branch"));
            if (branch.Length == 0)
            {
                FillGlance(_glanceRepository, repository.Name, L10n.Text("windows.newchatglance.no_branch"));
                return;
            }
            var count = (git?["files"] as JsonArray ?? status["files"] as JsonArray)?.Count ?? 0;
            var ahead = Format.Long(git, "ahead");
            var behind = Format.Long(git, "behind");
            var sync = new List<string>();
            if (ahead > 0) sync.Add(L10n.Text("windows.newchatglance.ahead", ahead));
            if (behind > 0) sync.Add(L10n.Text("windows.newchatglance.behind", behind));
            FillGlance(_glanceRepository, WorkspaceGit.ShortBranch(branch), count == 0
                ? L10n.Text("windows.newchatglance.clean") : L10n.Text("windows.newchatglance.changed", count),
                sync.Count > 0 ? string.Join(" · ", sync) : repository.Machine);
        }

        async Task SpendAsync()
        {
            var keys = Enumerable.Range(-6, 7).Select(offset => DateTime.Today.AddDays(offset).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)).ToArray();
            var spendLabel = repository.Name;
            async Task<JsonNode?> ReadLocal(string? project)
            {
                var query = new JsonObject { ["since"] = keys[0] };
                if (project is not null) query["project"] = project;
                return await GlanceReadAsync(() => AppServices.Host.CallAsync("report", new JsonObject { ["group"] = "day", ["query"] = query }));
            }
            var report = repository.IsLocal && !general ? await ReadLocal(repository.Name) : null;
            if (!Current()) return;
            var week = GlanceWeek(report, keys);
            if (week is null || week.All(day => day == 0))
            {
                spendLabel = L10n.Text("windows.newchatglance.synced_projects");
                report = await GlanceReadAsync(() => AppServices.Host.CallAsync("account.report", new JsonObject { ["group"] = "day", ["weeks"] = 1 }));
                if (!Current()) return;
                week = GlanceWeek(report, keys);
                if (week is null)
                {
                    spendLabel = L10n.Text("windows.newchatglance.local_projects");
                    week = GlanceWeek(await ReadLocal(null), keys);
                    if (!Current()) return;
                }
            }
            if (week is null)
            {
                FillGlance(_glanceSpend, L10n.Text("windows.newchatglance.no_spend_reading"));
                return;
            }
            var total = week.Aggregate(0L, static (sum, item) => sum + Math.Min(item, long.MaxValue - sum));
            FillGlance(_glanceSpend, Format.ListRate(total),
                L10n.Text("windows.newchatglance.today", Format.ListRate(week[^1])), spendLabel);
            if (total == 0) return;
            var peak = week.Max();
            var bars = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3, Height = 20 };
            AutomationProperties.SetAccessibilityView(bars, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            foreach (var day in week)
                bars.Children.Add(new Border { Width = 8, Height = Math.Max(2, 20d * day / peak), VerticalAlignment = VerticalAlignment.Bottom,
                    Background = day > 0 ? Theme.AccentBrush : Theme.BorderBrush, CornerRadius = new CornerRadius(2) });
            _glanceSpend.Children.Insert(1, bars);
        }

        async Task LimitsAsync()
        {
            if (_glanceProviders is not null) return;
            var status = await GlanceReadAsync(() => AppServices.Host.CallAsync("config.limitsSync", new JsonObject()));
            if (!Current()) return;
            _glanceProviders = status?["providers"] as JsonArray ?? new JsonArray();
            RenderGlanceLimits();
        }
    }

    private static async Task<JsonNode?> GlanceReadAsync(Func<Task<JsonNode>> load)
    {
        try { return await load(); }
        catch { return null; }
    }

    private static long[]? GlanceWeek(JsonNode? report, IReadOnlyList<string> keys)
    {
        if (Format.Items(report, "rows") is not { } rows) return null;
        var values = rows.OfType<JsonObject>().GroupBy(item => Format.Text(item, "key"), StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Aggregate(0L, (sum, item) =>
                sum + Math.Min(Math.Max(0, Format.Long(item, "valueMicros")), long.MaxValue - sum)), StringComparer.Ordinal);
        return keys.Select(key => values.GetValueOrDefault(key)).ToArray();
    }

    private void RenderGlanceLimits()
    {
        if (_glanceProviders is null)
        {
            FillGlance(_glanceLimits, L10n.Text("common.loading"));
            return;
        }
        var id = AccountPage.HarnessCanonicalId(Format.Text(CurrentBackend(), "id"));
        var sources = _glanceProviders.OfType<JsonObject>()
            .Select(provider => (Source: Format.Text(provider, "source"),
                Windows: (provider["windows"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
                    .Where(window => window["percent"] is not null && double.IsFinite(AccountPage.WindowPercent(window)))
                    .OrderByDescending(AccountPage.WindowPercent).ToArray()))
            .Where(provider => provider.Windows.Length > 0).ToArray();
        var own = sources.FirstOrDefault(provider => id.Length > 0 && AccountPage.HarnessCanonicalId(provider.Source) == id);
        var rows = own.Windows is not null
            ? own.Windows.Take(2).Select(window => (own.Source, window))
            : sources.Select(provider => (provider.Source, window: provider.Windows[0])).OrderByDescending(row => AccountPage.WindowPercent(row.window)).Take(2);
        if (!rows.Any())
        {
            FillGlance(_glanceLimits, L10n.Text("windows.newchatglance.no_limits"));
            return;
        }
        _glanceLimits.Children.Clear();
        foreach (var (source, window) in rows)
        {
            var percent = Math.Clamp(AccountPage.WindowPercent(window), 0, 100);
            var label = Format.Text(window, "label");
            var agent = AccountPage.HarnessName(source);
            _glanceLimits.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.newchatglance.limit", agent, label, percent / 100d),
                FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis,
            });
            _glanceLimits.Children.Add(new ProgressBar { Value = percent, Height = 4, Foreground = Theme.AccentBrush });
        }
    }

    private static void FillGlance(StackPanel panel, params string[] text)
    {
        panel.Children.Clear();
        for (var i = 0; i < text.Length; i++)
            panel.Children.Add(new TextBlock { Text = text[i], TextTrimming = TextTrimming.CharacterEllipsis,
                FontSize = i == 0 ? 15 : 12, Opacity = i == 0 ? 1 : 0.72,
                FontWeight = i == 0 ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal });
    }
}
