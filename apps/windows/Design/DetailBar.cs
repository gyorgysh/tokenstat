// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Tokenstat.Design;

/// <summary>
/// The fixed action strip above scrolling content. Mirrors the Mac
/// DetailChromeBar, which is the source of truth: one 40 point row on every
/// destination, leading navigation and scope on the left, the screen's own
/// actions on the right, a hairline underneath. Pages with ad-hoc chrome rows
/// can drop them for this.
/// </summary>
internal static class DetailBar
{
    /// <summary>The bar height. Fixed, like the Mac.</summary>
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
            Height = Height,
            Background = Theme.TabStripBrush,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Top,
        };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            VerticalAlignment = VerticalAlignment.Center,
            // The bottom breathing room is part of the metric rather than a
            // local adjustment, like the Mac: a 40 point bar with 3 points of
            // bottom inset centres its content on the shared optical baseline.
            Margin = new Thickness(Theme.SpaceM, 0, 0, BottomSpacing),
        };
        if (leading is not null)
        {
            foreach (var item in leading)
            {
                left.Children.Add(item);
            }
        }
        if (scope is not null)
        {
            left.Children.Add(scope);
        }
        if (accessory is not null)
        {
            left.Children.Add(accessory);
        }
        bar.Children.Add(left);
        var right = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 0, Theme.SpaceM, BottomSpacing),
        };
        if (trailing is not null)
        {
            foreach (var item in trailing)
            {
                right.Children.Add(item);
            }
        }
        Grid.SetColumn(right, 2);
        bar.Children.Add(right);
        var rule = new Microsoft.UI.Xaml.Shapes.Rectangle
        {
            Height = 1,
            Fill = Theme.BorderBrush,
            VerticalAlignment = VerticalAlignment.Bottom,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        Grid.SetColumnSpan(rule, 3);
        bar.Children.Add(rule);
        return bar;
    }

    /// <summary>
    /// Shared with the Mac DetailChromeBottomSpacing: the bottom inset that
    /// puts adjacent headers on the same optical baseline.
    /// </summary>
    private const double BottomSpacing = 3;
}
