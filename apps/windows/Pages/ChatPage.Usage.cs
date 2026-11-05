// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal sealed partial class ChatPage
{
    private bool _commandUsageOnly;
    private JsonObject? _usageLimits;
    private JsonObject? _usageRenderedTotals;
    private bool _usageReadFailed;
    private long _usageReadVisibility = -1;
    private object? _usageFlight;
    private DateTimeOffset _usageAttempt;

    private void ResetUsageRead()
    {
        _usageLimits = null; _usageRenderedTotals = null; _usageReadFailed = false; _usageReadVisibility = -1;
        _usageFlight = null; _usageAttempt = default;
    }
    private async Task RefreshChatLimitsAsync(bool force = false)
    {
        var body = _commandDialogBody;
        var owner = _commandDialogOwner;
        var visibility = _inspectionVisibilityGeneration;
        bool Current() => _commandUsageOnly && body is not null && ReferenceEquals(body, _commandDialogBody)
            && owner == InspectionOwner() && visibility == _inspectionVisibilityGeneration && IsLoaded
            && App.CurrentWindow is not MainWindow { IsForeground: false };
        if (!Current() || _usageFlight is not null || !force && DateTimeOffset.UtcNow - _usageAttempt < TimeSpan.FromSeconds(30)) return;
        var flight = new object(); _usageFlight = flight; _usageAttempt = DateTimeOffset.UtcNow;
        try
        {
            RenderCommandStats();
            var result = await AppServices.Host.CallAsync("usage.limits", new JsonObject { ["force"] = force });
            if (!Current()) return;
            if (result is not JsonArray readings) throw new InvalidDataException();
            _usageLimits = ChatQuotaData.Read(readings, Format.Text(_openChat, "backend"));
            _usageReadFailed = false; _usageReadVisibility = visibility;
        }
        catch { if (Current()) _usageReadFailed = true; }
        finally
        {
            if (ReferenceEquals(_usageFlight, flight)) _usageFlight = null;
            if (Current()) RenderCommandStats();
        }
    }
    private void AddChatUsage(StackPanel target)
    {
        var limits = new StackPanel { Spacing = Theme.SpaceS };
        var refresh = Buttons.ToolbarIcon(ActionIcon.Refresh, L10n.Text("common.refresh"), async (_, _) => await RefreshChatLimitsAsync(force: true));
        refresh.IsEnabled = _usageFlight is null;
        if (_usageLimits is JsonObject provider)
        {
            var stale = _usageReadFailed || _usageReadVisibility != _inspectionVisibilityGeneration || Format.Flag(provider, "stale");
            foreach (var window in AsArray(provider, "windows").OfType<JsonObject>())
            {
                var percent = ChatUsageTotals.Amount(window["percent"])!.Value;
                var label = Format.Text(window, "label");
                var scope = Format.Text(window, "scope");
                if (!string.IsNullOrWhiteSpace(scope)) label += $" ({scope})";
                limits.Children.Add(StatsMetric(label, $"{percent:0}%"));
                limits.Children.Add(new ProgressBar { Value = Math.Clamp(percent, 0, 100), Maximum = 100, Height = 5,
                    Foreground = stale ? Theme.Brush(static () => Theme.Secondary)
                        : percent >= 90 ? Theme.Brush(static () => Theme.Danger)
                        : percent >= 70 ? Theme.Brush(static () => Theme.Warning) : Theme.AccentBrush });
                if (UsageDate(window["resetsAtMs"]) is string reset)
                    limits.Children.Add(Muted(L10n.Text("common.chat.usage.resets", reset)));
            }
            if (stale) limits.Children.Add(Muted(L10n.Text("common.chat.usage.stale")));
            if (UsageDate(provider["observedAtMs"]) is string observed)
                limits.Children.Add(Muted(L10n.Text("common.chat.usage.reported", observed)));
        }
        else limits.Children.Add(Muted(L10n.Text(_usageFlight is not null ? "common.loading" : "common.chat.usage.no_limits")));
        target.Children.Add(Chrome.Card(Format.Text(Backend(Format.Text(_openChat, "backend")), "label", Format.Text(_openChat, "backend")), limits,
            Format.Text(_usageLimits, "plan"), accessory: refresh));

        var data = CurrentInspection as JsonObject;
        var context = new StackPanel { Spacing = Theme.SpaceS };
        if (ChatUsageTotals.Count(data?["contextUsed"]) is ulong used)
        {
            if (ChatUsageTotals.Count(data?["contextWindow"]) is ulong window && window > 0)
            {
                var fraction = used / (double)window;
                context.Children.Add(Muted(L10n.Text("common.chat.stats.capacity", used.ToString("N0"), window.ToString("N0"))));
                context.Children.Add(StatsMetric(L10n.Text("common.chat.stats.context"), fraction.ToString("P0")));
                context.Children.Add(new ProgressBar { Value = Math.Clamp(fraction, 0, 1), Maximum = 1, Height = 5,
                    Foreground = fraction >= .95 ? Theme.Brush(static () => Theme.Danger)
                        : fraction >= .8 ? Theme.Brush(static () => Theme.Warning) : Theme.AccentBrush });
                var source = Format.Text(data, "windowSource");
                if (source == "catalog") context.Children.Add(Muted(L10n.Text("common.chat.stats.catalog_window")));
                if (source == "previousAgent") context.Children.Add(Muted(L10n.Text("common.chat.stats.last_window")));
            }
            else
            {
                context.Children.Add(Muted(L10n.Text("common.chat.stats.in_context", used.ToString("N0"))));
                context.Children.Add(Muted(L10n.Text("common.chat.stats.window_unknown")));
            }
            if (!_inspectionLiveLease) context.Children.Add(Muted(L10n.Text("common.chat.usage.stale")));
            if (UsageDate(data?["observedAtMs"]) is string stamp)
                context.Children.Add(Muted(L10n.Text("common.chat.usage.reported", stamp)));
        }
        else context.Children.Add(Muted(L10n.Text("common.chat.stats.no_data")));
        target.Children.Add(Chrome.Card(L10n.Text("common.chat.stats.context"), context));
        var totals = new StackPanel { Spacing = Theme.SpaceS };
        _usageRenderedTotals = _aggregateUsage;
        var usage = ChatUsageTotals.Read(data?["usage"]) ?? _aggregateUsage;
        if (usage is not null && ChatUsageTotals.HasReportedUsage(usage)) AppendUsage(totals, usage);
        else totals.Children.Add(Muted(L10n.Text("common.chat.usage.no_totals")));
        target.Children.Add(Chrome.Card(L10n.Text("common.chat.stats.conversation"), totals));
    }
    private static string? UsageDate(JsonNode? raw) => ChatUsageTotals.Count(raw) is ulong milliseconds && milliseconds > 0 && milliseconds <= long.MaxValue
        ? Format.Instant((long)milliseconds)?.ToLocalTime().ToString("g") : null;
}
