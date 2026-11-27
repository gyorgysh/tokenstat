// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;
// The WinUI shape element collides with System.IO.Path under implicit usings.
using ShapesPath = Microsoft.UI.Xaml.Shapes.Path;

namespace Tokenstat.Design;

internal static class LogoRefresh
{
    internal static event Action? Refreshing;

    public static void Began() => Refreshing?.Invoke();
}

internal static class Marks
{
    public static FrameworkElement Device(string platform, bool client = false, double size = 30)
    {
        var phone = client || platform.Contains("ios", StringComparison.OrdinalIgnoreCase)
            || platform.Contains("android", StringComparison.OrdinalIgnoreCase);
        IconElement icon = phone ? new SymbolIcon(Symbol.CellPhone) : new FontIcon
        {
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
            Glyph = char.ToString((char)0xE770), FontSize = 18,
        };
        icon.Foreground = Theme.AccentBrush;
        return new Border
        {
            Width = size, Height = size, Background = Theme.AccentSoftBrush,
            CornerRadius = new CornerRadius(8), Child = icon,
        };
    }

    private static Color BarColor(Color brand, int index)
    {
        if (Theme.ShowsBrandColors) return brand;
        var text = Theme.DefaultText;
        return Color.FromArgb(index switch { 0 => (byte)102, 1 => (byte)173, _ => (byte)255 }, text.R, text.G, text.B);
    }

    public static FrameworkElement LogoMark(double size = 18, bool animated = false, bool loops = true)
    {
        double unit = size / 42;
        double[] tops = [34, 22, 10];
        double[] heights = [18, 30, 42];
        Color[] fills = [Theme.Hex(0xC3B0FFu), Theme.Hex(0x8B5CF6u), Theme.Hex(0xE879F9u)];

        bool moves = animated && AnimationsEnabled();
        var canvas = new Canvas { Width = size, Height = size };
        var bars = new List<Rectangle>();
        for (int i = 0; i < 3; i++)
        {
            var (fill, index) = (fills[i], i);
            var bar = new Rectangle
            {
                Width = 12 * unit,
                Height = heights[i] * unit,
                RadiusX = 3.5 * unit,
                RadiusY = 3.5 * unit,
                Fill = Theme.Brush(() => BarColor(fill, index)),
                RenderTransform = new ScaleTransform { ScaleY = moves ? 0.35 : 1 },
                RenderTransformOrigin = new Point(0.5, 1.0),
            };
            Canvas.SetLeft(bar, i * 15 * unit);
            Canvas.SetTop(bar, (tops[i] - 10) * unit);
            canvas.Children.Add(bar);
            bars.Add(bar);
        }
        AutomationProperties.SetName(canvas, L10n.Text("windows.marks.tokenstat.63d30539"));

        if (!animated)
        {
            WatchRefresh(canvas, bars);
            return canvas;
        }

        if (!moves)
        {
            return canvas;
        }

        var boards = new List<Storyboard>();
        bool started = false;
        canvas.Loaded += (_, _) =>
        {
            if (started)
            {
                return;
            }
            started = true;
            var board = new Storyboard();
            foreach (var (bar, index) in bars.Select((bar, index) => (bar, index)))
            {
                var rise = loops
                    ? BarScale(index, 620, 140, loop: true)
                    : BarScale(index, 1200, 150, loop: false);
                TargetScaleY(rise, bar);
                board.Children.Add(rise);
            }
            boards.Add(board);
            board.Begin();
        };
        canvas.Unloaded += (_, _) =>
        {
            started = false;
            foreach (var board in boards)
            {
                board.Stop();
            }
            boards.Clear();
        };
        return canvas;
    }

    public static FrameworkElement Wordmark(double size = 17, bool fills = true, bool showsMark = true)
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (fills)
        {
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        }

        if (showsMark)
        {
            var mark = LogoMark(size);
            Grid.SetColumn(mark, 0);
            mark.Margin = new Thickness(0, 0, size * 0.75, 0);
            mark.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(mark);
        }

