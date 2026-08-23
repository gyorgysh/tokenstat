// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal static class Format
{
    /// <summary>List-rate micros as a dollar figure. Never a charge.</summary>
    public static string ListRate(long micros)
    {
        var dollars = micros / 1_000_000d;
        return dollars.ToString("C2", CultureInfo.GetCultureInfo("en-US"));
    }

    public static string Tokens(long n)
    {
        if (n >= 1_000_000)
        {
            return (n / 1_000_000d).ToString("0.0") + "M";
        }
        if (n >= 1_000)
        {
            return (n / 1_000d).ToString("0.0") + "k";
        }
        return n.ToString("N0", CultureInfo.InvariantCulture);
    }

    public static long Long(JsonNode? node, string name) =>
        (long)Math.Round(Number(node, name));

    public static double Number(JsonNode? node, string name)
    {
        var value = node?[name];
        if (value is null || value.GetValueKind() is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            return 0;
        }
        try
        {
            return value.GetValueKind() switch
            {
                JsonValueKind.Number => value.GetValue<double>(),
                JsonValueKind.String => double.TryParse(
                    value.GetValue<string>(),
                    NumberStyles.Any,
                    CultureInfo.InvariantCulture,
                    out var n)
                    ? n
                    : 0,
                JsonValueKind.True => 1,
                JsonValueKind.False => 0,
                _ => 0,
            };
        }
        catch
        {
            return 0;
        }
    }

    public static bool Flag(JsonNode? node, string name) =>
        node?[name] is JsonValue v && v.GetValueKind() == JsonValueKind.True;

    public static string Text(JsonNode? node, string name, string fallback = "")
    {
        var value = node?[name];
        if (value is null || value.GetValueKind() is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            return fallback;
        }
        if (value.GetValueKind() == JsonValueKind.String)
        {
            return value.GetValue<string>() ?? fallback;
        }
        var printed = value.ToJsonString().Trim('"');
        return string.IsNullOrEmpty(printed) ? fallback : printed;
    }
}
