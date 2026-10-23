// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

internal static class ChartViewport
{
    // WinUI reports the effective scroll viewport in the chart's coordinates.
    internal static bool Intersects(double width, double height, double x, double y, double viewportWidth, double viewportHeight) =>
        width > 0 && height > 0 && viewportWidth > 0 && viewportHeight > 0
        && x < width && y < height && x + viewportWidth > 0 && y + viewportHeight > 0;
}
