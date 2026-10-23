// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using static Tokenstat.Pages.TeamManagementModel;

namespace Tokenstat.Pages;

internal sealed partial class TeamsPage
{
    private async Task ShowTeamPublisherSettingsAsync(TeamPublisherModel model, JsonObject repository, JsonObject publication, Func<Task> back)
    {
        Reset(L10n.Text("common.teams.project_settings")); var view = _view; var checkout = Text(publication, "id");
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.back"), ActionIcon.Back, async (_, _) => { if (IsLoaded && _view == view) await back(); }));
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.agent_runs"), ActionIcon.Run, async (_, _) => { if (IsLoaded && _view == view) await ShowTeamAgentGrantsAsync(model, repository, publication, back); }));
        JsonNode result;
        try { result = await model.Call("teams.lanes.get", new() { ["checkout"] = checkout }); }
        catch (Exception error)
        {
            if (!IsLoaded || _view != view) return; Note(TeamError(error), true);
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => { if (IsLoaded && _view == view) await ShowTeamPublisherSettingsAsync(model, repository, publication, back); })); return;
        }
        if (!IsLoaded || _view != view) return;
        var settings = result["settings"] as JsonObject;
        var mode = new ComboBox { Header = L10n.Text("common.teams.workflow"), HorizontalAlignment = HorizontalAlignment.Stretch };
        mode.Items.Add(new ComboBoxItem { Content = L10n.Text("common.teams.workflow_manual"), Tag = "manual" });
        mode.Items.Add(new ComboBoxItem { Content = L10n.Text("common.teams.workflow_review"), Tag = "review" });
        mode.Items.Add(new ComboBoxItem { Content = L10n.Text("common.teams.workflow_lanes"), Tag = "automatic" });
        mode.SelectedIndex = !Flag(settings, "enabled") ? 0 : Flag(settings, "review") ? 1 : 2;
        var target = new TextBox { Header = L10n.Text("common.teams.target_branch"), Text = settings is null ? "main" : Text(settings, "target"), IsSpellCheckEnabled = false };
        var remote = new TextBox { Header = L10n.Text("common.teams.remote"), Text = settings is null ? "origin" : Text(settings, "remote"), IsSpellCheckEnabled = false };
        var loadedCheck = settings?["check"] is JsonArray args ? args.Select(arg => arg!.GetValue<string>()).ToArray() : [];
        var check = new TextBox { Header = L10n.Text("common.teams.check_command"), Text = string.Join(" ", loadedCheck), IsSpellCheckEnabled = false };
        var acknowledge = new CheckBox { Content = L10n.Text("common.teams.check_confirm"), IsChecked = Flag(settings, "checkRunsChangedCode") };
        var pullRequest = new CheckBox { Content = L10n.Text("common.teams.open_pull_request"), IsChecked = Flag(settings, "pullRequest") };
        var supportsUpdates = Flag(result, "supportsCheckoutUpdates");
        var updateCheckout = new CheckBox { Content = L10n.Text("common.teams.checkout_updates"), IsChecked = Flag(settings, "updateCheckout") };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(updateCheckout, "team.workflow.update-checkout");
        var fields = new StackPanel { Spacing = Theme.SpaceM }; fields.Children.Add(mode);
        var description = TeamText(""); fields.Children.Add(description);
        fields.Children.Add(updateCheckout);
        var updateDetail = TeamText(L10n.Text("common.teams.checkout_updates_detail")); fields.Children.Add(updateDetail);
        var checkoutInputs = new StackPanel { Spacing = Theme.SpaceM }; checkoutInputs.Children.Add(target); checkoutInputs.Children.Add(remote); fields.Children.Add(checkoutInputs);
        var inputs = new StackPanel { Spacing = Theme.SpaceM }; inputs.Children.Add(check);
        inputs.Children.Add(TeamText(L10n.Text("common.teams.check_warning"))); inputs.Children.Add(acknowledge); inputs.Children.Add(pullRequest);
        inputs.Children.Add(TeamText(L10n.Text("common.teams.open_pull_request_detail"))); fields.Children.Add(inputs);
        void Describe()
        {
            var updates = supportsUpdates && mode.SelectedIndex != 2 && updateCheckout.IsChecked == true;
            description.Text = L10n.Text(mode.SelectedIndex == 2 ? "common.teams.workflow_lanes_detail"
                : mode.SelectedIndex == 1 ? (updates ? "common.teams.workflow_review_updates_detail" : "common.teams.workflow_review_detail")
                : (updates ? "common.teams.workflow_manual_updates_detail" : "common.teams.workflow_manual_detail"));
            updateCheckout.Visibility = updateDetail.Visibility = supportsUpdates && mode.SelectedIndex != 2 ? Visibility.Visible : Visibility.Collapsed;
            checkoutInputs.Visibility = mode.SelectedIndex != 0 || updates ? Visibility.Visible : Visibility.Collapsed;
            inputs.Visibility = mode.SelectedIndex == 0 ? Visibility.Collapsed : Visibility.Visible;
            pullRequest.Visibility = mode.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
        }
        mode.SelectionChanged += (_, _) => Describe(); updateCheckout.Checked += (_, _) => Describe(); updateCheckout.Unchecked += (_, _) => Describe(); check.TextChanged += (_, _) => acknowledge.IsChecked = false; Describe();
        // This editor shares the settings page's navigation but does not redraw
        // it until all fields have been assembled from the successful read.
        TeamEditor(L10n.Text("common.teams.workflow"), fields, L10n.Text("common.save"), () => target.Text.Trim().Length > 0
            && (!supportsUpdates || mode.SelectedIndex == 2 || updateCheckout.IsChecked != true || remote.Text.Trim().Length > 0)
            && (mode.SelectedIndex == 0 || check.Text.Trim().Length == 0 || acknowledge.IsChecked == true), async () => {
            var value = new JsonObject { ["enabled"] = mode.SelectedIndex != 0, ["target"] = target.Text.Trim(), ["review"] = mode.SelectedIndex == 1, ["pullRequest"] = mode.SelectedIndex == 1 && pullRequest.IsChecked == true,
                ["check"] = new JsonArray((mode.SelectedIndex == 0 ? [] : TeamPublisherModel.LaneCheckArguments(check.Text, loadedCheck)).Select(arg => (JsonNode)JsonValue.Create(arg)!).ToArray()), ["checkRunsChangedCode"] = mode.SelectedIndex != 0 && check.Text.Trim().Length > 0 && acknowledge.IsChecked == true };
            if (remote.Text.Trim().Length > 0) value["remote"] = remote.Text.Trim();
            if (supportsUpdates) value["updateCheckout"] = mode.SelectedIndex != 2 && updateCheckout.IsChecked == true;
            return await model.Call("teams.lanes.set", new() { ["checkout"] = checkout, ["settings"] = value });
        }, back, _ => ShowTeamPublisherSettingsAsync(model, repository, publication, back));
        var editorView = _view;
        if (_canResumeSharing && Text(publication, "workspaceId").Length > 0)
        {
            try
            {
                var pending = await model.Call("teams.projectSharing.read", new() { ["organization"] = model.Organization, ["workspace"] = Text(publication, "workspaceId") });
                if (!IsLoaded || _view != editorView) return;
                if (pending["setup"] is JsonObject && pending["workspace"] is JsonObject workspace)
                    _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.project_setup_resume"), ActionIcon.Connect, async (_, _) => {
                        if (!IsLoaded || _view != editorView) return;
                        try {
                            var details = await model.Directory("organizations.get", new() { ["organization"] = model.Organization });
                            if (IsLoaded && _view == editorView) await ShowFolderShareAsync(DirectoryClient(), workspace, details["organization"]!.AsObject());
                        } catch (Exception error) { if (IsLoaded && _view == editorView) Note(TeamError(error), true); }
                    }));
            }
            catch (Exception error) { if (IsLoaded && _view == editorView) Note(TeamError(error), true); }
        }
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.agent_runs"), ActionIcon.Run, async (_, _) => { if (IsLoaded && _view == editorView) await ShowTeamAgentGrantsAsync(model, repository, publication, back); }));
        if (Text(result, "catchUp").Length > 0)
        {
            Note(Text(result, "catchUp"), true);
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.catch_up_again"), ActionIcon.Refresh, async (_, _) => {
                if (!IsLoaded || _view != editorView) return;
                try { await model.Call("teams.lanes.catchUp", new() { ["checkout"] = checkout }); if (IsLoaded && _view == editorView) await ShowTeamPublisherSettingsAsync(model, repository, publication, back); }
                catch (Exception error) { if (IsLoaded && _view == editorView) Note(TeamError(error), true); }
            }));
        }
    }
    private async Task ShowTeamAgentGrantsAsync(TeamPublisherModel model, JsonObject repository, JsonObject publication, Func<Task> back)
    {
        Reset(L10n.Text("common.teams.agent_runs")); var view = _view; var checkout = Text(publication, "id");
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.back"), ActionIcon.Back, async (_, _) => { if (IsLoaded && _view == view) await back(); }));
        try
        {
            var answer = await model.Directory("execution.list", new() { ["organization"] = model.Organization, ["checkout"] = checkout });
            var revision = Revision(answer); var grants = answer["grants"] as JsonArray ?? throw new InvalidDataException();
            Require(grants.Count <= 1000 && grants.All(row => row is JsonObject && Text(row, "userId").Length > 0 && Text(row, "deviceKey").Length > 0));
            if (!IsLoaded || _view != view) return;
            var supportsPolicy = Flag(answer, "supportsMemberPolicy");
            var policy = supportsPolicy ? Text(answer, "policy") : "devices";
            Require(policy is "members" or "devices");
            if (supportsPolicy)
            {
                var choice = new ComboBox { Header = L10n.Text("common.teams.agent_access_policy"), HorizontalAlignment = HorizontalAlignment.Stretch };
                choice.Items.Add(new ComboBoxItem { Content = L10n.Text("common.teams.agent_access_members"), Tag = "members" });
                choice.Items.Add(new ComboBoxItem { Content = L10n.Text("common.teams.agent_access_devices"), Tag = "devices" });
                choice.SelectedIndex = policy == "members" ? 0 : 1;
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(choice, "team.agent-access.policy");
                _body.Children.Add(choice);
                Note(L10n.Text("common.teams.agent_access_account_detail"));
                var saving = false;
                Button? save = null;
                save = ActionIconGlyph.Button(L10n.Text("common.save"), ActionIcon.Save, async (_, _) => {
                    if (!IsLoaded || _view != view || saving || (choice.SelectedIndex == 0 ? "members" : "devices") == policy) return;
                    saving = true; choice.IsEnabled = false; save!.IsEnabled = false;
                    try
                    {
                        await model.Directory("execution.policy", new() { ["organization"] = model.Organization, ["checkout"] = checkout,
                            ["input"] = new JsonObject { ["policy"] = choice.SelectedIndex == 0 ? "members" : "devices", ["expectedRevision"] = revision, ["acknowledgeHostAccess"] = true } });
                        if (IsLoaded && _view == view) await ShowTeamAgentGrantsAsync(model, repository, publication, back);
                    }
                    catch (Exception error) { if (IsLoaded && _view == view) Note(TeamError(error), true); }
                    finally { saving = false; if (IsLoaded && _view == view) { choice.IsEnabled = true; save!.IsEnabled = (choice.SelectedIndex == 0 ? "members" : "devices") != policy; } }
                });
                save.IsEnabled = false; save.Visibility = Visibility.Collapsed;
                choice.SelectionChanged += (_, _) => {
                    if (saving) return;
                    var changed = (choice.SelectedIndex == 0 ? "members" : "devices") != policy;
                    save.IsEnabled = changed; save.Visibility = changed ? Visibility.Visible : Visibility.Collapsed;
                };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(save, "team.agent-access.save");
                _body.Children.Add(save);
            }
            if (policy == "members") { Note(L10n.Text("common.teams.agent_access_members_detail")); return; }
            Note(L10n.Text("common.teams.agent_grants_detail"));
            if (grants.Count == 0) Note(L10n.Text("common.teams.agent_grants_none"));
            foreach (var grant in grants.OfType<JsonObject>())
            {
                var card = TeamCard(Text(grant, "userId"), Text(grant, "deviceKey")[..Math.Min(12, Text(grant, "deviceKey").Length)]);
                if (Text(grant, "grantId").Length == 0) card.Children.Add(TeamText(L10n.Text("common.teams.agent_grant_renew")));
                card.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.remove_agent_grant"), ActionIcon.Revoke, (_, _) => {
                    if (!IsLoaded || _view != view) return;
                    TeamEditor(L10n.Text("common.teams.remove_agent_grant"), TeamCard(Text(grant, "userId"), L10n.Text("common.teams.agent_grants_detail")), L10n.Text("common.teams.remove_agent_grant"), () => true,
                        () => SetTeamAgentGrant(model, checkout, Text(grant, "userId"), Text(grant, "deviceKey"), null, false, revision),
                        () => ShowTeamAgentGrantsAsync(model, repository, publication, back), _ => ShowTeamAgentGrantsAsync(model, repository, publication, back), confirmation: true);
                })); _body.Children.Add(card);
            }
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.add_agent_grant"), ActionIcon.Create, async (_, _) => {
                if (IsLoaded && _view == view) await ShowTeamGrantMembersAsync(model, repository, publication, revision, back);
            }));
        }
        catch (Exception error)
        {
            if (!IsLoaded || _view != view) return; Note(TeamError(error), true);
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => { if (IsLoaded && _view == view) await ShowTeamAgentGrantsAsync(model, repository, publication, back); }));
        }
    }
    private static Task<JsonNode> SetTeamAgentGrant(TeamPublisherModel model, string checkout, string user, string device, string? machine, bool allow, long revision)
    {
        var input = new JsonObject { ["userId"] = user, ["deviceKey"] = device, ["allow"] = allow, ["expectedRevision"] = revision };
        if (machine is not null) input["machineId"] = machine; if (allow) input["acknowledgeHostAccess"] = true;
        return model.Directory("execution.set", new() { ["organization"] = model.Organization, ["checkout"] = checkout, ["input"] = input });
    }
    private Task ShowTeamGrantMembersAsync(TeamPublisherModel model, JsonObject repository, JsonObject publication, long revision, Func<Task> back) =>
        PublisherRowsAsync(L10n.Text("common.teams.choose_member"), async offset => TeamDirectoryPage.Read(await model.Directory("repositories.members", new() { ["organization"] = model.Organization, ["repository"] = model.Repository,
            ["page"] = new JsonObject { ["limit"] = 100, ["offset"] = offset } }), "members", offset), (member, view) => {
            if (!Flag(member, "eligible") || Text(member, "role") is not ("contributor" or "maintainer")) return;
            _body.Children.Add(ActionIconGlyph.Button(Text(member, "name"), ActionIcon.Profile, async (_, _) => {
                if (IsLoaded && _view == view) await ShowTeamGrantDevicesAsync(model, repository, publication, member, revision, back);
            }));
        }, () => ShowTeamAgentGrantsAsync(model, repository, publication, back));
    private async Task ShowTeamGrantDevicesAsync(TeamPublisherModel model, JsonObject repository, JsonObject publication, JsonObject member, long revision, Func<Task> back)
    {
        Reset(L10n.Text("common.teams.choose_device")); var view = _view; var checkout = Text(publication, "id");
        Task Return() => ShowTeamAgentGrantsAsync(model, repository, publication, back);
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.back"), ActionIcon.Back, async (_, _) => { if (IsLoaded && _view == view) await Return(); }));
        try
        {
            var answer = await model.Directory("execution.devices", new() { ["organization"] = model.Organization, ["checkout"] = checkout, ["user"] = Text(member, "id") });
            var devices = answer["devices"] as JsonArray ?? throw new InvalidDataException();
            Require(devices.Count <= 1000 && devices.All(row => row is JsonObject && Text(row, "id").Length > 0 && Text(row, "key").Length > 0));
            if (!IsLoaded || _view != view) return;
            Note(Text(member, "name"));
            foreach (var device in devices.OfType<JsonObject>())
                _body.Children.Add(ActionIconGlyph.Button(TeamGrantDeviceLabel(device), ActionIcon.Device, (_, _) => {
                    if (!IsLoaded || _view != view) return;
                    TeamEditor(L10n.Text("common.teams.allow_agent_runs"), TeamCard(Text(member, "name"), TeamGrantDeviceLabel(device) + "\n" + L10n.Text("common.teams.agent_grant_warning")), L10n.Text("common.teams.allow_agent_runs"), () => true,
                        () => SetTeamAgentGrant(model, checkout, Text(member, "id"), Text(device, "key"), Text(device, "id"), true, revision), Return, _ => Return(), confirmation: true);
                }));
        }
        catch (Exception error) { if (IsLoaded && _view == view) Note(TeamError(error), true); }
    }
    private static string TeamGrantDeviceLabel(JsonNode device) => Text(device, "name").Trim() is { Length: > 0 } name
        ? name : L10n.Text("common.teams.device") + " · " + Text(device, "key")[..Math.Min(12, Text(device, "key").Length)];
}
