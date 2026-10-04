// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

/// <summary>Bound text layout without losing any UTF-16 or splitting a surrogate pair.</summary>
internal static class DiffTextChunks
{
    public const int MaxUnits = 256;

    public static int Count(string text)
    {
        var count = 0;
        for (var start = 0; start < text.Length; count++) start = End(text, start);
        return Math.Max(1, count);
    }

    private static int End(string text, int start)
    {
        var end = Math.Min(text.Length, start + MaxUnits);
        if (end < text.Length && char.IsHighSurrogate(text[end - 1]) && char.IsLowSurrogate(text[end])) end--;
        return end;
    }

    public static IEnumerable<string> Split(string text)
    {
        if (text.Length == 0) { yield return ""; yield break; }
        for (var start = 0; start < text.Length;)
        {
            var end = End(text, start);
            yield return text[start..end];
            start = end;
        }
    }
}
