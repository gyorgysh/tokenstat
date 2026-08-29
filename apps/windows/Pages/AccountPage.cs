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
    private CancellationTokenSource? _pullPoll;

    public AccountPage()
    {
        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL),
            Content = _root,
        };
        Loaded += async (_, _) => await LoadAsync();
        Unloaded += (_, _) =>
        {
            _poll?.Cancel();
            _pullPoll?.Cancel();
        };
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

        _root.Children.Add(await PullConnectionCardAsync());
        _root.Children.Add(UpdateCard());
        _root.Children.Add(AboutBlurb());
    }

    private async Task<UIElement> PullConnectionCardAsync()
    {
        try
        {
            var connection = await AppServices.Host.CallAsync(
                "pulls.connection",
                new JsonObject { ["host"] = "github.com" });
            var state = Format.Text(connection, "state", "signedOut");
            var login = Format.Text(connection, "login");
            var source = Format.Text(connection, "source");
            var body = new StackPanel { Spacing = Theme.SpaceM };
            var identity = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceM };
            identity.Children.Add(new Border
            {
                Width = 38,
                Height = 38,
                CornerRadius = new CornerRadius(11),
                Background = Theme.AccentSoftBrush,
                Child = new SymbolIcon { Symbol = Symbol.Switch, Foreground = Theme.AccentBrush },
            });
            var words = new StackPanel { Spacing = 2 };
            words.Children.Add(new TextBlock
            {
                Text = state == "ready" && !string.IsNullOrEmpty(login) ? "@" + login : "Not connected",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
            words.Children.Add(new TextBlock
            {
                Text = "github.com · " + PullSourceLabel(source),
                FontSize = 12,
                Opacity = 0.68,
                TextWrapping = TextWrapping.Wrap,
            });
            identity.Children.Add(words);
            body.Children.Add(identity);
            body.Children.Add(new TextBlock
            {
                Text = source switch
                {
                    "tokenstat" => "Connected with the tokenstat GitHub App. Pull requests are limited to repositories you choose on GitHub.",
                    "gitCredential" or "environment" => "Pull requests work through a credential owned by another tool. Connect the tokenstat GitHub App to choose exactly which repositories tokenstat may access.",
                    "pasted" => "A token saved by tokenstat is active. You can replace it with the tokenstat GitHub App and selected-repository access.",
                    _ => "Connect the tokenstat GitHub App, then choose the repositories tokenstat may open.",
                },
                FontSize = 12,
                Opacity = 0.68,
                TextWrapping = TextWrapping.Wrap,
            });
            if (source != "tokenstat")
            {
                body.Children.Add(ActionIconGlyph.PrimaryButton(
                    "Connect tokenstat GitHub App",
                    ActionIcon.Connect,
                    async (_, _) => await StartPullLoginAsync()));
            }
            else
            {
                body.Children.Add(ActionIconGlyph.Button(
                    "Choose repositories",
                    ActionIcon.External,
                    (_, _) => Open("https://github.com/apps/tokenstat/installations/new")));
            }
            if (source is "tokenstat" or "pasted")
            {
                body.Children.Add(ActionIconGlyph.Button("Sign out", ActionIcon.SignOut, async (_, _) =>
                {
                    var dialog = new ContentDialog
                    {
                        Title = "Sign out of GitHub pull requests?",
                        Content = "The GitHub token saved by tokenstat will be removed. A credential already managed by git or your login environment may still be used.",
                        PrimaryButtonText = "Sign out",
                        CloseButtonText = "Cancel",
                        DefaultButton = ContentDialogButton.Close,
                    };
                    if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary) return;
                    try
                    {
                        await AppServices.Host.CallAsync(
                            "pulls.signOut",
                            new JsonObject { ["host"] = Format.Text(connection, "host", "github.com") });
                        await LoadAsync();
                    }
                    catch (Exception ex)
                    {
                        _root.Children.Insert(0, Chrome.Banner(ex.Message, Theme.Warning, Symbol.Important));
                    }
                }));
            }
            return Chrome.Card(
                "GitHub pull requests",
                body,
                "Checked only when you open pull requests or this Account screen");
        }
        catch (Exception ex)
        {
            return Chrome.Card(
                "GitHub pull requests",
                Chrome.Banner(ex.Message, Theme.Warning, Symbol.Important),
                "The connection could not be checked");
        }
    }

    private static string PullSourceLabel(string source) => source switch
    {
        "gitCredential" => "using the credential git already has",
        "environment" => "using GH_TOKEN or GITHUB_TOKEN from your login environment",
        "pasted" => "using a token saved by tokenstat",
        "tokenstat" => "connected through tokenstat",
        _ => "no GitHub credential found",
    };

    private async Task StartPullLoginAsync()
    {
        _pullPoll?.Cancel();
        try
        {
            var started = await AppServices.Host.CallAsync(
                "pulls.signIn",
                new JsonObject { ["host"] = "github.com" });
            var url = Format.Text(started, "openUrl");
            var code = Format.Text(started, "userCode");
            if (!string.IsNullOrEmpty(url)) Open(url);

            var content = new StackPanel { Spacing = Theme.SpaceM };
            content.Children.Add(new TextBlock
            {
                Text = "Enter this one-time code in the GitHub page that just opened.",
                TextWrapping = TextWrapping.Wrap,
                Opacity = 0.72,
            });
            content.Children.Add(new Border
            {
                Background = Theme.AccentSoftBrush,
                BorderBrush = Theme.AccentBrush,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(12),
                Padding = new Thickness(Theme.SpaceL, Theme.SpaceM, Theme.SpaceL, Theme.SpaceM),
                HorizontalAlignment = HorizontalAlignment.Left,
                Child = new TextBlock
                {
                    Text = code,
                    FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"),
                    FontSize = 25,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    CharacterSpacing = 120,
                    Foreground = Theme.AccentBrush,
                    IsTextSelectionEnabled = true,
                },
            });
            var waiting = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            waiting.Children.Add(new ProgressRing { Width = 18, Height = 18, IsActive = true });
            waiting.Children.Add(new TextBlock
            {
                Text = "Waiting for GitHub…",
                VerticalAlignment = VerticalAlignment.Center,
                Opacity = 0.72,
            });
            content.Children.Add(waiting);

            var dialog = new ContentDialog
            {
                Title = "Connect tokenstat GitHub App",
                Content = content,
                CloseButtonText = "Cancel",
            };
            _pullPoll = new CancellationTokenSource();
            var token = _pullPoll.Token;
            var confirmed = false;

            async Task PollAsync()
            {
                var interval = Math.Max(1, Format.Long(started, "interval"));
                while (!token.IsCancellationRequested)
                {
                    await Task.Delay(TimeSpan.FromSeconds(interval), token);
                    var polled = await AppServices.Host.CallAsync("pulls.signInPoll", new JsonObject());
                    if (Format.Text(polled, "state") == "confirmed")
                    {
                        confirmed = true;
                        dialog.Hide();
                        return;
                    }
                    var next = Format.Long(polled, "interval");
                    if (next > 0) interval = next;
                }
            }

            var polling = PollAsync();
            await Chrome.ShowDialog(this, dialog);
            _pullPoll.Cancel();
            try { await polling; }
            catch (OperationCanceledException) { }
            if (!confirmed)
            {
                await AppServices.Host.CallAsync("pulls.cancelSignIn", new JsonObject());
            }
            await LoadAsync();
        }
        catch (Exception ex)
        {
            _root.Children.Insert(0, Chrome.Banner(ex.Message, Theme.Warning, Symbol.Important));
        }
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
