// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Navigation;

internal static class ChatHistoryWindow
{
    public static (int Start, int Count) Visible(int count, int? selected, bool expanded)
    {
        if (count <= 0) return (0, 0);
        if (selected is int current && current >= 0 && current < count && (expanded || current >= 5))
        {
            if (count <= 10) return (0, count);
            return (current < 10 ? 0 : Math.Min(current - 4, count - 10), 10);
        }
        return (0, Math.Min(count, expanded ? 10 : 5));
    }
}
