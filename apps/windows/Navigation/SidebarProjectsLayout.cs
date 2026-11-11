// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Globalization;
using System.Text.Json.Nodes;

namespace Tokenstat.Navigation;

/// <summary>How the Repositories sidebar lists work. Same raw values as the Mac.</summary>
internal enum SidebarProjectsDisplay { ByRepository, ByChat }

/// <summary>Order inside the Repositories sidebar. Same raw values as the Mac.</summary>
internal enum SidebarProjectsSort { Manual, Name, Recent }

/// <summary>One chat drawn in the chat list, with the folder it belongs to.</summary>
internal sealed record SidebarChatEntry(string FolderId, string FolderName, string MachineLabel, JsonNode Chat)
{
    public string Id => SidebarProjectsLayout.Text(Chat, "id");
    public string Title => SidebarProjectsLayout.Text(Chat, "title");
    public bool Running => SidebarProjectsLayout.Flag(Chat, "running");

    /// <summary>The last message, or the last update when a chat has no message yet.</summary>
    public long ActivityMs
    {
        get
        {
            var last = SidebarProjectsLayout.Number(Chat, "lastMessageAtMs");
            return last > 0 ? last : SidebarProjectsLayout.Number(Chat, "updatedAtMs");
        }
    }
}

internal enum SidebarChatDayKind { Working, Today, Yesterday, Day, Older }

/// <summary>Which heading a chat sits under. <c>Date</c> is only set for <c>Day</c>.</summary>
internal readonly record struct SidebarChatDay(SidebarChatDayKind Kind, DateTime Date)
{
    public string Id => Kind switch
    {
        SidebarChatDayKind.Working => "working",
        SidebarChatDayKind.Today => "today",
        SidebarChatDayKind.Yesterday => "yesterday",
        SidebarChatDayKind.Older => "older",
        _ => "day:" + Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
    };
}

internal sealed record SidebarChatDayGroup(SidebarChatDay Day, IReadOnlyList<SidebarChatEntry> Entries);

/// <summary>
/// Filter, sort and day rules for the Repositories sidebar, kept free of WinUI
/// so they can be checked without a window. Mirrors the Mac
/// <c>SidebarProjectsLayout</c>.
/// </summary>
internal static class SidebarProjectsLayout
{
    /// <summary>Chats drawn before Show more, and how many more each press adds.</summary>
    public const int ChatPageSize = 30;
    /// <summary>Past this many days, chats share one Older heading instead of a day each.</summary>
    public const int OlderAfterDays = 7;

    public static string Raw(SidebarProjectsDisplay display) =>
        display == SidebarProjectsDisplay.ByChat ? "byChat" : "byRepository";

    public static SidebarProjectsDisplay ParseDisplay(string? raw) =>
        raw == "byChat" ? SidebarProjectsDisplay.ByChat : SidebarProjectsDisplay.ByRepository;

    public static string Raw(SidebarProjectsSort sort) => sort switch
    {
        SidebarProjectsSort.Name => "name",
        SidebarProjectsSort.Recent => "recent",
        _ => "manual",
    };

    public static SidebarProjectsSort ParseSort(string? raw) => raw switch
    {
        "name" => SidebarProjectsSort.Name,
        "recent" => SidebarProjectsSort.Recent,
        _ => SidebarProjectsSort.Manual,
    };

    /// <summary>A folder survives the filter when its name, machine or any of its chats match.</summary>
    public static bool FolderMatches(string query, string folderName, string machineLabel, IEnumerable<JsonNode> chats)
    {
        var needle = query.Trim();
        if (needle.Length == 0) return true;
        return FolderNameMatches(needle, folderName, machineLabel) || chats.Any(chat => ChatMatches(needle, chat));
    }

    public static bool FolderNameMatches(string query, string folderName, string machineLabel)
    {
        var needle = query.Trim();
        return needle.Length == 0 || Contains(folderName, needle) || Contains(machineLabel, needle);
    }

