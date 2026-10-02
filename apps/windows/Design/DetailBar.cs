// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Tokenstat.Design;

/// <summary>
/// The action strip above scrolling content. Mirrors the Mac
/// DetailChromeBar, which is the source of truth: a 40 point row on every
/// destination, leading navigation and scope on the left, the screen's own
/// actions on the right, a hairline underneath. Pages with ad-hoc chrome rows
/// can drop them for this.
/// </summary>
internal static class DetailBar
{
    private static readonly ConditionalWeakTable<UIElement, ToolbarPanel> Owners = new();

    /// <summary>The shared row height. Narrow toolbars may wrap into more rows.</summary>
    public const double Height = 40;

    /// <summary>
    /// Build the bar. Leading carries the screen's own navigation, then scope
    /// names which folder is on screen, then the accessory says which version
    /// of that folder it is, so it reads as part of the folder and not as one
    /// more control at the far end. Trailing carries the destination actions
    /// such as Refresh and the scope picker. Either side may be empty.
    /// </summary>
    /// <param name="leading">Navigation within this screen, in order.</param>
    /// <param name="scope">Which folder this screen is showing, when it is showing one.</param>
    /// <param name="accessory">Something belonging to the folder rather than the screen.</param>
    /// <param name="trailing">This screen's actions, in order.</param>
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

    /// <summary>
    /// Shared with the Mac DetailChromeBottomSpacing: the bottom inset that
    /// puts adjacent headers on the same optical baseline.
    /// </summary>
    private const double BottomSpacing = 3;

    /// <summary>
    /// Keep the two ends on one baseline when they fit. At narrower widths,
    /// wrap whole controls onto more rows instead of measuring both ends at
    /// infinity and letting them overlap or disappear outside the window.
    /// Stateful pickers remain mounted during resizing.
    /// </summary>
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
                var height = sharedHeight ?? Math.Max(Height, items.Max(c => c.DesiredSize.Height) + BottomSpacing);
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
                var height = Math.Max(Height, Children.Where(c => c.Visibility != Visibility.Collapsed)
                    .Select(c => c.DesiredSize.Height + BottomSpacing).DefaultIfEmpty(Height).Max());
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
            return new Size(width, Math.Max(Height, y));
        }
    }

    private static void Attach(ToolbarPanel controls, UIElement element)
    {
        // Stateful actions (for example terminal lifecycle buttons) survive
        // toolbar rebuilds, even before their previous strip was mounted.
        // Remember that owner instead of relying only on the visual tree.
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
