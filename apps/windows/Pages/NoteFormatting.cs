// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

internal static class NoteFormatting
{
    internal readonly record struct Edit(int Start, int Length, string Replacement, int SelectionStart, int SelectionLength);

    internal static Edit Apply(string text, int start, int length, string prefix, string suffix, string placeholder, bool lines)
    {
        start = Math.Clamp(start, 0, text.Length);
        int end = start + Math.Clamp(length, 0, text.Length - start);
        if (lines)
        {
            start = start == 0 ? 0 : text.LastIndexOf('\n', start - 1) + 1;
            if (end > start && text[end - 1] == '\n') end--;
            else { int next = text.IndexOf('\n', end); end = next < 0 ? text.Length : next; }
            if (end > start && text[end - 1] == '\r') end--;
        }
        var selected = text[start..end];
        if (selected.Length == 0) selected = placeholder;
        var replacement = lines ? string.Join("\n", selected.Split('\n').Select(line => prefix + line)) : prefix + selected + suffix;
        return new(start, end - start, replacement, start + prefix.Length, replacement.Length - prefix.Length - suffix.Length);
    }
}
