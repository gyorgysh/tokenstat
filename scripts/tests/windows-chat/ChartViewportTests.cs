// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Tokenstat.Pages;

internal static class ChartViewportTests
{
    internal static void Run()
    {
        static void Check(bool result) { if (!result) throw new Exception("Chart viewport regression"); }
        Check(ChartViewport.Intersects(640, 430, 0, 0, 640, 500));
        Check(ChartViewport.Intersects(640, 430, 0, -490, 640, 500));
        Check(ChartViewport.Intersects(640, 430, 0, 429, 640, 500));
        Check(!ChartViewport.Intersects(640, 430, 0, 430, 640, 500));
        Check(!ChartViewport.Intersects(640, 430, 0, -500, 640, 500));
        Check(!ChartViewport.Intersects(640, 430, 640, 0, 640, 500));
        Check(!ChartViewport.Intersects(640, 430, 0, 0, 0, 500));
        Check(!ChartViewport.Intersects(640, 0, 0, 0, 640, 500));
        Check(!ChartViewport.Intersects(640, 430, double.NaN, 0, 640, 500));
        Console.WriteLine("Chart viewports: partially visible charts mount; clipped and offscreen charts release their browsers.");
    }
}
