// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Tokenstat.Pages;

/// <summary>Original project targets only. Tunnel addresses never enter this store.</summary>
internal sealed class BrowserHistory
{
    public const int Capacity = 8;
    private readonly string _path;
    private readonly Dictionary<string, List<string>> _entries = new(StringComparer.Ordinal);
    public BrowserHistory(string path)
    {
        _path = path;
        try
        {
            using var saved = JsonDocument.Parse(File.ReadAllText(path));
            if (saved.RootElement.ValueKind != JsonValueKind.Object) return;
            foreach (var entry in saved.RootElement.EnumerateObject())
            {
                if (entry.Value.ValueKind != JsonValueKind.Array) continue;
                foreach (var target in entry.Value.EnumerateArray().Reverse())
                    if (target.ValueKind == JsonValueKind.String) RememberCore(entry.Name, target.GetString() ?? "");
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        catch (JsonException) { }
    }

    public static string AccountScope(string origin, string identity)
    {
        if (Uri.TryCreate(origin, UriKind.Absolute, out var server))
            origin = server.GetLeftPart(UriPartial.Authority).ToLowerInvariant() + server.AbsolutePath.TrimEnd('/');
        return Key(origin, identity);
    }
    public static string Key(params string[] components) => Convert.ToHexString(
        SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(components))));
    public IReadOnlyList<string> Read(string owner) => _entries.TryGetValue(owner, out var targets) ? targets.ToArray() : [];
    public bool Remember(string owner, string raw)
    {
        if (!RememberCore(owner, raw)) return false;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(_entries));
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        return true;
    }
    private bool RememberCore(string owner, string raw)
    {
        if (owner.Length == 0 || CanonicalTarget(raw) is not string target) return false;
        if (!_entries.TryGetValue(owner, out var targets)) _entries[owner] = targets = [];
        var origin = new Uri(target).GetLeftPart(UriPartial.Authority);
        targets.RemoveAll(old => new Uri(old).GetLeftPart(UriPartial.Authority) == origin);
        targets.Insert(0, target);
        if (targets.Count > Capacity) targets.RemoveRange(Capacity, targets.Count - Capacity);
        return true;
    }
    public static string? CanonicalTarget(string raw)
    {
        var value = raw.Trim();
        if (ushort.TryParse(value, out var port))
        {
            if (port == 0) return null;
            value = $"http://127.0.0.1:{port}/";
        }
        else if (value.Length > 0 && value.All(char.IsDigit)) return null;
        else if (!value.Contains("://", StringComparison.Ordinal))
        {
            if (!Uri.TryCreate("http://" + value, UriKind.Absolute, out var probe)) return null;
            value = (IsLoopback(probe) ? "http://" : "https://") + value;
        }
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Host.Length == 0 || uri.Port <= 0
            || uri.Scheme is not ("http" or "https") || uri.UserInfo.Length > 0) return null;
        return uri.AbsoluteUri;
    }
    public static bool IsLoopback(Uri uri) => uri.IsLoopback || uri.Host == "0.0.0.0";
}