        var word = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(word, 1);
        word.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.marks.token.3c469e9d"),
            FontFamily = Fonts.Interface,
            FontSize = size * 0.88,
            FontWeight = FontWeights.Bold,
            Foreground = Theme.Brush(static () => Theme.DefaultText),
            VerticalAlignment = VerticalAlignment.Center,
        });
        word.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.marks.stat.40460da8"),
            FontFamily = Fonts.Interface,
            FontSize = size * 0.88,
            FontWeight = FontWeights.Bold,
            Foreground = Theme.Brush(static () => Theme.ShowsBrandColors ? Theme.Accent
                : Color.FromArgb(153, Theme.DefaultText.R, Theme.DefaultText.G, Theme.DefaultText.B)),
            VerticalAlignment = VerticalAlignment.Center,
        });
        row.Children.Add(word);

        AutomationProperties.SetName(row, L10n.Text("windows.marks.tokenstat.63d30539"));
        return row;
    }

    public static FrameworkElement Avatar(
        string? url = null,
        string? name = null,
        string? handle = null,
        double size = 22,
        Color? tint = null)
    {
        Color seat = tint ?? Theme.Accent;
        Color deep = seat == Theme.Accent
            ? Theme.Secondary
            : Color.FromArgb(184, seat.R, seat.G, seat.B);
        var bubble = new Ellipse
        {
            Width = size,
            Height = size,
            Fill = new LinearGradientBrush
            {
                StartPoint = new Point(0, 0),
                EndPoint = new Point(1, 1),
                GradientStops =
                {
                    new GradientStop { Color = seat, Offset = 0 },
                    new GradientStop { Color = deep, Offset = 1 },
                },
            },
        };

        string monogram = Initials(name) ?? Initials(handle) ?? string.Empty;
        UIElement face;
        if (monogram.Length == 0)
        {
            face = new SymbolIcon
            {
                Symbol = Symbol.Contact,
                Foreground = Theme.Brush(Colors.White),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
        }
        else
        {
            face = new TextBlock
            {
                Text = monogram,
                FontFamily = Fonts.Interface,
                FontSize = size * (monogram.Length > 1 ? 0.34 : 0.42),
                FontWeight = FontWeights.SemiBold,
                Foreground = Theme.Brush(Colors.White),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
        }

        var grid = new Grid { Width = size, Height = size };
        grid.Children.Add(bubble);
        grid.Children.Add(face);

        if (!string.IsNullOrWhiteSpace(url))
        {
            // The bubble and the face are already round; only the square
            // photo needs circularizing. WinUI has no circular clip
            // (UIElement.Clip takes a RectangleGeometry, which carries only
            // a Rect), so the photo is an ellipse filled with the image
            // instead of a clipped rectangle. A slow or failed load still
            // shows the letters rather than a hole.
            var source = AvatarImage(url.Trim());
            if (source is not null)
            {
                var brush = new ImageBrush
                {
                    ImageSource = source,
                    Stretch = Stretch.UniformToFill,
                };
                var photo = new Ellipse
                {
                    Width = size,
                    Height = size,
                    Fill = brush,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                brush.ImageFailed += (_, _) => photo.Visibility = Visibility.Collapsed;
                grid.Children.Add(photo);
            }
        }

        AutomationProperties.SetName(grid, string.IsNullOrWhiteSpace(name) ? L10n.Text("windows.marks.avatar.87bbe879") : name.Trim());
        return grid;
    }

    public static string? Initials(string? name)
    {
        var parts = (name ?? "").Trim()
            .Split([' ', '\t', '\n', '\r'], StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0)
        {
            return null;
        }
        string letters = FirstCharacter(parts[0]);
        if (parts.Length > 1)
        {
            letters += FirstCharacter(parts[1]);
        }
        return letters.ToUpperInvariant();
    }

    public static Color TintForIdentity(string identity)
    {
        var ramp = Theme.IsDark ? Theme.HeatDark : Theme.Heat;
        var palette = ramp.Skip(2).Append(Theme.Warning).Append(Theme.Danger).ToArray();
        ulong hash = 5381;
        foreach (byte b in Encoding.UTF8.GetBytes((identity ?? "").ToLowerInvariant()))
        {
            hash = (hash * 33) + b;
        }
        return palette[hash % (ulong)palette.Length];
    }

    public static FrameworkElement? TierMark(string tier, double size = 15)
    {
        string kind = (tier ?? "").ToLowerInvariant();
        if (kind is "free" or "")
        {
            return null;
        }
        Geometry data = kind switch
        {
            "legend" => Crown(size),
            "patron" => PatronShield(size),
            "supporter" => SupporterStar(size),
            _ => new EllipseGeometry
            {
                Center = new Point(size / 2, size / 2),
                RadiusX = size * 8 / 24,
                RadiusY = size * 8 / 24,
            },
        };
        var mark = new ShapesPath
        {
            Data = data,
            Fill = new LinearGradientBrush
            {
                StartPoint = new Point(0.5, 0),
                EndPoint = new Point(0.5, 1),
                GradientStops =
                {
                    new GradientStop { Color = Theme.ShowsBrandColors ? Theme.Hex(0x8B5CF6u) : Theme.Accent, Offset = 0 },
                    new GradientStop { Color = Theme.ShowsBrandColors ? Theme.Hex(0xC026D3u) : Theme.Secondary, Offset = 1 },
                },
            },
            Width = size,
            Height = size,
        };
        string label = PlanName.Title(kind) + L10n.Text("windows.marks.tier.9382d092");
        ToolTipService.SetToolTip(mark, label);
        AutomationProperties.SetName(mark, label);
        return mark;
    }

    private static void WatchRefresh(Canvas canvas, List<Rectangle> bars)
    {
        bool pulsing = false;
        void OnRefresh()
        {
            if (pulsing || !AnimationsEnabled())
            {
                return;
            }
            pulsing = true;
            var board = new Storyboard();
            foreach (var (bar, index) in bars.Select((bar, index) => (bar, index)))
            {
                var dip = BarScale(index, 260, 70, loop: false);
                dip.From = 1;
                dip.To = 0.35;
                dip.AutoReverse = true;
                TargetScaleY(dip, bar);
                board.Children.Add(dip);
            }
            board.Completed += (_, _) =>
            {
                pulsing = false;
                foreach (var bar in bars)
                {
                    ((ScaleTransform)bar.RenderTransform).ScaleY = 1;
                }
            };
            board.Begin();
        }

        canvas.Loaded += (_, _) => LogoRefresh.Refreshing += OnRefresh;
        canvas.Unloaded += (_, _) =>
        {
            LogoRefresh.Refreshing -= OnRefresh;
            pulsing = false;
        };
    }

    private static DoubleAnimation BarScale(int index, int durationMs, int staggerMs, bool loop)
    {
        var animation = new DoubleAnimation
        {
            From = 0.35,
            To = 1,
            Duration = new Duration(TimeSpan.FromMilliseconds(durationMs)),
            BeginTime = TimeSpan.FromMilliseconds(index * staggerMs),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut },
        };
        if (loop)
        {
            animation.AutoReverse = true;
            animation.RepeatBehavior = RepeatBehavior.Forever;
        }
        return animation;
    }

    private static void TargetScaleY(DoubleAnimation animation, Rectangle bar)
    {
        Storyboard.SetTarget(animation, bar);
        Storyboard.SetTargetProperty(animation, "(UIElement.RenderTransform).(ScaleTransform.ScaleY)");
    }

    private static bool AnimationsEnabled()
    {
        try
        {
            return new Windows.UI.ViewManagement.UISettings().AnimationsEnabled;
        }
        catch
        {
            return true;
        }
    }

    private static string FirstCharacter(string word) =>
        Rune.GetRuneAt(word, 0).ToString();

    private static readonly Dictionary<string, BitmapImage> AvatarImages = new();
    private static readonly Queue<string> AvatarImageOrder = new();

    private static BitmapImage? AvatarImage(string url)
    {
        if (AvatarImages.TryGetValue(url, out var cached))
        {
            return cached;
        }
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)
            || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            return null;
        }
        try
        {
            var bitmap = new BitmapImage(uri);
            bitmap.ImageFailed += (_, _) => { AvatarImages.Remove(url); };
            AvatarImages[url] = bitmap;
            AvatarImageOrder.Enqueue(url);
            while (AvatarImageOrder.Count > 128 && AvatarImageOrder.TryDequeue(out var oldest))
            {
                AvatarImages.Remove(oldest);
            }
            return bitmap;
        }
        catch
        {
            return null;
        }
    }

    private static PathGeometry Crown(double size)
    {
        double u = size / 24;
        Point p(double x, double y) => new(x * u, y * u);
        var band = new PathFigure
        {
            StartPoint = p(3, 7.4),
            IsClosed = true,
            Segments =
            {
                new LineSegment { Point = p(7.6, 10.6) },
                new LineSegment { Point = p(12, 3.4) },
                new LineSegment { Point = p(16.4, 10.6) },
                new LineSegment { Point = p(21, 7.4) },
                new LineSegment { Point = p(19.3, 18.6) },
                new LineSegment { Point = p(4.7, 18.6) },
            },
        };
        var bar = new PathFigure
        {
            StartPoint = p(4.7, 20.1),
            IsClosed = true,
            Segments =
            {
                new LineSegment { Point = p(19.3, 20.1) },
                new LineSegment { Point = p(19.3, 22) },
                new LineSegment { Point = p(4.7, 22) },
            },
        };
        return new PathGeometry { Figures = { band, bar } };
    }

    private static PathGeometry SupporterStar(double size)
    {
        double u = size / 24;
        Point p(double x, double y) => new(x * u, y * u);
        var star = new PathFigure
        {
            StartPoint = p(12, 2.6),
            IsClosed = true,
            Segments =
            {
                new LineSegment { Point = p(14.7, 8.5) },
                new LineSegment { Point = p(21, 9.2) },
                new LineSegment { Point = p(16.3, 13.5) },
                new LineSegment { Point = p(17.6, 19.8) },
                new LineSegment { Point = p(12, 16.7) },
                new LineSegment { Point = p(6.4, 19.8) },
                new LineSegment { Point = p(7.7, 13.5) },
                new LineSegment { Point = p(3, 9.2) },
                new LineSegment { Point = p(9.3, 8.5) },
            },
        };
        return new PathGeometry { Figures = { star } };
    }

    private static PathGeometry PatronShield(double size)
    {
        double u = size / 24;
        Point p(double x, double y) => new(x * u, y * u);
        var shield = new PathFigure
        {
            StartPoint = p(12, 2.1),
            IsClosed = true,
            Segments =
            {
                new LineSegment { Point = p(20.4, 4.9) },
                new LineSegment { Point = p(20.4, 11) },
                new BezierSegment { Point1 = p(20.4, 16.1), Point2 = p(16.8, 20.2), Point3 = p(12, 21.9) },
                new BezierSegment { Point1 = p(7.2, 20.2), Point2 = p(3.6, 16.1), Point3 = p(3.6, 11) },
                new LineSegment { Point = p(3.6, 4.9) },
            },
        };
        var chevron = new PathFigure
        {
            StartPoint = p(7.9, 9.2),
            IsClosed = true,
            Segments =
            {
                new LineSegment { Point = p(7.9, 11.9) },
                new LineSegment { Point = p(12, 16) },
                new LineSegment { Point = p(16.1, 11.9) },
                new LineSegment { Point = p(16.1, 9.2) },
                new LineSegment { Point = p(12, 13.3) },
            },
        };
        return new PathGeometry { FillRule = FillRule.EvenOdd, Figures = { shield, chevron } };
    }
}
