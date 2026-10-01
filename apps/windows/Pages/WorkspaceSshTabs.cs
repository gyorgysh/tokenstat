// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json;

namespace Tokenstat.Pages;

/// <summary>Project associations hold session IDs only; SSH remains owned by hostd.</summary>
internal static class WorkspaceSshTabs
{
    private static readonly string PathName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "workspace-ssh-tabs.json");
    private static readonly Dictionary<string, List<string>> Tabs = Read(PathName);
    public static event Action? Changed;
    internal static Dictionary<string, List<string>> Read(string path)
    {
        try
        {
            var stored = JsonSerializer.Deserialize<Dictionary<string, List<string>?>>(File.ReadAllText(path));
            return stored?.Where(pair => !string.IsNullOrWhiteSpace(pair.Key)).ToDictionary(pair => pair.Key,
                pair => (pair.Value ?? new()).Where(id => !string.IsNullOrWhiteSpace(id)).Distinct(StringComparer.Ordinal).ToList()) ?? new();
        }
        catch { return new(); }
    }
    public static IReadOnlyList<string> In(string workspace) => Tabs.TryGetValue(workspace, out var ids) ? ids : Array.Empty<string>();
    public static void Attach(string workspace, string id)
    {
        if (string.IsNullOrWhiteSpace(workspace) || string.IsNullOrWhiteSpace(id)) return;
        if (!Tabs.TryGetValue(workspace, out var ids)) Tabs[workspace] = ids = new();
        if (ids.Contains(id)) return;
        ids.Add(id);
        Persist();
    }
    public static void Remove(string id)
    {
        if (!Remove(Tabs, id)) return;
        Persist();
    }
    internal static bool Remove(Dictionary<string, List<string>> tabs, string id)
    {
        var changed = false;
        foreach (var ids in tabs.Values) changed |= ids.RemoveAll(candidate => candidate == id) > 0;
        return changed;
    }
    private static void Persist()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(PathName)!);
            File.WriteAllText(PathName + ".tmp", JsonSerializer.Serialize(Tabs));
            File.Move(PathName + ".tmp", PathName, true);
        }
        catch { /* The running window still retains its project associations. */ }
        Changed?.Invoke();
    }
}
