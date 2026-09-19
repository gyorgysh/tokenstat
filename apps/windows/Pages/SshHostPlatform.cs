// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>Verified SSH platform hints, scoped to the saved endpoint and host keys.</summary>
internal static class SshHostPlatform
{
    private sealed record Entry(string Endpoint, string Label, string Name, long CheckedAt);
    private static readonly string CachePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "ssh-platforms.json");
    private static readonly Dictionary<string, Entry> Cache = Read();
    private static readonly HashSet<string> Checking = new();
    private static Dictionary<string, Entry> Read()
    {
        try { return JsonSerializer.Deserialize<Dictionary<string, Entry>>(File.ReadAllText(CachePath)) ?? new(); }
        catch { return new(); }
    }
    private static string Endpoint(JsonNode host) => Format.Text(host, "hostname").ToLowerInvariant() + ":" + Format.Long(host, "port") + ":" +
        string.Join(",", (host["hostKeys"] as JsonArray ?? new()).Select(key => key?.ToString() ?? "").Order());
    public static string? Label(JsonNode? host) => host is not null && Cache.TryGetValue(Format.Text(host, "id"), out var entry) && entry.Endpoint == Endpoint(host) ? entry.Label : null;
    public static string SessionLabel(JsonNode? session)
    {
        if (Cache.TryGetValue(Format.Text(session, "hostId"), out var entry) && !string.IsNullOrWhiteSpace(entry.Name)) return entry.Name;
        var label = Format.Text(session, "label", "SSH session");
        return label.Contains('@') || System.Net.IPAddress.TryParse(label, out _) ? "SSH session" : label;
    }
    public static FrameworkElement SessionRow(JsonNode? session) => Row(
        Cache.TryGetValue(Format.Text(session, "hostId"), out var entry) ? entry.Label : null,
        new TextBlock { Text = SessionLabel(session), TextTrimming = TextTrimming.CharacterEllipsis });
    public static FrameworkElement Row(string? platform, FrameworkElement content)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var distro = Distro(platform);
        row.Children.Add(distro is not null ? AgentMark.AssetView("distro_" + distro, 30) : string.IsNullOrEmpty(platform)
            ? new Border { Width = 30, Height = 30, Background = Theme.AccentSoftBrush, CornerRadius = new CornerRadius(8), Child = new FontIcon { Glyph = "\uE968", FontSize = 16, Foreground = Theme.AccentBrush } }
            : Marks.Device(platform, size: 30));
        Grid.SetColumn(content, 1); row.Children.Add(content);
        if (!string.IsNullOrEmpty(platform)) ToolTipService.SetToolTip(row, platform);
        return row;
    }
    private static string? Distro(string? platform)
    {
        var name = (platform ?? "").ToLowerInvariant();
        foreach (var (term, asset) in new[] { ("ubuntu", "ubuntu"), ("debian", "debian"), ("fedora", "fedora"), ("alpine", "alpinelinux"), ("arch", "archlinux"), ("nixos", "nixos"), ("mint", "linuxmint"), ("gentoo", "gentoo"), ("rocky", "rockylinux"), ("alma", "almalinux"), ("centos", "centos"), ("red hat", "redhat"), ("rhel", "redhat"), ("opensuse", "opensuse"), ("suse", "suse"), ("linux", "linux") })
            if (name.Contains(term, StringComparison.Ordinal)) return asset;
        return null;
    }
    public static async Task<bool> RememberAsync(JsonObject host, JsonObject connection)
    {
        var id = Format.Text(host, "id");
        if (id.Length == 0 || Checking.Contains(id)) return false;
        var endpoint = Endpoint(host);
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        if (Cache.TryGetValue(id, out var previous) && previous.Endpoint == endpoint && now - previous.CheckedAt < TimeSpan.FromDays(7).TotalMilliseconds) return false;
        Checking.Add(id);
        try
        {
            // Only after a successful, host-key-verified connection. No keys or
            // passwords enter the cache, and polling never starts another check.
            var result = await AppServices.Host.CallAsync("ssh.provision.check", connection, TimeSpan.FromSeconds(20));
            var label = Format.Text(result, "distro");
            if (string.IsNullOrWhiteSpace(label)) label = Format.Text(result, "os");
            label = string.Join(" ", label.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
            if (label.Length == 0) return false;
            Cache[id] = new Entry(endpoint, label[..Math.Min(label.Length, 80)], Format.Text(host, "label", "SSH session"), now);
            foreach (var old in Cache.OrderByDescending(pair => pair.Value.CheckedAt).Skip(128).Select(pair => pair.Key).ToArray()) Cache.Remove(old);
            try { Directory.CreateDirectory(Path.GetDirectoryName(CachePath)!); File.WriteAllText(CachePath + ".tmp", JsonSerializer.Serialize(Cache)); File.Move(CachePath + ".tmp", CachePath, true); } catch { /* Memory cache remains useful if the disk is unavailable. */ }
            return true;
        }
        catch { return false; }
        finally { Checking.Remove(id); }
    }
}
