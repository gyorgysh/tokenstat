// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

/// <summary>Recover subjects that Muse logged in a result rather than its tool start.</summary>
internal static class MuseToolPresentation
{
    private const int ScanCap = 128 * 1024;

    public static (string Verb, string Target) Refine(string backend, string verb, string target, string? detail)
    {
        if (backend != "muse") return (verb, target);
        var name = verb switch
        {
            "Bash Input" => "Bash",
            "Write Todos" => "TodoWrite",
            "Read Skill" => "Read",
            _ => verb,
        };
        if (!string.IsNullOrWhiteSpace(target) || string.IsNullOrEmpty(detail) || detail.Length > ScanCap)
            return (name, target);

        JsonObject? value = null;
        try { value = JsonNode.Parse(detail) as JsonObject; }
        catch (System.Text.Json.JsonException) { }
        string Field(string key) => value?[key] is JsonValue item && item.TryGetValue<string>(out var text) ? text ?? "" : "";
        var subject = name switch
        {
            "Bash" or "Shell" => Field("command"),
            "WebSearch" => Field("query"),
            "WebFetch" => Field("url"),
            "Read" or "Write" => Field("path"),
            _ => "",
        };
        var lines = detail.Split('\n', 3);
        var first = lines[0].TrimEnd('\r');
        if (subject.Length == 0 && name is "Bash" or "Shell")
        {
            // The renderer puts a description before the command. Never scan stdout for '$'.
            if (first.StartsWith("$ ", StringComparison.Ordinal)) subject = first[2..];
            else if (lines.Length > 1 && lines[1].StartsWith("$ ", StringComparison.Ordinal)) subject = lines[1][2..].TrimEnd('\r');
        }
        if (subject.Length == 0 && name == "Read")
        {
            const string prefix = "Read text file `";
            if (first.StartsWith(prefix, StringComparison.Ordinal) && first.EndsWith("`.", StringComparison.Ordinal))
                subject = first[prefix.Length..^2];
            else if (first.StartsWith("<read-skill-result name=\"", StringComparison.Ordinal))
            {
                var remainder = first["<read-skill-result name=\"".Length..];
                var end = remainder.IndexOf('"');
                if (end >= 0) subject = remainder[..end];
            }
        }
        if (subject.Length == 0 && name == "Write" && first.StartsWith("wrote ", StringComparison.Ordinal))
        {
            var at = first.IndexOf(" bytes to ", StringComparison.Ordinal);
            if (at > 6 && first[6..at].All(char.IsAsciiDigit)) subject = first[(at + " bytes to ".Length)..];
        }
        if (subject.Length == 0 && name == "TodoWrite")
        {
            if (value?["items"] is JsonValue count && count.TryGetValue<long>(out var total) && total >= 0)
                subject = total == 1 ? "1 todo" : $"{total} todos";
            else if (value?["items"] is JsonArray items) subject = items.Count == 1 ? "1 todo" : $"{items.Count} todos";
            else if (first == "no todos" || IsTodoSummary(first)) subject = first;
            if (subject.Length > 0 && value?["revision"] is JsonValue revision && revision.TryGetValue<long>(out var number) && number >= 0)
                subject += $" (revision {number})";
        }
        if (subject.Length > 0)
        {
            subject = subject.Split('\n', 2)[0].TrimEnd('\r');
            if (subject.Length > 160) subject = subject[..(char.IsHighSurrogate(subject[159]) ? 159 : 160)] + "…";
        }
        return (name, subject.Length == 0 ? target : subject);
    }

    private static bool IsTodoSummary(string text)
    {
        var space = text.IndexOf(' ');
        if (space < 1 || !text[..space].All(char.IsAsciiDigit)) return false;
        var rest = text[space..];
        if (rest is " todo" or " todos") return true;
        var prefix = rest.StartsWith(" todo (revision ", StringComparison.Ordinal) ? " todo (revision " : " todos (revision ";
        return rest.StartsWith(prefix, StringComparison.Ordinal) && rest.EndsWith(')')
            && rest.Length > prefix.Length + 1 && rest[prefix.Length..^1].All(char.IsAsciiDigit);
    }
}
