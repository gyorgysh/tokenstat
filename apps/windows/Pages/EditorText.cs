// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Text;

namespace Tokenstat.Pages;

internal static class EditorText
{
    // The final RichEdit paragraph marker belongs to the control, not the file.
    public static string Read(RichEditTextDocument document)
    {
        var range = document.GetRange(0, int.MaxValue);
        range.EndPosition = Math.Max(0, range.EndPosition - 1);
        range.GetText(TextGetOptions.None, out var text);
        return text;
    }
}
