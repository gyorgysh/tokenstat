// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal static class ChatFastMode
{
    public static bool Available(string? model, JsonArray? models)
    {
        if (models is null) return false;
        if (models.Count == 0) return true;
        if (string.IsNullOrEmpty(model)) return false;
        var candidate = model.EndsWith("[1m]", StringComparison.Ordinal) ? model[..^4] : model;
        foreach (var item in models)
        {
            if (item is not JsonValue value || !value.TryGetValue<string>(out var prefix)) continue;
            if (candidate == prefix) return true;
            if (!candidate.StartsWith(prefix, StringComparison.Ordinal)) continue;
            var suffix = candidate[prefix.Length..];
            if (suffix.Length == 9 && suffix[0] == '-' && suffix[1..].All(c => c is >= '0' and <= '9')) return true;
        }
        return false;
    }
}
