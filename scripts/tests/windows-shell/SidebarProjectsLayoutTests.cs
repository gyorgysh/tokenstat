// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Navigation;

internal static class SidebarProjectsLayoutTests
{
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }

    private static SidebarChatEntry Entry(string folder, string title, DateTime local, bool running = false, string branch = "") =>
        new(folder, folder, "This PC", new JsonObject
        {
            ["id"] = folder + "/" + title,
            ["title"] = title,
            ["branch"] = branch,
            ["backend"] = "codex",
            ["running"] = running,
            ["lastMessageAtMs"] = new DateTimeOffset(local).ToUnixTimeMilliseconds(),
        });

    public static void Run()
    {
        var now = new DateTime(2026, 11, 10, 15, 0, 0, DateTimeKind.Local);
        var entries = SidebarProjectsLayout.ChatEntries(new[]
        {
            Entry("api", "Old migration", now.AddDays(-20)),
            Entry("web", "Fix login", now.AddHours(-1)),
            Entry("api", "Ship build", now.AddDays(-3), running: true),
            Entry("web", "Yesterday chat", now.AddDays(-1)),
            Entry("api", "Three days", now.AddDays(-3)),
        }, "");
        Check(entries[0].Title == "Ship build", "A running chat did not lead the list");
        Check(entries.Select(e => e.Title).Skip(1).SequenceEqual(new[] { "Fix login", "Yesterday chat", "Three days", "Old migration" }),
            "Chats are not newest first after the running ones");

        var groups = SidebarProjectsLayout.DayGroups(entries, now);
        Check(groups.Select(g => g.Day.Kind).SequenceEqual(new[]
            { SidebarChatDayKind.Working, SidebarChatDayKind.Today, SidebarChatDayKind.Yesterday, SidebarChatDayKind.Day, SidebarChatDayKind.Older }),
            "Day headings are not Working, Today, Yesterday, a date, Older");
        Check(groups[3].Day.Date == now.AddDays(-3).Date && groups[3].Day.Id == "day:" + now.AddDays(-3).ToString("yyyy-MM-dd"),
            "A chat from this week did not get its own date");

        var byFolder = SidebarProjectsLayout.ChatEntries(entries, "WEB");
        Check(byFolder.Count == 2 && byFolder.All(e => e.FolderId == "web"), "A folder name hit did not keep that folder's chats");
        var byTitle = SidebarProjectsLayout.ChatEntries(entries, "migration");
        Check(byTitle.Count == 1 && byTitle[0].Title == "Old migration", "A title filter did not narrow the list");
        var byBranch = SidebarProjectsLayout.ChatEntries(new[] { Entry("api", "Plain", now, branch: "feature/café") }, "cafe");
        Check(byBranch.Count == 1, "Filtering is not accent insensitive on branches");

        var folders = new[] { ("beta", 5L), ("Alpha", 1L), ("gamma", 9L) };
        Check(SidebarProjectsLayout.OrderFolders(folders, SidebarProjectsSort.Manual, f => f.Item1, f => f.Item2)
            .Select(f => f.Item1).SequenceEqual(new[] { "beta", "Alpha", "gamma" }), "Manual order was changed");
        Check(SidebarProjectsLayout.OrderFolders(folders, SidebarProjectsSort.Name, f => f.Item1, f => f.Item2)
            .Select(f => f.Item1).SequenceEqual(new[] { "Alpha", "beta", "gamma" }), "Name order is not case insensitive");
        Check(SidebarProjectsLayout.OrderFolders(folders, SidebarProjectsSort.Recent, f => f.Item1, f => f.Item2)
            .Select(f => f.Item1).SequenceEqual(new[] { "gamma", "beta", "Alpha" }), "Recent order is not newest first");

        var chats = new JsonNode[] { new JsonObject { ["title"] = "Refactor parser" } };
        Check(SidebarProjectsLayout.FolderMatches("parser", "tokenstat", "This PC", chats), "A chat hit did not keep its folder");
        Check(!SidebarProjectsLayout.FolderMatches("nothing", "tokenstat", "This PC", chats), "A miss kept the folder");
        Check(SidebarProjectsLayout.ParseDisplay("future") == SidebarProjectsDisplay.ByRepository
            && SidebarProjectsLayout.ParseSort(null) == SidebarProjectsSort.Manual, "Unknown stored values did not fall back");
        Console.WriteLine("Sidebar layout: chat timeline, day headings, filter and folder sort passed");
    }
}
