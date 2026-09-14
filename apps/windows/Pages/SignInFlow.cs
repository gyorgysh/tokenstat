// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>
/// The device sign-in flow, shared by every page that offers it. Starts
/// <c>account.deviceStart</c>, opens the approval page, shows the code the
/// page must show back, and polls <c>account.devicePoll</c> until it confirms.
/// Copy follows the Mac sign-in card: the code, the check, and the wait.
/// </summary>
internal static class SignInFlow
{
    public static async Task RunAsync(Page owner, StackPanel slot, Func<Task> onSignedIn)
    {
        foreach (var child in slot.Children)
        {
            if (child is Border framed && framed.Name == "SignInFlowCard")
            {
                return;
            }
        }
        JsonNode started;
        try
        {
            started = await AppServices.Host.CallAsync("account.deviceStart");
        }
        catch (Exception ex)
        {
            slot.Children.Add(Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Contact));
            return;
        }
        var openUrl = Format.Text(started, "openUrl");
        var code = Format.Text(started, "userCode");
        var verify = Format.Text(started, "verificationUri");
        var interval = Math.Max(1, Format.Long(started, "interval"));
        var expires = Format.Long(started, "expiresIn");
        if (!string.IsNullOrEmpty(openUrl))
        {
            Open(openUrl);
        }

        var cts = new CancellationTokenSource();
        var token = cts.Token;
        var notice = new TextBlock { FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        void Note(string text)
        {
            notice.Text = text;
            notice.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
        }
        Border? card = null;
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(new Border
        {
            Background = Theme.AccentSoftBrush,
            BorderBrush = Theme.AccentBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(Theme.SpaceL, Theme.SpaceM, Theme.SpaceL, Theme.SpaceM),
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = new TextBlock
            {
                Text = string.IsNullOrEmpty(code) ? "Complete sign-in in the browser." : code,
                FontFamily = Fonts.Mono,
                FontSize = Fonts.SignInCode,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = Theme.AccentBrush,
                IsTextSelectionEnabled = true,
            },
        });
        body.Children.Add(new TextBlock
        {
            Text = "Check that the page shows this code, then approve it there.",
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
        var waiting = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        waiting.Children.Add(new ProgressRing { Width = 18, Height = 18, IsActive = true });
        waiting.Children.Add(new TextBlock
        {
            Text = "Waiting for confirmation…",
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = 0.7,
        });
        body.Children.Add(waiting);
        body.Children.Add(notice);
        body.Children.Add(ActionIconGlyph.Button("Cancel", ActionIcon.Dismiss, (_, _) =>
        {
            cts.Cancel();
            if (card is not null)
            {
                slot.Children.Remove(card);
            }
            _ = AppServices.Host.CallAsync("account.cancelLogin");
        }));
        card = Chrome.Card(
            "Confirm in your browser",
            body,
            string.IsNullOrEmpty(verify) ? null : "A page should have opened at " + verify);
        card.Name = "SignInFlowCard";
        slot.Children.Add(card);

        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(expires > 0 ? expires : 900);
        var failures = 0;
        try
        {
            while (!token.IsCancellationRequested && DateTime.UtcNow < deadline)
            {
                await Task.Delay(TimeSpan.FromSeconds(interval), token);
                JsonNode poll;
                try
                {
                    poll = await AppServices.Host.CallAsync("account.devicePoll");
                }
                catch (Exception ex) when (!token.IsCancellationRequested)
                {
                    var lower = ex.Message.ToLowerInvariant();
                    if (lower.Contains("invalid_grant") || lower.Contains("device_invalid_grant"))
                    {
                        Note("That sign-in expired. Start again.");
                        break;
                    }
                    failures++;
                    if (failures >= 3)
                    {
                        Note("The account service could not be reached after several tries. Try again.");
                        break;
                    }
                    Note("Waiting for the network.");
                    continue;
                }
                failures = 0;
                Note("");
                if (Format.Text(poll, "state") == "confirmed")
                {
                    if (card is not null)
                    {
                        slot.Children.Remove(card);
                    }
                    await onSignedIn();
                    return;
                }
                var next = Format.Long(poll, "interval");
                if (next > 0)
                {
                    interval = next;
                }
            }
            if (!token.IsCancellationRequested && DateTime.UtcNow >= deadline)
            {
                Note("The sign-in code expired before it was confirmed.");
            }
            try { await AppServices.Host.CallAsync("account.cancelLogin"); }
            catch { /* the wait is over either way */ }
        }
        catch (OperationCanceledException)
        {
            // Cancelled from the card. The card is already gone.
        }
    }

    private static void Open(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
        }
        catch
        {
            // The card shows the address, so the user can get there by hand.
        }
    }
}
