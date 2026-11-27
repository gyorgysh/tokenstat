// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal static class WorkbenchOps
{
    public static async Task<long?> ProtocolAsync()
    {
        try
        {
            var answer = await AppServices.Host.CallAsync("protocol", new JsonObject());
            return RemoteFeatureGate.ProtocolOf(answer);
        }
        catch
        {
            return null;
        }
    }

    public static bool TaskEditing(long? protocol) =>
        RemoteFeatureGate.SupportsProtocol(protocol, RemoteFeatureGate.TaskEditingMinProtocol);

    public static bool TaskDeletion(long? protocol) =>
        RemoteFeatureGate.SupportsProtocol(protocol, RemoteFeatureGate.TaskDeletionMinProtocol);

    public static bool TaskCreation(long? protocol) =>
        RemoteFeatureGate.SupportsProtocol(protocol, RemoteFeatureGate.TaskCreationMinProtocol);

    public static bool TaskExecution(long? protocol) =>
        RemoteFeatureGate.SupportsProtocol(protocol, RemoteFeatureGate.TaskExecutionMinProtocol);

    public static bool AutomationReceipts(long? protocol) =>
        RemoteFeatureGate.SupportsProtocol(protocol, RemoteFeatureGate.AutomationReceiptsMinProtocol);

    public static bool WorkflowEditing(long? protocol) =>
        RemoteFeatureGate.SupportsProtocol(protocol, RemoteFeatureGate.WorkflowEditingMinProtocol);

    public static string NewOperationId(string prefix) => $"{prefix}-{Guid.NewGuid()}";

    public static bool IsConflict(Exception ex) =>
        ex.Message.Contains("changed since", StringComparison.OrdinalIgnoreCase)
        || ex.Message.Contains("revision", StringComparison.OrdinalIgnoreCase);

    public static ulong? Revision(JsonNode? item)
    {
        if (item?["revision"] is JsonValue v)
        {
            try
            {
                return v.GetValue<ulong?>();
            }
            catch
            {
                return null;
            }
        }
        return null;
    }

    public static bool IsRunning(JsonNode? runOrDelegate)
    {
        var status = Format.Text(runOrDelegate, "status");
        return status is "starting" or "queued" or "running" or "stopping";
    }

    public static string RunLabel(string status) => status switch
    {
        "starting" => L10n.Text("windows.workbenchops.starting.aeed4d26"),
        "queued" => L10n.Text("common.queued"),
        "running" => L10n.Text("common.running"),
        "stopping" => L10n.Text("windows.workbenchops.stopping.a71ee1d4"),
        "ok" => L10n.Text("common.done"),
        "stopped" => L10n.Text("windows.workbenchops.stopped.1a4f630a"),
        "error" => L10n.Text("common.failed"),
        "interrupted" => L10n.Text("windows.workbenchops.interrupted_by_restart.012812fe"),
        _ => string.IsNullOrEmpty(status) ? L10n.Text("common.unknown") : status,
    };

    public static List<JsonNode?> OrderedRuns(JsonArray? runs)
    {
        var list = new List<JsonNode?>();
        if (runs is not null)
        {
            foreach (var run in runs)
            {
                list.Add(run);
            }
        }
        list.Sort((a, b) =>
        {
            var liveA = IsRunning(a);
            var liveB = IsRunning(b);
            if (liveA != liveB)
            {
                return liveA ? -1 : 1;
            }
            var startedA = Format.Long(a, "startedAtMs");
            var startedB = Format.Long(b, "startedAtMs");
            if (startedA != startedB)
            {
                return startedB.CompareTo(startedA);
            }
            return string.CompareOrdinal(Format.Text(b, "id"), Format.Text(a, "id"));
        });
        return list;
    }

    public const int RunPageSize = 20;
    public const int RunPreviewCount = 5;

    public static string? HostZone(string? identifier)
    {
        var trimmed = identifier?.Trim();
        if (string.IsNullOrEmpty(trimmed) || trimmed == "unknown")
        {
            return null;
        }
        return trimmed;
    }

    public static string? ZonePlace(string? identifier)
    {
        var zone = HostZone(identifier);
        if (zone is null)
        {
            return null;
        }
        if (zone is "UTC" or "GMT")
        {
            return "UTC";
        }
        var slash = zone.LastIndexOf('/');
        var tail = slash >= 0 ? zone[(slash + 1)..] : zone;
        return tail.Replace('_', ' ');
    }

    public static string ClockCaption(string hostName, string? timezone, string? subject = null)
    {
        subject ??= L10n.Text("windows.workbenchops.this_time_is.e63a9d6e");
        var host = hostName.Trim();
        var place = ZonePlace(timezone);
        if (place is not null)
        {
            return string.IsNullOrEmpty(host)
                ? L10n.Text("windows.workbenchops.0_on_the_connected_computer_1.856ab0a3", $"{subject}", $"{place}")
                : L10n.Text("windows.workbenchops.0_on_1_2.39b8735b", $"{subject}", $"{host}", $"{place}");
        }
        return string.IsNullOrEmpty(host)
            ? L10n.Text("windows.workbenchops.0_on_the_connected_computer_not_this_devic.444e2648", $"{subject}")
            : L10n.Text("windows.workbenchops.0_on_1_not_this_device.4df70e6c", $"{subject}", $"{host}");
    }

    public static ulong? BudgetSeconds(string value, string unit, bool noLimit)
    {
        if (noLimit)
        {
            return 0;
        }
        if (!ulong.TryParse(value.Trim(), out var amount) || amount == 0)
        {
            return null;
        }
        try
        {
            return unit == "minutes" ? checked(amount * 60) : amount;
        }
        catch (OverflowException)
        {
            return null;
        }
    }

    public static (string Value, string Unit, bool NoLimit) SplitBudget(ulong seconds)
    {
        if (seconds == 0)
        {
            return ("180", "minutes", true);
        }
        if (seconds % 60 == 0)
        {
            return ((seconds / 60).ToString(), "minutes", false);
        }
        return (seconds.ToString(), "seconds", false);
    }

    public static JsonObject SchedulePayload(
        string kind, ulong everySeconds, int hour, int minute, int weekday, int weekdays)
    {
        return new JsonObject
        {
            ["kind"] = kind,
            ["everySeconds"] = everySeconds,
            ["hour"] = Math.Clamp(hour, 0, 23),
            ["minute"] = Math.Clamp(minute, 0, 59),
            ["weekday"] = Math.Clamp(weekday, 0, 6),
            ["weekdays"] = weekdays & 0x7F,
        };
    }

    public static string? ScheduleValidation(string kind, ulong everySeconds, int weekdays)
    {
        if (kind == "custom" && (weekdays & 0x7F) == 0)
        {
            return L10n.Text("windows.workbenchops.pick_at_least_one_day_for_a_custom_schedul.0c926625");
        }
        if (kind == "interval" && everySeconds < 60)
        {
            return L10n.Text("windows.workbenchops.pick_an_interval_of_at_least_one_minute.e57770a7");
        }
        return null;
    }

    public static readonly string[] ScheduleKinds =
        ["once", "interval", "daily", "weekdays", "weekly", "custom"];

    public static readonly string[] DayShortNames =
        [L10n.Text("windows.workbenchops.mon.f40d7f51"), L10n.Text("windows.workbenchops.tue.d1eb39b0"), L10n.Text("windows.workbenchops.wed.58339f45"), L10n.Text("windows.workbenchops.thu.7da11212"), L10n.Text("windows.workbenchops.fri.66dab40c"), L10n.Text("windows.workbenchops.sat.fdeb71b5"), L10n.Text("windows.workbenchops.sun.db18f17f")];

    public static readonly string[] DayNames =
        [L10n.Text("windows.workbenchops.monday.6a00dfc1"), L10n.Text("windows.workbenchops.tuesday.7d8af1de"), L10n.Text("windows.workbenchops.wednesday.c0a6cc82"), L10n.Text("windows.workbenchops.thursday.fc266206"), L10n.Text("windows.workbenchops.friday.e21f3f37"), L10n.Text("windows.workbenchops.saturday.dbe35c73"), L10n.Text("windows.workbenchops.sunday.873fef76")];

    public static JsonObject PreserveUnknown(JsonObject? raw, JsonObject edited)
    {
        var merged = new JsonObject();
        if (raw is not null)
        {
            foreach (var (key, value) in raw)
            {
                merged[key] = value?.DeepClone();
            }
        }
        foreach (var (key, value) in edited)
        {
            merged[key] = value?.DeepClone();
        }
        return merged;
    }
}
