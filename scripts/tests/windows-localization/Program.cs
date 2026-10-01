// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json;
using Tokenstat;

void Equal(string actual, string expected)
{
    if (actual != expected) throw new Exception($"Expected '{expected}', received '{actual}'.");
}
var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
try
{
    void Write(string language, string table, Dictionary<string, string> strings)
    {
        var folder = Path.Combine(directory, language);
        Directory.CreateDirectory(folder);
        File.WriteAllText(Path.Combine(folder, table + ".json"), JsonSerializer.Serialize(strings));
    }
    Write("en", "common", new() { ["shared"] = "English", ["fallback"] = "Still English", ["platform"] = "Common" });
    Write("en", "windows", new() { ["platform"] = "Windows" });
    Write("hu", "common", new() { ["shared"] = "Magyar", ["base"] = "Base language" });
    Write("hu-HU", "windows", new() { ["shared"] = "Regional", ["platform"] = "Regional Windows" });
    Write("zh-Hant", "windows", new() { ["shared"] = "Script language" });
    Equal(LanguageCatalog.Load(directory, new[] { "zh-Hant-TW" }).Text("shared"), "Script language");
    var regional = LanguageCatalog.Load(directory, new[] { "hu_HU", "en" });
    Equal(regional.Text("shared"), "Regional");
    Equal(regional.Text("base"), "Base language");
    Equal(regional.Text("platform"), "Regional Windows");
    Equal(regional.Text("fallback"), "Still English");
    Equal(LanguageCatalog.Load(directory, new[] { "zz", "hu" }).Text("shared"), "Magyar");
    Equal(LanguageCatalog.Load(directory, new[] { "en-US", "hu" }).Text("shared"), "English");
    Equal(LanguageCatalog.Load(directory, new[] { "zz" }).Text("platform"), "Windows");
    var formatted = new LanguageCatalog(new Dictionary<string, string> { ["message"] = "Á😀 {1}: {0} / {1} · 100%", ["overflow"] = "{999999999999999999999}" });
    Equal(formatted.Text("message", "{1}", "$5% \\ path"), "Á😀 $5% \\ path: {1} / $5% \\ path · 100%");
    Equal(formatted.Text("message"), "Á😀 {1}: {0} / {1} · 100%");
    Equal(formatted.Text("overflow", "x"), "{999999999999999999999}");
    Equal(formatted.Text("missing"), "missing");
    Equal(L10n.Text("common.cancel"), "Cancel");
    Console.WriteLine("Language catalog fallback, formatting, and bundled English passed.");
}
finally { Directory.Delete(directory, recursive: true); }
