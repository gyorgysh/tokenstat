// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;

namespace Tokenstat.Design;

internal static class Motion
{
    public const int ArriveMillis = 220;

    public const double ArriveRiseDip = 4;

    public const int DoorMillis = 280;

    public const int ToastMillis = 250;

    public const int PulseMillis = 950;

    public const int BreatheMillis = 1100;

    public readonly record struct IntroSpring(double Response, double DampingFraction, double Delay);

    public static readonly IntroSpring SpringRise = new(0.5, 0.82, 0);

    public static readonly IntroSpring SpringCard = new(0.55, 0.78, 0);

    public static readonly IntroSpring SpringBars = new(0.7, 0.78, 0);

    public static readonly IntroSpring SpringSettle = new(0.6, 0.7, 0.15);

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

    public static Border SkeletonCard(int rows = 3)
    {
        var body = new StackPanel { Spacing = Theme.SpaceM, Opacity = 0.75 };
        var heading = new StackPanel { Spacing = 6 };
        heading.Children.Add(SkeletonBar(116, height: 10));
        heading.Children.Add(SkeletonBar(168, height: 8, phaseSecs: 0.06));
        body.Children.Add(heading);
        body.Children.Add(SkeletonRows(rows));
        var background = Theme.PanelBrush;
        background.Opacity = 0.6;
        return new Border
        {
            Background = background,
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.CardPadding),
            Child = body,
        };
    }

    private static readonly (bool Mine, int Lines)[] TranscriptTurns =
    {
        (false, 3), (true, 1), (false, 5), (true, 2), (false, 2), (false, 4), (true, 1), (false, 3),
    };
    private static readonly double[] TranscriptWidths = { 0.94, 0.86, 0.71, 0.9, 0.58, 0.8 };

    public static StackPanel TranscriptSkeleton(int turns = 10, double lane = 640)
    {
        var stack = new StackPanel { Spacing = 22, Opacity = 0.7, Margin = new Thickness(0, Theme.SpaceL, 0, 0) };
        for (var index = turns - 1; index >= 0; index--)
        {
            var turn = TranscriptTurns[index % TranscriptTurns.Length];
            var span = turn.Mine ? lane * 0.5 : lane;
            var lines = new StackPanel { Spacing = 9 };
            for (var line = 0; line < turn.Lines; line++)
            {
                lines.Children.Add(SkeletonBar(span * TranscriptWidths[(index * 2 + line) % TranscriptWidths.Length],
                    height: 9, phaseSecs: (index % TranscriptTurns.Length) * 0.11 + line * 0.05));
            }
            var fade = 0.2 + 0.8 * (turns - index) / turns;
            FrameworkElement element = turn.Mine
                ? new Border
                {
                    Background = Theme.AccentSoftBrush,
                    CornerRadius = new CornerRadius(16),
                    Padding = new Thickness(12),
                    HorizontalAlignment = HorizontalAlignment.Right,
                    Width = span + 24,
                    Child = lines,
                }
                : lines;
            element.Opacity = fade;
            stack.Children.Add(element);
        }
        AutomationProperties.SetName(stack, L10n.Text("common.loading"));
        return stack;
    }

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

    public static TextBlock WorkingLabel()
    {
        var label = new TextBlock
        {
            Text = L10n.Text("common.working"),
            Foreground = Theme.AccentBrush,
            FontSize = 12,
        };
        Breathe(label, low: 0.35, high: 1);
        return label;
    }

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
