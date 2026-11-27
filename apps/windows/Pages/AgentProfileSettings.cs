// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal sealed class AgentProfileSettings : StackPanel
{
    private readonly TextBlock _error = new() { TextWrapping = TextWrapping.Wrap };
    private readonly StackPanel _body = new() { Spacing = Theme.SpaceS };
    private AgentProfiles? _profiles;
    private JsonNode[] _agents = [];
    private readonly Dictionary<string, JsonNode> _statuses = new();
    private string _selected = AgentProfiles.SystemId;
    private bool _busy;

    internal AgentProfileSettings()
    {
        Spacing = Theme.SpaceS;
        Children.Add(_error);
        Children.Add(_body);
        Loaded += async (_, _) => await RunAsync(async () =>
        {
            _profiles = await AgentProfiles.ReadAsync("");
            _agents = (await AppServices.Host.CallAsync("chat.backends") as JsonArray ?? [])
                .OfType<JsonObject>().Where(backend => ChatAgentPicker.Installed(backend) && Format.Text(backend, "id") != "sh").ToArray();
        });
    }

    private async Task RunAsync(Func<Task> action)
    {
        if (_busy) return;
        _busy = true;
        _body.Opacity = 0.65;
        _body.IsHitTestVisible = false;
        _error.Text = "";
        try { await action(); }
        catch (Exception failure) { _error.Text = failure.Message; }
        finally
        {
            _busy = false;
            _body.IsHitTestVisible = true;
            _body.Opacity = 1;
            Render();
        }
    }

    private async Task ChangeAsync(string method, JsonObject parameters)
    {
        var result = await AppServices.Host.CallAsync("profiles." + method, parameters);
        if (method == "create")
        {
            _selected = Format.Text(result, "id", AgentProfiles.SystemId);
            result = result["profiles"] ?? throw new InvalidOperationException();
        }
        _profiles = new AgentProfiles(result);
        if (_profiles.Find(_selected) is null) _selected = AgentProfiles.SystemId;
        if (method is "create" or "delete" or "setAgent") await RefreshStatusAsync();
    }

    private async Task RefreshStatusAsync()
    {
        _statuses.Clear();
        if (_profiles is not { } profiles || _selected == AgentProfiles.SystemId) return;
        foreach (var backend in _agents)
        {
            var agent = Format.Text(backend, "launcherId");
            if (!profiles.Owns(_selected, agent)) continue;
            try
            {
                _statuses[agent] = await AppServices.Host.CallAsync("launcher.checkSignIn",
                    new JsonObject { ["id"] = agent, ["profile"] = _selected });
            }
            catch { /* The agent can still offer its sign-in terminal. */ }
        }
    }

    private void Render()
    {
        _body.Children.Clear();
        var profiles = _profiles;
        if (profiles is null) return;
        _body.Children.Add(Selection(L10n.Text("common.profiles.label"), _selected, profiles, id => RunAsync(async () =>
        {
            _selected = id;
            await RefreshStatusAsync();
        })));
        _body.Children.Add(Button(L10n.Text("windows.profiles.add"), () => EditNameAsync(null)));
        if (_selected == AgentProfiles.SystemId)
        {
            _body.Children.Add(new TextBlock { Text = L10n.Text("windows.profiles.terminal_logins") });
        }
        else
        {
            var profileId = _selected;
            foreach (var backend in _agents)
            {
                var agent = Format.Text(backend, "launcherId");
                var own = profiles.Owns(profileId, agent);
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
                row.Children.Add(new TextBlock
                {
                    Text = Format.Text(backend, "label"),
                    VerticalAlignment = VerticalAlignment.Center,
                });
                if (profiles.Agents.Contains(agent))
                {
                    var toggle = new ToggleSwitch
                    {
                        IsOn = own,
                        OnContent = L10n.Text("windows.profiles.own_login"),
                        OffContent = L10n.Text("windows.profiles.same_pc"),
                    };
                    toggle.Toggled += async (_, _) => await RunAsync(() =>
                        ChangeAsync("setAgent", new JsonObject { ["id"] = profileId, ["agent"] = agent, ["own"] = toggle.IsOn }));
                    row.Children.Add(toggle);
                    if (own && AgentSignInDialog.Supported(backend))
                    {
                        _statuses.TryGetValue(agent, out var status);
                        var signedIn = Format.Text(status, "readiness") == "signedIn";
                        var email = Format.Text(status, "email");
                        if (signedIn) row.Children.Add(new TextBlock
                        {
                            Text = email.Length > 0 ? email : L10n.Text("windows.profiles.signed_in"),
                            VerticalAlignment = VerticalAlignment.Center,
                            TextTrimming = TextTrimming.CharacterEllipsis,
                        });
                        row.Children.Add(Button(signedIn ? L10n.Text("windows.profiles.sign_in_again") : L10n.Text("common.sign_in"),
                            () => RunAsync(async () =>
                            {
                                await AgentSignInDialog.ShowAsync(this, "", backend,
                                    (method, args) => AppServices.Host.CallAsync(method, args), profileId);
                                await RefreshStatusAsync();
                            })));
                    }
                }
                else row.Children.Add(new TextBlock { Text = L10n.Text("windows.profiles.same_pc"), VerticalAlignment = VerticalAlignment.Center });
                _body.Children.Add(row);
            }
            _body.Children.Add(Button(L10n.Text("common.rename"), () => EditNameAsync(profileId)));
            _body.Children.Add(Button(L10n.Text("common.delete"), async () =>
            {
                var result = await Chrome.ShowDialog(this, new ContentDialog
                {
                    Title = L10n.Text("windows.profiles.delete", profiles.Title(profileId)),
                    Content = L10n.Text("windows.profiles.delete_message"),
                    PrimaryButtonText = L10n.Text("common.delete"),
                    CloseButtonText = L10n.Text("common.cancel"),
                });
                if (result == ContentDialogResult.Primary)
                    await RunAsync(() => ChangeAsync("delete", new JsonObject { ["id"] = profileId }));
            }));
        }
        if (profiles.Choices.Length > 1)
            _body.Children.Add(Selection(L10n.Text("windows.profiles.default"), profiles.DefaultId, profiles,
                id => RunAsync(() => ChangeAsync("setDefault", new JsonObject { ["id"] = id }))));
    }

    private async Task EditNameAsync(string? id)
    {
        var name = new TextBox { Header = L10n.Text("windows.profiles.name"), Text = id is null ? "" : _profiles?.Title(id) ?? "" };
        var result = await Chrome.ShowDialog(this, new ContentDialog
        {
            Title = L10n.Text(id is null ? "windows.profiles.add" : "common.rename"),
            Content = name,
            PrimaryButtonText = L10n.Text("common.save"),
            CloseButtonText = L10n.Text("common.cancel"),
        });
        if (result == ContentDialogResult.Primary)
        {
            var parameters = new JsonObject { ["name"] = name.Text };
            if (id is not null) parameters["id"] = id;
            await RunAsync(() => ChangeAsync(id is null ? "create" : "rename", parameters));
        }
    }

    private static Button Selection(string label, string active, AgentProfiles profiles, Func<string, Task> choose)
    {
        var menu = new MenuFlyout();
        foreach (var profile in profiles.Choices)
        {
            var id = Format.Text(profile, "id");
            var item = new MenuFlyoutItem { Text = profiles.Title(id), IsEnabled = id != active };
            item.Click += async (_, _) => await choose(id);
            menu.Items.Add(item);
        }
        return new Button { Content = label + " · " + profiles.Title(active), Flyout = menu };
    }

    private static Button Button(string label, Func<Task> action)
    {
        var button = new Button { Content = label };
        button.Click += async (_, _) => await action();
        return button;
    }
}
