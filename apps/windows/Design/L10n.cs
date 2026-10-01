// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Tokenstat;

internal static class L10n
{
    private static readonly ConcurrentDictionary<string, LanguageCatalog> Catalogs = new();

    internal static string Text(string key, params object?[] arguments)
    {
        var language = CultureInfo.CurrentUICulture.Name;
        var catalog = Catalogs.GetOrAdd(language, name => LanguageCatalog.Load(
            Path.Combine(AppContext.BaseDirectory, "localization"), new[] { name }));
        return catalog.Text(key, arguments.Select(value => Convert.ToString(value, CultureInfo.CurrentCulture) ?? "").ToArray());
    }
}

internal sealed class LanguageCatalog
{
    private readonly IReadOnlyDictionary<string, string> _strings;
    private static readonly Regex Placeholder = new(@"\{([0-9]+)\}", RegexOptions.Compiled | RegexOptions.CultureInvariant);

    internal LanguageCatalog(IReadOnlyDictionary<string, string> strings) => _strings = strings;

    internal static LanguageCatalog Load(string directory, IEnumerable<string> languages)
    {
        Dictionary<string, string> Read(string language, string table)
        {
            var path = Path.Combine(directory, language, table + ".json");
            try
            {
                return File.Exists(path)
                    ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path)) ?? new()
                    : new();
            }
            catch (JsonException) { return new(); }
            catch (IOException) { return new(); }
        }
        var strings = Read("en", "common");
        foreach (var pair in Read("en", "windows")) strings[pair.Key] = pair.Value;
        foreach (var language in languages)
        {
            var normalized = language.Replace('_', '-');
            var components = normalized.Split('-');
            var translated = new Dictionary<string, string>();
            for (var count = 1; count <= components.Length; count++)
            {
                var tag = string.Join("-", components.Take(count));
                foreach (var pair in Read(tag, "common")) translated[pair.Key] = pair.Value;
                foreach (var pair in Read(tag, "windows")) translated[pair.Key] = pair.Value;
            }
            if (translated.Count == 0) continue;
            foreach (var pair in translated) strings[pair.Key] = pair.Value;
            break;
        }
        return new LanguageCatalog(strings);
    }

    internal string Text(string key, params string[] arguments)
    {
        if (!_strings.TryGetValue(key, out var template)) return key;
        if (arguments.Length == 0) return template;
        return Placeholder.Replace(template, match =>
            int.TryParse(match.Groups[1].Value, out var index) && index < arguments.Length ? arguments[index] : match.Value);
    }
}
