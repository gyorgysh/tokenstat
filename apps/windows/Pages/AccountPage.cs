// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Install;
using Tokenstat.Notifications;

namespace Tokenstat.Pages;

/// <summary>
/// Account is three jobs, not one scrolling pile: who you are, vendor quota
/// windows, and what this PC itself does. Mirrors the Mac AccountView panes.
/// </summary>
internal sealed class AccountPage : Page
{
    private readonly ContentControl _barSlot = new()
    {
        HorizontalAlignment = HorizontalAlignment.Stretch,
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
    };
    private readonly ContentControl _tabSlot = new()
    {
        HorizontalAlignment = HorizontalAlignment.Stretch,
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
    };
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _signSlot = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _content = new() { Spacing = Theme.SpaceL };
    private CancellationTokenSource? _pullPoll;

    private string _pane = "account";
    private JsonNode? _account;
    private string? _accountError;
    private bool _signedIn;

    public AccountPage()
    {
        _root.Children.Add(_signSlot);
        _root.Children.Add(_content);
        var scroller = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL),
            Content = _root,
        };
        var layout = new Grid();
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition
        {
            Height = new GridLength(1, GridUnitType.Star),
        });
        layout.Children.Add(_barSlot);
        Grid.SetRow(_tabSlot, 1);
        layout.Children.Add(_tabSlot);
        Grid.SetRow(scroller, 2);
        layout.Children.Add(scroller);
        Content = layout;
        RebuildChrome();
        RebuildTabs();
        Loaded += async (_, _) => await LoadAsync();
        Unloaded += (_, _) =>
        {
            _pullPoll?.Cancel();
        };
        AppServices.Update.Changed += () =>
        {
            DispatcherQueue.TryEnqueue(() => _ = LoadAsync());
        };
    }

    private void RebuildChrome()
    {
        var trailing = new List<UIElement>();
        if (_signedIn)
        {
            trailing.Add(Buttons.ToolbarIcon(
                ActionIcon.Refresh,
                "Sync now",
                async (_, _) => await SyncNowAsync()));
        }
        _barSlot.Content = DetailBar.View(trailing: trailing);
    }

    private void RebuildTabs()
    {
        var tabs = new List<(string Value, string Label, ActionIcon? Glyph)>
        {
            ("account", "Account", ActionIcon.Account),
            ("limits", "Plan limits", ActionIcon.Plan),
            ("pc", "This PC", ActionIcon.Device),
        };
        _tabSlot.Content = TabStrip.View(
            tabs,
            _pane,
            async value =>
            {
                _pane = value;
                RebuildTabs();
                await RenderPaneAsync();
            });
    }

    private async Task LoadAsync()
    {
        try
        {
            _account = await AppServices.Host.CallAsync("account.status");
            _accountError = null;
        }
        catch (Exception ex)
        {
            _account = null;
            _accountError = FriendlyError.Display(ex.Message);
        }
        _signedIn = _account?["signedIn"]?.GetValue<bool>() ?? false;
        RebuildChrome();
        RebuildTabs();
        await RenderPaneAsync();
    }

    private async Task RenderPaneAsync()
    {
        _content.Children.Clear();
        switch (_pane)
        {
            case "limits":
                await RenderLimitsPaneAsync();
                break;
            case "pc":
                await RenderThisPcPaneAsync();
                break;
            default:
                await RenderAccountPaneAsync();
                break;
        }
    }

    /// <summary>
    /// Who you are, who can reach you, and the legal end of the account.
    /// </summary>
    private async Task RenderAccountPaneAsync()
    {
        var account = _account;
        if (account is null)
        {
            if (!string.IsNullOrEmpty(_accountError))
            {
                _content.Children.Add(Chrome.Banner(
                    _accountError, Theme.Danger, Symbol.Important));
            }
            _content.Children.Add(await PullConnectionCardAsync());
            _content.Children.Add(PrivacyNote());
            _content.Children.Add(AboutBlurb());
            return;
        }
        if (!_signedIn)
        {
            _content.Children.Add(SignedOutCard());
        }
        else
        {
            _content.Children.Add(IdentityCard(account));
            _content.Children.Add(RelayUsageCard(account));
            _content.Children.Add(SyncCard(account));
            _content.Children.Add(DevicesCard(account));
        }
        _content.Children.Add(await PullConnectionCardAsync());
        _content.Children.Add(PrivacyNote());
        if (_signedIn)
        {
            _content.Children.Add(DeleteAccountCard(account));
        }
        _content.Children.Add(AboutBlurb());
    }

    private async Task RenderLimitsPaneAsync()
    {
        var account = _account;
        if (account is null)
        {
            if (!string.IsNullOrEmpty(_accountError))
            {
                _content.Children.Add(Chrome.Banner(
                    _accountError, Theme.Danger, Symbol.Important));
            }
            else
            {
                _content.Children.Add(new ProgressRing
                {
                    IsActive = true,
                    HorizontalAlignment = HorizontalAlignment.Center,
                });
            }
            return;
        }
        if (!_signedIn)
        {
            _content.Children.Add(LimitsSignedOutCard());
            return;
        }
        _content.Children.Add(await PlanLimitsCardAsync());
    }

    /// <summary>
    /// Settings that live on this computer, signed in or not.
    /// </summary>
    private async Task RenderThisPcPaneAsync()
    {
        _content.Children.Add(await HostCardAsync());
        _content.Children.Add(await LocalTrafficCardAsync());
        _content.Children.Add(await LocalModelsCardAsync());
        _content.Children.Add(NotificationsCard());
        _content.Children.Add(UpdateCard());
    }

    /// <summary>
    /// Everything works without an account. Signing in only adds the option
    /// to publish: a profile page, and usage from all machines in one place.
    /// </summary>
    private UIElement SignedOutCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(new TextBlock
        {
            Text = "An account lets you publish a profile page and see usage from "
                + "all your machines in one place. Only aggregate counters are "
                + "eligible to be sent.",
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(ActionIconGlyph.PrimaryButton(
            "Sign in to tokenstat.ai", ActionIcon.SignIn,
            async (_, _) => await SignInFlow.RunAsync(this, _signSlot, LoadAsync)));
        return Chrome.Card(
            "Not signed in",
            body,
            "Everything works without an account. Signing in only adds the option to publish.");
    }

    private UIElement LimitsSignedOutCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(ActionIconGlyph.PrimaryButton(
            "Sign in to tokenstat.ai", ActionIcon.SignIn,
            async (_, _) => await SignInFlow.RunAsync(this, _signSlot, LoadAsync)));
        return Chrome.Card(
            "Plan limits",
            body,
            "Sign in to track vendor quota windows on this PC and share them with your other devices.");
    }

    /// <summary>Who you are, at the size a profile deserves.</summary>
    private static UIElement IdentityCard(JsonNode account)
    {
        var handle = Format.Text(account, "handle", "");
        var name = Format.Text(account, "displayName", handle);
        if (string.IsNullOrEmpty(name))
        {
            name = "Signed in";
        }
        var tier = Format.Text(account, "tier", "");
        var host = Format.Text(account, "host");
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var nameRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        nameRow.Children.Add(new TextBlock
        {
            Text = name,
            FontSize = 22,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        if (!string.IsNullOrEmpty(tier))
        {
            nameRow.Children.Add(Chrome.TierBadge(tier));
        }
        body.Children.Add(nameRow);
        if (!string.IsNullOrEmpty(handle))
        {
            body.Children.Add(new TextBlock
            {
                Text = "@" + handle,
                Opacity = 0.7,
                IsTextSelectionEnabled = true,
            });
        }
        if (!string.IsNullOrEmpty(host))
        {
            body.Children.Add(new TextBlock { Text = host, Opacity = 0.55, FontSize = 12 });
        }
        if (!string.IsNullOrEmpty(handle) && !string.IsNullOrEmpty(host))
        {
            // The profile is a public page and this is the only place in the
            // app that knows its address.
            var url = host.TrimEnd('/') + "/" + handle;
            body.Children.Add(ActionIconGlyph.Button(
                "View profile", ActionIcon.External, (_, _) => Open(url)));
        }
        return Chrome.Card("Account", body);
    }

    /// <summary>
    /// Sync is a desktop act: it uploads this PC's archive. Last sync, a
    /// button, and the way out.
    /// </summary>
    private UIElement SyncCard(JsonNode account)
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceM };
        var last = Format.Text(account, "lastSyncAt");
        row.Children.Add(new TextBlock { Text = "Last sync", Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(last) ? "Never" : Format.Relative(last),
            FontFamily = Fonts.Mono,
            VerticalAlignment = VerticalAlignment.Center,
        });
        row.Children.Add(ActionIconGlyph.Button("Sync now", ActionIcon.Refresh, async (_, _) =>
        {
            await SyncNowAsync();
        }));
        body.Children.Add(row);
        body.Children.Add(ActionIconGlyph.Button("Sign out", ActionIcon.SignOut, async (_, _) =>
        {
            try { await AppServices.Host.CallAsync("account.logout"); }
            catch { /* stay on the page */ }
            await LoadAsync();
        }));
        return Chrome.Card("Sync", body, "Only aggregate counters are eligible");
    }

    private async Task SyncNowAsync()
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
            _content.Children.Insert(0, Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            return;
        }
        await LoadAsync();
    }

    /// <summary>
    /// Every device that has synced to this account. The one you are sitting
    /// at is marked, or the list is a set of opaque ids and the only machine
    /// anyone can act on is the one they cannot pick out.
    /// </summary>
    private static UIElement DevicesCard(JsonNode account)
    {
        var machines = account["machines"] as JsonArray;
        var used = machines?.Count ?? 0;
        var limitNode = account["machineLimit"];
        var subtitle = "Every device that has synced to this account";
        if (machines is not null && used > 0)
        {
            if (limitNode is not null)
            {
                subtitle = $"{used} of {Format.Long(account, "machineLimit")} devices";
                if (account["canRemote"] is JsonValue noRemote
                    && noRemote.GetValueKind() == System.Text.Json.JsonValueKind.False)
                {
                    subtitle += ". No remote control on this plan.";
                }
            }
            else
            {
                subtitle = $"{used} linked";
            }
        }
        if (used == 0)
        {
            return Chrome.Card(
                "Devices",
                EmptyState.View(
                    "Nothing linked yet",
                    "Free includes two devices. Sync now to put this PC on the account.",
                    EmptyArtKind.Devices),
                subtitle);
        }
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var thisId = Format.Text(account, "thisMachineId");
        foreach (var machine in machines!.OfType<JsonNode>())
        {
            var id = Format.Text(machine, "id");
            if (string.IsNullOrEmpty(id))
            {
                id = Format.Text(machine, "machineID");
            }
            body.Children.Add(MachineRow(machine, id, id == thisId));
        }
        body.Children.Add(new TextBlock
        {
            Text = "Rename, reach, or remove a device on the Devices page.",
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        return Chrome.Card("Devices", body, subtitle);
    }

    private static UIElement MachineRow(JsonNode machine, string id, bool isThis)
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { Spacing = 1 };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        var label = Format.Text(machine, "label");
        if (!string.IsNullOrEmpty(label))
        {
            head.Children.Add(new TextBlock
            {
                Text = label,
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        else if (!string.IsNullOrEmpty(id))
        {
            // A machine the user has never named shows its id. The id is a
            // public machine key, so it is shown plain and selectable rather
            // than blurred.
            head.Children.Add(new TextBlock
            {
                Text = id,
                FontFamily = Fonts.Mono,
                FontSize = 12,
                TextTrimming = TextTrimming.CharacterEllipsis,
                IsTextSelectionEnabled = true,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        else
        {
            head.Children.Add(new TextBlock
            {
                Text = "Unnamed device",
                Opacity = 0.7,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        if (isThis)
        {
            head.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(9),
                Background = Theme.AccentSoftBrush,
                Padding = new Thickness(5, 2, 5, 2),
                VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock
                {
                    Text = "THIS PC",
                    FontSize = 9,
                    FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                    Foreground = Theme.AccentBrush,
                },
            });
        }
        left.Children.Add(head);
        // Only when the machine has a name, so the id is not printed twice on
        // a row that is already showing it as its title.
        if (!string.IsNullOrEmpty(label) && !string.IsNullOrEmpty(id))
        {
            left.Children.Add(new TextBlock
            {
                Text = id,
                FontFamily = Fonts.Mono,
                FontSize = 10,
                Opacity = 0.55,
                IsTextSelectionEnabled = true,
            });
        }
        row.Children.Add(left);
        var seen = Format.Text(machine, "lastSyncAt");
        var stamp = string.IsNullOrEmpty(seen)
            ? ""
            : Format.Relative(seen);
        if (string.IsNullOrEmpty(stamp))
        {
            seen = Format.Text(machine, "lastSeenAt");
            stamp = string.IsNullOrEmpty(seen) ? "never synced" : "last used " + Format.Relative(seen);
        }
        var right = new TextBlock
        {
            Text = stamp,
            FontSize = 12,
            Opacity = 0.7,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(right, 1);
        row.Children.Add(right);
        return row;
    }

    /// <summary>
    /// Opt-in posting of vendor quota windows, one switch per reading we have.
    /// The master switch is still the privacy gate, off by default: percentages
    /// and reset times only, never a credential. Each row is a source the user
    /// can leave on this PC, for an expired subscription or a tool they do not
    /// want on the phone.
    /// </summary>
    private async Task<UIElement> PlanLimitsCardAsync()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        JsonNode state;
        try
        {
            state = await AppServices.Host.CallAsync(
                "config.limitsSync", new JsonObject());
        }
        catch (Exception ex)
        {
            body.Children.Add(Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Warning, Symbol.Important));
            return Chrome.Card("Plan limits", body);
        }
        var enabled = state["enabled"]?.GetValue<bool>() ?? false;
        var skip = new HashSet<string>(StringComparer.Ordinal);
        if (state["skip"] is JsonArray skipped)
        {
            foreach (var item in skipped)
            {
                try
                {
                    var source = item?.GetValue<string>();
                    if (!string.IsNullOrEmpty(source))
                    {
                        skip.Add(source);
                    }
                }
                catch
                {
                    // A non-string entry is not a source.
                }
            }
        }
        body.Children.Add(new TextBlock
        {
            Text = "Posts how full each window is, so your other devices can show "
                + "what is left while this PC is asleep. Percentages and reset "
                + "times only, never a credential. Turning a vendor off below "
                + "also stops tracking it on this PC.",
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(Chrome.ToggleChip("Share with my devices", enabled, async on =>
        {
            try
            {
                await AppServices.Host.CallAsync(
                    "config.limitsSync",
                    new JsonObject { ["enabled"] = on });
            }
            catch (Exception ex)
            {
                _content.Children.Insert(0, Chrome.Banner(
                    FriendlyError.Display(ex.Message), Theme.Warning, Symbol.Important));
                return;
            }
            await LoadAsync();
        }));
        var providers = state["providers"] as JsonArray;
        if (providers is null || providers.Count == 0)
        {
            body.Children.Add(new TextBlock
            {
                Text = "No readings yet. Open Home, or wait for the hourly pass, then come back.",
                Opacity = 0.7,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        else
        {
            foreach (var provider in providers.OfType<JsonNode>())
            {
                var source = Format.Text(provider, "source", "Plan");
                body.Children.Add(PlanLimitRow(provider, source, !skip.Contains(source)));
            }
        }
        return Chrome.Card(
            "Plan limits",
            body,
            "Track vendor quota windows. Off means this PC does not read that vendor and does not show it on Home.");
    }

    private UIElement PlanLimitRow(JsonNode provider, string source, bool shared)
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(new TextBlock { Text = HarnessName(source), TextWrapping = TextWrapping.Wrap });
        var detail = PlanLimitDetail(provider);
        if (!string.IsNullOrEmpty(detail))
        {
            left.Children.Add(new TextBlock
            {
                Text = detail,
                Opacity = 0.7,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        row.Children.Add(left);
        var toggle = new ToggleSwitch
        {
            IsOn = shared,
            OnContent = "",
            OffContent = "",
            MinWidth = 0,
            VerticalAlignment = VerticalAlignment.Center,
        };
        toggle.Toggled += async (_, _) =>
        {
            try
            {
                await AppServices.Host.CallAsync(
                    "config.limitsSync",
                    new JsonObject { ["source"] = source, ["shared"] = toggle.IsOn });
            }
            catch (Exception ex)
            {
                _content.Children.Insert(0, Chrome.Banner(
                    FriendlyError.Display(ex.Message), Theme.Warning, Symbol.Important));
                return;
            }
            await LoadAsync();
        };
        ToolTipService.SetToolTip(toggle, "Track " + HarnessName(source));
        Grid.SetColumn(toggle, 1);
        row.Children.Add(toggle);
        return row;
    }

    private static string PlanLimitDetail(JsonNode provider)
    {
        var parts = new List<string>();
        var plan = Format.Text(provider, "plan");
        if (!string.IsNullOrEmpty(plan))
        {
            parts.Add(plan);
        }
        var windows = new List<string>();
        if (provider["windows"] is JsonArray list)
        {
            foreach (var window in list.OfType<JsonNode>())
            {
                var label = Format.Text(window, "label");
                if (string.IsNullOrEmpty(label))
                {
                    continue;
                }
                windows.Add($"{label} {(int)Math.Round(WindowPercent(window))}%");
            }
        }
        if (windows.Count > 0)
        {
            parts.Add(string.Join(", ", windows));
        }
        else
        {
            var note = Format.Text(provider, "note");
            if (!string.IsNullOrEmpty(note))
            {
                parts.Add(note);
            }
        }
        try
        {
            if (provider["stale"]?.GetValue<bool>() == true)
            {
                parts.Add("last reading is old");
            }
        }
        catch
        {
            // A missing flag is not stale.
        }
        return parts.Count == 0 ? "No windows reported" : string.Join(" · ", parts);
    }

    private static double WindowPercent(JsonNode window)
    {
        try
        {
            return window["percent"]?.GetValue<double>() ?? 0;
        }
        catch
        {
            return 0;
        }
    }

    /// <summary>
    /// Whether this PC stays a host after the app quits. The stored policy the
    /// host helper honours.
    /// </summary>
    private async Task<UIElement> HostCardAsync()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        JsonNode? policy = null;
        try
        {
            policy = await AppServices.Host.CallAsync("host.policy");
        }
        catch
        {
            // The card below says the helper has not answered.
        }
        if (policy is null)
        {
            body.Children.Add(new TextBlock
            {
                Text = "The host helper has not answered yet.",
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
            return Chrome.Card(
                "This PC",
                body,
                "Whether the host helper stays up after you quit");
        }
        var alwaysOn = policy["alwaysOn"]?.GetValue<bool>() ?? false;
        var hasBattery = policy["hasInternalBattery"]?.GetValue<bool>() ?? false;
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(new TextBlock { Text = "Always-on host" });
        left.Children.Add(new TextBlock
        {
            Text = alwaysOn
                ? "The host helper keeps running after you quit tokenstat, so other devices can reach this PC. This PC will not idle-sleep. A laptop still sleeps when you close the lid."
                : "The host helper stops when you quit tokenstat, so this PC can sleep. Other devices cannot open folders or terminals here until you open the app again.",
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        row.Children.Add(left);
        var toggle = new ToggleSwitch
        {
            IsOn = alwaysOn,
            OnContent = "",
            OffContent = "",
            MinWidth = 0,
            VerticalAlignment = VerticalAlignment.Center,
        };
        toggle.Toggled += async (_, _) =>
        {
            toggle.IsEnabled = false;
            try
            {
                await AppServices.ApplyHostPolicyAsync(toggle.IsOn);
            }
            catch (Exception ex)
            {
                _content.Children.Insert(0, Chrome.Banner(
                    FriendlyError.Display(ex.Message), Theme.Warning, Symbol.Important));
            }
            await LoadAsync();
        };
        Grid.SetColumn(toggle, 1);
        row.Children.Add(toggle);
        body.Children.Add(row);
        if (alwaysOn && hasBattery)
        {
            body.Children.Add(new TextBlock
            {
                Text = "Uses more power.",
                Opacity = 0.7,
                FontSize = 12,
            });
        }
        if (!alwaysOn)
        {
            body.Children.Add(new TextBlock
            {
                Text = "Automations run only while tokenstat is open.",
                Opacity = 0.7,
                FontSize = 12,
            });
        }
        return Chrome.Card(
            "This PC",
            body,
            "Whether the host helper stays up after you quit");
    }

    /// <summary>
    /// Local model servers on this PC, found over loopback by the host. A
    /// missing provider is a normal state, not an error. Per-provider switches
    /// stay on this machine, beside other launch settings.
    /// </summary>
    private async Task<UIElement> LocalModelsCardAsync()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(new TextBlock
        {
            Text = "Nothing is sent to tokenstat. These checks use loopback only. Start the app, load a model, then refresh.",
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var refresh = ActionIconGlyph.Button("Refresh", ActionIcon.Refresh, async (_, _) =>
        {
            await RenderPaneAsync();
        });
        Grid.SetColumn(refresh, 1);
        head.Children.Add(refresh);
        body.Children.Add(head);

        JsonArray providers;
        try
        {
            providers = await AppServices.Host.CallAsync("local.models") as JsonArray ?? new();
        }
        catch (Exception ex)
        {
            body.Children.Add(new TextBlock
            {
                Text = FriendlyError.Display(ex.Message),
                Foreground = Theme.Brush(Theme.Danger),
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
            });
            return Chrome.Card(
                "Local models",
                body,
                "LM Studio on port 1234, Ollama on port 11434");
        }
        if (providers.Count == 0)
        {
            body.Children.Add(new TextBlock
            {
                Text = "LM Studio (port 1234) and Ollama (port 11434) could not be checked. Start one and tap refresh.",
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
            return Chrome.Card(
                "Local models",
                body,
                "LM Studio on port 1234, Ollama on port 11434");
        }
        foreach (var provider in providers.OfType<JsonNode>())
        {
            body.Children.Add(LocalProviderRow(provider));
        }
        return Chrome.Card(
            "Local models",
            body,
            "LM Studio on port 1234, Ollama on port 11434");
    }

    private UIElement LocalProviderRow(JsonNode provider)
    {
        var id = Format.Text(provider, "id");
        var available = provider["available"]?.GetValue<bool>() ?? false;
        var enabled = LocalProviderEnabled(id);
        var stack = new StackPanel { Spacing = Theme.SpaceS };
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            VerticalAlignment = VerticalAlignment.Center,
        };
        left.Children.Add(new Border
        {
            Width = 8,
            Height = 8,
            CornerRadius = new CornerRadius(4),
            Background = available && enabled ? Theme.AccentBrush : Theme.BorderBrush,
            VerticalAlignment = VerticalAlignment.Center,
        });
        left.Children.Add(new TextBlock
        {
            Text = Format.Text(provider, "name", id),
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            VerticalAlignment = VerticalAlignment.Center,
        });
        head.Children.Add(left);
        var toggle = new ToggleSwitch
        {
            IsOn = enabled,
            OnContent = "",
            OffContent = "",
            MinWidth = 0,
            VerticalAlignment = VerticalAlignment.Center,
        };
        toggle.Toggled += async (_, _) =>
        {
            SetLocalProviderEnabled(id, toggle.IsOn);
            await RenderPaneAsync();
        };
        Grid.SetColumn(toggle, 1);
        head.Children.Add(toggle);
        stack.Children.Add(head);
        if (!enabled)
        {
            stack.Children.Add(new TextBlock
            {
                Text = "Disabled for local model selection",
                Opacity = 0.7,
                FontSize = 12,
            });
        }
        else if (available)
        {
            var models = provider["models"] as JsonArray;
            if (models is null || models.Count == 0)
            {
                stack.Children.Add(new TextBlock
                {
                    Text = id == "lmstudio"
                        ? "Server is up. Load a model in LM Studio to use it here."
                        : "Server is up. Pull or run a model in Ollama to use it here.",
                    Opacity = 0.7,
                    FontSize = 12,
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            else
            {
                foreach (var model in models.OfType<JsonNode>())
                {
                    var size = Format.Long(model, "sizeBytes");
                    var line = new Grid();
                    line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    line.Children.Add(new TextBlock
                    {
                        Text = Format.Text(model, "name"),
                        FontFamily = Fonts.Mono,
                        FontSize = 11,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                    });
                    if (size > 0)
                    {
                        var sizeBlock = new TextBlock
                        {
                            Text = Format.DataSize(size),
                            FontSize = 12,
                            Opacity = 0.6,
                        };
                        Grid.SetColumn(sizeBlock, 1);
                        line.Children.Add(sizeBlock);
                    }
                    stack.Children.Add(line);
                }
            }
        }
        else
        {
            stack.Children.Add(new TextBlock
            {
                Text = LocalProviderHint(provider, id),
                Opacity = 0.6,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                MaxLines = 3,
            });
        }
        return stack;
    }

    private static string LocalProviderHint(JsonNode provider, string id)
    {
        var raw = Format.Text(provider, "error", "not running");
        if (raw == "not running" || raw.StartsWith("not running", StringComparison.Ordinal))
        {
            return id == "lmstudio"
                ? "Not running. Open LM Studio and turn on the local server (port 1234)."
                : "Not running. Start Ollama (port 11434).";
        }
        return raw;
    }

    /// <summary>
    /// Local provider switches on disk. A plain file, not LocalSettings: this
    /// app is unpackaged and has no package identity, so
    /// <c>ApplicationData.Current</c> throws. Never read settings through a
    /// packaged-identity API from this app.
    /// </summary>
    private static string LocalModelsSettingsPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "tokenstat",
            "localmodels.json");

    private static bool LocalProviderEnabled(string id)
    {
        try
        {
            var doc = JsonNode.Parse(File.ReadAllText(LocalModelsSettingsPath)) as JsonObject;
            return doc?["enabled"]?[id]?.GetValue<bool>() ?? true;
        }
        catch
        {
            return true;
        }
    }

    private static void SetLocalProviderEnabled(string id, bool enabled)
    {
        try
        {
            JsonObject doc;
            try
            {
                doc = JsonNode.Parse(File.ReadAllText(LocalModelsSettingsPath)) as JsonObject ?? new();
            }
            catch
            {
                doc = new();
            }
            var map = doc["enabled"] as JsonObject ?? new();
            map[id] = enabled;
            doc["enabled"] = map;
            Directory.CreateDirectory(Path.GetDirectoryName(LocalModelsSettingsPath)!);
            File.WriteAllText(LocalModelsSettingsPath, doc.ToJsonString());
        }
        catch
        {
            // A switch that cannot persist still works for this run.
        }
    }

    /// <summary>
    /// The claim, stated where someone is deciding whether to connect an
    /// account. This is the moment it matters.
    /// </summary>
    private static UIElement PrivacyNote()
    {
        return Chrome.Card("What syncing sends", new TextBlock
        {
            Text = "Aggregate counts per day, tool and model, and project names replaced "
                + "by salted hashes. Prompts, replies, file contents, file paths and "
                + "session ids are never eligible.",
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
    }

    /// <summary>
    /// Where deletion happens: `{host}/settings/data#delete` on the website.
    /// The fragment jumps to the delete section once the page loads, so the
    /// button lands on the section instead of the top of the page.
    /// </summary>
    private static UIElement DeleteAccountCard(JsonNode account)
    {
        var host = Format.Text(account, "host", "https://tokenstat.ai");
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(new TextBlock
        {
            Text = "Deletion happens on the website, where you confirm it. This removes "
                + "the account and its uploaded history.",
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(ActionIconGlyph.Button(
            "Open data settings", ActionIcon.External,
            (_, _) => Open(host.TrimEnd('/') + "/settings/data#delete")));
        return Chrome.Card(
            "Delete this account",
            body,
            "Permanent. Confirmed on the website's data settings.");
    }

    private UIElement RelayUsageCard(JsonNode? account)
    {
        var usage = account?["relayUsage"];
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var supported = Format.Text(usage, "policy") == "rolling_30_utc_days"
            && Format.Long(usage, "windowDays") == 30
            && Format.Text(usage, "timezone") == "UTC";
        if (usage is null || !supported)
        {
            body.Children.Add(new TextBlock
            {
                Text = "Relay usage details are not available from this server yet.",
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
            return Chrome.Card("Relay usage", body, "One allowance across your devices");
        }
        var used = Format.Long(usage, "usedBytes");
        var limit = Format.Long(usage, "limitBytes");
        var remaining = Format.Long(usage, "remainingBytes");
        body.Children.Add(new TextBlock
        {
            Text = Format.DataSize(used) + " of " + Format.DataSize(limit) + " used",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        body.Children.Add(new ProgressBar
        {
            Minimum = 0,
            Maximum = 1,
            Value = limit > 0 ? Math.Min(1, used / (double)limit) : 0,
        });
        body.Children.Add(new TextBlock
        {
            Text = Format.DataSize(remaining) + " remaining",
            Opacity = 0.7,
        });
        body.Children.Add(UsageRow("Today (UTC)", Format.Long(usage, "todayBytes")));
        body.Children.Add(UsageRow("This calendar month (UTC)", Format.Long(usage, "monthBytes")));
        body.Children.Add(UsageRow("Rolling 30 days, used for your limit", used));
        body.Children.Add(new TextBlock
        {
            Text = "All relayed traffic shares this allowance. Direct connections do not count. The limit includes today and the previous 29 UTC days. Each day, older usage leaves the window. This is not a daily refill or a calendar-month reset.",
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
        });
        var unlock = Format.Text(usage, "nextUnlockAt");
        if (!string.IsNullOrEmpty(unlock))
        {
            var day = unlock.Length >= 10 ? unlock[..10] : unlock;
            body.Children.Add(new TextBlock
            {
                Text = "Next usage to expire: " + Format.DataSize(Format.Long(usage, "nextUnlockBytes"))
                    + " on " + day + " at 00:00 UTC.",
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
                FontSize = 12,
            });
        }
        if (usage["daily"] is JsonArray days)
        {
            var usedDays = days.OfType<JsonNode>().Where(day => Format.Long(day, "bytes") > 0).ToList();
            body.Children.Add(new TextBlock
            {
                Text = "Daily usage (UTC)",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
            if (usedDays.Count == 0)
            {
                body.Children.Add(new TextBlock
                {
                    Text = "No relayed traffic in this window.",
                    Opacity = 0.7,
                    FontSize = 12,
                });
            }
            else
            {
                foreach (var day in usedDays.AsEnumerable().Reverse())
                {
                    body.Children.Add(UsageRow(Format.Text(day, "day"), Format.Long(day, "bytes")));
                }
            }
        }
        var asOf = Format.Text(usage, "asOf");
        var delay = Format.Long(usage, "reportingDelaySeconds");
        var stamp = asOf.Length >= 10 ? asOf[..10] : asOf;
        body.Children.Add(new TextBlock
        {
            Text = "As of " + stamp + ". Relay reporting can lag by about " + delay + " seconds.",
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(ActionIconGlyph.Button("Refresh usage", ActionIcon.Refresh, async (_, _) => await LoadAsync()));
        return Chrome.Card("Relay usage", body, "One allowance across your devices");
    }

    private static UIElement UsageRow(string label, long bytes)
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var name = new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap };
        var value = new TextBlock { Text = Format.DataSize(bytes), FontFamily = Fonts.Mono };
        Grid.SetColumn(value, 1);
        row.Children.Add(name);
        row.Children.Add(value);
        return row;
    }

    private async Task<UIElement> LocalTrafficCardAsync()
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        try
        {
            var status = await AppServices.Host.CallAsync("remote.status");
            var traffic = status["traffic"];
            if (traffic is null)
            {
                body.Children.Add(new TextBlock
                {
                    Text = "This host does not report local traffic yet.",
                    Opacity = 0.7,
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            else
            {
                body.Children.Add(UsageRow("Direct", Format.Long(traffic, "directBytes")));
                body.Children.Add(UsageRow("Relayed", Format.Long(traffic, "relayBytes")));
                body.Children.Add(new TextBlock
                {
                    Text = "Counted on this device since tokenstat started. Direct traffic does not use the account relay allowance. The relayed figure is this machine only, not the account total.",
                    Opacity = 0.7,
                    FontSize = 12,
                    TextWrapping = TextWrapping.Wrap,
                });
                if (traffic["peers"] is JsonArray peers && peers.Count > 0)
                {
                    foreach (var peer in peers.OfType<JsonNode>())
                    {
                        var name = Format.Text(peer, "label");
                        if (string.IsNullOrEmpty(name)) name = Format.Text(peer, "peer");
                        var row = new Grid();
                        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                        var left = new TextBlock { Text = name, TextWrapping = TextWrapping.Wrap };
                        var right = new TextBlock
                        {
                            Text = Format.Transport(Format.Text(peer, "route")),
                            Opacity = 0.7,
                        };
                        Grid.SetColumn(right, 1);
                        row.Children.Add(left);
                        row.Children.Add(right);
                        body.Children.Add(row);
                    }
                }
                else
                {
                    body.Children.Add(new TextBlock
                    {
                        Text = "No live connections right now.",
                        Opacity = 0.7,
                        FontSize = 12,
                    });
                }
            }
        }
        catch (Exception ex)
        {
            body.Children.Add(Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Warning, Symbol.Important));
        }
        body.Children.Add(ActionIconGlyph.Button("Refresh traffic", ActionIcon.Refresh, async (_, _) => await LoadAsync()));
        return Chrome.Card("This device", body, "How connections leave this machine");
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
                Child = new SymbolIcon { Symbol = ActionIcon.Merge.Symbol(), Foreground = Theme.AccentBrush },
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
                        _content.Children.Insert(0, Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Warning, Symbol.Important));
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
                Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Warning, Symbol.Important),
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
                    FontFamily = Fonts.Mono,
                    FontSize = Fonts.SignInCode,
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
            _content.Children.Insert(0, Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Warning, Symbol.Important));
        }
    }

    /// <summary>
    /// Local run notifications, matching the Mac account card. One switch for
    /// one feature: this computer watches its own automations and workflows
    /// and posts a toast when one finishes or stops for a question. No
    /// account and no network are involved, so the card shows whether or not
    /// the host answered above.
    /// </summary>
    private UIElement NotificationsCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(Chrome.ToggleChip(
            "Tell me when work needs attention",
            RunNotifications.Shared.IsOn,
            async on =>
            {
                RunNotifications.Shared.IsOn = on;
                await LoadAsync();
            }));
        body.Children.Add(new TextBlock
        {
            Text = "Automations and workflows on this computer. Nothing leaves "
                + "the machine: this computer watches its own work.",
            FontSize = 12,
            Opacity = 0.68,
            TextWrapping = TextWrapping.Wrap,
        });
        if (RunNotifications.Shared.IsOn)
        {
            body.Children.Add(ActionIconGlyph.Button(
                "Send a test", ActionIcon.Preview,
                (_, _) => RunNotifications.Shared.SendTest()));
        }
        return Chrome.Card(
            "Notifications",
            body,
            "When an agent run finishes, or stops for a question.");
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
                body.Children.Add(ActionIconGlyph.Button("Manual", ActionIcon.External, (_, _) =>
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
            body.Children.Add(ActionIconGlyph.Button("Check", ActionIcon.Refresh, async (_, _) => await update.CheckNowAsync()));
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

    /// <summary>
    /// Display name for a harness, the agent CLI that produced the events.
    /// The archive stores source ids like `claude_code`. These are shown to
    /// people, so they get the same spelling tokenstat.ai uses.
    /// </summary>
    private static string HarnessName(string id)
    {
        if (id == "opencode2")
        {
            return "OpenCode 2";
        }
        return HarnessCanonicalId(id) switch
        {
            "claude_code" => "Claude Code",
            "claude_code_rollup" or "claude_code_estimate" => "Claude Code (recovered)",
            "codex" => "Codex",
            "grok" => "Grok Build",
            "opencode" => "OpenCode",
            "cline" => "Cline",
            "openclaw" => "OpenClaw",
            "muse" => "Muse",
            "devin" => "Devin CLI",
            "pi" => "Pi",
            "dsh" => "DeepSeek Harness",
            "zed" => "Zed",
            "copilot" => "Copilot CLI",
            "antigravity" => "Antigravity",
            "cursor" => "Cursor",
            "gemini" => "Gemini",
            "hermes" => "Hermes Agent",
            "kilo" => "Kilo Code",
            "kimi" => "Kimi Code",
            "qwen" => "Qwen Code",
            "" => "unknown",
            var canonical => canonical,
        };
    }

    private static string HarnessCanonicalId(string id)
    {
        if (id == "agy")
        {
            return "antigravity";
        }
        if (id.StartsWith("antigravity", StringComparison.Ordinal))
        {
            return "antigravity";
        }
        if (id == "claude")
        {
            return "claude_code";
        }
        if (id == "opencode2")
        {
            return "opencode";
        }
        return id;
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
