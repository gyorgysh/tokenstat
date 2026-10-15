// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

internal readonly record struct ChatImageTile(int Index, double X, double Y, double Width, double Height);
internal sealed record ChatImageGeometry(double Width, double Height, IReadOnlyList<ChatImageTile> Tiles);

/// <summary>Justified thumbnail rows, measured without creating UI or decoding images.</summary>
internal static class ChatImageLayout
{
    internal const double FallbackAspect = 1.2;
    internal const double MaximumWidth = 640;
    internal const double MinimumTile = 44;
    internal static double Aspect(double width, double height) =>
        double.IsFinite(width) && double.IsFinite(height) && width > 0 && height > 0 ? width / height : FallbackAspect;

    internal static ChatImageGeometry Measure(IReadOnlyList<double> aspects, double availableWidth, bool compact = false)
    {
        var count = Math.Min(aspects.Count, ChatImageGallery.VisibleLimit);
        if (count == 0) return new(0, 0, []);
        var width = Math.Clamp(double.IsFinite(availableWidth) ? availableWidth : MaximumWidth, compact ? 1 : MinimumTile, compact ? count * 78 : MaximumWidth);
        var tiles = new List<ChatImageTile>(count);
        if (compact)
        {
            var gap = Math.Min(6, width / (count * 2));
            var tileWidth = (width - gap * (count - 1)) / count;
            for (var index = 0; index < count; index++) tiles.Add(new(index, index * (tileWidth + gap), 0, tileWidth, 58));
            return new(width, 58, tiles);
        }
        var columns = count <= 3 ? count : 2;
        while (columns > 1 && width < columns * MinimumTile + (columns - 1) * 6) columns--;
        var y = 0d;
        var measuredWidth = 0d;
        for (var start = 0; start < count; start += columns)
        {
            var rowCount = Math.Min(columns, count - start);
            var ratios = Enumerable.Range(start, rowCount).Select(index =>
                Math.Clamp(double.IsFinite(aspects[index]) && aspects[index] > 0 ? aspects[index] : FallbackAspect, .65, 2.2)).ToArray();
            const double gap = 6;
            var height = Math.Clamp((width - gap * (rowCount - 1)) / ratios.Sum(), MinimumTile, count == 1 ? 300 : 240);
            var rowWidth = Math.Min(width, Math.Max(rowCount * MinimumTile + gap * (rowCount - 1), ratios.Sum() * height + gap * (rowCount - 1)));
            var widths = new double[rowCount];
            var flexible = Enumerable.Range(0, rowCount).ToList();
            var remaining = rowWidth - gap * (rowCount - 1);
            while (flexible.Count > 0)
            {
                var weight = flexible.Sum(column => ratios[column]);
                var narrow = flexible.Where(column => remaining * ratios[column] / weight < MinimumTile).ToArray();
                if (narrow.Length == 0) {
                    foreach (var column in flexible) widths[column] = remaining * ratios[column] / weight;
                    break;
                }
                foreach (var column in narrow) { widths[column] = MinimumTile; remaining -= MinimumTile; flexible.Remove(column); }
            }
            var x = 0d;
            for (var column = 0; column < rowCount; column++)
            {
                var tileWidth = widths[column];
                tiles.Add(new(start + column, x, y, tileWidth, height));
                x += tileWidth + gap;
            }
            measuredWidth = Math.Max(measuredWidth, x - gap);
            y += height + 6;
        }
        return new(measuredWidth, y - 6, tiles);
    }
}
