// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;

namespace Tokenstat.Design;

/// <summary>
/// Motion tokens and storyboard helpers, ported from the Apple clients and
/// the Android TsMotion port. Timings are read from the sources, nothing here
/// is invented: arrive 220ms with a 4pt rise (Skeleton smoothIn, TsMotion
/// arriveMillis), door 280ms easeInOut between shell states (TsMotion
/// doorMillis), toast 250ms snappy (Theme TransientToast), skeleton pulse
/// 950ms easeInOut autoreverse (Skeleton Bar), breathe 1100ms easeInOut loop
/// (MiniGraph live node, ClientEmptyArt scenes), and the staggered intro
/// spring family from ClientOnboardingArt and ClientEmptyArt.
/// Every helper respects the system animation setting: loops land on the
/// resting frame, arrivals collapse to a fade.
/// </summary>
internal static class Motion
{
    /// <summary>Smooth arrival of loaded content: fade with a small rise.</summary>
    public const int ArriveMillis = 220;

    /// <summary>The rise in a smooth arrival, in device independent pixels.</summary>
    public const double ArriveRiseDip = 4;

    /// <summary>Root shell door transitions between shell states.</summary>
    public const int DoorMillis = 280;

    /// <summary>Toast slide and fade.</summary>
    public const int ToastMillis = 250;

    /// <summary>Skeleton pulse period.</summary>
    public const int PulseMillis = 950;

    /// <summary>Breathing live indicators.</summary>
    public const int BreatheMillis = 1100;

    /// <summary>
    /// One spring of the staggered onboarding intro family: response in
    /// seconds, damping fraction, and delay in seconds. From
    /// ClientOnboardingArt (0.5/0.82 rows, 0.55/0.78 card, 0.7/0.78 bars)
    /// and ClientEmptyArt (0.6/0.7 delayed 0.15 settle).
    /// </summary>
    /// <param name="Response">Spring response time in seconds.</param>
    /// <param name="DampingFraction">Damping fraction, 0 is undamped.</param>
    /// <param name="Delay">Start delay in seconds.</param>
    public readonly record struct IntroSpring(double Response, double DampingFraction, double Delay);

    /// <summary>Staggered intro rows: spring 0.5, damping 0.82.</summary>
    public static readonly IntroSpring SpringRise = new(0.5, 0.82, 0);

    /// <summary>Card arrival: spring 0.55, damping 0.78.</summary>
    public static readonly IntroSpring SpringCard = new(0.55, 0.78, 0);

    /// <summary>Bars landing: spring 0.7, damping 0.78.</summary>
    public static readonly IntroSpring SpringBars = new(0.7, 0.78, 0);

    /// <summary>Empty art settle: spring 0.6, damping 0.7, delayed 0.15.</summary>
    public static readonly IntroSpring SpringSettle = new(0.6, 0.7, 0.15);

    /// <summary>
    /// Whether the system wants motion. Loops land on the resting frame and
    /// arrivals become fades when this is off. Same probe Marks uses.
    /// </summary>
    public static bool AnimationsEnabled()
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

    /// <summary>
    /// The smoothIn arrival for loaded content replacing a skeleton: a short
    /// fade with a small rise. Collapses to a plain fade when motion is off.
    /// Plays once the element is in the tree.
    /// </summary>
    public static void PlayArrival(UIElement element)
    {
        void Run()
        {
            bool moves = AnimationsEnabled();
            double rise = moves ? ArriveRiseDip : 0;
            element.Opacity = 0;
            element.RenderTransform = new TranslateTransform { Y = rise };
            var board = new Storyboard();
            var fade = Fade(0, 1, ArriveMillis, delayMs: 0);
            Storyboard.SetTarget(fade, element);
            board.Children.Add(fade);
            if (moves)
            {
                var up = new DoubleAnimation
                {
                    From = rise,
                    To = 0,
                    Duration = new Duration(TimeSpan.FromMilliseconds(ArriveMillis)),
                };
                Storyboard.SetTarget(up, element);
                Storyboard.SetTargetProperty(up, "(UIElement.RenderTransform).(TranslateTransform.Y)");
                board.Children.Add(up);
            }
            board.Begin();
        }

        if (element is FrameworkElement live && !live.IsLoaded)
        {
            RoutedEventHandler? loaded = null;
            loaded = (_, _) =>
            {
                live.Loaded -= loaded;
                Run();
            };
            live.Loaded += loaded;
            return;
        }
        Run();
    }

