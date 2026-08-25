// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal static class Format
{
    /// <summary>List-rate micros as a dollar figure. Never a charge.</summary>
    public static string ListRate(long micros)
    {
        var dollars = micros / 1_000_000d;
        return dollars.ToString("C2", CultureInfo.GetCultureInfo("en-US"));
    }

    public static string Tokens(long n)
    {
        if (n >= 1_000_000)
        {
            return (n / 1_000_000d).ToString("0.0") + "M";
        }
        if (n >= 1_000)
        {
            return (n / 1_000d).ToString("0.0") + "k";
        }
        return n.ToString("N0", CultureInfo.InvariantCulture);
    }

    public static long Long(JsonNode? node, string name) =>
        (long)Math.Round(Number(node, name));

    public static double Number(JsonNode? node, string name)
    {
        var value = node?[name];
        if (value is null || value.GetValueKind() is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            return 0;
        }
        try
        {
            return value.GetValueKind() switch
            {
                JsonValueKind.Number => value.GetValue<double>(),
                JsonValueKind.String => double.TryParse(
                    value.GetValue<string>(),
                    NumberStyles.Any,
                    CultureInfo.InvariantCulture,
                    out var n)
                    ? n
                    : 0,
                JsonValueKind.True => 1,
                JsonValueKind.False => 0,
                _ => 0,
            };
        }
        catch
        {
            return 0;
        }
    }

    public static bool Flag(JsonNode? node, string name) =>
        node?[name] is JsonValue v && v.GetValueKind() == JsonValueKind.True;

    public static string Text(JsonNode? node, string name, string fallback = "")
    {
        if (node is not JsonObject)
        {
            return fallback;
        }
        var value = node?[name];
        if (value is null || value.GetValueKind() is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            return fallback;
        }
        if (value.GetValueKind() == JsonValueKind.String)
        {
            return value.GetValue<string>() ?? fallback;
        }
        var printed = value.ToJsonString().Trim('"');
        return string.IsNullOrEmpty(printed) ? fallback : printed;
    }

    /// <summary>
    /// JSON array of 0–255 numbers, as the SSH session methods speak them.
    /// </summary>
    public static byte[] Bytes(JsonNode? node)
    {
        if (node is not JsonArray array)
        {
            return [];
        }
        var bytes = new byte[array.Count];
        for (var i = 0; i < array.Count; i++)
        {
            var n = array[i];
            if (n is null)
            {
                continue;
            }
            try
            {
                bytes[i] = n.GetValueKind() switch
                {
                    JsonValueKind.Number => (byte)Math.Clamp((int)n.GetValue<double>(), 0, 255),
                    JsonValueKind.String => byte.TryParse(n.GetValue<string>(), out var b) ? b : (byte)0,
                    _ => (byte)0,
                };
            }
            catch
            {
                bytes[i] = 0;
            }
        }
        return bytes;
    }

    public static JsonArray ByteArray(byte[] bytes)
    {
        var array = new JsonArray();
        foreach (var b in bytes)
        {
            array.Add(JsonValue.Create((int)b));
        }
        return array;
    }

    /// <summary>Host list methods return a bare array or a named wrapper.</summary>
    public static JsonArray? Items(JsonNode? node, params string[] keys)
    {
        if (node is JsonArray array)
        {
            return array;
        }
        if (node is not JsonObject)
        {
            return null;
        }
        foreach (var key in keys)
        {
            if (node[key] is JsonArray named)
            {
                return named;
            }
        }
        return node["items"] as JsonArray
            ?? node["cards"] as JsonArray
            ?? node["jobs"] as JsonArray
            ?? node["workflows"] as JsonArray
            ?? node["notes"] as JsonArray
            ?? node["hosts"] as JsonArray
            ?? node["keys"] as JsonArray
            ?? node["sessions"] as JsonArray;
    }

    /// <summary>
    /// Folder filter used by Tasks and Notes: an empty workspace id is
    /// unscoped and still belongs on this folder's board.
    /// </summary>
    public static bool InWorkspace(JsonNode? item, string? workspaceId, bool includeUnscoped)
    {
        if (string.IsNullOrEmpty(workspaceId))
        {
            return true;
        }
        var id = Text(item, "workspaceId");
        if (includeUnscoped && string.IsNullOrEmpty(id))
        {
            return true;
        }
        return id == workspaceId;
    }

    public static bool IsLegend(string? tier) =>
        string.Equals(tier?.Trim(), "legend", StringComparison.OrdinalIgnoreCase);

    /// <summary>One line for an automation schedule, matching the Mac summary.</summary>
    public static string Cadence(JsonNode? item)
    {
        var written = Text(item, "cadence");
        if (!string.IsNullOrEmpty(written))
        {
            return written;
        }
        var schedule = item?["schedule"] ?? item;
        var kind = Text(schedule, "kind", "once");
        var hour = Long(schedule, "hour");
        var minute = Long(schedule, "minute");
        var time = $"{hour}:{minute:00}";
        return kind switch
        {
            "interval" => IntervalLabel(Long(schedule, "everySeconds")),
            "daily" => "daily at " + time,
            "weekdays" => "weekdays at " + time,
            "weekly" => WeeklyLabel(schedule, time),
            "custom" => CustomLabel(schedule, time),
            _ => "once, when you run it",
        };
    }

    private static string IntervalLabel(long everySeconds)
    {
        var minutes = Math.Max(1, everySeconds / 60);
        if (minutes >= 60 && minutes % 60 == 0)
        {
            var hours = minutes / 60;
            return hours == 1 ? "every 1 hour" : $"every {hours} hours";
        }
        return minutes == 1 ? "every 1 minute" : $"every {minutes} minutes";
    }

    private static string WeeklyLabel(JsonNode? schedule, string time)
    {
        var mask = Long(schedule, "weekdays");
        if (mask != 0)
        {
            return DayList(mask) + " at " + time;
        }
        var names = new[] { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
        var day = (int)Long(schedule, "weekday");
        var name = day >= 0 && day < names.Length ? names[day] : "?";
        return name + " at " + time;
    }

    private static string CustomLabel(JsonNode? schedule, string time)
    {
        var days = DayList(Long(schedule, "weekdays"));
        return string.IsNullOrEmpty(days) ? "custom at " + time : days + " at " + time;
    }

    private static string DayList(long mask)
    {
        var shortNames = new[] { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
        var parts = new List<string>();
        for (var bit = 0; bit < 7; bit++)
        {
            if ((mask & (1 << bit)) != 0)
            {
                parts.Add(shortNames[bit]);
            }
        }
        return string.Join(", ", parts);
    }
}
