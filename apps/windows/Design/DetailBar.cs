// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Tokenstat.Design;

internal static class DetailBar
{
    private static readonly ConditionalWeakTable<UIElement, ToolbarPanel> Owners = new();

    public const double Height = 40;

    public static Grid View(
        IList<UIElement>? leading = null,
        UIElement? scope = null,
        UIElement? accessory = null,
        IList<UIElement>? trailing = null)
    {
        var bar = new Grid
        {
            MinHeight = Height,
            Background = Theme.TabStripBrush,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Top,
        };
        var controls = new ToolbarPanel();
        if (leading is not null)
        {
            foreach (var item in leading)
            {
                Attach(controls, item);
            }
        }
        if (scope is not null)
        {
            Attach(controls, scope);
        }
        if (accessory is not null)
        {
            Attach(controls, accessory);
        }
        controls.LeadingCount = controls.Children.Count;
        if (trailing is not null)
        {
            foreach (var item in trailing)
            {
                Attach(controls, item);
            }
        }
        bar.Children.Add(controls);
        var rule = new Microsoft.UI.Xaml.Shapes.Rectangle
        {
            Height = 1,
            Fill = Theme.BorderBrush,
            VerticalAlignment = VerticalAlignment.Bottom,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        bar.Children.Add(rule);
        return bar;
    }

    private const double BottomSpacing = 3;

    private sealed class ToolbarPanel : Panel
    {
        public int LeadingCount { get; set; }

        protected override Size MeasureOverride(Size available)
        {
            var width = double.IsFinite(available.Width) ? available.Width : 800;
            foreach (var child in Children)
                child.Measure(new Size(Math.Max(0, width - 2 * Theme.SpaceM), double.PositiveInfinity));
            return Layout(width, false);
        }

        protected override Size ArrangeOverride(Size finalSize)
        {
            Layout(finalSize.Width, true);
            return finalSize;
        }

        private Size Layout(double width, bool arrange)
        {
            var available = Math.Max(0, width - 2 * Theme.SpaceM);
            var leading = Children.Take(LeadingCount).Where(c => c.Visibility != Visibility.Collapsed).ToList();
            var trailing = Children.Skip(LeadingCount).Where(c => c.Visibility != Visibility.Collapsed).ToList();
            double Length(List<UIElement> items) => items.Sum(c => c.DesiredSize.Width)
                + Math.Max(0, items.Count - 1) * Theme.SpaceS;
            var total = Length(leading) + Length(trailing)
                + (leading.Count > 0 && trailing.Count > 0 ? Theme.SpaceS : 0);
            double y = 0;
            void Row(List<UIElement> items, bool right, double? sharedHeight = null)
            {
                var height = sharedHeight ?? Math.Max(DetailBar.Height, items.Max(c => c.DesiredSize.Height) + BottomSpacing);
                var x = Theme.SpaceM + (right ? Math.Max(0, available - Length(items)) : 0);
                foreach (var child in items)
                {
                    if (arrange) child.Arrange(new Rect(x, y + Math.Max(0, (height - BottomSpacing - child.DesiredSize.Height) / 2),
                        Math.Min(available, child.DesiredSize.Width), child.DesiredSize.Height));
                    x += child.DesiredSize.Width + Theme.SpaceS;
                }
                if (sharedHeight is null) y += height;
            }
            if (total <= available)
            {
                var height = Math.Max(DetailBar.Height, Children.Where(c => c.Visibility != Visibility.Collapsed)
                    .Select(c => c.DesiredSize.Height + BottomSpacing).DefaultIfEmpty(DetailBar.Height).Max());
                Row(leading, false, height);
                Row(trailing, true, height);
                return new Size(width, height);
            }
            foreach (var (items, right) in new[] { (leading, false), (trailing, true) })
            {
                var row = new List<UIElement>();
                foreach (var child in items)
                {
                    if (row.Count > 0 && Length(row) + Theme.SpaceS + child.DesiredSize.Width > available)
                    { Row(row, right); row.Clear(); }
                    row.Add(child);
                }
                if (row.Count > 0) Row(row, right);
            }
            return new Size(width, Math.Max(DetailBar.Height, y));
        }
    }

    private static void Attach(ToolbarPanel controls, UIElement element)
    {
        if (Owners.TryGetValue(element, out var previous))
        {
            previous.Children.Remove(element);
            Owners.Remove(element);
        }
        var owner = (element as FrameworkElement)?.Parent ?? VisualTreeHelper.GetParent(element);
        if (owner is Panel parent)
        {
            parent.Children.Remove(element);
        }
        controls.Children.Add(element);
        Owners.Add(element, controls);
    }
}
