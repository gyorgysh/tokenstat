// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Tokenstat.Install;
using Windows.UI;

namespace Tokenstat.Navigation;

/// <summary>
/// The updater's stages as a card above the account row. Mirrors the Mac
/// UpdateCard: progress while checking or installing, a restart offer once
/// the new build is in place, a warning with Retry when it failed, and a
/// short "Up to date" after a check somebody asked for. Nothing otherwise,
/// so a quiet sidebar stays quiet.
/// </summary>
internal static class SidebarUpdateCard
{
    /// <summary>
    /// The card for the model's current state, or null when there is nothing
    /// to say. A quiet check that answers within <paramref name="showChecking"/>
    /// is never drawn, so the sidebar does not flicker on every launch.
    /// </summary>
    public static UIElement? For(AppUpdateModel update, bool showChecking)
    {
        if (update.IsChecking)
        {
            return update.Current != AppUpdateModel.Stage.Checking || showChecking ? Progress(update) : null;
        }
        if (update.IsReady) return Ready(update);
        if (update.Failure is not null && !update.FailureDismissed) return Failed(update);
        if (update.CheckNotice == AppUpdateModel.UpToDateMessage)
        {
            return Status(
                L10n.Text("windows.updatecard.up_to_date.ce29b7f8"),
                L10n.Text("windows.updatecard.v_0.9ad023b9", $"{update.CurrentVersion}"),
                Glyph(0xE73E, Theme.AccentBrush));
        }
        return null;
    }

    private static UIElement Progress(AppUpdateModel update)
    {
        var (title, detail, step) = update.Current switch
        {
            AppUpdateModel.Stage.Checking => (
                L10n.Text("windows.updatecard.checking_for_updates.53b276ad"),
                L10n.Text("windows.updatecard.looking_for_the_latest_release.c835769a"), 0),
            AppUpdateModel.Stage.Downloading => (
                L10n.Text("windows.updatecard.downloading_update.01436823"),
                L10n.Text("windows.updatecard.fetching_v_0_securely.1e4bf8c3", $"{update.Latest}"), 1),
            _ => (
                L10n.Text("windows.updatecard.preparing_update.e2562d8c"),
                L10n.Text("windows.updatecard.verifying_and_installing_v_0.c39d2002", $"{update.Latest}"), 2),
        };
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        head.Children.Add(new ProgressRing { IsActive = true, Width = 14, Height = 14, Foreground = Theme.AccentBrush });
        head.Children.Add(Title(title));
        body.Children.Add(head);
        body.Children.Add(Caption(detail));
        var steps = new Grid { ColumnSpacing = 4 };
        for (var i = 0; i < 3; i++)
        {
            steps.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var bar = new Border
            {
                Height = 3,
                CornerRadius = new CornerRadius(1.5),
                Background = i <= step ? Theme.AccentBrush : Theme.Brush(static () => WithAlpha(Theme.Accent, 0.15)),
            };
            Grid.SetColumn(bar, i);
            steps.Children.Add(bar);
        }
        AutomationProperties.SetAccessibilityView(steps, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        body.Children.Add(steps);
        var keepWorking = Caption(L10n.Text("windows.updatecard.you_can_keep_working.7f151a6e"));
        keepWorking.FontSize = 11;
        body.Children.Add(keepWorking);
        var card = Card(body, Theme.PanelBrush, Theme.Brush(static () => WithAlpha(Theme.Accent, 0.35)));
        AutomationProperties.SetName(card, title + ". " + detail);
        return card;
    }

    private static UIElement Ready(AppUpdateModel update)
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        head.Children.Add(Glyph(0xE73E, Theme.AccentBrush));
        var title = Title(L10n.Text("windows.updatecard.ready_to_restart.6a6c90ba"));
        title.Foreground = Theme.AccentBrush;
        head.Children.Add(title);
        body.Children.Add(head);
        body.Children.Add(Caption(L10n.Text("windows.updatecard.v_0_is_installed_restart_when_you_re_ready.e317415f", $"{update.Latest}")));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        var restart = Buttons.Primary(L10n.Text("windows.updatecard.restart.6b983a81"), ActionIcon.Refresh, async (s, _) => await UpdateRestart.AskAsync(update, (s as UIElement)?.XamlRoot), small: true);
        ToolTipService.SetToolTip(restart, L10n.Text("windows.updatecard.restarts_tokenstat_to_finish_the_update_sa.2c3392cc"));
        actions.Children.Add(restart);
        var skip = Buttons.Secondary(L10n.Text("common.skip"), ActionIcon.Dismiss, (_, _) => update.SkipThisVersion(), small: true);
        ToolTipService.SetToolTip(skip, L10n.Text("windows.updatecard.stops_this_card_until_you_check_for_update.4e19dc95"));
        actions.Children.Add(skip);
        body.Children.Add(actions);
        return Card(body, Theme.AccentSoftBrush, Theme.Brush(static () => WithAlpha(Theme.Accent, 0.35)));
    }

