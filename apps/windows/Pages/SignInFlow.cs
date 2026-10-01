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
    private static bool _running;

    public static async Task RunAsync(Page owner, StackPanel slot, Func<Task> onSignedIn)
    {
        // The host owns one device flow. Reserve it before the first await,
        // including while deviceStart is still waiting on the network.
        if (_running)
        {
            return;
        }
        _running = true;
        slot.Visibility = Visibility.Visible;
        using var cts = new CancellationTokenSource();
        void OnUnloaded(object sender, RoutedEventArgs args) => cts.Cancel();
        owner.Unloaded += OnUnloaded;
        try
        {
            await RunCoreAsync(owner, slot, onSignedIn, cts);
        }
        catch (Exception) when (cts.IsCancellationRequested)
        {
        }
        catch (Exception ex)
        {
            slot.Children.Add(Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Contact));
        }
        finally
        {
            owner.Unloaded -= OnUnloaded;
            if (cts.IsCancellationRequested)
            {
                foreach (var card in slot.Children.OfType<Border>()
                    .Where(card => card.Name == "SignInFlowCard").ToList())
                {
                    slot.Children.Remove(card);
                }
                try { await AppServices.Host.CallAsync("account.cancelLogin"); }
                catch { /* leaving the page must not throw */ }
            }
            slot.Visibility = slot.Children.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            _running = false;
        }
    }

    private static async Task RunCoreAsync(
        Page owner, StackPanel slot, Func<Task> onSignedIn, CancellationTokenSource cts)
    {
        var token = cts.Token;
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
            token.ThrowIfCancellationRequested();
            slot.Children.Add(Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Contact));
            return;
        }
        token.ThrowIfCancellationRequested();
        var openUrl = Format.Text(started, "openUrl");
        var code = Format.Text(started, "userCode");
        var verify = Format.Text(started, "verificationUri");
        var interval = Math.Max(1, Format.Long(started, "interval"));
        var expires = Format.Long(started, "expiresIn");
        if (!string.IsNullOrEmpty(openUrl))
        {
            Open(openUrl);
        }

        var notice = new TextBlock { FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        void Note(string text)
        {
            notice.Text = text;
            notice.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
        }
        Border? card = null;
        // Same order as the Mac approval wait: the spinner and the
        // instruction, the code, then the way back to the page and out.
        // The card can outlive the browser window, and without this state
        // the screen would look exactly as it did before the tap.
        var body = new StackPanel { Spacing = Theme.SpaceM };
        var waiting = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        var progress = new ProgressRing { Width = 18, Height = 18, IsActive = true };
        waiting.Children.Add(progress);
        waiting.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.signinflow.waiting_for_approval.10c5739b"),
            VerticalAlignment = VerticalAlignment.Center,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        body.Children.Add(waiting);
        body.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.signinflow.approve_this_device_on_tokenstat_ai_this_s.bad8690a"),
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
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
                Text = string.IsNullOrEmpty(code) ? L10n.Text("windows.signinflow.complete_sign_in_in_the_browser.73cba30f") : code,
                FontFamily = Fonts.Mono,
                FontSize = Fonts.SignInCode,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = Theme.AccentBrush,
                IsTextSelectionEnabled = true,
            },
        });
        body.Children.Add(notice);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        if (!string.IsNullOrEmpty(openUrl))
        {
            buttons.Children.Add(ActionIconGlyph.Button(
                L10n.Text("windows.signinflow.open_the_page.911fa06e"), ActionIcon.External, (_, _) => Open(openUrl)));
        }
        buttons.Children.Add(ActionIconGlyph.Button(L10n.Text("common.cancel"), ActionIcon.Dismiss, (_, _) =>
        {
            if (progress.IsActive)
            {
                cts.Cancel();
            }
            if (card is not null)
            {
                slot.Children.Remove(card);
            }
        }));
        body.Children.Add(buttons);
        card = Chrome.Card(
            L10n.Text("windows.signinflow.waiting_for_approval.10c5739b"),
            body,
            string.IsNullOrEmpty(verify) ? null : L10n.Text("windows.signinflow.a_page_should_have_opened_at_0.8fba8da9", $"{verify}"));
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
                        Note(L10n.Text("windows.signinflow.that_sign_in_expired_start_again.28cffde9"));
                        break;
                    }
                    failures++;
                    if (failures >= 3)
                    {
                        Note(L10n.Text("windows.signinflow.the_account_service_could_not_be_reached_a.445bdbf0"));
                        break;
                    }
                    Note(L10n.Text("windows.signinflow.waiting_for_the_network.76a08f16"));
                    continue;
                }
                token.ThrowIfCancellationRequested();
                failures = 0;
                Note("");
                if (Format.Text(poll, "state") == "confirmed")
                {
                    if (card is not null)
                    {
                        slot.Children.Remove(card);
                    }
                    AppServices.NotifyAccountChanged();
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
                Note(L10n.Text("windows.signinflow.the_sign_in_code_expired_before_it_was_con.84ac1b4b"));
            }
            try { await AppServices.Host.CallAsync("account.cancelLogin"); }
            catch { /* the wait is over either way */ }
        }
        catch (OperationCanceledException)
        {
            // The wrapper cancels the host flow before accepting another.
        }
        finally
        {
            progress.IsActive = false;
        }
        if (!token.IsCancellationRequested)
        {
            buttons.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.signinflow.try_again.d8b8392e"), ActionIcon.Refresh, async (_, _) =>
            {
                slot.Children.Remove(card);
                await RunAsync(owner, slot, onSignedIn);
            }));
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
