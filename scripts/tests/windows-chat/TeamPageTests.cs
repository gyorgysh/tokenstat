// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;

internal static class TeamPageTests
{
    internal static void Run()
    {
        static void Check(bool answer) { if (!answer) throw new Exception("Team page regression"); }
        static JsonObject Row(int n) => new() { ["id"] = $"row-{n}", ["checkoutId"] = "computer" };
        static JsonObject Page(string key, IEnumerable<int> rows) => new() { [key] = new JsonArray(rows.Select(n => (JsonNode)Row(n)).ToArray()) };
        static void Refuses(Action action) { try { action(); throw new Exception("expected page refusal"); } catch (InvalidDataException) { } }
        var first = Page("checkouts", [0, 1, 2]); first["nextOffset"] = 3;
        var a = TeamDirectoryPage.Read(first, "checkouts", 0);
        var b = TeamDirectoryPage.Read(Page("checkouts", [3]), "checkouts", a.Next!.Value);
        Check(TeamCatalogPage.Append(a.Rows, b.Rows).Count == 4 && b.Next is null);
        var catalog = Page("shares", Enumerable.Range(0, 50)); catalog["nextCursor"] = "next";
        var c = TeamCatalogPage.Read(catalog, "computer", null);
        var d = TeamCatalogPage.Read(Page("shares", [49, 50]), "computer", c.Next);
        Check(TeamCatalogPage.Append(c.Rows, d.Rows).Count == 51);
        Refuses(() => TeamDirectoryPage.Read(first, "checkouts", 3));
        Refuses(() => TeamCatalogPage.Read(catalog, "computer", "next"));
        Refuses(() => TeamCatalogPage.Read(catalog, "foreign", null));
        Refuses(() => TeamCatalogPage.Read(Page("shares", [1, 1]), "computer", null));
        var empty = Page("shares", []); empty["nextCursor"] = "next";
        Check(TeamCatalogPage.Read(empty, "computer", null).Next == "next");
        Check(TeamCatalogPage.Read(empty, "computer", null).Backends.Count == 0);
        string[] backendIds = ["claude", "codex", "muse", "grok", "cursor", "agy", "opencode", "opencode2"];
        var backendPage = Page("shares", []);
        backendPage["backends"] = new JsonArray(backendIds.Select(id => (JsonNode)new JsonObject { ["id"] = id, ["label"] = "Publisher " + id }).ToArray());
        var advertised = TeamCatalogPage.Read(backendPage, "computer", null).Backends;
        Check(advertised.Select(option => option.Id).SequenceEqual(backendIds) && advertised[5].Label == "Publisher agy");
        Check(TeamBackendOption.Read(new JsonObject()).Count == 0);
        var invalid = new JsonArray(null, new JsonObject { ["id"] = "" }, new JsonObject { ["id"] = "UPPER" }, new JsonObject { ["id"] = "slash/name" },
            new JsonObject { ["id"] = "é" }, new JsonObject { ["id"] = new string('x', 65) }, new JsonObject { ["id"] = "blank", ["label"] = "  " },
            new JsonObject { ["id"] = "long", ["label"] = new string('x', 129) }, new JsonObject { ["id"] = "wrong", ["label"] = 4 },
            new JsonObject { ["id"] = "multiline", ["label"] = "Agent\nname" }, new JsonObject { ["id"] = "hidden", ["label"] = "\u200b" },
            new JsonObject { ["id"] = "claude", ["label"] = "First" }, new JsonObject { ["id"] = "claude", ["label"] = "Duplicate" }, new JsonObject { ["id"] = "future-agent_v2" });
        Check(TeamBackendOption.Read(invalid).SequenceEqual(new[] { new TeamBackendOption("claude", "First"), new TeamBackendOption("future-agent_v2", "future-agent_v2") }));
        var many = new JsonArray(Enumerable.Range(0, 1000).Select(i => (JsonNode)new JsonObject { ["id"] = $"agent-{i}" }).ToArray());
        Check(TeamBackendOption.Read(many).Count == 32 && TeamBackendOption.Read(many)[^1].Id == "agent-31");
        var duplicates = new JsonArray(Enumerable.Range(0, 32).Select(_ => (JsonNode)new JsonObject { ["id"] = "claude" }).Append(new JsonObject { ["id"] = "outside-cap" }).ToArray());
        var invalidPrefix = new JsonArray(Enumerable.Repeat<JsonNode?>(null, 32).Append(new JsonObject { ["id"] = "outside-cap" }).ToArray());
        Check(TeamBackendOption.Read(duplicates).Select(option => option.Id).SequenceEqual(new[] { "claude" }) && TeamBackendOption.Read(invalidPrefix).Count == 0);
        Console.WriteLine("Teams pages: fourth computer, fifty-first chat, boundary deduplication, cursor progress and target checks pass.");
    }
}
