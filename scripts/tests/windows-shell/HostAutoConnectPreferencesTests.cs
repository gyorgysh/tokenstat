// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Navigation;

internal static class HostAutoConnectPreferencesTests
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }

    public static void Run(string directory)
    {
        var oldPath = Path.Combine(directory, "remote-autoconnect.json");
        var path = Path.Combine(directory, "remote-autoconnect-scoped.json");
        File.WriteAllText(oldPath, "{\"host-a\":false,\"host-b\":true,\"host-c\":false}");
        var prefs = new HostAutoConnectPreferences(path, oldPath);
        Check(!prefs.IsEnabled(null, "host-a"), "Unknown account started a dial");
        prefs.Set(null, "host-a", true);
        Check(!File.Exists(path), "Unknown account wrote a preference");
        prefs.Migrate("account-a", ["host-a", "host-b"]);
        Check(!prefs.IsEnabled("account-a", "host-a") && prefs.IsEnabled("account-a", "host-b"),
            "Listed legacy hosts were not migrated");
        Check(prefs.IsEnabled("account-a", "host-c"), "Unlisted old host leaked into this account");
        prefs.Migrate("account-b", ["host-a", "host-c"]);
        Check(prefs.IsEnabled("account-b", "host-a") && !prefs.IsEnabled("account-b", "host-c"),
            "Legacy choice was not claimed once by its account");
        prefs.Set("account-a", "host-b", false);
        prefs.Set("account-b", "host-a", false);
        var reopened = new HostAutoConnectPreferences(path, oldPath);
        Check(!reopened.IsEnabled("account-a", "host-a") && !reopened.IsEnabled("account-a", "host-b")
            && !reopened.IsEnabled("account-b", "host-a"), "Disconnect did not survive restart");
        reopened.Set("account-a", "host-a", true);
        Check(reopened.IsEnabled("account-a", "host-a") && !reopened.IsEnabled("account-b", "host-a"),
            "Reconnect choice crossed accounts");
        var raw = JsonNode.Parse(File.ReadAllText(path))!;
        Check(raw["claimedLegacyPeers"]?["host-a"]?.GetValue<bool>() == true,
            "Old preference can be replayed by another account");
        Console.WriteLine("Host auto-connect preferences: account isolation, safe migration and restart passed");
    }
}
