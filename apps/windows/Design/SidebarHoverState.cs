// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Design;

internal readonly record struct HoverRect(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
    public bool Contains(double x, double y, double margin = 4) =>
        x >= X - margin && x <= Right + margin && y >= Y - margin && y <= Bottom + margin;
}

/// <summary>Pointer union and a fixed exit grace, also sampled when no exit event arrives.</summary>
internal sealed class SidebarHoverState
{
    private long? _leftAt;
    public bool ShouldClose(bool inside, long milliseconds)
    {
        if (inside) { _leftAt = null; return false; }
        _leftAt ??= milliseconds;
        return milliseconds - _leftAt.Value >= 220;
    }

    public static bool Contains(double x, double y, HoverRect? row, HoverRect? card)
    {
        if (row is { } trigger)
        {
            if (trigger.Contains(x, y)) return true;
            if (card is { } panel)
            {
                var rightward = panel.X + panel.Width / 2 >= trigger.X + trigger.Width / 2;
                var left = rightward ? trigger.Right : panel.Right;
                var right = rightward ? panel.X : trigger.X;
                var top = Math.Max(trigger.Y, panel.Y);
                var bottom = Math.Min(trigger.Bottom, panel.Bottom);
                // Only the crossing beside the row is a corridor. The empty
                // space beside the rest of a tall card must dismiss it.
                if (right >= left && bottom > top && new HoverRect(left, top, right - left, bottom - top).Contains(x, y)) return true;
            }
        }
        return card?.Contains(x, y) == true;
    }
}
