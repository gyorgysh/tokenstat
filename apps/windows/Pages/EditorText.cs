// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Text;

namespace Tokenstat.Pages;

internal static class EditorText
{
    public static void Format(RichEditTextDocument document, Action apply)
    {
        document.BatchDisplayUpdates();
        try { apply(); }
        finally { document.ApplyDisplayUpdates(); }
    }

    public static string ForFile(string text, string original)
    {
        var normalized = text.Replace("\r\n", "\n").Replace('\r', '\n');
        var first = original.IndexOfAny(['\r', '\n']);
        if (first < 0 || original[first] == '\n') return normalized;
        var ending = first + 1 < original.Length && original[first + 1] == '\n' ? "\r\n" : "\r";
        return normalized.Replace("\n", ending);
    }

    // The final RichEdit paragraph marker belongs to the control, not the file.
    public static string Read(RichEditTextDocument document)
    {
        var range = document.GetRange(0, int.MaxValue);
        range.EndPosition = Math.Max(0, range.EndPosition - 1);
        range.GetText(TextGetOptions.None, out var text);
        return text;
    }
}
