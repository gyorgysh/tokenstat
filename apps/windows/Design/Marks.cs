// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
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

/// <summary>
/// A refresh somebody asked for, as an event the logo bars listen for.
/// Matches the Mac clientRefreshing notification: toolbar refresh, scan and
/// sync all go through here so the bars move the same way on both platforms.
/// </summary>
internal static class LogoRefresh
{
    internal static event Action? Refreshing;

    public static void Began() => Refreshing?.Invoke();
}

/// <summary>
/// The tokenstat brand marks, drawn in code. No image assets: the logo is
/// three rounded rectangles, so an asset would be a resource to keep in step
/// with the website SVG for no benefit, and drawn geometry is sharp at any
/// size. Geometry, colours, sizes and timings are read from the Mac
/// Marks.swift, which is the source of truth. Nothing here is invented.
/// </summary>
internal static class Marks
{
    /// <summary>
    /// The tokenstat mark: three ascending bars on a shared baseline.
    /// Bars 12 wide on a 15 pitch, sharing a baseline, from the website's
    /// 64 unit artboard. The frame is the ink (x 11..53, y 10..52), not the
    /// artboard, so the mark does not sit high next to text beside it.
    /// </summary>
    /// <param name="size">Frame side. The text in <see cref="Wordmark"/> scales with it.</param>
    /// <param name="animated">Draw the bars rising in turn, for a screen waiting on something.</param>
    /// <param name="loops">A repeating rise for a screen that stays while it waits,
    /// or one rise that lands and holds.</param>
    public static FrameworkElement LogoMark(double size = 18, bool animated = false, bool loops = true)
    {
        double unit = size / 42;
        // Bar tops and heights in artboard units, from Marks.swift. Colours are
        // the dark-context ramp the favicon badge uses.
        double[] tops = [34, 22, 10];
        double[] heights = [18, 30, 42];
        Color[] fills = [Theme.Hex(0xC3B0FFu), Theme.Hex(0x8B5CF6u), Theme.Hex(0xE879F9u)];

        // With the system reduce-motion setting on, loops land on the last
        // frame: full bars, no storyboard.
        bool moves = animated && AnimationsEnabled();
        var canvas = new Canvas { Width = size, Height = size };
        var bars = new List<Rectangle>();
        for (int i = 0; i < 3; i++)
        {
            var bar = new Rectangle
            {
                Width = 12 * unit,
                Height = heights[i] * unit,
                RadiusX = 3.5 * unit,
                RadiusY = 3.5 * unit,
                Fill = Theme.Brush(fills[i]),
                // Anchored at the foot, so a bar grows out of the shared
                // baseline rather than shrinking in place.
                RenderTransform = new ScaleTransform { ScaleY = moves ? 0.35 : 1 },
                RenderTransformOrigin = new Point(0.5, 1.0),
            };
            Canvas.SetLeft(bar, i * 15 * unit);
            Canvas.SetTop(bar, (tops[i] - 10) * unit);
            canvas.Children.Add(bar);
            bars.Add(bar);
        }
        AutomationProperties.SetName(canvas, "tokenstat");

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
                // Loops: 620ms rise, each bar a beat (140ms) after the one
                // before it. One shot: a single 1200ms rise on a 150ms
                // stagger that lands and holds.
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

    /// <summary>
    /// The mark and the name, for the top of the sidebar. 17 by default,
    /// where this sits above rows and must not shout over them.
    /// </summary>
    /// <param name="size">Mark height. The text scales with it, so one number sizes the lockup.</param>
    /// <param name="fills">Take the full width and push later content right,
    /// which is what a sidebar header wants and a centred toolbar item does not.</param>
    /// <param name="showsMark">Draw the bars as well as the name. A lockup that
    /// already placed the mark above the letters wants the word only.</param>
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
            // The website leaves a deliberate breath between the bars and the
            // word. A half-mark gap read as compressed.
            mark.Margin = new Thickness(0, 0, size * 0.75, 0);
            mark.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(mark);
        }

        var word = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(word, 1);
        word.Children.Add(new TextBlock
        {
            Text = "token",
            FontFamily = Fonts.Interface,
            FontSize = size * 0.88,
            FontWeight = FontWeights.Bold,
            Foreground = Theme.Brush(Theme.DefaultText),
            VerticalAlignment = VerticalAlignment.Center,
        });
        word.Children.Add(new TextBlock
        {
            Text = "stat",
            FontFamily = Fonts.Interface,
            FontSize = size * 0.88,
            FontWeight = FontWeights.Bold,
            Foreground = Theme.AccentBrush,
            VerticalAlignment = VerticalAlignment.Center,
        });
        row.Children.Add(word);

