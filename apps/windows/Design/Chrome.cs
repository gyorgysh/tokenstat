// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace Tokenstat.Design;

internal static class Chrome
{
    public static Border Card(string title, UIElement body, string? subtitle = null)
    {
        var header = new StackPanel { Spacing = 2 };
        header.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            FontSize = 13,
        });
        if (!string.IsNullOrEmpty(subtitle))
        {
            header.Children.Add(new TextBlock
            {
                Text = subtitle,
                FontSize = 12,
                Opacity = 0.7,
            });
        }

        var stack = new StackPanel { Spacing = Theme.SpaceM };
        stack.Children.Add(header);
        stack.Children.Add(body);

        return new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.CardPadding),
            Child = stack,
        };
    }

    public static StackPanel Stat(string label, string value, string? note = null)
    {
        var row = new StackPanel { Spacing = Theme.SpaceXs };
        row.Children.Add(new TextBlock
        {
            Text = label.ToUpperInvariant(),
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Opacity = 0.55,
        });
        var figures = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceXs };
        figures.Children.Add(new TextBlock
        {
            Text = value,
            FontSize = 22,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            FontFamily = new FontFamily("Segoe UI"),
        });
        if (!string.IsNullOrEmpty(note))
        {
            figures.Children.Add(new TextBlock
            {
                Text = note,
                FontSize = 12,
                Opacity = 0.7,
                VerticalAlignment = VerticalAlignment.Bottom,
            });
        }
        row.Children.Add(figures);
        return row;
    }

    public static Border Banner(string text, Color tint, Symbol symbol)
    {
        var label = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children =
            {
                new SymbolIcon { Symbol = symbol, Foreground = Theme.Brush(tint) },
                new TextBlock
                {
                    Text = text,
                    TextWrapping = TextWrapping.Wrap,
                    Foreground = Theme.Brush(tint),
                },
            },
        };
        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(30, tint.R, tint.G, tint.B)),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.SpaceM),
            Child = label,
        };
    }

    public static StackPanel Empty(string title, string message, Symbol symbol, UIElement? action = null)
    {
        var stack = new StackPanel
        {
            Spacing = Theme.SpaceS,
            HorizontalAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(0, Theme.SpaceXl, 0, Theme.SpaceXl),
        };
        stack.Children.Add(new SymbolIcon
        {
            Symbol = symbol,
            Width = 28,
            Height = 28,
            Foreground = Theme.AccentBrush,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        stack.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            FontSize = 14,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        stack.Children.Add(new TextBlock
        {
            Text = message,
            FontSize = 13,
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 420,
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
        });
        if (action is not null)
        {
            stack.Children.Add(action);
        }
        return stack;
    }

    public static Rectangle HeatCell(int level, double size = 12)
    {
        return new Rectangle
        {
            Width = size,
            Height = size,
            RadiusX = 2,
            RadiusY = 2,
            Fill = Theme.Brush(Theme.HeatLevel(level)),
            Margin = new Thickness(1),
        };
    }

    /// <summary>
    /// Show a dialog owned by a page. Returns <see cref="ContentDialogResult.None"/>
    /// when the page is not in the tree yet, rather than throwing.
    /// </summary>
    public static async Task<ContentDialogResult> ShowDialog(UIElement owner, ContentDialog dialog)
    {
        var root = owner.XamlRoot;
        if (root is null)
        {
            return ContentDialogResult.None;
        }
        dialog.XamlRoot = root;
        try
        {
            return await dialog.ShowAsync();
        }
        catch
        {
            return ContentDialogResult.None;
        }
    }
}
