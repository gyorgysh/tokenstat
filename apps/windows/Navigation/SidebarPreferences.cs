// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Tokenstat.Navigation;

internal sealed class SidebarPreferences
{
    public static readonly string[] DefaultOrder = ["projects", "servers"];
    private static readonly Lazy<SidebarPreferences> Saved = new(() => new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "sidebar.json")));
    public static SidebarPreferences Shared => Saved.Value;
    private readonly string _path;
    private JsonObject _saved;

    public SidebarPreferences(string path) { _path = path; _saved = Read(); }

    public bool IsExpanded(string key, bool fallback) =>
        _saved["expanded"] is JsonObject expanded && expanded[key] is JsonValue value
            && value.TryGetValue<bool>(out var flag) ? flag : fallback;

    public HashSet<string> ExpandedIDs(string prefix) => _saved["expanded"] is JsonObject expanded
        ? expanded.Where(pair => pair.Key.StartsWith(prefix, StringComparison.Ordinal)
                && pair.Value is JsonValue value && value.TryGetValue<bool>(out var flag) && flag)
            .Select(pair => pair.Key[prefix.Length..]).ToHashSet(StringComparer.Ordinal)
        : new(StringComparer.Ordinal);

    public IReadOnlyList<string> SectionOrder
    {
        get
        {
            var order = new List<string>();
            if (_saved["sectionOrder"] is JsonArray sections)
                foreach (var node in sections)
                    if (node is JsonValue value && value.TryGetValue<string>(out var section)
                        && DefaultOrder.Contains(section) && !order.Contains(section)) order.Add(section);
            order.AddRange(DefaultOrder.Where(section => !order.Contains(section)));
            return order;
        }
    }

    public SidebarProjectsDisplay ProjectsDisplay
    {
        get => SidebarProjectsLayout.ParseDisplay(String("projectsDisplay"));
        set => Save(saved => saved["projectsDisplay"] = SidebarProjectsLayout.Raw(value));
    }

    public SidebarProjectsSort ProjectsSort
    {
        get => SidebarProjectsLayout.ParseSort(String("projectsSort"));
        set => Save(saved => saved["projectsSort"] = SidebarProjectsLayout.Raw(value));
    }

    private string? String(string key) =>
        _saved[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    public void RememberExpansion(string key, bool expanded) => Save(saved =>
    {
        if (saved["expanded"] is not JsonObject rows) saved["expanded"] = rows = new JsonObject();
        rows[key] = expanded;
    });

    public void Move(string section, string before)
    {
        if (!DefaultOrder.Contains(section) || !DefaultOrder.Contains(before) || section == before) return;
        Save(saved =>
        {
            if (saved["sectionOrder"] is not JsonArray order)
                saved["sectionOrder"] = order = new JsonArray(DefaultOrder.Select(s => (JsonNode?)JsonValue.Create(s)).ToArray());
            for (var index = order.Count - 1; index >= 0; index--)
                if (order[index] is JsonValue value && value.TryGetValue<string>(out var name) && name == section) order.RemoveAt(index);
            var at = order.ToList().FindIndex(node => node is JsonValue value && value.TryGetValue<string>(out var name) && name == before);
            if (at < 0) { at = order.Count; order.Add(before); }
            order.Insert(at, section);
        });
    }

    private JsonObject Read()
    {
        try
        {
            var saved = JsonNode.Parse(File.ReadAllText(_path)) as JsonObject ?? new();
            _ = saved.Count;
            if (saved["expanded"] is JsonObject rows) _ = rows.Count;
            return saved;
        }
        catch (IOException) { return new(); }
        catch (UnauthorizedAccessException) { return new(); }
        catch (JsonException) { return new(); }
        catch (ArgumentException) { return new(); }
    }

    private void Save(Action<JsonObject> update)
    {
        var saved = Read();
        update(saved);
        _saved = saved;
        var temporary = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_path))!);
            File.WriteAllText(temporary, saved.ToJsonString());
            File.Move(temporary, _path, overwrite: true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        finally
        {
            try { File.Delete(temporary); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
