// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Tokenstat.Design;

internal static class SegmentedCapsule
{
    public static Border View(
        IList<(string Value, string Label, ActionIcon? Glyph)> options,
        string selected,
        Func<string, Task> onSelect,
        bool enabled = true)
    {
        var row = new Grid { ColumnSpacing = Theme.SpaceXs };
        foreach (var option in options)
        {
            row.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
        }
        string current = selected;
        var paints = new List<(string Value, Action<bool> Paint)>();
        int column = 0;
        foreach (var option in options)
        {
            var value = option.Value;
            var (segment, paint) = Segment(option.Label, option.Glyph, value == current);
            paints.Add((value, paint));
            segment.Click += async (_, _) =>
            {
                if (value == current)
                {
                    return;
                }
                current = value;
                foreach (var (other, repaint) in paints)
                {
                    repaint(other == current);
                }
                await onSelect(value);
            };
            segment.IsEnabled = enabled;
            Grid.SetColumn(segment, column);
            row.Children.Add(segment);
            column++;
        }
        return new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(3),
            HorizontalAlignment = HorizontalAlignment.Left,
            Opacity = enabled ? 1 : 0.42,
            Child = row,
        };
    }

    private static (Button Cell, Action<bool> Paint) Segment(string label, ActionIcon? glyph, bool active)
    {
        var content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceXs,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        IconElement? mark = null;
        if (glyph.HasValue)
        {
            mark = glyph.Value.Icon();
            content.Children.Add(new Viewbox
            {
                Width = 11,
                Height = 11,
                VerticalAlignment = VerticalAlignment.Center,
                Child = mark,
            });
        }
        var text = new TextBlock
        {
            Text = label,
            FontFamily = Fonts.Interface,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            VerticalAlignment = VerticalAlignment.Center,
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        content.Children.Add(text);
        var segment = new Button
        {
            Content = content,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(glyph.HasValue ? 12 : 10, 6, glyph.HasValue ? 12 : 10, 6),
            CornerRadius = new CornerRadius(8),
            MinWidth = 0,
            MinHeight = 0,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        segment.Resources["ButtonBorderBrushPointerOver"] = Theme.ClearBrush;
        segment.Resources["ButtonBorderBrushPressed"] = Theme.ClearBrush;
        void Paint(bool now)
        {
            if (mark is not null)
            {
                mark.Foreground = now ? Theme.AccentBrush : Theme.Brush(static () => Theme.ControlGlyph);
            }
            text.Foreground = now ? Theme.AccentBrush : Theme.Brush(static () => Theme.ControlGlyph);
            Brush resting = now
                ? Theme.AccentSoftBrush
                : Theme.ClearBrush;
            segment.Background = resting;
            segment.Resources["ButtonBackgroundPointerOver"] = now
                ? Theme.AccentSoftBrush
                : Theme.Brush(static () => WithAlpha(Theme.RowHighlight, 0.7));
            segment.Resources["ButtonBackgroundPressed"] = resting;
            AutomationProperties.SetItemStatus(segment, now ? L10n.Text("windows.segmentedcapsule.selected.57fd7a0c") : L10n.Text("windows.segmentedcapsule.not_selected.df12aeba"));
        }
        Paint(active);
        ToolTipService.SetToolTip(segment, label);
        AutomationProperties.SetName(segment, label);
        return (segment, Paint);
    }

    private static Color WithAlpha(Color color, double alpha) =>
        Color.FromArgb((byte)(255 * alpha), color.R, color.G, color.B);
}
