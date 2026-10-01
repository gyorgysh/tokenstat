// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json;

namespace Tokenstat.Pages;

internal sealed record PinnedWork(string AccountScope, string Owner, string WorkspaceId, string ChatId, string Label, string FolderName)
{
    public string Key => BrowserHistory.Key(Owner, ChatId);
}

/// <summary>Eight user-chosen Home shortcuts per account, scoped to their owning host.</summary>
internal sealed class PinnedWorkStore
{
    public const int Capacity = 8;
    private static readonly Lazy<PinnedWorkStore> Saved = new(() => new PinnedWorkStore(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "pinned-work.json")));
    public static PinnedWorkStore Shared => Saved.Value;
    private readonly string _path;
    private readonly List<PinnedWork> _pins = [];
    public event Action? Changed;
    public PinnedWorkStore(string path)
    {
        _path = path;
        try
        {
            var pins = JsonSerializer.Deserialize<List<PinnedWork>>(File.ReadAllText(path)) ?? [];
            foreach (var pin in pins)
                if (pin is not null && pin.AccountScope?.Length > 0 && pin.Owner?.Length > 0 && pin.WorkspaceId?.Length > 0
                    && pin.ChatId is not null && pin.Label is not null && pin.FolderName is not null
                    && !_pins.Any(saved => saved.Key == pin.Key) && Read(pin.AccountScope).Count < Capacity) _pins.Add(pin);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        catch (JsonException) { }
    }
    public IReadOnlyList<PinnedWork> Read(string accountScope) => _pins.Where(pin => pin.AccountScope == accountScope).ToArray();
    public bool Contains(string owner, string chatId) => _pins.Any(pin => pin.Owner == owner && pin.ChatId == chatId);
    public bool Pin(PinnedWork pin)
    {
        var index = _pins.FindIndex(saved => saved.Key == pin.Key);
        if (index >= 0) _pins[index] = pin;
        else if (Read(pin.AccountScope).Count < Capacity) _pins.Add(pin);
        else return false;
        Save(); return true;
    }
    public void Remove(string owner, string chatId)
    {
        if (_pins.RemoveAll(pin => pin.Owner == owner && pin.ChatId == chatId) > 0) Save();
    }
    public void Rename(string owner, string chatId, string name)
    {
        var index = _pins.FindIndex(pin => pin.Owner == owner && pin.ChatId == chatId);
        if (index < 0) return;
        _pins[index] = _pins[index] with { Label = name }; Save();
    }
    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(_pins));
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        Changed?.Invoke();
    }
}
