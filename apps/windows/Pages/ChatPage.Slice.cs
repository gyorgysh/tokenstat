// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

internal sealed partial class ChatPage
{
    internal const int OpenPageEvents = 1200;
    internal const int EarlierPageEvents = 1500;

    private const int SliceLength = 150;
    private const int SliceStep = 100;

    internal static int SliceClamp(int older, int count)
    {
        if (count <= SliceLength) return 0;
        return Math.Min(Math.Max(0, older), count - SliceLength);
    }

    internal static string? AnchorRow(IReadOnlyList<string> before, int firstVisible, int lastVisible, IReadOnlySet<string> after)
    {
        for (var i = Math.Max(0, firstVisible); i <= lastVisible && i < before.Count; i++)
            if (after.Contains(before[i])) return before[i];
        var below = lastVisible + 1;
        return below >= 0 && below < before.Count && after.Contains(before[below]) ? before[below] : null;
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