    private static UIElement Failed(AppUpdateModel update)
    {
        var title = update.RetryAfter is not null
            ? L10n.Text("windows.updatecard.update_checks_paused.fc82663e")
            : update.IsAvailable
                ? L10n.Text("windows.updatecard.update_didn_t_finish.d1b16ee1")
                : L10n.Text("windows.updatecard.couldn_t_check_for_updates.b6108d62");
        var detail = update.Failure ?? L10n.Text("windows.updatecard.please_try_again.eea4fb33");

        var head = new Grid { ColumnSpacing = Theme.SpaceS };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var warning = Glyph(0xE7BA, Theme.Brush(static () => Theme.Warning));
        warning.VerticalAlignment = VerticalAlignment.Top;
        warning.Margin = new Thickness(0, 2, 0, 0);
        head.Children.Add(warning);
        var text = new StackPanel { Spacing = 1 };
        text.Children.Add(Title(title));
        var caption = Caption(detail);
        caption.MaxLines = 3;
        ToolTipService.SetToolTip(caption, detail);
        text.Children.Add(caption);
        Grid.SetColumn(text, 1);
        head.Children.Add(text);
        var dismiss = Buttons.ToolbarIcon(ActionIcon.Dismiss, L10n.Text("windows.updatecard.dismiss.6bfcab12"), (_, _) => update.DismissFailure());
        dismiss.Width = dismiss.Height = 24;
        dismiss.VerticalAlignment = VerticalAlignment.Top;
        Grid.SetColumn(dismiss, 2);
        head.Children.Add(dismiss);

        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(head);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        var retry = Buttons.Primary(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => await update.RetryAsync(), small: true);
        retry.IsEnabled = !update.IsRateLimited && !update.IsRetrying;
        // GitHub's wait ends on its own, with no model change to redraw the
        // card, so the button wakes itself when the time comes.
        if (!update.IsRetrying && update.RetryAfter is DateTimeOffset until && until > DateTimeOffset.Now
            && Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread() is { } queue)
        {
            var wake = queue.CreateTimer();
            wake.Interval = until - DateTimeOffset.Now + TimeSpan.FromMilliseconds(250);
            wake.IsRepeating = false;
            wake.Tick += (_, _) =>
            {
                wake.Stop();
                retry.IsEnabled = !update.IsRateLimited && !update.IsRetrying;
            };
            wake.Start();
        }
        ToolTipService.SetToolTip(retry, L10n.Text("windows.updatecard.check_again_when_github_s_waiting_period_h.a5314d1b"));
        actions.Children.Add(retry);
        if (update.IsAvailable && !string.IsNullOrEmpty(update.HtmlUrl))
        {
            var url = update.HtmlUrl;
            var manual = Buttons.Secondary(L10n.Text("windows.updatecard.manual.b0b9fe24"), ActionIcon.Download, (_, _) => Open(url), small: true);
            ToolTipService.SetToolTip(manual, L10n.Text("windows.updatecard.open_the_download_page_and_install_by_hand.4dd377fb"));
            actions.Children.Add(manual);
        }
        body.Children.Add(actions);
        return Card(body, Theme.PanelBrush, Theme.Brush(static () => WithAlpha(Theme.Warning, 0.35)));
    }

    /// <summary>A confirmation row with no action, for a state that needs none.</summary>
    private static UIElement Status(string title, string subtitle, FrameworkElement mark)
    {
        var row = new Grid { ColumnSpacing = Theme.SpaceS };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        mark.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(mark);
        var text = new StackPanel { Spacing = 1 };
        text.Children.Add(Title(title));
        var caption = Caption(subtitle);
        caption.MaxLines = 1;
        text.Children.Add(caption);
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        var card = Card(row, Theme.PanelBrush, Theme.Brush(static () => WithAlpha(Theme.Accent, 0.35)));
        AutomationProperties.SetName(card, title + ". " + subtitle);
        return card;
    }

    private static Border Card(UIElement child, Brush background, Brush border) => new()
    {
        Background = background,
        BorderBrush = border,
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(Theme.CardRadius),
        Padding = new Thickness(Theme.SpaceM, Theme.SpaceS, Theme.SpaceM, Theme.SpaceS),
        Margin = new Thickness(Theme.SpaceS, 0, Theme.SpaceS, Theme.SpaceS),
        HorizontalAlignment = HorizontalAlignment.Stretch,
        Child = child,
    };

    private static TextBlock Title(string text) => new()
    {
        Text = text,
        FontSize = 13,
        FontWeight = FontWeights.Medium,
        TextWrapping = TextWrapping.Wrap,
    };

    private static TextBlock Caption(string text) => new()
    {
        Text = text,
        FontSize = 12,
        Opacity = 0.7,
        TextWrapping = TextWrapping.Wrap,
        TextTrimming = TextTrimming.CharacterEllipsis,
    };

    private static FontIcon Glyph(int code, Brush tint) => new()
    {
        Glyph = char.ToString((char)code),
        FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
        FontSize = 15,
        Foreground = tint,
    };

    private static Color WithAlpha(Color color, double alpha) =>
        Color.FromArgb((byte)Math.Round(alpha * 255), color.R, color.G, color.B);

    private static void Open(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
        }
        catch
        {
            // The account page still carries the same link.
        }
    }
}