        AutomationProperties.SetName(row, "tokenstat");
        return row;
    }

    /// <summary>
    /// The account's profile picture, or initials when there is none. Same
    /// rule as the website and the Mac client: a real upload is the picture,
    /// a missing one is letters from the display name, first letter of the
    /// first two words, on a filled bubble.
    /// </summary>
    /// <param name="url">Profile picture URL. Empty and blank mean no picture.</param>
    /// <param name="name">The name the person is shown as. Initials come from this first.</param>
    /// <param name="handle">Falls back to this when there is no display name.</param>
    /// <param name="tint">Bubble colour when this is not the signed-in account.
    /// Left unset for our own picture, which uses the brand gradient.</param>
    public static FrameworkElement Avatar(
        string? url = null,
        string? name = null,
        string? handle = null,
        double size = 22,
        Color? tint = null)
    {
        Color seat = tint ?? Theme.Accent;
        // The signed-in account uses the same two-stop fill as the Mac bubble.
        // A per-person tint stays that person's colour, darkened toward the foot.
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
        // WinUI RectangleGeometry carries only a Rect: the WPF corner radii
        // do not exist on it, so the circle is an EllipseGeometry instead.
        grid.Clip = new EllipseGeometry
        {
            Center = new Point(size / 2, size / 2),
            RadiusX = size / 2,
            RadiusY = size / 2,
        };

        if (!string.IsNullOrWhiteSpace(url))
        {
            // Under the photo, so a slow or failed load still shows the
            // letters rather than a hole. A failed load collapses the photo.
            var photo = new Image
            {
                Width = size,
                Height = size,
                Stretch = Stretch.UniformToFill,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            photo.ImageFailed += (_, _) => photo.Visibility = Visibility.Collapsed;
            photo.Source = AvatarImage(url.Trim());
            if (photo.Source is not null)
            {
                grid.Children.Add(photo);
            }
        }

        AutomationProperties.SetName(grid, string.IsNullOrWhiteSpace(name) ? "avatar" : name.Trim());
        return grid;
    }

    /// <summary>
    /// One or two letters, uppercased, from a display name or a handle. First
    /// letter of the first two words, the same function the website uses.
    /// </summary>
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

    /// <summary>
    /// A stable colour for a person, from the heat ramp. Hashed over the bytes
    /// (djb2) rather than GetHashCode, which is seeded per process: the same
    /// author would get a different colour on every launch, and a mark that
    /// moves is not a mark. The ramp's first two steps are left out, they are
    /// the quiet-day greys and a letter in one of them is unreadable.
    /// </summary>
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

    /// <summary>
    /// The tier, as the silhouette the website puts beside a name. The paths
    /// are the site's own: a crest shield for Patron, a star for Supporter, a
    /// crown for Legend. Free has no mark at all, a badge everyone holds is
    /// decoration. A tier this build does not know still gets a mark (a seal),
    /// so a new tier on the server never makes an account look downgraded.
    /// </summary>
    /// <returns>The mark, or null when there is nothing to show.</returns>
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
                // The logo's own two strongest bars, so a badge beside a name
                // belongs to the same brand as the mark in the corner.
                StartPoint = new Point(0.5, 0),
                EndPoint = new Point(0.5, 1),
                GradientStops =
                {
                    new GradientStop { Color = Theme.Hex(0x8B5CF6u), Offset = 0 },
                    new GradientStop { Color = Theme.Hex(0xC026D3u), Offset = 1 },
                },
            },
            Width = size,
            Height = size,
        };
        string label = char.ToUpperInvariant(kind[0]) + kind[1..] + " tier";
        ToolTipService.SetToolTip(mark, label);
        AutomationProperties.SetName(mark, label);
        return mark;
    }

    /// <summary>
    /// One run of the logo rise for a refresh somebody pulled: the bars dip
    /// and come back up, once. Not the repeating launch animation. Wired only
    /// for a static mark, and only while it is in the tree.
    /// </summary>
    private static void WatchRefresh(Canvas canvas, List<Rectangle> bars)
    {
        bool pulsing = false;
        void OnRefresh()
        {
            // Raised on the UI thread by whoever handled the gesture.
            if (pulsing || !AnimationsEnabled())
            {
                return;
            }
            pulsing = true;
            // 260ms dip on a 70ms stagger, then back up. Matches the Mac
            // pulse animation values; the whole dip lasts about 600ms.
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

    /// <summary>
    /// A scale-Y rise for one bar: ease in-out, starting a stagger after the
    /// previous bar. A looping rise reverses back down and repeats; a single
    /// rise lands and holds.
    /// </summary>
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

    /// <summary>
    /// One decoded profile picture per URL, for the life of the process. The
    /// same face is drawn in several places, fetching it each time is a
    /// request nobody asked for. Capped at 128 entries; WinUI owns the decode
    /// cache, so there is no byte cap to account here like the Mac NSCache has.
    /// A shared instance also dedupes in-flight loads: views created while a
    /// download is running get the same bitmap and paint when it opens.
    /// </summary>
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

    /// <summary>
    /// Legend crown with the bar under it, in the website's 24 unit square.
    /// Transcribed from the SVG via Marks.swift, points absolute.
    /// </summary>
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

    /// <summary>
    /// Supporter star, in the website's 24 unit square.
    /// </summary>
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

    /// <summary>
    /// Patron crest shield with a chevron cut out of it. The cut is wound
    /// against the shield under an even-odd fill, so it stays open; at small
    /// sizes it closes up into a plain shield rather than mush.
    /// </summary>
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