    /// <summary>Title, branch or agent.</summary>
    public static bool ChatMatches(string query, JsonNode chat)
    {
        var needle = query.Trim();
        if (needle.Length == 0) return true;
        return Contains(Text(chat, "title"), needle) || Contains(Text(chat, "branch"), needle)
            || Contains(Text(chat, "backend"), needle);
    }

    /// <summary>Folders in the chosen order. Recent uses each folder's newest chat.</summary>
    public static List<T> OrderFolders<T>(IEnumerable<T> folders, SidebarProjectsSort sort,
        Func<T, string> name, Func<T, long> activity) => sort switch
    {
        SidebarProjectsSort.Name => folders.OrderBy(name, NameOrder).ToList(),
        SidebarProjectsSort.Recent => folders.OrderByDescending(activity).ThenBy(name, NameOrder).ToList(),
        _ => folders.ToList(),
    };

    /// <summary>
    /// Every chat that survives the filter, running first, then newest first.
    /// The chat list is a timeline, so the repository sort does not apply.
    /// </summary>
    public static List<SidebarChatEntry> ChatEntries(IEnumerable<SidebarChatEntry> entries, string query)
    {
        var needle = query.Trim();
        return entries
            .Where(entry => needle.Length == 0 || FolderNameMatches(needle, entry.FolderName, entry.MachineLabel)
                || ChatMatches(needle, entry.Chat))
            .OrderByDescending(entry => entry.Running)
            .ThenByDescending(entry => entry.ActivityMs)
            .ThenBy(entry => entry.Title, NameOrder)
            .ToList();
    }

    /// <summary>
    /// Splits ordered entries into Working, Today, Yesterday, one heading per
    /// day of the past week, and Older, keeping their order.
    /// </summary>
    public static List<SidebarChatDayGroup> DayGroups(IReadOnlyList<SidebarChatEntry> entries, DateTime nowLocal)
    {
        var today = nowLocal.Date;
        var order = new List<SidebarChatDay>();
        var buckets = new Dictionary<SidebarChatDay, List<SidebarChatEntry>>();
        foreach (var entry in entries)
        {
            var day = DayOf(entry, today);
            if (!buckets.TryGetValue(day, out var bucket))
            {
                buckets[day] = bucket = new List<SidebarChatEntry>();
                order.Add(day);
            }
            bucket.Add(entry);
        }
        return order.Select(day => new SidebarChatDayGroup(day, buckets[day])).ToList();
    }

    private static SidebarChatDay DayOf(SidebarChatEntry entry, DateTime today)
    {
        if (entry.Running) return new(SidebarChatDayKind.Working, default);
        var ms = entry.ActivityMs;
        var date = ms > 0 ? DateTimeOffset.FromUnixTimeMilliseconds(ms).ToLocalTime().Date : DateTime.MinValue.Date;
        var days = (today - date).Days;
        if (days <= 0) return new(SidebarChatDayKind.Today, default);
        if (days == 1) return new(SidebarChatDayKind.Yesterday, default);
        if (days < OlderAfterDays) return new(SidebarChatDayKind.Day, date);
        return new(SidebarChatDayKind.Older, default);
    }

    private static readonly StringComparer NameOrder = StringComparer.Create(CultureInfo.CurrentCulture, ignoreCase: true);

    private static bool Contains(string haystack, string needle) =>
        haystack.Length > 0 && CultureInfo.CurrentCulture.CompareInfo.IndexOf(haystack, needle,
            CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace) >= 0;

    internal static string Text(JsonNode? node, string key) =>
        node?[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : "";

    internal static bool Flag(JsonNode? node, string key) =>
        node?[key] is JsonValue value && value.TryGetValue<bool>(out var flag) && flag;

    internal static long Number(JsonNode? node, string key)
    {
        if (node?[key] is not JsonValue value) return 0;
        if (value.TryGetValue<long>(out var whole)) return whole;
        return value.TryGetValue<double>(out var real) ? (long)real : 0;
    }
}
