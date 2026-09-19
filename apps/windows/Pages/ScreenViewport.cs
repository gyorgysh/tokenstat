// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

internal static class ScreenViewport
{
    // The video uses Uniform stretch. Exclude its letterbox margins from input.
    public static (double x, double y)? Normalize(double x, double y, double viewWidth, double viewHeight,
        double imageWidth, double imageHeight, bool dragging)
    {
        if (viewWidth <= 0 || viewHeight <= 0 || imageWidth <= 0 || imageHeight <= 0) return null;
        var scale = Math.Min(viewWidth / imageWidth, viewHeight / imageHeight);
        var width = imageWidth * scale;
        var height = imageHeight * scale;
        var localX = (x - (viewWidth - width) / 2) / width;
        var localY = (y - (viewHeight - height) / 2) / height;
        if (!dragging && (localX < 0 || localX > 1 || localY < 0 || localY > 1)) return null;
        return (Math.Clamp(localX, 0, 1), Math.Clamp(localY, 0, 1));
    }
}
