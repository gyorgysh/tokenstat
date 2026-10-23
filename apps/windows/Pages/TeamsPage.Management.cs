// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Windows.ApplicationModel.DataTransfer;
using static Tokenstat.Pages.TeamManagementModel;

namespace Tokenstat.Pages;

internal sealed partial class TeamsPage
{
    private TeamDirectoryClient DirectoryClient() => new(_scope ?? throw new InvalidDataException(), _session, _person ?? throw new InvalidDataException(), _call);
    private static TextBlock TeamText(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private static StackPanel TeamCard(string title, string? detail = null)
    {
        var panel = new StackPanel { Spacing = Theme.SpaceS, Padding = new Thickness(16), Background = Theme.PanelBrush, CornerRadius = new CornerRadius(10) };
        panel.Children.Add(TeamText(title)); if (detail is not null) panel.Children.Add(TeamText(detail)); return panel;
    }
    private static string TeamRole(string? role) => role switch {
        "owner" => L10n.Text("common.teams.owner"), "admin" => L10n.Text("common.teams.admin"), "member" => L10n.Text("common.teams.member"),
        "viewer" => L10n.Text("common.teams.viewer"), "contributor" => L10n.Text("common.teams.contributor"), "maintainer" => L10n.Text("common.teams.maintainer"),
        _ => L10n.Text("common.teams.no_access"),
    };
    private static string TeamError(Exception error) => error is InvalidDataException ? L10n.Text("common.teams.load_failed") : error.Message;
    private static ComboBox TeamRoles(string? selected, string?[] choices, string label)
    {
        var picker = new ComboBox { Header = label, HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var choice in choices) picker.Items.Add(new ComboBoxItem { Content = TeamRole(choice), Tag = choice });
        picker.SelectedIndex = Array.FindIndex(choices, choice => choice == selected);
        AutomationProperties.SetName(picker, label); return picker;
    }
    private static string? PickedRole(ComboBox picker) => (picker.SelectedItem as ComboBoxItem)?.Tag as string;
    private void AddTeamDirectoryActions()
    {
        var client = DirectoryClient(); var view = _view;
        var actions = new FlowPanel { Spacing = Theme.SpaceS };
        actions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.invitations_for_you"), ActionIcon.Send, async (_, _) => {
            if (IsLoaded && _view == view) await ShowTeamInboxAsync(client, new(client));
        }));
        actions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.create_organization"), ActionIcon.Create, (_, _) => {
            if (IsLoaded && _view == view) ShowTeamCreate(client);
        }));
        actions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.refresh"), ActionIcon.Refresh, async (_, _) => { if (IsLoaded && _view == view) await LoadAsync(); }));
        _body.Children.Add(actions);
    }

    // Editors are native page content, so long access reviews scroll with the
    // page and text scaling does not hide the final explicit action.
    private void TeamEditor(string title, StackPanel fields, string submit, Func<bool> ready, Func<Task<JsonNode>> save,
        Func<Task> back, Func<JsonNode, Task> done, bool confirmation = false, bool invitationLink = false, TeamDirectoryClient? client = null)
    {
        Reset(title); var view = _view; var sending = false;
        _body.Children.Add(fields);
        CheckBox? confirm = null;
        if (confirmation) { confirm = new CheckBox { Content = L10n.Text("common.teams.confirm_understood") }; _body.Children.Add(confirm); }
        var error = TeamText(""); _body.Children.Add(error);
        Button? apply = null; Button? cancel = null;
        apply = ActionIconGlyph.Button(submit, ActionIcon.Approve, async (_, _) => {
            if (sending || !IsLoaded || _view != view || !ready() || confirm is not null && confirm.IsChecked != true) return;
            sending = true; EnableTeamInputs(fields, false); apply!.IsEnabled = false; cancel!.IsEnabled = false; if (confirm is not null) confirm.IsEnabled = false;
            error.Text = "";
            try
            {
                var result = await save();
                if (!IsLoaded || _view != view) return;
                if (invitationLink) ShowTeamInvitationLink(client ?? throw new InvalidDataException(), result, back);
                else await done(result);
            }
            catch (Exception failure) { if (IsLoaded && _view == view) error.Text = TeamError(failure); }
            finally
            {
                sending = false;
                if (IsLoaded && _view == view) { EnableTeamInputs(fields, true); cancel.IsEnabled = true; if (confirm is not null) confirm.IsEnabled = true; Update(); }
            }
        });
        cancel = ActionIconGlyph.Button(L10n.Text("common.cancel"), ActionIcon.Dismiss, async (_, _) => { if (!sending && IsLoaded && _view == view) await back(); });
        void Update() { if (IsLoaded && _view == view) apply.IsEnabled = !sending && ready() && (confirm is null || confirm.IsChecked == true); }
        foreach (var input in TeamInputs(fields))
        {
            if (input is TextBox text) text.TextChanged += (_, _) => Update();
            if (input is ComboBox combo) combo.SelectionChanged += (_, _) => Update();
        }
        if (confirm is not null) { confirm.Checked += (_, _) => Update(); confirm.Unchecked += (_, _) => Update(); }
        _body.Children.Add(apply); _body.Children.Add(cancel); Update();
    }
    private static IEnumerable<Control> TeamInputs(Panel panel)
    {
        foreach (var child in panel.Children) { if (child is Control control) yield return control; if (child is Panel nested) foreach (var input in TeamInputs(nested)) yield return input; }
    }
    private static void EnableTeamInputs(Panel panel, bool enabled) { foreach (var control in TeamInputs(panel)) control.IsEnabled = enabled; }
    private void ShowTeamInvitationLink(TeamDirectoryClient client, JsonNode result, Func<Task> back)
    {
        var url = client.InvitationUrl(result);
        Reset(L10n.Text("common.teams.invitation_ready")); var view = _view;
        Note(L10n.Text("common.teams.invitation_send_detail")); _body.Children.Add(TeamText(url)); Note(L10n.Text("common.teams.invitation_expiry"));
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.copy"), ActionIcon.Copy, (_, _) => {
            if (!IsLoaded || _view != view) return; var data = new DataPackage(); data.SetText(url); Clipboard.SetContent(data);
        }));
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.done"), ActionIcon.Done, async (_, _) => { if (IsLoaded && _view == view) await back(); }));
    }
    private void ShowTeamCreate(TeamDirectoryClient client)
    {
        var fields = new StackPanel { Spacing = Theme.SpaceM };
        fields.Children.Add(TeamText(L10n.Text("common.teams.legend_creator")));
        var name = new TextBox { Header = L10n.Text("common.teams.organization_name"), MaxLength = 80 };
        var slug = new TextBox { Header = L10n.Text("common.teams.organization_address"), MaxLength = 48, IsSpellCheckEnabled = false };
        var old = "";
        name.TextChanged += (_, _) => { if (slug.Text.Length == 0 || slug.Text == SuggestedSlug(old)) slug.Text = SuggestedSlug(name.Text); old = name.Text; };
        fields.Children.Add(name); fields.Children.Add(slug); fields.Children.Add(TeamText(L10n.Text("common.teams.address_detail")));
        TeamEditor(L10n.Text("common.teams.create_organization"), fields, L10n.Text("common.teams.create_organization"), () => ValidName(name.Text) && ValidSlug(slug.Text),
            async () => await client.Create(name.Text, slug.Text), LoadAsync, async result => { _organization = result.AsObject(); await LoadAsync(); });
    }
    private async Task ShowTeamManagementAsync(TeamDirectoryClient client, TeamManagementModel model, string section = "members", bool more = false)
    {
        Reset(Text(model.Organization, "name")); var view = _view; string? error = null;
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.back"), ActionIcon.Back, async (_, _) => { if (IsLoaded && _view == view) await LoadAsync(); }));
        Note(L10n.Text("common.teams.loading"));
        try { await model.Refresh(section, more); }
        catch (Exception failure) { error = TeamError(failure); }
        if (!IsLoaded || _view != view) return;
        DrawTeamManagement(client, model, section, error);
    }
    private void DrawTeamManagement(TeamDirectoryClient client, TeamManagementModel model, string section, string? error)
    {
        Reset(Text(model.Organization, "name")); var view = _view;
        bool Alive() => IsLoaded && _view == view;
        Task Reload() => ShowTeamManagementAsync(client, model, section);
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.back"), ActionIcon.Back, async (_, _) => { if (Alive()) { _organization = model.Organization; await LoadAsync(); } }));
        if (!model.Active) Note(L10n.Text("common.teams.organization_paused"));
        if (error is not null) Note(error, true);
        var tabs = new FlowPanel { Spacing = Theme.SpaceS };
        void Tab(string key, string label, ActionIcon icon) => tabs.Children.Add(ActionIconGlyph.Button(L10n.Text(label), icon, async (_, _) => { if (Alive()) await ShowTeamManagementAsync(client, model, key); }));
        Tab("members", "common.teams.members", ActionIcon.Profile); Tab("repositories", "common.teams.repositories", ActionIcon.Source);
        if (model.Manager) Tab("invitations", "common.teams.invitations", ActionIcon.Send);
        Tab("settings", "common.settings", ActionIcon.Settings);
        tabs.Children.Add(ActionIconGlyph.Button(L10n.Text("common.refresh"), ActionIcon.Refresh, async (_, _) => { if (Alive()) await Reload(); })); _body.Children.Add(tabs);
        if (model.Verified && model.OwnershipRequest is { } request && Text(request, "requestId").Length > 0)
        {
            var recipient = Text(request, "toUserId") == client.Person;
            var sender = model.CurrentOwner && Text(request, "fromUserId") == client.Person;
            if (recipient || sender)
            {
                var card = TeamCard(L10n.Text("common.teams.ownership_request"), L10n.Text(Flag(request, "current") ? "common.teams.ownership_pending" : "common.teams.ownership_stale"));
                if (sender || Flag(request, "current")) card.Children.Add(ActionIconGlyph.Button(L10n.Text(sender ? "common.teams.cancel_ownership_request" : "common.teams.review_ownership"), ActionIcon.Preview, (_, _) => {
                    if (Alive()) ReviewTeamOwnership(client, model, (JsonObject)request.DeepClone(), sender, Reload);
                })); _body.Children.Add(card);
            }
        }
        if (section is "members" or "invitations" && model.Manager)
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.invite_member"), ActionIcon.Create, async (_, _) => {
                if (!Alive()) return;
                try { if (!model.Repositories.Loaded) await model.Refresh("repositories"); if (Alive() && model.Manager) ShowTeamInvite(client, model, Reload); }
                catch (Exception failure) { if (Alive()) Note(TeamError(failure), true); }
            }));
        if (section == "settings") { AddTeamSettings(client, model, Reload, Alive); return; }
        var rows = model.Rows(section);
        if (rows.Loaded && rows.Rows.Count == 0 && section is "invitations" or "repositories") Note(L10n.Text(section == "invitations" ? "common.teams.no_invitations" : "common.teams.no_repositories"));
        foreach (var row in rows.Rows)
        {
            var card = TeamCard(section == "invitations" ? Text(row["recipient"], "name") : Text(row, "name"), TeamRole(Text(row, "role")));
            if (section == "members")
            {
                if (Text(row, "handle").Length > 0) card.Children.Add(TeamText("@" + Text(row, "handle")));
                if (!Flag(row, "eligible")) card.Children.Add(TeamText(L10n.Text("common.teams.needs_patron")));
                var other = Text(row, "id") != client.Person && Text(row, "role") is "member" or "admin";
                if (model.Owner && other) card.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.change_role"), ActionIcon.Edit, (_, _) => { if (Alive()) ShowTeamMemberRole(client, model, row, Reload); }));
                if (model.Manager && other && (model.Owner || Text(row, "role") == "member")) card.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.remove_member"), ActionIcon.Revoke, (_, _) => {
                    if (Alive()) TeamEditor(L10n.Text("common.teams.remove_member"), TeamCard(Text(row, "name"), L10n.Text("common.teams.remove_confirmation_detail")), L10n.Text("common.teams.remove_member"), () => model.Manager,
                        () => model.Mutate("members.remove", model.RemoveMember(row), user: Text(row, "id")), Reload, _ => Reload(), confirmation: true);
                }));
            }
            else if (section == "repositories" && model.Active && (model.Manager || Text(row, "role") == "maintainer"))
                card.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.repository_access"), ActionIcon.Security, async (_, _) => { if (Alive()) await ShowTeamAccessAsync(client, model, row); }));
            else if (section == "invitations")
            {
                card.Children.Add(TeamText(TeamInvitationState(Text(row, "state"))));
                if (model.Manager && Text(row, "state") is "pending" or "expired")
                    card.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.new_invitation_link"), ActionIcon.Refresh, (_, _) => { if (Alive()) ReviewTeamInvitation(client, model, row, true, Reload); }));
                if (model.Manager && Text(row, "state") == "pending")
                    card.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.revoke_invitation"), ActionIcon.Revoke, (_, _) => { if (Alive()) ReviewTeamInvitation(client, model, row, false, Reload); }));
            }
            _body.Children.Add(card);
        }
        if (rows.Next is not null || error is not null) _body.Children.Add(ActionIconGlyph.Button(L10n.Text(error is null ? "common.teams.load_more" : "common.retry"), ActionIcon.More, async (_, _) => {
            if (Alive()) await ShowTeamManagementAsync(client, model, section, rows.Next is not null && rows.Loaded);
        }));
    }
    private static string TeamInvitationState(string state) => state switch {
        "pending" => L10n.Text("common.teams.pending"), "accepted" => L10n.Text("common.teams.accepted"), "expired" => L10n.Text("common.teams.expired"),
        "revoked" => L10n.Text("common.teams.revoked"), _ => L10n.Text("common.teams.invitation_unavailable"),
    };
    private void ShowTeamMemberRole(TeamDirectoryClient client, TeamManagementModel model, JsonObject row, Func<Task> back)
    {
        var fields = TeamCard(Text(row, "name"), L10n.Text("common.teams.role_content_separate"));
        var role = TeamRoles(Text(row, "role"), ["member", "admin"], L10n.Text("common.teams.change_role")); fields.Children.Add(role);
        var detail = TeamText(""); fields.Children.Add(detail);
        void Describe() => detail.Text = L10n.Text(PickedRole(role) == "admin" ? "common.teams.admin_detail" : "common.teams.member_detail");
        role.SelectionChanged += (_, _) => Describe(); Describe();
        TeamEditor(L10n.Text("common.teams.change_role"), fields, L10n.Text("common.save"), () => model.Owner && PickedRole(role) != Text(row, "role"),
            () => model.Mutate("members.role", model.MemberRole(row, PickedRole(role) ?? "member"), user: Text(row, "id")), back, _ => back());
    }
    private void ReviewTeamInvitation(TeamDirectoryClient client, TeamManagementModel model, JsonObject row, bool renew, Func<Task> back)
    {
        var title = L10n.Text(renew ? "common.teams.new_invitation_link" : "common.teams.revoke_invitation");
        TeamEditor(title, TeamCard(Text(row["recipient"], "name"), L10n.Text(renew ? "common.teams.renew_invitation_detail" : "common.teams.revoke_invitation_detail")), title, () => model.Manager,
            () => model.Mutate(renew ? "invitations.renew" : "invitations.revoke", new() { ["expectedRevision"] = Revision(row) }, invitation: Text(row, "id")),
            back, _ => back(), confirmation: !renew, invitationLink: renew, client: client);
    }
    private void ShowTeamInvite(TeamDirectoryClient client, TeamManagementModel model, Func<Task> back)
    {
        var fields = new StackPanel { Spacing = Theme.SpaceM };
        var handle = new TextBox { Header = L10n.Text("common.teams.tokenstat_handle"), IsSpellCheckEnabled = false };
        var role = TeamRoles("member", model.Owner ? ["member", "admin"] : ["member"], L10n.Text("common.teams.change_role"));
        fields.Children.Add(handle); fields.Children.Add(role); fields.Children.Add(TeamText(L10n.Text("common.teams.invite_repository_detail")));
        var choices = new Dictionary<string, ComboBox>();
        var repositories = new StackPanel { Spacing = Theme.SpaceS }; fields.Children.Add(repositories);
        var moreError = TeamText(""); fields.Children.Add(moreError);
        Button? more = null;
        var expectedView = _view + 1;
        void AddChoices()
        {
            foreach (var repo in model.Repositories.Rows)
            {
                var id = Text(repo, "id"); if (choices.ContainsKey(id)) continue;
                var picker = TeamRoles(null, [null, "viewer", "contributor", "maintainer"], Text(repo, "name"));
                choices.Add(id, picker); repositories.Children.Add(picker);
            }
            if (more is not null) more.Visibility = model.Repositories.Next is null ? Visibility.Collapsed : Visibility.Visible;
        }
        more = ActionIconGlyph.Button(L10n.Text("common.teams.load_more"), ActionIcon.More, async (_, _) => {
            if (!IsLoaded || _view != expectedView || model.Busy) return; more!.IsEnabled = false;
            try { await model.Refresh("repositories", true); if (IsLoaded && _view == expectedView) { moreError.Text = ""; AddChoices(); } }
            catch (Exception failure) { if (IsLoaded && _view == expectedView) moreError.Text = TeamError(failure); }
            finally { if (IsLoaded && _view == expectedView) more.IsEnabled = true; }
        });
        fields.Children.Add(more); AddChoices(); fields.Children.Add(TeamText(L10n.Text("common.teams.execution_separate")));
        TeamEditor(L10n.Text("common.teams.invite_member"), fields, L10n.Text("common.teams.invite_member"), () => model.Manager && !model.Busy && ValidHandle(handle.Text),
            () => model.Mutate("invitations.create", model.Invite(handle.Text, PickedRole(role) ?? "member", choices.Where(item => PickedRole(item.Value) is not null).ToDictionary(item => item.Key, item => PickedRole(item.Value)!))),
            back, _ => back(), invitationLink: true, client: client);
    }
    private async Task ShowTeamAccessAsync(TeamDirectoryClient client, TeamManagementModel model, JsonObject repository, TeamManagementRows? previous = null)
    {
        Reset(Text(repository, "name")); var view = _view; var rows = previous ?? new([]); string? error = null;
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.back"), ActionIcon.Back, async (_, _) => { if (IsLoaded && _view == view) await ShowTeamManagementAsync(client, model, "repositories"); }));
        try { var page = await model.RepositoryMembers(repository, previous?.Next ?? 0); rows = new(TeamCatalogPage.Append(rows.Rows, page.Rows), page.Next, true); }
        catch (Exception failure) { error = TeamError(failure); }
        if (!IsLoaded || _view != view) return;
        Note(L10n.Text("common.teams.execution_separate")); if (error is not null) Note(error, true);
        foreach (var member in rows.Rows)
        {
            var card = TeamCard(Text(member, "name"), TeamRole(Text(member, "role")));
            if (!Flag(member, "eligible")) card.Children.Add(TeamText(L10n.Text("common.teams.needs_patron")));
            card.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.manage_access"), ActionIcon.Security, (_, _) => {
                if (!IsLoaded || _view != view) return;
                var fields = TeamCard(Text(repository, "name") + " · " + Text(member, "name"), L10n.Text("common.teams.execution_separate"));
                var role = TeamRoles(Text(member, "role").Length == 0 ? null : Text(member, "role"), [null, "viewer", "contributor", "maintainer"], L10n.Text("common.teams.repository_access")); fields.Children.Add(role);
                fields.Children.Add(TeamText(L10n.Text("common.teams.access_reduction_detail")));
                TeamEditor(L10n.Text("common.teams.repository_access"), fields, L10n.Text("common.save"), () => model.Active && (PickedRole(role) ?? "") != Text(member, "role"),
                    () => model.Mutate("repositories.access", model.Access(repository, member, PickedRole(role)), user: Text(member, "id"), repository: Text(repository, "id")),
                    () => ShowTeamAccessAsync(client, model, repository), _ => ShowTeamAccessAsync(client, model, repository));
            })); _body.Children.Add(card);
        }
        if (rows.Next is not null || error is not null) _body.Children.Add(ActionIconGlyph.Button(L10n.Text(error is null ? "common.teams.load_more" : "common.retry"), ActionIcon.More, async (_, _) => {
            if (IsLoaded && _view == view) await ShowTeamAccessAsync(client, model, repository, rows.Next is not null ? rows : null);
        }));
    }
    private void AddTeamSettings(TeamDirectoryClient client, TeamManagementModel model, Func<Task> back, Func<bool> alive)
    {
        if (model.Manager) _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.rename_organization"), ActionIcon.Edit, (_, _) => {
            if (!alive()) return; var fields = new StackPanel { Spacing = Theme.SpaceM };
            var name = new TextBox { Header = L10n.Text("common.teams.organization_name"), Text = Text(model.Organization, "name"), MaxLength = 80 }; fields.Children.Add(name);
            TeamEditor(L10n.Text("common.teams.rename_organization"), fields, L10n.Text("common.save"), () => model.Manager && ValidName(name.Text) && name.Text.Trim() != Text(model.Organization, "name"),
                () => model.Mutate("organizations.rename", model.Rename(name.Text)), back, _ => back());
        }));
        if (model.CurrentOwner)
        {
            Note(L10n.Text(model.Active ? "common.teams.owner_detail" : "common.teams.owner_plan_recovery"));
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.transfer_ownership"), ActionIcon.Move, async (_, _) => { if (alive()) await ShowTeamTransferAsync(client, model, back); }));
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.delete_organization"), ActionIcon.Delete, (_, _) => {
                if (!alive()) return; var org = (JsonObject)model.Organization.DeepClone();
                var fields = TeamCard(Text(org, "name"), L10n.Text("common.teams.delete_confirmation_detail"));
                var typed = new TextBox { Header = L10n.Text("common.teams.type_name_to_delete", Text(org, "name")), IsSpellCheckEnabled = false }; fields.Children.Add(typed);
                TeamEditor(L10n.Text("common.teams.delete_organization"), fields, L10n.Text("common.teams.delete_organization"), () => model.CurrentOwner && typed.Text == Text(org, "name"),
                    () => model.Mutate("organizations.delete", model.Delete(typed.Text, org)), back, async _ => { _organization = null; await LoadAsync(); });
            }));
        }
        else if (model.Verified && model.Role is "member" or "admin")
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.leave_organization"), ActionIcon.SignOut, (_, _) => {
                if (!alive()) return; var org = (JsonObject)model.Organization.DeepClone();
                TeamEditor(L10n.Text("common.teams.leave_organization"), TeamCard(Text(org, "name"), L10n.Text("common.teams.leave_confirmation_detail")), L10n.Text("common.teams.leave_organization"), () => model.Verified && model.Role is "member" or "admin",
                    () => model.Mutate("members.remove", model.Leave(org), user: client.Person), back, async _ => { _organization = null; await LoadAsync(); }, confirmation: true);
            }));
    }
    private async Task ShowTeamTransferAsync(TeamDirectoryClient client, TeamManagementModel model, Func<Task> back, bool more = false)
    {
        Reset(L10n.Text("common.teams.transfer_ownership")); var view = _view;
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.back"), ActionIcon.Back, async (_, _) => { if (IsLoaded && _view == view) await back(); }));
        string? error = null; try { await model.Refresh("members", more); } catch (Exception failure) { error = TeamError(failure); }
        if (!IsLoaded || _view != view) return;
        if (error is not null) Note(error, true);
        Note(L10n.Text("common.teams.transfer_detail")); var count = 0;
        foreach (var member in model.Members.Rows.Where(row => Text(row, "id") != Text(model.Organization, "ownerId") && Flag(row, "ownershipEligible")))
        {
            count++; _body.Children.Add(ActionIconGlyph.Button(Text(member, "name"), ActionIcon.Move, (_, _) => {
                if (!IsLoaded || _view != view || !model.CurrentOwner) return;
                var org = (JsonObject)model.Organization.DeepClone();
                TeamEditor(L10n.Text("common.teams.transfer_ownership"), TeamCard(Text(member, "name"), L10n.Text("common.teams.transfer_confirmation_detail")), L10n.Text("common.teams.send_ownership_request"), () => model.CurrentOwner,
                    () => model.Mutate("ownership.request", model.Transfer(member, org)), back, _ => back(), confirmation: true);
            }));
        }
        if (count == 0) Note(L10n.Text("common.teams.no_eligible_owner"));
        if (model.Members.Next is not null || error is not null) _body.Children.Add(ActionIconGlyph.Button(L10n.Text(error is null ? "common.teams.load_more" : "common.retry"), ActionIcon.More, async (_, _) => {
            if (IsLoaded && _view == view) await ShowTeamTransferAsync(client, model, back, model.Members.Next is not null);
        }));
    }
    private void ReviewTeamOwnership(TeamDirectoryClient client, TeamManagementModel model, JsonObject request, bool cancelling, Func<Task> back)
    {
        var title = L10n.Text(cancelling ? "common.teams.cancel_ownership_request" : "common.teams.accept_ownership");
        TeamEditor(title, TeamCard(Text(model.Organization, "name"), L10n.Text(cancelling ? "common.teams.cancel_ownership_detail" : "common.teams.accept_ownership_confirmation")), title,
            () => model.Verified && JsonNode.DeepEquals(request, model.OwnershipRequest),
            () => model.Mutate(cancelling ? "ownership.cancel" : "ownership.accept", model.OwnershipDecision(request, cancelling)), back, _ => back(), confirmation: true);
    }
    private async Task ShowTeamInboxAsync(TeamDirectoryClient client, TeamInboxModel model, bool more = false)
    {
        Reset(L10n.Text("common.teams.invitations_for_you")); var view = _view;
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.back"), ActionIcon.Back, async (_, _) => { if (IsLoaded && _view == view) await LoadAsync(); }));
        string? error = null; try { model.Close(); await model.Load(more); } catch (Exception failure) { error = TeamError(failure); }
        if (!IsLoaded || _view != view) return;
        Note(L10n.Text("common.teams.inbox_detail")); if (error is not null) Note(error, true);
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.refresh"), ActionIcon.Refresh, async (_, _) => { if (IsLoaded && _view == view) await ShowTeamInboxAsync(client, model); }));
        if (model.Page.Loaded && model.Page.Rows.Count == 0) Note(L10n.Text("common.teams.no_invitations"));
        foreach (var invitation in model.Page.Rows)
        {
            var card = TeamCard(Text(invitation, "organizationName"), TeamRole(Text(invitation, "role")));
            card.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.review_invitation"), ActionIcon.Preview, async (_, _) => {
                if (IsLoaded && _view == view) await ReviewTeamIncomingAsync(client, model, Text(invitation, "id"));
            })); _body.Children.Add(card);
        }
        if (model.Page.Next is not null || error is not null) _body.Children.Add(ActionIconGlyph.Button(L10n.Text(error is null ? "common.teams.load_more" : "common.retry"), ActionIcon.More, async (_, _) => {
            if (IsLoaded && _view == view) await ShowTeamInboxAsync(client, model, model.Page.Next is not null);
        }));
    }
    private async Task ReviewTeamIncomingAsync(TeamDirectoryClient client, TeamInboxModel model, string id)
    {
        Reset(L10n.Text("common.teams.review_invitation")); var view = _view;
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.cancel"), ActionIcon.Dismiss, async (_, _) => { if (IsLoaded && _view == view) { model.Close(); await ShowTeamInboxAsync(client, model); } }));
        try { await model.Review(id); }
        catch (Exception error)
        {
            if (!IsLoaded || _view != view) return; Note(TeamError(error), true);
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => { if (IsLoaded && _view == view) await ReviewTeamIncomingAsync(client, model, id); })); return;
        }
        if (!IsLoaded || _view != view || model.Preview is not { } preview) return;
        var fields = TeamCard(Text(preview["invitation"], "organizationName"), TeamRole(Text(preview["invitation"], "role")));
        if (Flag(preview, "available"))
        {
            var access = preview["repositoryAccess"]!.AsArray();
            if (access.Count == 0) fields.Children.Add(TeamText(L10n.Text("common.teams.join_no_repository_access")));
            foreach (var row in access) fields.Children.Add(TeamText(Text(row, "name") + " · " + TeamRole(Text(row, "role"))));
            fields.Children.Add(TeamText(L10n.Text("common.teams.execution_separate"))); fields.Children.Add(TeamText(L10n.Text("common.teams.join_content_detail")));
        }
        else fields.Children.Add(TeamText(L10n.Text(Text(preview, "unavailableReason") == "organization_paused" ? "common.teams.organization_paused" : "common.teams.invitation_unavailable")));
        if (!Flag(preview, "eligible")) fields.Children.Add(TeamText(L10n.Text("common.teams.patron_invitation")));
        TeamEditor(L10n.Text("common.teams.review_invitation"), fields, L10n.Text("common.teams.join_organization"), () => model.CanJoin,
            async () => await model.Accept(), () => ShowTeamInboxAsync(client, model), async joined => { _organization = joined.AsObject(); await LoadAsync(); });
    }
}
