// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace Tokenstat.Design;

/// <summary>Wrap actions, or form equal-width responsive device cards.</summary>
internal sealed class FlowPanel : Panel
{
    public double Spacing { get; set; } = Theme.SpaceS;
    public double MinimumItemWidth { get; set; }

    private double ItemWidth(double width)
    {
        if (MinimumItemWidth <= 0) return width;
        var columns = Math.Max(1, (int)Math.Floor((width + Spacing) / (MinimumItemWidth + Spacing)));
        return Math.Max(0, (width - (columns - 1) * Spacing) / columns);
    }

    protected override Size MeasureOverride(Size available)
    {
        var width = double.IsFinite(available.Width) ? available.Width : Math.Max(MinimumItemWidth, 320);
        var itemWidth = ItemWidth(width);
        foreach (var child in Children) child.Measure(new Size(itemWidth, double.PositiveInfinity));
        return Layout(width, itemWidth, arrange: false);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        Layout(finalSize.Width, ItemWidth(finalSize.Width), arrange: true);
        return finalSize;
    }

    private Size Layout(double width, double itemWidth, bool arrange)
    {
        double x = 0, y = 0, rowHeight = 0;
        var row = new List<(UIElement Child, double X, double Width)>();
        void FinishRow()
        {
            if (arrange)
                foreach (var cell in row)
                    cell.Child.Arrange(new Rect(cell.X, y, cell.Width,
                        MinimumItemWidth > 0 ? rowHeight : cell.Child.DesiredSize.Height));
            row.Clear();
        }
        foreach (var child in Children)
        {
            if (child.Visibility == Visibility.Collapsed) continue;
            var size = child.DesiredSize;
            var w = MinimumItemWidth > 0 ? itemWidth : Math.Min(width, size.Width);
            if (x > 0 && x + w > width + 0.5)
            {
                FinishRow(); x = 0; y += rowHeight + Spacing; rowHeight = 0;
            }
            row.Add((child, x, w));
            x += w + Spacing;
            rowHeight = Math.Max(rowHeight, size.Height);
        }
        FinishRow();
        return new Size(width, y + rowHeight);
    }
}
