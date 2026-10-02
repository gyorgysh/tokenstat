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
internal sealed class AccountPage : Page, IToolbarItems
{
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
    private int _loadGeneration;

    public AccountPage()
    {
        _root.Children.Add(_signSlot);
        _root.Children.Add(_content);
        var scroller = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceM),
            Content = _root,
        };
        var layout = new Grid();
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition
        {
            Height = new GridLength(1, GridUnitType.Star),
        });
        layout.Children.Add(_tabSlot);
        Grid.SetRow(scroller, 1);
        layout.Children.Add(scroller);
        Content = layout;
        RebuildTabs();
        Loaded += async (_, _) =>
        {
            AppServices.Update.Changed += OnUpdateChanged;
            await LoadAsync();
        };
        Unloaded += (_, _) =>
        {
            _pullPoll?.Cancel();
            ++_loadGeneration;
            AppServices.Update.Changed -= OnUpdateChanged;
        };
    }

    private void OnUpdateChanged() => DispatcherQueue.TryEnqueue(() =>
    {
        if (IsLoaded)
        {
            _ = LoadAsync();
        }
    });

    public event Action? ToolbarChanged;

    /// <summary>Global screen: no folder to name.</summary>
    public UIElement? ToolbarScope => null;

    /// <summary>
    /// Sync now, offered only while signed in, like the desktop Mac bar.
    /// </summary>
    public IList<UIElement> ToolbarActions()
    {
        var trailing = new List<UIElement>();
        if (_signedIn)
        {
            trailing.Add(Buttons.ToolbarIcon(
                ActionIcon.Refresh,
                L10n.Text("common.sync_now"),
                async (_, _) =>
                {
                    LogoRefresh.Began();
                    await SyncNowAsync();
                }));
        }
        return trailing;
    }

    private void RaiseToolbarChanged() => ToolbarChanged?.Invoke();

    private void RebuildTabs()
    {
        var tabs = new List<(string Value, string Label, ActionIcon? Glyph)>
        {
            ("account", L10n.Text("common.account"), ActionIcon.Account),
            ("limits", L10n.Text("windows.accountpage.plan_limits.925788cd"), ActionIcon.Plan),
            ("pc", L10n.Text("windows.accountpage.this_pc.638a348b"), ActionIcon.Device),
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
        var generation = ++_loadGeneration;
        try
        {
            var account = await AppServices.Host.CallAsync("account.status");
            if (generation != _loadGeneration) return;
            _account = account;
            _accountError = null;
        }
        catch (Exception ex)
        {
            if (generation != _loadGeneration) return;
            _account = null;
            _accountError = FriendlyError.Display(ex.Message);
        }
        _signedIn = _account?["signedIn"]?.GetValue<bool>() ?? false;
        RaiseToolbarChanged();
        RebuildTabs();
        await RenderPaneAsync();
    }

    private async Task RenderPaneAsync()
    {
        _content.Children.Clear();
        // Each render owns its panel. A slower previous tab can finish
        // loading without appending its cards into the newly selected tab.
        var content = new StackPanel { Spacing = Theme.SpaceL };
        _content.Children.Add(content);
        var skeleton = Motion.SkeletonCard();
        content.Children.Add(skeleton);
        try
        {
            switch (_pane)
            {
                case "limits":
                    await RenderLimitsPaneAsync(content);
                    break;
                case "pc":
                    await RenderThisPcPaneAsync(content);
                    break;
                default:
                    await RenderAccountPaneAsync(content);
                    break;
            }
        }
        finally
        {
            content.Children.Remove(skeleton);
        }
    }

    /// <summary>
    /// Who you are, who can reach you, and the legal end of the account.
    /// </summary>
    private async Task RenderAccountPaneAsync(StackPanel content)
    {
        var account = _account;
        if (account is null)
        {
            if (!string.IsNullOrEmpty(_accountError))
            {
                content.Children.Add(Chrome.Banner(
                    _accountError, Theme.Danger, Symbol.Important));
            }
            content.Children.Add(await PullConnectionCardAsync());
            content.Children.Add(PrivacyNote());
            content.Children.Add(AboutBlurb());
            return;
        }
        if (!_signedIn)
        {
            content.Children.Add(SignedOutCard());
        }
        else
        {
            content.Children.Add(IdentityCard(account));
            content.Children.Add(RelayUsageCard(account));
            content.Children.Add(SyncCard(account));
            content.Children.Add(DevicesCard(account));
        }
        content.Children.Add(await PullConnectionCardAsync());
        content.Children.Add(PrivacyNote());
        if (_signedIn)
        {
            content.Children.Add(DeleteAccountCard(account));
        }
        content.Children.Add(AboutBlurb());
    }

    private async Task RenderLimitsPaneAsync(StackPanel content)
    {
        var account = _account;
        if (account is null)
        {
            if (!string.IsNullOrEmpty(_accountError))
            {
                content.Children.Add(Chrome.Banner(
                    _accountError, Theme.Danger, Symbol.Important));
            }
            else
            {
                content.Children.Add(new ProgressRing
                {
                    IsActive = true,
                    HorizontalAlignment = HorizontalAlignment.Center,
                });
            }
            return;
        }
        if (!_signedIn)
        {
            content.Children.Add(LimitsSignedOutCard());
            return;
        }
        content.Children.Add(await PlanLimitsCardAsync());
    }

    /// <summary>
    /// Settings that live on this computer, signed in or not.
    /// </summary>
    private async Task RenderThisPcPaneAsync(StackPanel content)
    {
        content.Children.Add(await HostCardAsync());
        content.Children.Add(await LocalTrafficCardAsync());
        content.Children.Add(await LocalModelsCardAsync());
        content.Children.Add(NotificationsCard());
        content.Children.Add(UpdateCard());
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
            Text = L10n.Text("windows.accountpage.an_account_lets_you_publish_a_profile_page.d28d80da"),
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(ActionIconGlyph.PrimaryButton(
            L10n.Text("windows.accountpage.sign_in_to_tokenstat_ai.6276dc4d"), ActionIcon.SignIn,
            async (_, _) => await SignInFlow.RunAsync(this, _signSlot, LoadAsync)));
        return Chrome.Card(
            L10n.Text("windows.accountpage.not_signed_in.491fc91c"),
            body,
            L10n.Text("windows.accountpage.everything_works_without_an_account_signin.77323e45"));
    }

    private UIElement LimitsSignedOutCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(ActionIconGlyph.PrimaryButton(
            L10n.Text("windows.accountpage.sign_in_to_tokenstat_ai.6276dc4d"), ActionIcon.SignIn,
            async (_, _) => await SignInFlow.RunAsync(this, _signSlot, LoadAsync)));
        return Chrome.Card(
            L10n.Text("windows.accountpage.plan_limits.925788cd"),
            body,
            L10n.Text("windows.accountpage.sign_in_to_see_how_much_of_each_tool_s_sub.2b26b3eb"));
    }

    /// <summary>Who you are, at the size a profile deserves.</summary>
    private static UIElement IdentityCard(JsonNode account)
    {
        var handle = Format.Text(account, "handle", "");
        var name = Format.Text(account, "displayName", handle);
        if (string.IsNullOrEmpty(name))
        {
            name = L10n.Text("windows.accountpage.signed_in.ca566c89");
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
                L10n.Text("windows.accountpage.view_profile.d4788f25"), ActionIcon.External, (_, _) => Open(url)));
        }
        return Chrome.Card(L10n.Text("common.account"), body);
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
        row.Children.Add(new TextBlock { Text = L10n.Text("windows.accountpage.last_sync.71967fca"), Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(last) ? L10n.Text("common.never") : Format.Relative(last),
            FontFamily = Fonts.Mono,
            VerticalAlignment = VerticalAlignment.Center,
        });
        row.Children.Add(ActionIconGlyph.Button(L10n.Text("common.sync_now"), ActionIcon.Refresh, async (_, _) =>
        {
            await SyncNowAsync();
        }));
        body.Children.Add(row);
        body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.sign_out"), ActionIcon.SignOut, async (_, _) =>
        {
            try { await AppServices.Host.CallAsync("account.logout"); AppServices.NotifyAccountChanged(); }
            catch { /* stay on the page */ }
            await LoadAsync();
        }));
        return Chrome.Card(L10n.Text("windows.accountpage.sync.8d261a37"), body, L10n.Text("windows.accountpage.only_aggregate_counters_are_eligible.141802f7"));
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
        var subtitle = L10n.Text("windows.accountpage.every_device_that_has_synced_to_this_accou.cdc060e6");
        if (machines is not null && used > 0)
        {
            if (limitNode is not null)
            {
                subtitle = L10n.Text("windows.accountpage.0_of_1_devices.bd266bff", $"{used}", $"{Format.Long(account, "machineLimit")}");
                if (account["canRemote"] is JsonValue noRemote
                    && noRemote.GetValueKind() == System.Text.Json.JsonValueKind.False)
                {
                    subtitle += L10n.Text("windows.accountpage.no_remote_control_on_this_plan.278f9ff0");
                }
            }
            else
            {
                subtitle = L10n.Text("windows.accountpage.0_linked.6897cc07", $"{used}");
            }
        }
        if (used == 0)
        {
            return Chrome.Card(
                L10n.Text("common.devices"),
                EmptyState.View(
                    L10n.Text("windows.accountpage.nothing_linked_yet.2e60783b"),
                    L10n.Text("windows.accountpage.free_includes_two_devices_sync_now_to_put.e9a61412"),
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
            Text = L10n.Text("windows.accountpage.rename_reach_or_remove_a_device_on_the_dev.09b11869"),
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        return Chrome.Card(L10n.Text("common.devices"), body, subtitle);
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
                Text = L10n.Text("windows.accountpage.unnamed_device.6aba593f"),
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
                    Text = L10n.Text("windows.accountpage.this_pc.66f5aa0b"),
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
            stamp = string.IsNullOrEmpty(seen) ? L10n.Text("windows.accountpage.never_synced.ee394cab") : L10n.Text("windows.accountpage.last_used_0.acf5f8f5", $"{Format.Relative(seen)}");
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
            return Chrome.Card(L10n.Text("windows.accountpage.plan_limits.925788cd"), body);
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
            Text = L10n.Text("windows.accountpage.shows_how_much_of_each_tool_s_subscription.d271be32"),
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(Chrome.ToggleChip(L10n.Text("windows.accountpage.share_with_my_devices.44aa4fc8"), enabled, async on =>
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
                Text = L10n.Text("windows.accountpage.no_readings_yet_open_home_or_wait_for_the.6d2835f0"),
                Opacity = 0.7,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        else
        {
            foreach (var provider in providers.OfType<JsonNode>())
            {
                var source = Format.Text(provider, "source", L10n.Text("windows.accountpage.plan.fa8ed0bd"));
                body.Children.Add(PlanLimitRow(provider, source, !skip.Contains(source)));
            }
        }
        return Chrome.Card(
            L10n.Text("windows.accountpage.plan_limits.925788cd"),
            body,
            L10n.Text("windows.accountpage.how_much_of_each_tool_s_subscription_is_le.72953050"));
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
        ToolTipService.SetToolTip(toggle, L10n.Text("windows.accountpage.track_0.7cd9419b", $"{HarnessName(source)}"));
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
        return parts.Count == 0 ? L10n.Text("windows.accountpage.no_windows_reported.6e652c80") : string.Join(" · ", parts);
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
                Text = L10n.Text("windows.accountpage.the_host_helper_has_not_answered_yet.ed11e9fb"),
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
            return Chrome.Card(
                L10n.Text("windows.accountpage.this_pc.638a348b"),
                body,
                L10n.Text("windows.accountpage.whether_the_host_helper_stays_up_after_you.dd1619f2"));
        }
        var alwaysOn = policy["alwaysOn"]?.GetValue<bool>() ?? false;
        var hasBattery = policy["hasInternalBattery"]?.GetValue<bool>() ?? false;
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(new TextBlock { Text = L10n.Text("windows.accountpage.always_on_host.f7990642") });
        left.Children.Add(new TextBlock
        {
            Text = alwaysOn
                ? L10n.Text("windows.accountpage.the_host_helper_keeps_running_after_you_qu.a283800a")
                : L10n.Text("windows.accountpage.the_host_helper_stops_when_you_quit_tokens.d6e04c9b"),
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
                Text = L10n.Text("windows.accountpage.uses_more_power.a24adb34"),
                Opacity = 0.7,
                FontSize = 12,
            });
        }
        if (!alwaysOn)
        {
            body.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.accountpage.automations_run_only_while_tokenstat_is_op.72980d54"),
                Opacity = 0.7,
                FontSize = 12,
            });
        }
        return Chrome.Card(
            L10n.Text("windows.accountpage.this_pc.638a348b"),
            body,
            L10n.Text("windows.accountpage.whether_the_host_helper_stays_up_after_you.dd1619f2"));
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
            Text = L10n.Text("windows.accountpage.nothing_is_sent_to_tokenstat_these_checks.0b0d8242"),
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var refresh = ActionIconGlyph.Button(L10n.Text("common.refresh"), ActionIcon.Refresh, async (_, _) =>
        {
            await RenderPaneAsync();
        });
        Grid.SetColumn(refresh, 1);
        head.Children.Add(refresh);
        body.Children.Add(head);
        body.Children.Add(new TextBlock { Text = L10n.Text("common.local_provider_settings_help"), FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap });

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
                Foreground = Theme.Brush(static () => Theme.Danger),
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
            });
            return Chrome.Card(
                L10n.Text("windows.accountpage.local_models.8e4bf436"),
                body,
                L10n.Text("windows.accountpage.lm_studio_on_port_1234_ollama_on_port_1143.9fad3f80"));
        }
        if (providers.Count == 0)
        {
            body.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.accountpage.lm_studio_port_1234_and_ollama_port_11434.a765442f"),
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
            return Chrome.Card(
                L10n.Text("windows.accountpage.local_models.8e4bf436"),
                body,
                L10n.Text("windows.accountpage.lm_studio_on_port_1234_ollama_on_port_1143.9fad3f80"));
        }
        foreach (var provider in providers.OfType<JsonNode>())
        {
            body.Children.Add(LocalProviderRow(provider));
        }
        return Chrome.Card(
            L10n.Text("windows.accountpage.local_models.8e4bf436"),
            body,
            L10n.Text("windows.accountpage.lm_studio_on_port_1234_ollama_on_port_1143.9fad3f80"));
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
        var providerDot = new Border
        {
            Width = 8,
            Height = 8,
            CornerRadius = new CornerRadius(4),
            Background = available && enabled ? Theme.AccentBrush : Theme.BorderBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };
        left.Children.Add(providerDot);
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
        stack.Children.Add(LocalProviderPortEditor(provider, stack, () =>
        {
            providerDot.Background = Theme.BorderBrush;
            while (stack.Children.Count > 2) stack.Children.RemoveAt(2);
        }));
        if (!enabled)
        {
            stack.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.accountpage.disabled_for_local_model_selection.8bd93638"),
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
                        ? L10n.Text("windows.accountpage.server_is_up_load_a_model_in_lm_studio_to.45657b3c")
                        : L10n.Text("windows.accountpage.server_is_up_pull_or_run_a_model_in_ollama.d3666ac5"),
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

    private UIElement LocalProviderPortEditor(JsonNode provider, StackPanel owner, Action onSaved)
    {
        var id = Format.Text(provider, "id");
        var defaultPort = provider["defaultPort"]?.GetValue<int>() ?? (id == "lmstudio" ? 1234 : 11434);
        var currentPort = provider["port"]?.GetValue<int>() ?? defaultPort;
        if (provider["port"] is null && Uri.TryCreate(Format.Text(provider, "baseUrl"), UriKind.Absolute, out var address)) currentPort = address.Port;
        var editor = new StackPanel { Spacing = Theme.SpaceXs };
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        controls.Children.Add(new TextBlock { Text = L10n.Text("common.local_provider_port"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
        var field = new TextBox { Text = currentPort.ToString(System.Globalization.CultureInfo.InvariantCulture), Width = 84, MaxLength = 5, FontFamily = Fonts.Mono };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(field, L10n.Text("common.local_provider_port_label", Format.Text(provider, "name", id)));
        controls.Children.Add(field);
        var error = new TextBlock { Foreground = Theme.Brush(static () => Theme.Danger), FontSize = 12, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        var endpoint = new TextBlock { Text = Format.Text(provider, "baseUrl"), FontSize = 11, FontFamily = Fonts.Mono, Opacity = 0.7, IsTextSelectionEnabled = true };
        var busy = false;
        Button? save = null;
        Button? reset = null;
        bool Valid(out int port) => int.TryParse(field.Text.Trim(), System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out port) && port is >= 1 and <= 65535;
        void Validate()
        {
            var valid = Valid(out var port);
            if (save is not null) save.IsEnabled = !busy && valid && port != currentPort;
            if (reset is not null) reset.IsEnabled = !busy && field.Text != defaultPort.ToString(System.Globalization.CultureInfo.InvariantCulture);
            error.Text = valid ? "" : L10n.Text("common.local_provider_port_invalid");
            error.Visibility = valid ? Visibility.Collapsed : Visibility.Visible;
        }
        async Task Apply(int port)
        {
            if (busy) return;
            busy = true; field.IsEnabled = false; Validate();
            error.Visibility = Visibility.Collapsed;
            var saved = false;
            try
            {
                await AppServices.Host.CallAsync("local.provider.set", new JsonObject { ["id"] = id, ["port"] = port });
                saved = true; currentPort = port; onSaved();
                if (Uri.TryCreate(endpoint.Text, UriKind.Absolute, out var previous)) endpoint.Text = new UriBuilder(previous) { Port = port }.Uri.AbsoluteUri;
                var providers = await AppServices.Host.CallAsync("local.models") as JsonArray;
                var updated = providers?.OfType<JsonNode>().FirstOrDefault(item => Format.Text(item, "id") == id);
                if (updated is not null && owner.Parent is Panel parent)
                {
                    var index = parent.Children.IndexOf(owner);
                    if (index >= 0) { parent.Children.RemoveAt(index); parent.Children.Insert(index, LocalProviderRow(updated)); }
                }
            }
            catch (Exception ex) { error.Text = saved ? L10n.Text("common.local_provider_saved_refresh") : FriendlyError.Display(ex.Message); error.Visibility = Visibility.Visible; }
            finally
            {
                busy = false; field.IsEnabled = true;
                if (save is not null) save.IsEnabled = Valid(out var value) && value != currentPort;
                if (reset is not null) reset.IsEnabled = field.Text != defaultPort.ToString(System.Globalization.CultureInfo.InvariantCulture);
            }
        }
        save = Buttons.Primary(L10n.Text("common.save"), ActionIcon.Save, async (_, _) => { if (Valid(out var port)) await Apply(port); }, small: true);
        reset = Buttons.Secondary(L10n.Text("common.local_provider_use_default"), ActionIcon.Restore, async (_, _) =>
        {
            field.Text = defaultPort.ToString(System.Globalization.CultureInfo.InvariantCulture);
            if (currentPort != defaultPort) await Apply(defaultPort);
        }, small: true);
        field.TextChanged += (_, _) => Validate();
        field.KeyDown += async (_, key) => { if (key.Key == Windows.System.VirtualKey.Enter && Valid(out var port) && port != currentPort) { key.Handled = true; await Apply(port); } };
        controls.Children.Add(save); controls.Children.Add(reset);
        editor.Children.Add(controls);
        editor.Children.Add(endpoint);
        editor.Children.Add(error);
        Validate();
        return editor;
    }

    private static string LocalProviderHint(JsonNode provider, string id)
    {
        var raw = Format.Text(provider, "error", "not running");
        if (raw == "not running" || raw.StartsWith("not running", StringComparison.Ordinal))
        {
            return id == "lmstudio"
                ? L10n.Text("windows.accountpage.not_running_open_lm_studio_and_turn_on_the.d9dc45d4")
                : L10n.Text("windows.accountpage.not_running_start_ollama_port_11434.2f65e946");
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
        return Chrome.Card(L10n.Text("windows.accountpage.what_syncing_sends.6540deb3"), new TextBlock
        {
            Text = L10n.Text("windows.accountpage.aggregate_counts_per_day_tool_and_model_an.4f196b00"),
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
            Text = L10n.Text("windows.accountpage.deletion_happens_on_the_website_where_you.2b90d7e2"),
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(ActionIconGlyph.Button(
            L10n.Text("windows.accountpage.open_data_settings.ad95c620"), ActionIcon.External,
            (_, _) => Open(host.TrimEnd('/') + "/settings/data#delete")));
        return Chrome.Card(
            L10n.Text("windows.accountpage.delete_this_account.5e78b966"),
            body,
            L10n.Text("windows.accountpage.permanent_confirmed_on_the_website_s_data.68431d9f"));
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
                Text = L10n.Text("windows.accountpage.relay_usage_details_are_not_available_from.84fc7e91"),
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
            return Chrome.Card(L10n.Text("windows.accountpage.relay_usage.1addb713"), body, L10n.Text("windows.accountpage.one_allowance_across_your_devices.608bfc41"));
        }
        var used = Format.Long(usage, "usedBytes");
        var limit = Format.Long(usage, "limitBytes");
        var remaining = Format.Long(usage, "remainingBytes");
        body.Children.Add(new TextBlock
        {
            Text = Format.DataSize(used) + L10n.Text("windows.accountpage.of.a4282e4b") + Format.DataSize(limit) + L10n.Text("windows.accountpage.used.f194a918"),
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
            Text = Format.DataSize(remaining) + L10n.Text("windows.accountpage.remaining.62fc42d5"),
            Opacity = 0.7,
        });
        body.Children.Add(UsageRow(L10n.Text("windows.accountpage.today_utc"), Format.Long(usage, "todayBytes")));
        body.Children.Add(UsageRow(L10n.Text("windows.accountpage.this_calendar_month_utc.379dc97f"), Format.Long(usage, "monthBytes")));
        body.Children.Add(UsageRow(L10n.Text("windows.accountpage.rolling_30_days_used_for_your_limit.290548eb"), used));
        body.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.accountpage.all_relayed_traffic_shares_this_allowance.a652388b"),
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
                Text = L10n.Text("windows.accountpage.next_usage_to_expire_0_on_1_at_00_00_utc.1b64d175", $"{Format.DataSize(Format.Long(usage, "nextUnlockBytes"))}", $"{day}"),
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
                Text = L10n.Text("windows.accountpage.daily_usage_utc.520a8261"),
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
            if (usedDays.Count == 0)
            {
                body.Children.Add(new TextBlock
                {
                    Text = L10n.Text("windows.accountpage.no_relayed_traffic_in_this_window.a3f245c1"),
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
            Text = L10n.Text("windows.accountpage.as_of_0_relay_reporting_can_lag_by_about_1.f028d9ec", $"{stamp}", $"{delay}"),
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.accountpage.refresh_usage.8d3a136d"), ActionIcon.Refresh, async (_, _) => await LoadAsync()));
        return Chrome.Card(L10n.Text("windows.accountpage.relay_usage.1addb713"), body, L10n.Text("windows.accountpage.one_allowance_across_your_devices.608bfc41"));
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
                    Text = L10n.Text("windows.accountpage.this_computer_does_not_report_local_traffi.c31505cb"),
                    Opacity = 0.7,
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            else
            {
                body.Children.Add(UsageRow(L10n.Text("windows.accountpage.direct.002c7c68"), Format.Long(traffic, "directBytes")));
                body.Children.Add(UsageRow(L10n.Text("windows.accountpage.relayed.feb39b70"), Format.Long(traffic, "relayBytes")));
                body.Children.Add(new TextBlock
                {
                    Text = L10n.Text("windows.accountpage.counted_on_this_device_since_tokenstat_sta.0fc360a7"),
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
                        Text = L10n.Text("windows.accountpage.no_live_connections_right_now.a7f971c5"),
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
        body.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.accountpage.refresh_traffic.9e5ac8c2"), ActionIcon.Refresh, async (_, _) => await LoadAsync()));
        return Chrome.Card(L10n.Text("windows.accountpage.this_device.d052579c"), body, L10n.Text("windows.accountpage.how_connections_leave_this_machine.a5ac544a"));
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
                Text = state == "ready" && !string.IsNullOrEmpty(login) ? "@" + login : L10n.Text("windows.accountpage.not_connected.0303e182"),
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
            words.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.accountpage.github_com_0.2d9757a6", $"{PullSourceLabel(source)}"),
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
                    "tokenstat" => L10n.Text("windows.accountpage.connected_with_the_tokenstat_github_app_pu.408c2b35"),
                    "gitCredential" or "environment" => L10n.Text("windows.accountpage.pull_requests_work_through_a_credential_ow.304f9738"),
                    "pasted" => L10n.Text("windows.accountpage.a_token_saved_by_tokenstat_is_active_you_c.574bdb58"),
                    _ => L10n.Text("windows.accountpage.connect_the_tokenstat_github_app_then_choo.0a205707"),
                },
                FontSize = 12,
                Opacity = 0.68,
                TextWrapping = TextWrapping.Wrap,
            });
            if (source != "tokenstat")
            {
                body.Children.Add(ActionIconGlyph.PrimaryButton(
                    L10n.Text("windows.accountpage.connect_tokenstat_github_app.f936ff5f"),
                    ActionIcon.Connect,
                    async (_, _) => await StartPullLoginAsync()));
            }
            else
            {
                body.Children.Add(ActionIconGlyph.Button(
                    L10n.Text("windows.accountpage.choose_repositories.df6de593"),
                    ActionIcon.External,
                    (_, _) => Open("https://github.com/apps/tokenstat/installations/new")));
            }
            if (source is "tokenstat" or "pasted")
            {
                body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.sign_out"), ActionIcon.SignOut, async (_, _) =>
                {
                    var dialog = new ContentDialog
                    {
                        Title = L10n.Text("windows.accountpage.sign_out_of_github_pull_requests.9aed016d"),
                        Content = L10n.Text("windows.accountpage.the_github_token_saved_by_tokenstat_will_b.182fb193"),
                        PrimaryButtonText = L10n.Text("common.sign_out"),
                        CloseButtonText = L10n.Text("common.cancel"),
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
                L10n.Text("windows.accountpage.github_pull_requests.0973f247"),
                body,
                L10n.Text("windows.accountpage.checked_only_when_you_open_pull_requests_o.6c9f4103"));
        }
        catch (Exception ex)
        {
            return Chrome.Card(
                L10n.Text("windows.accountpage.github_pull_requests.0973f247"),
                Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Warning, Symbol.Important),
                L10n.Text("windows.accountpage.the_connection_could_not_be_checked.7599ac82"));
        }
    }

    private static string PullSourceLabel(string source) => source switch
    {
        "gitCredential" => L10n.Text("windows.accountpage.using_the_credential_git_already_has.6aad5a87"),
        "environment" => L10n.Text("windows.accountpage.using_gh_token_or_github_token_from_your_l.33077193"),
        "pasted" => L10n.Text("windows.accountpage.using_a_token_saved_by_tokenstat.c1e203e4"),
        "tokenstat" => L10n.Text("windows.accountpage.connected_through_tokenstat.2d13dbe0"),
        _ => L10n.Text("windows.accountpage.no_github_credential_found.56851452"),
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
                Text = L10n.Text("windows.accountpage.enter_this_one_time_code_in_the_github_pag.2babe0df"),
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
                Text = L10n.Text("windows.accountpage.waiting_for_github.d3f403f4"),
                VerticalAlignment = VerticalAlignment.Center,
                Opacity = 0.72,
            });
            content.Children.Add(waiting);

            var dialog = new ContentDialog
            {
                Title = L10n.Text("windows.accountpage.connect_tokenstat_github_app.f936ff5f"),
                Content = content,
                CloseButtonText = L10n.Text("common.cancel"),
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
            L10n.Text("windows.accountpage.tell_me_when_work_needs_attention.016eb3de"),
            RunNotifications.Shared.IsOn,
            async on =>
            {
                RunNotifications.Shared.IsOn = on;
                await LoadAsync();
            }));
        body.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.accountpage.automations_and_workflows_on_this_computer.5d221a8b"),
            FontSize = 12,
            Opacity = 0.68,
            TextWrapping = TextWrapping.Wrap,
        });
        if (RunNotifications.Shared.IsOn)
        {
            body.Children.Add(ActionIconGlyph.Button(
                L10n.Text("windows.accountpage.send_a_test.edc01436"), ActionIcon.Preview,
                (_, _) => RunNotifications.Shared.SendTest()));
        }
        return Chrome.Card(
            L10n.Text("windows.accountpage.notifications.78801183"),
            body,
            L10n.Text("windows.accountpage.when_an_agent_run_finishes_or_stops_for_a.62ef2fd8"));
    }

    private UIElement UpdateCard()
    {
        var update = AppServices.Update;
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock { Text = L10n.Text("windows.accountpage.installed_0.1bf9d96f", $"{update.CurrentVersion}") });
        if (update.IsReady)
        {
            body.Children.Add(new TextBlock { Text = L10n.Text("windows.accountpage.v_0_is_ready.3e648cdc", $"{update.Latest}") });
            body.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.accountpage.relaunch.8bd85e54"), ActionIcon.Refresh, (_, _) => update.Relaunch()));
        }
        else if (update.Current == AppUpdateModel.Stage.Failed)
        {
            body.Children.Add(new TextBlock
            {
                Text = update.Failure ?? L10n.Text("windows.accountpage.the_update_could_not_install_itself.a696796e"),
                TextWrapping = TextWrapping.Wrap,
                Foreground = Theme.Brush(static () => Theme.Danger),
            });
            body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => await update.RetryAsync()));
            if (!string.IsNullOrEmpty(update.HtmlUrl))
            {
                body.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.accountpage.manual.b0b9fe24"), ActionIcon.External, (_, _) =>
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
            body.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.accountpage.check.9d60841e"), ActionIcon.Refresh, async (_, _) => await update.CheckNowAsync()));
        }
        return Chrome.Card(L10n.Text("windows.accountpage.updates.22e2bada"), body, L10n.Text("windows.accountpage.sha_256_against_the_release_publisher_chec.2ded308f"));
    }

    private static UIElement AboutBlurb()
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock { Text = AppInfo.Copyright, Opacity = 0.8 });
        body.Children.Add(ActionIconGlyph.Button(AppInfo.WebsiteLabel, ActionIcon.External, (_, _) => Open(AppInfo.Website)));
        return Chrome.Card(L10n.Text("windows.accountpage.tokenstat.63d30539"), body, AppInfo.Company);
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
            "claude_code" => L10n.Text("windows.accountpage.claude_code.246ef8c1"),
            "claude_code_rollup" or "claude_code_estimate" => L10n.Text("windows.accountpage.claude_code_recovered.93f5e6b2"),
            "codex" => "Codex",
            "grok" => L10n.Text("windows.accountpage.grok_build.fd3bf01a"),
            "opencode" => "OpenCode",
            "cline" => "Cline",
            "openclaw" => "OpenClaw",
            "muse" => "Muse",
            "devin" => L10n.Text("windows.accountpage.devin_cli.29247d05"),
            "pi" => "Pi",
            "dsh" => L10n.Text("windows.accountpage.deepseek_harness.e562a9c5"),
            "zed" => "Zed",
            "copilot" => L10n.Text("windows.accountpage.copilot_cli.c73e38d4"),
            "antigravity" => "Antigravity",
            "cursor" => "Cursor",
            "gemini" => "Gemini",
            "hermes" => L10n.Text("windows.accountpage.hermes_agent.873e989a"),
            "kilo" => L10n.Text("windows.accountpage.kilo_code.83abecfd"),
            "kimi" => L10n.Text("windows.accountpage.kimi_code.0c486180"),
            "qwen" => L10n.Text("windows.accountpage.qwen_code.47487dbd"),
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
