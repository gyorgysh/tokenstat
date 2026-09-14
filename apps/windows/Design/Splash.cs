// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Tokenstat.Design;

/// <summary>
/// What the launch splash reports about the background helper. Starting is
/// the first frame. Offline and Error keep the mark on screen and say what
/// happened, with a way to try again.
/// </summary>
internal enum HostSplashState
{
    Starting,
    Offline,
    Error,
}

/// <summary>
/// The screen before the first page, while the background helper has not
/// answered yet. Paper background with the mark rising and the wordmark, so
/// the first frame is the brand: never a skeleton card, never a spinner. The
/// waiting motion is the logo rise itself, via <see cref="Marks.LogoMark"/>.
/// Needs no account: it shows before any sign-in check, and retry only knocks
/// on the local helper again.
/// </summary>
internal static class HostSplash
{
    public static FrameworkElement View(
        HostSplashState state,
        FriendlyErrorInfo? error,
        Action onRetry)
    {
        bool waiting = state != HostSplashState.Error;
        var column = new StackPanel
        {
            Spacing = Theme.SpaceL,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var mark = Marks.LogoMark(56, animated: waiting, loops: true);
        mark.HorizontalAlignment = HorizontalAlignment.Center;
        column.Children.Add(mark);
        // The mark is already above, so this is the word only.
        var word = Marks.Wordmark(22, fills: false, showsMark: false);
        word.HorizontalAlignment = HorizontalAlignment.Center;
        column.Children.Add(word);
        column.Children.Add(Status(state, error, onRetry));
        AutomationProperties.SetName(column, "tokenstat");
        return new Grid
        {
            Background = Theme.BackgroundBrush,
            Children = { column },
        };
    }

    private static UIElement Status(
        HostSplashState state,
        FriendlyErrorInfo? error,
        Action onRetry)
    {
        if (state == HostSplashState.Starting)
        {
            return new TextBlock
            {
                Text = "Starting the helper",
                FontSize = 13,
                Opacity = 0.7,
                HorizontalAlignment = HorizontalAlignment.Center,
            };
        }
        var info = error ?? FriendlyError.From(null);
        var card = new StackPanel
        {
            Spacing = Theme.SpaceS,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        card.Children.Add(new TextBlock
        {
            Text = info.Title,
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
        });
        card.Children.Add(new TextBlock
        {
            Text = info.Message,
            FontSize = 13,
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 420,
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
        });
        var retry = ActionIconGlyph.PrimaryButton(
            "Try again", ActionIcon.Refresh, (_, _) => onRetry());
        retry.HorizontalAlignment = HorizontalAlignment.Center;
        card.Children.Add(retry);
        AutomationProperties.SetName(card, info.Title);
        return card;
    }
}
