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
        Console.WriteLine("Teams pages: fourth computer, fifty-first chat, boundary deduplication, cursor progress and target checks pass.");
    }
}
