// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using static Tokenstat.Pages.TeamManagementModel;

namespace Tokenstat.Pages;

internal sealed record TeamSharedFileData(string Name, string MediaType, byte[] Bytes)
{
    internal const int MaximumBytes = 5 * 1024 * 1024;
    internal static string SafeName(string name)
    {
        var leaf = name.Replace('\\', '/').Split('/').Last();
        var clean = string.Concat(leaf.EnumerateRunes().Where(r => !Rune.IsControl(r) && Rune.GetUnicodeCategory(r) != UnicodeCategory.Format
            && !"<>:\"/\\|?*".Contains(r.ToString(), StringComparison.Ordinal)).Take(120)).Trim().TrimEnd('.');
        if (clean.Length == 0 || clean is "." or "..") return "shared-file";
        if (Regex.IsMatch(clean.Split('.')[0], "^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)) clean = "_" + clean;
        return clean;
    }
    internal static TeamSharedFileData Read(JsonNode reply, string share, string id)
    {
        Require(Text(reply, "shareId") == share && Text(reply["attachment"], "id") == id);
        var attachment = reply["attachment"] as JsonObject ?? throw new InvalidDataException();
        var size = Revision(attachment, "size"); var data = Text(reply, "data");
        Require(size <= MaximumBytes && data.Length <= 8 * 1024 * 1024);
        byte[] bytes;
        try { bytes = Convert.FromBase64String(data); } catch (FormatException) { throw new InvalidDataException(); }
        Require(bytes.LongLength == size && bytes.Length <= MaximumBytes);
        var media = Text(attachment, "mediaType").ToLowerInvariant();
        if (media.Length > 160 || !Regex.IsMatch(media, "^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$")) media = "application/octet-stream";
        return new(SafeName(Text(attachment, "name")), media, bytes);
    }
    internal bool IsRaster => MediaType.StartsWith("image/", StringComparison.Ordinal) && MediaType != "image/svg+xml";
}

internal static class TeamSharedFileSave
{
    /// Stage the downloaded bytes and their Windows Internet-zone mark on the
    /// destination volume, then move them together. Never publish unmarked data.
    internal static async Task WriteMarked(string destination, byte[] bytes, Func<bool> current)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        if (bytes.Length > TeamSharedFileData.MaximumBytes) throw new InvalidDataException();
        if (!current()) throw new OperationCanceledException();
        var directory = Path.GetDirectoryName(Path.GetFullPath(destination)) ?? throw new InvalidDataException();
        var staged = Path.Combine(directory, ".tokenstat-shared-" + Guid.NewGuid().ToString("N") + ".download");
        try
        {
            await using (var output = new FileStream(staged, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await output.WriteAsync(bytes); await output.FlushAsync(); output.Flush(true);
            }
            await File.WriteAllTextAsync(staged + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\n", Encoding.ASCII);
            if (!current()) throw new OperationCanceledException();
            File.Move(staged, destination, true);
        }
        finally { if (File.Exists(staged)) File.Delete(staged); }
    }
}
