// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Navigation;

internal static class SidebarPreferencesTests
{
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }

    public static void Run(string directory)
    {
        var path = Path.Combine(directory, "sidebar.json");
        var preferences = new SidebarPreferences(path);
        Check(preferences.SectionOrder.SequenceEqual(["projects", "servers"]), "Missing settings changed section order");
        Check(preferences.IsExpanded("row:new", true), "New rows lost their expansion default");
        preferences.RememberExpansion("row:ws:local:Launcher", false);
        preferences.RememberExpansion("row:machine:remote", true);
        preferences.RememberExpansion("history:local", true);
        preferences.RememberExpansion("row:ssh:Hosts", false);
        preferences.RememberExpansion("section:projects", false);
        preferences.Move("servers", "projects");
        var reopened = new SidebarPreferences(path);
        Check(!reopened.IsExpanded("row:ws:local:Launcher", true), "Collapsed project was not restored");
        Check(reopened.IsExpanded("row:machine:remote", false), "Disconnected machine lost its disclosure choice");
        Check(reopened.ExpandedIDs("history:").SetEquals(["local"]), "Expanded history was not restored");
        Check(!reopened.IsExpanded("row:ssh:Hosts", true) && !reopened.IsExpanded("section:projects", true), "Collapsed sections were not restored");
        Check(reopened.SectionOrder.SequenceEqual(["servers", "projects"]), "Section order did not survive reopening");

        File.WriteAllText(path, """
            {"futureSetting":{"version":8},"expanded":{"future:row":{"mode":"automatic"},"row:number":1,"row:string":"open"},
             "sectionOrder":["future",{"version":8},"servers","servers","projects",7]}
            """);
        reopened = new SidebarPreferences(path);
        Check(!reopened.IsExpanded("row:number", false) && reopened.IsExpanded("row:string", true), "Malformed choices did not use independent defaults");
        Check(reopened.SectionOrder.SequenceEqual(["servers", "projects"]), "Unknown or duplicate section rendered");
        reopened.Move("projects", "servers");
        reopened.RememberExpansion("row:ws:local:Launcher", true);
        var raw = JsonNode.Parse(File.ReadAllText(path))!;
        Check(raw["futureSetting"]?["version"]?.GetValue<int>() == 8, "Writing discarded a future setting");
        Check(raw["expanded"]?["future:row"]?["mode"]?.GetValue<string>() == "automatic", "Writing discarded a future disclosure mode");
        Check(raw["sectionOrder"]!.AsArray().Any(value => value is JsonObject obj && obj["version"]?.GetValue<int>() == 8)
            && raw["sectionOrder"]!.AsArray().Any(value => value is JsonValue v && v.TryGetValue<string>(out var name) && name == "future"), "Moving sections discarded future order values");
        Check(reopened.SectionOrder.SequenceEqual(["projects", "servers"]), "Moving known sections failed");
        var secondWindow = new SidebarPreferences(path);
        reopened.RememberExpansion("row:firstWindow", false);
        secondWindow.RememberExpansion("row:secondWindow", false);
        var merged = new SidebarPreferences(path);
        Check(!merged.IsExpanded("row:firstWindow", true) && !merged.IsExpanded("row:secondWindow", true), "A stale window overwrote another window's choice");
        Check(!Directory.EnumerateFiles(directory, "sidebar.json.*.tmp").Any(), "Atomic saves left temporary files behind");

        foreach (var invalid in new[] { "not json", "42", "{\"sectionOrder\":false,\"expanded\":[]}", "{\"sectionOrder\":[\"future\"]}",
            "{\"expanded\":{\"row:new\":false,\"row:new\":false}}", "{\"expanded\":{\"row:new\":false},\"expanded\":{\"row:new\":false}}" })
        {
            File.WriteAllText(path, invalid);
            var recovered = new SidebarPreferences(path);
            Check(recovered.SectionOrder.SequenceEqual(["projects", "servers"]), "Unsupported preferences prevented a default layout");
            Check(recovered.IsExpanded("row:new", true), "Invalid preferences blocked a default disclosure");
        }
        Console.WriteLine("Sidebar preferences: disclosure/order persistence, absent peers, unknown future data and malformed settings passed");
    }
}
