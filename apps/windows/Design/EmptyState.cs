// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;
using ShapesPath = Microsoft.UI.Xaml.Shapes.Path;

namespace Tokenstat.Design;

/// <summary>
/// Which picture an empty screen draws. One per surface, because "nothing
/// here" is a different sentence in a folder with no tasks and a folder with
/// no shells. Mirrors the Apple EmptyArtKind and the Android EmptyArtKind.
/// </summary>
internal enum EmptyArtKind
{
    Sessions,
    Tasks,
    Notes,
    Workflows,
    Automations,
    Changes,
    Files,
    Waiting,
    Vault,
    /// <summary>No machine linked yet. The Apple noMachine scene: a rack
    /// waiting rather than an empty tray.</summary>
    Devices,
    /// <summary>Saved servers reached with a key. The Apple workspaceAccess
    /// scene: a folder with the key swinging in.</summary>
    WorkspaceAccess,
    /// <summary>Insights with nothing on the account yet. Bars rising, the
    /// last one still a dashed slot.</summary>
    FirstBars,
}

/// <summary>
/// What a screen shows before it has anything to show. The Apple EmptyState
/// rule: the headline names what is missing, the line under it says what the
/// thing is for, and the button is the one action that ends the empty state.
/// The picture is drawn from the same art family as the other clients: brand
/// stroke at one weight with round joins, on a 128 by 84 canvas. These are
/// the resting frames the Apple loops land on.
/// </summary>
internal static class EmptyState
{
    public static StackPanel View(string title, string message, EmptyArtKind kind, UIElement? action = null)
    {
        var stack = new StackPanel
        {
            Spacing = Theme.SpaceS,
            HorizontalAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(Theme.SpaceL, Theme.SpaceXl, Theme.SpaceL, Theme.SpaceXl),
        };
        var art = EmptyArt(kind);
        art.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(art);
        stack.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            FontSize = 14,
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
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
            action.HorizontalAlignment = HorizontalAlignment.Center;
            stack.Children.Add(action);
        }
        AutomationProperties.SetName(stack, title);
        return stack;
    }

    /// <summary>
    /// The same Free-year note the public profile puts under the heatmap. Not
    /// a wall: the year is already on screen. This says why the older squares
    /// are muted and offers the page that unlocks them. Copy from the Apple
    /// HistoryLockBanner.
    /// </summary>
    /// <param name="days">How many recent days stay exact. Free is 30.</param>
    public static Border HistoryLockBanner(int days = 30)
    {
        var text = new TextBlock
        {
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        };
        text.Inlines.Add(new Run
        {
            Text = "Older history is locked. ",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        text.Inlines.Add(new Run
        {
            Text = $"Free shows the last {days} days in full. Older days keep the year shape only.",
        });
        var link = new Button
        {
            Content = "Upgrade to see the year",
            Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0)),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            Foreground = Theme.AccentBrush,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            FontSize = 12,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        link.Click += (_, _) =>
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "https://tokenstat.ai/pricing",
                    UseShellExecute = true,
                });
            }
            catch
            {
                // The banner stays. The URL is the whole message.
            }
        };
        var stack = new StackPanel { Spacing = 6 };
        stack.Children.Add(text);
        stack.Children.Add(link);
        return new Border
        {
            Background = Theme.AccentSoftBrush,
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12, 10, 12, 10),
            Child = stack,
        };
    }

    /// <summary>
    /// The picture over an empty state. Line drawings from ClientEmptyArt,
    /// through the Android port, at the Apple stroke weight of 1.7 with round
    /// joins, so the pictures read as one hand.
    /// </summary>
    public static Canvas EmptyArt(EmptyArtKind kind)
    {
        var canvas = new Canvas { Width = 128, Height = 84 };
        double w = 128, h = 84;
        Color quiet = Theme.Border;
        Color lead = Theme.Accent;
        Color second = Theme.Secondary;
        switch (kind)
        {
            case EmptyArtKind.Sessions:
                canvas.Children.Add(RoundRect(0.18 * w, 0.18 * h, 0.64 * w, 0.64 * h, 10, quiet));
                canvas.Children.Add(Dot(0.28 * w, 0.32 * h, 3.5, WithAlpha(Theme.Danger, 0.7)));
                canvas.Children.Add(Dot(0.36 * w, 0.32 * h, 3.5, WithAlpha(Theme.Warning, 0.7)));
                canvas.Children.Add(Dot(0.44 * w, 0.32 * h, 3.5, WithAlpha(lead, 0.7)));
                canvas.Children.Add(StrokeLine(0.28 * w, 0.55 * h, 0.34 * w, 0.55 * h, lead));
                canvas.Children.Add(StrokeLine(0.38 * w, 0.48 * h, 0.38 * w, 0.62 * h, lead));
                break;
            case EmptyArtKind.Tasks:
                for (int i = 0; i < 3; i++)
                {
                    canvas.Children.Add(RoundRect(
                        0.18 * w, (0.22 + i * 0.22) * h, 0.64 * w, 0.16 * h, 6,
                        i == 0 ? WithAlpha(lead, 0.45) : quiet));
                }
                break;
            case EmptyArtKind.Notes:
                canvas.Children.Add(RoundRect(0.28 * w, 0.16 * h, 0.44 * w, 0.68 * h, 6, quiet));
                canvas.Children.Add(StrokeLine(0.36 * w, 0.38 * h, 0.62 * w, 0.38 * h, lead, 3));
                canvas.Children.Add(StrokeLine(0.36 * w, 0.50 * h, 0.58 * w, 0.50 * h, WithAlpha(lead, 0.5), 3));
                break;
            case EmptyArtKind.Workflows:
            {
                double[] nodes = [0.22, 0.42, 0.62, 0.82];
                for (int i = 0; i < nodes.Length; i++)
                {
                    if (i < nodes.Length - 1)
                    {
                        canvas.Children.Add(StrokeLine(
                            nodes[i] * w + 8, 0.5 * h, nodes[i + 1] * w - 8, 0.5 * h, quiet, 2.4));
                    }
                }
                for (int i = 0; i < nodes.Length; i++)
                {
                    canvas.Children.Add(Ring(nodes[i] * w, 0.5 * h, 7, i == 0 ? lead : quiet));
                }
                break;
            }
            case EmptyArtKind.Automations:
                canvas.Children.Add(Ring(0.5 * w, 0.5 * h, 0.28 * Math.Min(w, h), quiet));
                canvas.Children.Add(StrokeLine(0.5 * w, 0.5 * h, 0.5 * w, 0.28 * h, lead));
                break;
            case EmptyArtKind.Changes:
                canvas.Children.Add(StrokeLine(0.28 * w, 0.30 * h, 0.72 * w, 0.30 * h, Theme.DiffAdded, 3));
                canvas.Children.Add(StrokeLine(0.28 * w, 0.48 * h, 0.62 * w, 0.48 * h, Theme.DiffRemoved, 3));
                canvas.Children.Add(StrokeLine(0.28 * w, 0.66 * h, 0.55 * w, 0.66 * h, lead, 3));
                break;
            case EmptyArtKind.Files:
                canvas.Children.Add(RoundRect(0.22 * w, 0.34 * h, 0.36 * w, 0.42 * h, 6, quiet));
                canvas.Children.Add(RoundRect(0.42 * w, 0.22 * h, 0.34 * w, 0.48 * h, 6, WithAlpha(lead, 0.55)));
                break;
            case EmptyArtKind.Waiting:
                canvas.Children.Add(RoundRect(0.32 * w, 0.28 * h, 0.36 * w, 0.44 * h, 8, quiet));
                canvas.Children.Add(Ring(0.5 * w, 0.5 * h, 0.22 * Math.Min(w, h), WithAlpha(lead, 0.35)));
                break;
            case EmptyArtKind.Vault:
            {
                canvas.Children.Add(RoundRect(0.16 * w, 0.22 * h, 0.22 * w, 0.56 * h, 10, quiet));
                canvas.Children.Add(RoundRect(0.48 * w, 0.28 * h, 0.36 * w, 0.44 * h, 8, quiet));
                var body = new Rectangle
                {
                    Width = 0.12 * w,
                    Height = 0.14 * h,
                    RadiusX = 2,
                    RadiusY = 2,
                    Stroke = Theme.Brush(lead),
                    StrokeThickness = InkWidth,
                };
                Canvas.SetLeft(body, 0.44 * w);
                Canvas.SetTop(body, 0.52 * h);
                canvas.Children.Add(body);
                break;
            }
            case EmptyArtKind.Devices:
            {
                // The Apple ServerScene rack in its ready state: three units
                // and the light on the top one lit.
                for (int unit = 0; unit < 3; unit++)
                {
                    double top = 19.5 + unit * 16;
                    canvas.Children.Add(RoundRect(42, top, 44, 13, 3, quiet));
                    if (unit == 0)
                    {
                        canvas.Children.Add(Dot(47, top + 6.5, 2, lead));
                    }
                    canvas.Children.Add(GhostLine(58, top + 6.5, 16, second));
                }
                canvas.Children.Add(Dot(24, 42, 2, quiet));
                canvas.Children.Add(Dot(32, 42, 2, quiet));
                canvas.Children.Add(Dot(104, 42, 2, quiet));
                break;
            }
            case EmptyArtKind.WorkspaceAccess:
            {
                // The Apple WorkspaceAccessScene resting frame: a folder with
                // its tab, and the key home.
                canvas.Children.Add(RoundRect(13, 21, 74, 54, 10, quiet));
                canvas.Children.Add(RoundRect(15, 12, 26, 10, 3, quiet));
                canvas.Children.Add(Ring(88, 52, 6, lead));
                canvas.Children.Add(StrokeLine(82, 52, 64, 52, lead));
                canvas.Children.Add(StrokeLine(70, 52, 70, 58, lead, 2.4));
                canvas.Children.Add(StrokeLine(76, 52, 76, 58, lead, 2.4));
                break;
            }
            case EmptyArtKind.FirstBars:
            {
                // The Apple FirstBarsScene resting frame: bars rising, the
                // last one still a dashed slot, over a baseline.
                var bar1 = new Rectangle
                {
                    Width = 16, Height = 20, RadiusX = 3, RadiusY = 3,
                    Fill = Theme.Brush(WithAlpha(lead, 0.85)),
                };
                Canvas.SetLeft(bar1, 31);
                Canvas.SetTop(bar1, 44);
                canvas.Children.Add(bar1);
                var bar2 = new Rectangle
                {
                    Width = 16, Height = 34, RadiusX = 3, RadiusY = 3,
                    Fill = Theme.Brush(WithAlpha(lead, 0.85)),
                };
                Canvas.SetLeft(bar2, 56);
                Canvas.SetTop(bar2, 30);
                canvas.Children.Add(bar2);
                var slot = new Rectangle
                {
                    Width = 16, Height = 48, RadiusX = 3, RadiusY = 3,
                    Stroke = Theme.Brush(lead),
                    StrokeThickness = InkWidth,
                    StrokeDashArray = new DoubleCollection { 4, 4 },
                    Opacity = 0.6,
                };
                Canvas.SetLeft(slot, 81);
                Canvas.SetTop(slot, 16);
                canvas.Children.Add(slot);
                var baseline = new Rectangle
                {
                    Width = 66, Height = 2, RadiusX = 1, RadiusY = 1,
                    Fill = Theme.Brush(quiet),
                };
                Canvas.SetLeft(baseline, 31);
                Canvas.SetTop(baseline, 70);
                canvas.Children.Add(baseline);
                var spark1 = Sparkle(9, Theme.Brush(lead));
                Canvas.SetLeft(spark1, 28 - 4.5);
                Canvas.SetTop(spark1, 20 - 4.5);
                canvas.Children.Add(spark1);
                var spark2 = Sparkle(6, Theme.Brush(lead));
                Canvas.SetLeft(spark2, 100 - 3);
                Canvas.SetTop(spark2, 62 - 3);
                canvas.Children.Add(spark2);
                break;
            }
        }
        AutomationProperties.SetAccessibilityView(canvas, AccessibilityView.Raw);
        return canvas;
    }

    private const double InkWidth = 1.7;

    private static Rectangle RoundRect(double left, double top, double width, double height, double radius, Color stroke)
    {
        var rect = new Rectangle
        {
            Width = width,
            Height = height,
            RadiusX = radius,
            RadiusY = radius,
            Stroke = Theme.Brush(stroke),
            StrokeThickness = InkWidth,
        };
        Canvas.SetLeft(rect, left);
        Canvas.SetTop(rect, top);
        return rect;
    }

    private static Ellipse Dot(double cx, double cy, double radius, Color fill)
    {
        var dot = new Ellipse
        {
            Width = radius * 2,
            Height = radius * 2,
            Fill = Theme.Brush(fill),
        };
        Canvas.SetLeft(dot, cx - radius);
        Canvas.SetTop(dot, cy - radius);
        return dot;
    }

    private static Ellipse Ring(double cx, double cy, double radius, Color stroke)
    {
        var ring = new Ellipse
        {
            Width = radius * 2,
            Height = radius * 2,
            Stroke = Theme.Brush(stroke),
            StrokeThickness = 3.4,
        };
        Canvas.SetLeft(ring, cx - radius);
        Canvas.SetTop(ring, cy - radius);
        return ring;
    }

    private static Line StrokeLine(double x1, double y1, double x2, double y2, Color stroke, double width = 3.4)
    {
        return new Line
        {
            X1 = x1,
            Y1 = y1,
            X2 = x2,
            Y2 = y2,
            Stroke = Theme.Brush(stroke),
            StrokeThickness = width,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
        };
    }

    /// <summary>A line of text that is not there yet. The Apple Ghost.</summary>
    private static Rectangle GhostLine(double x, double y, double width, Color color)
    {
        var ghost = new Rectangle
        {
            Width = width,
            Height = InkWidth,
            RadiusX = InkWidth / 2,
            RadiusY = InkWidth / 2,
            Fill = Theme.Brush(color),
        };
        Canvas.SetLeft(ghost, x);
        Canvas.SetTop(ghost, y - InkWidth / 2);
        return ghost;
    }

    /// <summary>
    /// A four-point spark, the accent that makes a scene pop. Static by
    /// design: each scene already carries its one loop.
    /// </summary>
    private static ShapesPath Sparkle(double size, Brush fill)
    {
        double half = size / 2;
        double inner = size * 0.16;
        var figure = new PathFigure { StartPoint = new Point(half, 0), IsClosed = true };
        figure.Segments.Add(new QuadraticBezierSegment
        {
            Point1 = new Point(half + inner, half - inner),
            Point2 = new Point(size, half),
        });
        figure.Segments.Add(new QuadraticBezierSegment
        {
            Point1 = new Point(half + inner, half + inner),
            Point2 = new Point(half, size),
        });
        figure.Segments.Add(new QuadraticBezierSegment
        {
            Point1 = new Point(half - inner, half + inner),
            Point2 = new Point(0, half),
        });
        figure.Segments.Add(new QuadraticBezierSegment
        {
            Point1 = new Point(half - inner, half - inner),
            Point2 = new Point(half, 0),
        });
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return new ShapesPath
        {
            Data = geometry,
            Fill = fill,
            Width = size,
            Height = size,
        };
    }

    private static Color WithAlpha(Color color, double alpha) =>
        Color.FromArgb((byte)(255 * alpha), color.R, color.G, color.B);
}