    /// <summary>
    /// A shell door swap: 280ms easeInOut fade between shell states, such as
    /// the host splash and the first page. No rise, doors do not rise.
    /// </summary>
    public static void PlayDoor(UIElement element)
    {
        void Run()
        {
            if (!AnimationsEnabled())
            {
                element.Opacity = 1;
                return;
            }
            element.Opacity = 0;
            var board = new Storyboard();
            var fade = Fade(0, 1, DoorMillis, delayMs: 0);
            fade.EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut };
            Storyboard.SetTarget(fade, element);
            board.Children.Add(fade);
            board.Begin();
        }

        if (element is FrameworkElement live && !live.IsLoaded)
        {
            RoutedEventHandler? loaded = null;
            loaded = (_, _) =>
            {
                live.Loaded -= loaded;
                Run();
            };
            live.Loaded += loaded;
            return;
        }
        Run();
    }

    /// <summary>
    /// A toast arrival: 250ms slide and fade. Snappy on the way in, like the
    /// Apple TransientToast.
    /// </summary>
    public static void ToastIn(FrameworkElement element)
    {
        void Run()
        {
            if (!AnimationsEnabled())
            {
                element.Opacity = 1;
                return;
            }
            element.Opacity = 0;
            element.RenderTransform = new TranslateTransform { Y = 8 };
            var board = new Storyboard();
            var fade = Fade(0, 1, ToastMillis, delayMs: 0);
            fade.EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut };
            Storyboard.SetTarget(fade, element);
            board.Children.Add(fade);
            var up = new DoubleAnimation
            {
                From = 8,
                To = 0,
                Duration = new Duration(TimeSpan.FromMilliseconds(ToastMillis)),
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            };
            Storyboard.SetTarget(up, element);
            Storyboard.SetTargetProperty(up, "(UIElement.RenderTransform).(TranslateTransform.Y)");
            board.Children.Add(up);
            board.Begin();
        }

        if (!element.IsLoaded)
        {
            RoutedEventHandler? loaded = null;
            loaded = (_, _) =>
            {
                element.Loaded -= loaded;
                Run();
            };
            element.Loaded += loaded;
            return;
        }
        Run();
    }

    /// <summary>
    /// One grey bar standing in for a line of text or a number. A soft
    /// opacity pulse keeps the layout alive without a shimmer that steals
    /// attention from the data about to land. Motion off leaves the resting
    /// frame: full opacity, no storyboard.
    /// </summary>
    /// <param name="widthDip">Bar width, or null to fill the space.</param>
    /// <param name="phaseSecs">Phase offset so neighbours do not pulse in lockstep.</param>
    public static Border SkeletonBar(double? widthDip, double height = 12, double phaseSecs = 0)
    {
        var bar = new Border
        {
            Height = height,
            CornerRadius = new CornerRadius(4),
            Background = Theme.BorderBrush,
            HorizontalAlignment = widthDip is null ? HorizontalAlignment.Stretch : HorizontalAlignment.Left,
        };
        if (widthDip is not null)
        {
            bar.Width = widthDip.Value;
        }
        if (!AnimationsEnabled())
        {
            return bar;
        }
        LoopOnLoad(bar, () =>
        {
            var pulse = new DoubleAnimation
            {
                From = 0.52,
                To = 1,
                Duration = new Duration(TimeSpan.FromMilliseconds(PulseMillis)),
                BeginTime = TimeSpan.FromSeconds(phaseSecs),
                AutoReverse = true,
                RepeatBehavior = RepeatBehavior.Forever,
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut },
            };
            Storyboard.SetTarget(pulse, bar);
            Storyboard.SetTargetProperty(pulse, "(UIElement.Opacity)");
            return pulse;
        });
        return bar;
    }

    /// <summary>
    /// A stack of rows, each a label bar and a value bar, like a list.
    /// Widths vary down the stack so it reads as text rather than as a bar
    /// chart. Deterministic, not random: a placeholder that reshuffles on
    /// every redraw is a distraction of its own.
    /// </summary>
    public static StackPanel SkeletonRows(int count = 5, bool showsValue = true)
    {
        double[] labelWidths = [128, 96, 152, 84, 116, 104];
        var stack = new StackPanel { Spacing = Theme.SpaceS };
        for (int index = 0; index < count; index++)
        {
            var row = new Grid { ColumnSpacing = Theme.SpaceS };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var label = SkeletonBar(labelWidths[index % labelWidths.Length], phaseSecs: index * 0.08);
            row.Children.Add(label);
            if (showsValue)
            {
                var value = SkeletonBar(52, phaseSecs: index * 0.08 + 0.04);
                Grid.SetColumn(value, 1);
                row.Children.Add(value);
            }
            stack.Children.Add(row);
        }
        return stack;
    }

    /// <summary>
    /// A card-shaped placeholder: heading, subheading, and some rows. What a
    /// page shows while the host has not answered yet, instead of a spinner.
    /// </summary>
    public static Border SkeletonCard(int rows = 3)
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        var heading = new StackPanel { Spacing = 4 };
        heading.Children.Add(SkeletonBar(116, height: 11));
        heading.Children.Add(SkeletonBar(168, height: 9, phaseSecs: 0.06));
        body.Children.Add(heading);
        body.Children.Add(SkeletonRows(rows));
        return new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.CardPadding),
            Child = body,
        };
    }

    /// <summary>
    /// A breathing opacity loop for a live indicator, 1100ms easeInOut. Only
    /// the thing that is actually working breathes. Motion off parks it lit.
    /// </summary>
    public static void Breathe(UIElement element, double low = 0.25, double high = 0.9)
    {
        if (!AnimationsEnabled())
        {
            element.Opacity = high;
            return;
        }
        LoopOnLoad(element, () =>
        {
            var breath = new DoubleAnimation
            {
                From = low,
                To = high,
                Duration = new Duration(TimeSpan.FromMilliseconds(BreatheMillis)),
                AutoReverse = true,
                RepeatBehavior = RepeatBehavior.Forever,
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut },
            };
            Storyboard.SetTarget(breath, element);
            Storyboard.SetTargetProperty(breath, "(UIElement.Opacity)");
            return breath;
        });
    }

    /// <summary>
    /// The "Working" line at the foot of a busy transcript. It breathes while
    /// the turn runs, so a long wait does not read as frozen.
    /// </summary>
    public static TextBlock WorkingLabel()
    {
        var label = new TextBlock
        {
            Text = "Working",
            Foreground = Theme.AccentBrush,
            FontSize = 12,
        };
        Breathe(label, low: 0.35, high: 1);
        return label;
    }

    /// <summary>
    /// One spring of the onboarding intro family: the element settles from a
    /// small dip with the response and damping the Apple spring carries.
    /// Period is the response, damping ratio is the damping fraction. Motion
    /// off leaves the resting frame.
    /// </summary>
    /// <param name="fromDip">How far below resting the element starts, in pixels.</param>
    public static void SpringIn(FrameworkElement element, IntroSpring spring, double fromDip = 12)
    {
        void Run()
        {
            if (!AnimationsEnabled())
            {
                return;
            }
            try
            {
                Visual visual = ElementCompositionPreview.GetElementVisual(element);
                Compositor compositor = visual.Compositor;
                SpringScalarNaturalMotionAnimation settle = compositor.CreateSpringScalarAnimation();
                settle.DampingRatio = (float)spring.DampingFraction;
                settle.Period = TimeSpan.FromSeconds(spring.Response);
                settle.DelayTime = TimeSpan.FromSeconds(spring.Delay);
                settle.FinalValue = 0;
                settle.InitialValue = (float)fromDip;
                visual.StartAnimation("Offset.Y", settle);
                var fade = Fade(0, 1, (int)(spring.Response * 1000), delayMs: (int)(spring.Delay * 1000));
                Storyboard.SetTarget(fade, element);
                var board = new Storyboard();
                board.Children.Add(fade);
                board.Begin();
            }
            catch
            {
                // The compositor is unavailable. The resting frame is already
                // on screen, which is the correct fallback.
            }
        }

        if (!element.IsLoaded)
        {
            RoutedEventHandler? loaded = null;
            loaded = (_, _) =>
            {
                element.Loaded -= loaded;
                Run();
            };
            element.Loaded += loaded;
            return;
        }
        Run();
    }

    private static DoubleAnimation Fade(double from, double to, int durationMs, int delayMs)
    {
        var fade = new DoubleAnimation
        {
            From = from,
            To = to,
            Duration = new Duration(TimeSpan.FromMilliseconds(durationMs)),
            BeginTime = TimeSpan.FromMilliseconds(delayMs),
        };
        Storyboard.SetTargetProperty(fade, "(UIElement.Opacity)");
        return fade;
    }

    /// <summary>
    /// Start a looping storyboard when the element enters the tree, stop it
    /// when it leaves. Loops never outlive their screen.
    /// </summary>
    private static void LoopOnLoad(UIElement element, Func<DoubleAnimation> build)
    {
        Storyboard? board = null;
        bool started = false;
        if (element is FrameworkElement live)
        {
            live.Loaded += (_, _) =>
            {
                if (started)
                {
                    return;
                }
                started = true;
                board = new Storyboard();
                board.Children.Add(build());
                board.Begin();
            };
            live.Unloaded += (_, _) =>
            {
                started = false;
                board?.Stop();
                board = null;
            };
        }
    }
}
