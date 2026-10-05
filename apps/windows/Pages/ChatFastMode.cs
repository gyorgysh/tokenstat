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
        foreach (var item in models)
        {
            if (item is not JsonValue value || !value.TryGetValue<string>(out var prefix)) continue;
            if (model == prefix) return true;
            if (!model.StartsWith(prefix, StringComparison.Ordinal)) continue;
            var suffix = model[prefix.Length..];
            if (suffix.StartsWith('[')) return true;
            if (suffix.Length == 9 && suffix[0] == '-' && suffix[1..].All(c => c is >= '0' and <= '9')) return true;
        }
        return false;
    }
}
