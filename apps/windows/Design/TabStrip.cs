// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Tokenstat.Design;

/// <summary>
/// A flat tab strip, flush with the top of the pane, reading as part of the
/// chrome. Mirrors the Mac TabStrip, which is the source of truth: 28 points
/// high, equal shares, the selected tab in accent on an accent-soft fill with
/// a 2.5 point capsule along its top edge rather than an underline, so the
/// strip reads as tabs attached to the pane below instead of as a toolbar.
/// </summary>
internal static class TabStrip
{
    /// <summary>The strip height. Fixed, like the Mac: the marker belongs to its tab.</summary>
    public const double Height = 28;

    /// <summary>
    /// Build the strip. A null glyph draws the label alone, for a strip narrow
    /// enough that icons would push the labels into truncation. Tapping the
    /// selected tab does nothing. When showsChrome is false only the tab row
    /// is drawn and the parent owns the fill and the rule.
    /// </summary>
    public static Grid View(
        IList<(string Value, string Label, ActionIcon? Glyph)> tabs,
        string selected,
        Func<string, Task> onSelect,
        bool showsChrome = true)
    {
        var strip = new Grid
        {
            Height = Height,
            Background = showsChrome
                ? Theme.TabStripBrush
                : new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Top,
        };
        var row = new Grid { Height = Height };
        foreach (var tab in tabs)
        {
            row.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
        }
        // The strip owns its selection. A tap repaints first and then runs
        // the handler, so the highlight and the content cannot disagree while
        // a load is in flight, and tapping the lit tab stays a no-op. Callers
        // that rebuild the strip in their handler get the same end state.
        string current = selected;
        var paints = new List<(string Value, Action<bool> Paint)>();
        int column = 0;
        foreach (var tab in tabs)
        {
            var value = tab.Value;
            var (cell, paint) = TabCell(tab.Label, tab.Glyph, value == current);
            paints.Add((value, paint));
            cell.Click += async (_, _) =>
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
            Grid.SetColumn(cell, column);
            row.Children.Add(cell);
            column++;
        }
        strip.Children.Add(row);
        if (showsChrome)
        {
            strip.Children.Add(new Microsoft.UI.Xaml.Shapes.Rectangle
            {
                Height = 1,
                Fill = Theme.BorderBrush,
                VerticalAlignment = VerticalAlignment.Bottom,
                HorizontalAlignment = HorizontalAlignment.Stretch,
            });
        }
        return strip;
    }

    private static (Button Cell, Action<bool> Paint) TabCell(string label, ActionIcon? glyph, bool active)
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
            FontSize = 13,
            VerticalAlignment = VerticalAlignment.Center,
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        content.Children.Add(text);
        var face = new Grid
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
        };
        face.Children.Add(content);
        var marker = new Border
        {
            Height = 2.5,
            CornerRadius = new CornerRadius(1.25),
            Margin = new Thickness(Theme.SpaceS, 0, Theme.SpaceS, 0),
            VerticalAlignment = VerticalAlignment.Top,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        face.Children.Add(marker);
        var tab = new Button
        {
            Content = face,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(Theme.SpaceXs, 0, Theme.SpaceXs, 0),
            CornerRadius = new CornerRadius(0),
            // The native minimum is 32 high, which would push the strip open.
            MinWidth = 0,
            MinHeight = 0,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
        };
        tab.Resources["ButtonBorderBrushPointerOver"] = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        tab.Resources["ButtonBorderBrushPressed"] = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        void Paint(bool now)
        {
            if (mark is not null)
            {
                mark.Foreground = now ? Theme.AccentBrush : Theme.Brush(static () => Theme.ControlGlyph);
            }
            text.FontWeight = now
                ? Microsoft.UI.Text.FontWeights.SemiBold
                : Microsoft.UI.Text.FontWeights.Normal;
            text.Foreground = now ? Theme.AccentBrush : Theme.Brush(static () => Theme.ControlGlyph);
            marker.Background = now
                ? Theme.AccentBrush
                : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            // The native hover and pressed fills are grey, which on a dark strip
            // is the same colour as everything around it. Pin them to the resting
            // fills so the selected tab stays the only accent on the row.
            Brush resting = now
                ? Theme.AccentSoftBrush
                : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            tab.Background = resting;
            tab.Resources["ButtonBackgroundPointerOver"] = resting;
            tab.Resources["ButtonBackgroundPressed"] = resting;
            AutomationProperties.SetItemStatus(tab, now ? "Selected" : "Not selected");
        }
        Paint(active);
        ToolTipService.SetToolTip(tab, label);
        AutomationProperties.SetName(tab, label);
        return (tab, Paint);
    }
}
