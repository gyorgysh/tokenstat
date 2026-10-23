// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using System.Text;
using Tokenstat.Pages;

internal static class TeamSharedFileTests
{
    internal static async Task RunAsync()
    {
        static void Check(bool value, string message) { if (!value) throw new Exception(message); }
        static void Refuses(Action run) { try { run(); } catch (InvalidDataException) { return; } throw new Exception("Unsafe shared file accepted"); }
        var bytes = System.Text.Encoding.UTF8.GetBytes("Fictional shared document");
        JsonObject Reply() => new() { ["shareId"] = "share", ["attachment"] = new JsonObject { ["id"] = "file", ["name"] = "../../fictional.txt", ["mediaType"] = "text/plain", ["size"] = (long)bytes.Length }, ["data"] = Convert.ToBase64String(bytes) };
        var file = TeamSharedFileData.Read(Reply(), "share", "file");
        Check(file.Name == "fictional.txt" && file.Bytes.SequenceEqual(bytes) && !file.IsRaster, "Shared file bytes or safe name changed");
        Refuses(() => TeamSharedFileData.Read(Reply(), "another-share", "file"));
        Refuses(() => TeamSharedFileData.Read(Reply(), "share", "another-file"));
        var size = Reply(); size["attachment"]!["size"] = 999L; Refuses(() => TeamSharedFileData.Read(size, "share", "file"));
        var large = Reply(); large["attachment"]!["size"] = (long)TeamSharedFileData.MaximumBytes + 1; Refuses(() => TeamSharedFileData.Read(large, "share", "file"));
        var bad = Reply(); bad["data"] = "not base64!"; Refuses(() => TeamSharedFileData.Read(bad, "share", "file"));
        var stringSize = Reply(); stringSize["attachment"]!["size"] = "24"; Refuses(() => TeamSharedFileData.Read(stringSize, "share", "file"));
        Check(TeamSharedFileData.SafeName("C:\\fictional\\CON.txt") == "_CON.txt" && TeamSharedFileData.SafeName("../..") == "shared-file"
            && TeamSharedFileData.SafeName("a\u202E.txt\n") == "a.txt" && TeamSharedFileData.SafeName(string.Concat(Enumerable.Repeat("🙂", 150))).EnumerateRunes().Count() == 120,
            "Shared filename allowed a path, reserved name, direction control or broken Unicode boundary");
        var svg = Reply(); svg["attachment"]!["mediaType"] = "IMAGE/SVG+XML"; Check(!TeamSharedFileData.Read(svg, "share", "file").IsRaster, "SVG entered native image decoding");
        if (OperatingSystem.IsWindows())
        {
            var root = Path.Combine(Path.GetTempPath(), "teams-save-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
            try
            {
                var path = Path.Combine(root, "fictional.txt"); await TeamSharedFileSave.WriteMarked(path, bytes, () => true);
                Check((await File.ReadAllBytesAsync(path)).SequenceEqual(bytes) && (await File.ReadAllTextAsync(path + ":Zone.Identifier")).Contains("ZoneId=3", StringComparison.Ordinal), "Saved file lost its Internet-zone mark");
                var calls = 0;
                try { await TeamSharedFileSave.WriteMarked(path, [1, 2, 3], () => ++calls == 1); throw new Exception("Stale save completed"); } catch (OperationCanceledException) { }
                Check((await File.ReadAllBytesAsync(path)).SequenceEqual(bytes) && !Directory.EnumerateFiles(root, ".tokenstat-shared-*").Any(), "Stale save overwrote the destination or left staging bytes");
            }
            finally { Directory.Delete(root, true); }
        }
        Console.WriteLine("Teams shared files: chat/file binding, size/base64 bounds, safe Unicode names and SVG exclusion pass; "
            + (OperatingSystem.IsWindows() ? "Windows marked atomic saves pass." : "marked saves await Windows runtime."));
    }
}
