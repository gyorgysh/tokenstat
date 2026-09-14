// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>
/// Shared operation semantics for the Tasks, Automations, and Workflows pages.
/// Ports the Mac state machines (receipts, revisions, conflict flows, and the
/// no-duplicate rules), not just the screens. Host methods are verified by name
/// in tokenstat-host dispatch; the host protocol stays at 22.
/// </summary>
internal static class WorkbenchOps
{
    /// <summary>
    /// Best-effort host protocol version. Null means unknown, and unknown
    /// means assume the feature is there, matching RemoteFeatureGate.
    /// </summary>
    public static async Task<long?> ProtocolAsync()
    {
        try
        {
            var answer = await AppServices.Host.CallAsync("protocol", new JsonObject());
            return answer?["protocolVersion"]?.GetValue<long?>()
                ?? answer?["protocol"]?.GetValue<long?>();
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

    /// <summary>
    /// Client-owned name for one launch or creation, so an answer lost on the
    /// way back can be repeated without running the agent twice. Callers mint
    /// one id per user action and reuse it for every retry of that action.
    /// </summary>
    public static string NewOperationId(string prefix) => $"{prefix}-{Guid.NewGuid()}";

    /// <summary>
    /// True when the host refused a checked write because the saved revision
    /// moved. The Mac detects a conflict by comparing revisions, not by code,
    /// so match the host sentence instead of an error code.
    /// </summary>
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
        "starting" => "Starting",
        "queued" => "Queued",
        "running" => "Running",
        "stopping" => "Stopping",
        "ok" => "Done",
        "stopped" => "Stopped",
        "error" => "Failed",
        "interrupted" => "Interrupted by restart",
        _ => string.IsNullOrEmpty(status) ? "Unknown" : status,
    };

    /// <summary>
    /// Live runs first so Stop is never behind Earlier runs, then newest first.
    /// Matches the Mac AutomationRunHistory ordering.
    /// </summary>
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

    /// <summary>
    /// IANA zone the host scheduler owns, or null when it is missing. A client
    /// in another zone must not convert host times into the device clock.
    /// Matches the Mac HostScheduleClock ownership rule.
    /// </summary>
    public static string? HostZone(string? identifier)
    {
        var trimmed = identifier?.Trim();
        if (string.IsNullOrEmpty(trimmed) || trimmed == "unknown")
        {
            return null;
        }
        return trimmed;
    }

    /// <summary>Short place name: America/New_York becomes New York.</summary>
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

    /// <summary>
    /// Who owns a wall-clock time. Never prints a host time without saying
    /// whose clock it is.
    /// </summary>
    public static string ClockCaption(string hostName, string? timezone, string subject = "This time is")
    {
        var host = hostName.Trim();
        var place = ZonePlace(timezone);
        if (place is not null)
        {
            return string.IsNullOrEmpty(host)
                ? $"{subject} on the connected computer ({place})."
                : $"{subject} on {host} ({place}).";
        }
        return string.IsNullOrEmpty(host)
            ? $"{subject} on the connected computer, not this device."
            : $"{subject} on {host}, not this device.";
    }

    /// <summary>
    /// Seconds from a value plus a minutes/seconds unit. Null means invalid,
    /// never zero: zero is No limit and is always explicit.
    /// </summary>
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

    /// <summary>
    /// Schedule payload for automation.create/edit and workflow.create/edit.
    /// Kinds: once, interval, daily, weekdays, weekly, custom. Weekly with a
    /// single day keeps using weekday; custom and weekdays use the bitset with
    /// Monday as bit 0 through Sunday as bit 6.
    /// </summary>
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
            return "Pick at least one day for a custom schedule.";
        }
        if (kind == "interval" && everySeconds < 60)
        {
            return "Pick an interval of at least one minute.";
        }
        return null;
    }

    public static readonly string[] ScheduleKinds =
        ["once", "interval", "daily", "weekdays", "weekly", "custom"];

    public static readonly string[] DayShortNames =
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

    public static readonly string[] DayNames =
        ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];

    /// <summary>
    /// Merge edited known fields back into the untouched raw object so unknown
    /// host fields round-trip. Never shown, never edited, written back intact.
    /// </summary>
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
