// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

/// <summary>The transcript window counts drawn rows, after detail folding.
/// Kept portable so history boundaries can be checked without WinUI.</summary>
internal sealed partial class ChatPage
{
    private const int SliceLength = 150;
    private const int SliceStep = 100;

    internal static int SliceClamp(int older, int count)
    {
        if (count <= SliceLength) return 0;
        return Math.Min(Math.Max(0, older), count - SliceLength);
    }

    internal static int SliceStart(int count, int older)
    {
        if (count <= 0) return 0;
        if (count <= SliceLength) return 0;
        var end = count - SliceClamp(older, count);
        return end - SliceLength;
    }

    internal static int SliceEnd(int count, int older)
    {
        if (count <= 0) return 0;
        if (count <= SliceLength) return count;
        return count - SliceClamp(older, count);
    }
}
