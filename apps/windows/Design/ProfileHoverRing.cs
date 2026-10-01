// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace Tokenstat.Design;

/// <summary>The picture keeps its own colors; only its surrounding ring becomes vivid.</summary>
internal static class ProfileHoverRing
{
    private sealed class Ring
    {
        private readonly Ellipse _outline;
        private readonly Ellipse _halo;
        private Storyboard? _animation;
        public readonly Grid View;
        public Ring(FrameworkElement mark, double size)
        {
            var stroke = new LinearGradientBrush
            {
                StartPoint = new Point(0, 0), EndPoint = new Point(1, 1),
                GradientStops = { new GradientStop { Color = Theme.Accent, Offset = 0 }, new GradientStop { Color = Theme.Secondary, Offset = 1 } },
            };
            View = new Grid { Width = size + 8, Height = size + 8 };
            _halo = new Ellipse { Width = size + 6, Height = size + 6, Stroke = stroke, StrokeThickness = 5, Opacity = 0, IsHitTestVisible = false };
            _outline = new Ellipse { Width = size + 4, Height = size + 4, Stroke = stroke, StrokeThickness = 1, Opacity = 0.18, IsHitTestVisible = false };
            mark.HorizontalAlignment = HorizontalAlignment.Center;
            mark.VerticalAlignment = VerticalAlignment.Center;
            View.Children.Add(_halo); View.Children.Add(_outline); View.Children.Add(mark);
            View.Tag = this;
            View.ActualThemeChanged += (_, _) =>
            { stroke.GradientStops[0].Color = Theme.Accent; stroke.GradientStops[1].Color = Theme.Secondary; };
            View.Unloaded += (_, _) => SetActive(false, animate: false);
        }
        public void SetActive(bool active, bool animate = true)
        {
            var outline = _outline.Opacity; var halo = _halo.Opacity;
            _animation?.Stop();
            _outline.Opacity = active ? 1 : 0.18;
            _halo.Opacity = active ? 0.25 : 0;
            _animation = null;
            if (!animate || !Motion.AnimationsEnabled()) return;
            var board = new Storyboard();
            void Fade(Ellipse element, double from, double to)
            {
                var fade = new DoubleAnimation { From = from, To = to, Duration = new Duration(TimeSpan.FromMilliseconds(180)), EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
                Storyboard.SetTarget(fade, element); Storyboard.SetTargetProperty(fade, "Opacity"); board.Children.Add(fade);
            }
            Fade(_outline, outline, _outline.Opacity); Fade(_halo, halo, _halo.Opacity);
            _animation = board; board.Begin();
        }
    }

    public static FrameworkElement Wrap(FrameworkElement mark, double size) => new Ring(mark, size).View;
    public static void Attach(FrameworkElement wrapped, FrameworkElement trigger)
    {
        if (wrapped.Tag is not Ring ring) return;
        var pointer = false; var focus = false;
        trigger.PointerEntered += (_, _) => { pointer = true; ring.SetActive(true); };
        trigger.PointerExited += (_, _) => { pointer = false; ring.SetActive(focus); };
        trigger.GotFocus += (_, _) => { focus = true; ring.SetActive(true); };
        trigger.LostFocus += (_, _) => { focus = false; ring.SetActive(pointer); };
        trigger.Unloaded += (_, _) => { pointer = focus = false; ring.SetActive(false, animate: false); };
    }
}
