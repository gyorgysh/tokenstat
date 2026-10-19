// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json;
using Tokenstat.Navigation;

internal static class DesktopOpenRequestTests
{
    public static void Run()
    {
        using var examples = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "desktop-actions.json")));
        string? Read(JsonElement item, string key) => item.TryGetProperty(key, out var value) ? value.GetString() : null;
        var count = 0;
        foreach (var example in examples.RootElement.EnumerateArray())
        {
            count++;
            var request = DesktopOpenRequest.Parse(Read(example, "url"));
            var tool = Read(example, "tool");
            var name = Read(example, "name");
            if (tool is null) { if (request is not null) throw new Exception(name); continue; }
            if (request is null || request.Tool.ToString().ToLowerInvariant() != tool || request.WorkspaceId != Read(example, "workspace")
                || request.InspectorTab != Read(example, "tab") || request.BrowserUrl?.AbsoluteUri != Read(example, "browser")
                || request.SessionId != Read(example, "session")
                || request.CommitId != Read(example, "commit")
                || request.NewTerminal != (example.TryGetProperty("new", out var spawn) && spawn.GetBoolean())) throw new Exception(name);
        }
        if (DesktopOpenRequest.Parse("tokenstat://workbench/open?workspace=" + new string('a', 4097) + "&tool=changes") is not null)
            throw new Exception("Oversized project accepted");
        foreach (var size in new[] { 2048, 2049 })
        {
            var address = "tokenstat://workbench/open?workspace=" + string.Concat(Enumerable.Repeat("%C3%A9", size)) + "&tool=changes";
            if ((DesktopOpenRequest.Parse(address) is not null) != (size == 2048)) throw new Exception("Project bounds must count decoded UTF-8 bytes");
        }
        if (DesktopOpenRequest.Parse("tokenstat://workbench/open?workspace=project-a&tool=terminal&session=" + new string('a', 513)) is not null)
            throw new Exception("Oversized session accepted");
        Console.WriteLine($"Desktop action contract: {count} shared Mac/Windows cases passed");
    }
}
