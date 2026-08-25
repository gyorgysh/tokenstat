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
using Tokenstat.Install;

namespace Tokenstat.Pages;

internal sealed class AccountPage : Page
{
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private CancellationTokenSource? _poll;

    public AccountPage()
    {
        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL),
            Content = _root,
        };
        Loaded += async (_, _) => await LoadAsync();
        Unloaded += (_, _) => _poll?.Cancel();
        AppServices.Update.Changed += () =>
        {
            DispatcherQueue.TryEnqueue(() => _ = LoadAsync());
        };
    }

    private async Task LoadAsync()
    {
        _root.Children.Clear();
        JsonNode account;
        try
        {
            account = await AppServices.Host.CallAsync("account.status");
        }
        catch (Exception ex)
        {
            _root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            _root.Children.Add(UpdateCard());
            return;
        }

        var signedIn = account["signedIn"]?.GetValue<bool>() ?? false;
        if (!signedIn)
        {
            _root.Children.Add(Chrome.Empty(
                "Not signed in",
                "Link an account to sync aggregates and see every device.",
                Symbol.Contact,
                ActionIconGlyph.Button("Sign in", ActionIcon.SignIn, async (_, _) => await StartLoginAsync())));
        }
        else
        {
            var handle = Format.Text(account, "handle", "");
            var name = Format.Text(account, "displayName", handle);
            var tier = Format.Text(account, "tier", "");
            var body = new StackPanel { Spacing = Theme.SpaceS };
            body.Children.Add(new TextBlock { Text = name, FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            if (!string.IsNullOrEmpty(handle))
            {
                body.Children.Add(new TextBlock { Text = "@" + handle, Opacity = 0.7 });
            }
            if (!string.IsNullOrEmpty(tier))
            {
                body.Children.Add(new Border
                {
                    Background = Theme.AccentSoftBrush,
                    CornerRadius = new CornerRadius(999),
                    Padding = new Thickness(8, 3, 8, 3),
                    HorizontalAlignment = HorizontalAlignment.Left,
                    Child = new TextBlock
                    {
                        Text = tier.ToUpperInvariant(),
                        FontSize = 10,
                        FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                        Foreground = Theme.AccentBrush,
                    },
                });
            }
            body.Children.Add(ActionIconGlyph.Button("Sync", ActionIcon.Refresh, async (_, _) =>
            {
                try
                {
                    await AppServices.Host.CallAsync(
                        "sync.run",
                        new JsonObject(),
                        TimeSpan.FromMinutes(5));
                }
                catch (Exception ex)
                {
                    _root.Children.Insert(0, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
                    return;
                }
                await LoadAsync();
            }));
            body.Children.Add(ActionIconGlyph.Button("Sign out", ActionIcon.SignOut, async (_, _) =>
            {
                try { await AppServices.Host.CallAsync("account.logout"); }
                catch { /* stay on the page */ }
                await LoadAsync();
            }));
            _root.Children.Add(Chrome.Card("Account", body));
        }

        _root.Children.Add(UpdateCard());
        _root.Children.Add(AboutBlurb());
    }

    private UIElement UpdateCard()
    {
        var update = AppServices.Update;
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock { Text = "Installed " + update.CurrentVersion });
        if (update.IsReady)
        {
            body.Children.Add(new TextBlock { Text = $"v{update.Latest} is ready." });
            body.Children.Add(ActionIconGlyph.Button("Relaunch", ActionIcon.Refresh, (_, _) => update.Relaunch()));
        }
        else if (update.Current == AppUpdateModel.Stage.Failed)
        {
            body.Children.Add(new TextBlock
            {
                Text = update.Failure ?? "The update could not install itself.",
                TextWrapping = TextWrapping.Wrap,
                Foreground = Theme.Brush(Theme.Danger),
            });
            body.Children.Add(ActionIconGlyph.Button("Retry", ActionIcon.Refresh, async (_, _) => await update.RetryAsync()));
            if (!string.IsNullOrEmpty(update.HtmlUrl))
            {
                body.Children.Add(ActionIconGlyph.Button("Download page", ActionIcon.External, (_, _) =>
                    Open(update.HtmlUrl)));
            }
        }
        else if (update.IsChecking)
        {
            body.Children.Add(new ProgressBar { IsIndeterminate = true });
        }
        else
        {
            if (!string.IsNullOrEmpty(update.CheckNotice))
            {
                body.Children.Add(new TextBlock { Text = update.CheckNotice, Opacity = 0.8 });
            }
            body.Children.Add(ActionIconGlyph.Button("Check for updates", ActionIcon.Refresh, async (_, _) => await update.CheckNowAsync()));
        }
        return Chrome.Card("Updates", body, "SHA-256 against the release. Publisher check only when this build is signed.");
    }

    private static UIElement AboutBlurb()
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock { Text = AppInfo.Copyright, Opacity = 0.8 });
        body.Children.Add(ActionIconGlyph.Button(AppInfo.WebsiteLabel, ActionIcon.External, (_, _) => Open(AppInfo.Website)));
        return Chrome.Card("tokenstat", body, AppInfo.Company);
    }

    private async Task StartLoginAsync()
    {
        _poll?.Cancel();
        JsonNode started;
        try
        {
            started = await AppServices.Host.CallAsync("account.deviceStart");
        }
        catch (Exception ex)
        {
            _root.Children.Insert(0, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }
        var url = Format.Text(started, "openUrl");
        var code = Format.Text(started, "userCode");
        if (!string.IsNullOrEmpty(url))
        {
            Open(url);
        }
        _root.Children.Insert(0, Chrome.Banner(
            string.IsNullOrEmpty(code) ? "Complete sign-in in the browser." : $"Enter code {code} if the browser did not fill it.",
            Theme.Accent,
            Symbol.Contact));
        _poll = new CancellationTokenSource();
        var token = _poll.Token;
        _ = Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                try
                {
                    var poll = await AppServices.Host.CallAsync("account.devicePoll");
                    var state = Format.Text(poll, "state");
                    if (state == "confirmed")
                    {
                        DispatcherQueue.TryEnqueue(() => _ = LoadAsync());
                        return;
                    }
                    var interval = Format.Long(poll, "interval");
                    await Task.Delay(TimeSpan.FromSeconds(interval > 0 ? interval : 5), token);
                }
                catch
                {
                    return;
                }
            }
        }, token);
    }

    private static void Open(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
        }
        catch
        {
            // The user can copy the URL from the card if a browser fails.
        }
    }
}
