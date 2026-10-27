// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using static Tokenstat.Pages.TeamManagementModel;

namespace Tokenstat.Pages;

internal sealed partial class TeamsPage
{
    private bool _canResumeSharing;
    private async Task ShowFocusedTeamProjectAsync(JsonObject repository)
    {
        Reset(L10n.Text("common.teams.shared_projects")); var view = _view;
        NavBack(L10n.Text("common.back"), async (_, _) => { if (IsLoaded && _view == view) await ShowAllTeamProjectsAsync(DirectoryClient()); });
        try
        {
            var details = await DirectoryClient().Request("repositories.get", new() { ["organization"] = Text(repository, "organizationId"), ["repository"] = Text(repository, "id") });
            if (!IsLoaded || _view != view) return;
            var fresh = details["repository"] as JsonObject ?? throw new InvalidDataException();
            Require(Text(fresh, "id") == Text(repository, "id") && Text(fresh, "organizationId") == Text(repository, "organizationId")); repository = fresh;
        }
        catch (Exception error) {
            if (IsLoaded && _view == view) { Note(TeamError(error), true); _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => { if (IsLoaded && _view == view) await ShowFocusedTeamProjectAsync(repository); })); } return;
        }
        Reset(Text(repository, "name")); view = _view;
        NavBack(L10n.Text("common.teams.shared_projects"), async (_, _) => { if (IsLoaded && _view == view) await ShowAllTeamProjectsAsync(DirectoryClient()); });
        Note(L10n.Text("common.teams.all_teammates")); Note(L10n.Text("common.teams.shared_project_chats_detail"));
        await AddRepositoryAsync(Text(repository, "organizationId"), repository);
    }
    private async Task ShowAllTeamProjectsAsync(TeamDirectoryClient client)
    {
        Reset(L10n.Text("common.teams.shared_projects")); var view = _view;
        Note(L10n.Text("common.teams.shared_projects_detail"));
        var localProjects = new HashSet<string>(StringComparer.Ordinal); var localKnown = false;
        if (_canPublish) try {
            var localOffset = 0;
            while (true) {
                var page = TeamDirectoryPage.Read(await client.Call("teams.checkout.list", new() { ["page"] = Page100(localOffset) }), "publications", localOffset);
                if (!IsLoaded || _view != view) return;
                foreach (var row in page.Rows.Where(row => Text(row, "phase") == "active" && !Flag(row, "accountCleanupPending"))) localProjects.Add(Text(row, "organizationId") + "/" + Text(row, "repositoryId"));
                if (page.Next is not { } next) break; localOffset = next;
            }
            localKnown = true;
        } catch { }
        Trail(Buttons.Secondary(L10n.Text("common.teams.manage_teams"), ActionIcon.Settings, async (_, _) => { if (IsLoaded && _view == view) await LoadAsync(); }));
        Tool(ActionIcon.Refresh, L10n.Text("common.refresh"), async (_, _) => {
            if (!IsLoaded || _view != view) return;
            _startSharedProjects = true; await LoadAsync();
        });
        foreach (var organization in _organizations)
        {
            var group = new StackPanel { Spacing = Theme.SpaceS }; var projects = Rows(); group.Children.Add(projects);
            Section(Text(organization, "name"), group, null, ActionIcon.Source);
            var next = (int?)0; var seen = new HashSet<string>(); var busy = false; Button? more = null; var error = TeamText(""); group.Children.Add(error);
            async Task LoadMore()
            {
                if (busy || next is not { } offset || !IsLoaded || _view != view) return; busy = true; more!.IsEnabled = false;
                try
                {
                    var page = TeamDirectoryPage.Read(await client.Request("repositories.list", new() { ["organization"] = Text(organization, "id"), ["page"] = Page100(offset) }), "repositories", offset);
                    if (!IsLoaded || _view != view) return;
                    Require(page.Rows.All(repo => Text(repo, "organizationId") == Text(organization, "id")));
                    // A project nobody shares any more is not shared with anyone, unless
                    // this computer's own sharing is newer than the count.
                    foreach (var repo in page.Rows.Where(repo => Text(repo, "role") is "viewer" or "contributor" or "maintainer"
                        && (Shared(repo) || localProjects.Contains(Text(repo, "organizationId") + "/" + Text(repo, "id"))))) if (seen.Add(Text(repo, "id")))
                    {
                        var where = localKnown ? L10n.Text(localProjects.Contains(Text(repo, "organizationId") + "/" + Text(repo, "id")) ? "common.teams.shared_from_this_computer" : "common.teams.shared_with_you") : null;
                        var mark = ActionIcon.Source.Mark(16); ((FrameworkElement)mark).Opacity = 0.8;
                        var open = Buttons.Secondary(L10n.Text("common.teams.open_shared_project"), ActionIcon.Connect, async (_, _) => { if (IsLoaded && _view == view) await ShowFocusedTeamProjectAsync(repo); }, small: true);
                        AddRow(projects, Row(Marked(mark, Labelled(Text(repo, "name"), where)), Badge(TeamRole(Text(repo, "role"))), open));
                    }
                    next = page.Next; error.Text = seen.Count == 0 && next is null ? L10n.Text("common.teams.no_shared_projects") : "";
                    more.Visibility = next is null ? Visibility.Collapsed : Visibility.Visible;
                }
                catch (Exception failure) { if (IsLoaded && _view == view) { error.Text = TeamError(failure); more.Visibility = Visibility.Visible; } }
                finally { busy = false; if (IsLoaded && _view == view) more.IsEnabled = true; }
            }
            more = ActionIconGlyph.Button(L10n.Text("common.teams.load_more"), ActionIcon.More, async (_, _) => await LoadMore()); group.Children.Add(more);
            await LoadMore(); if (!IsLoaded || _view != view) return;
        }
        if (_organizations.Count == 0) Note(L10n.Text("common.teams.no_shared_projects"));
        if (_organizationsNext is { } offset) _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.more_organizations"), ActionIcon.More, async (_, _) => {
            if (!IsLoaded || _view != view) return;
            try
            {
                var page = TeamDirectoryPage.Read(await client.Request("organizations.list", new() { ["page"] = Page100(offset) }), "organizations", offset);
                if (!IsLoaded || _view != view) return; _organizations = TeamCatalogPage.Append(_organizations, page.Rows); _organizationsNext = page.Next;
                await ShowAllTeamProjectsAsync(client);
            }
            catch (Exception error) { if (IsLoaded && _view == view) Note(TeamError(error), true); }
        }));
    }
    private ComboBox FolderTeamPicker(TeamDirectoryClient client, JsonObject workspace, string? selected, bool locked, int? viewToken = null)
    {
        var picker = new ComboBox { Header = L10n.Text("common.teams.title"), IsEnabled = !locked, HorizontalAlignment = HorizontalAlignment.Stretch };
        picker.Items.Add(new ComboBoxItem { Content = L10n.Text("common.teams.choose_team"), Tag = "" });
        foreach (var org in _organizations.Where(org => Text(org, "state") == "active" && Flag(org, "eligible"))) picker.Items.Add(new ComboBoxItem { Content = Text(org, "name"), Tag = Text(org, "id") });
        picker.SelectedIndex = picker.Items.OfType<ComboBoxItem>().ToList().FindIndex(item => (string?)item.Tag == (selected ?? ""));
        var view = viewToken ?? _view;
        picker.SelectionChanged += async (_, _) => {
            if (IsLoaded && _view == view && !locked) await ShowFolderShareAsync(client, workspace, _organizations.FirstOrDefault(org => Text(org, "id") == (string?)(picker.SelectedItem as ComboBoxItem)?.Tag));
        }; return picker;
    }
    private async Task ShowFolderShareAsync(TeamDirectoryClient client, JsonObject workspace, JsonObject? organization = null)
    {
        Reset(L10n.Text("common.teams.share_project")); var view = _view;
        if (!_canPublish) { Note(L10n.Text("common.teams.publish_on_computer")); AddTeamDirectoryActions(); return; }
        _body.Children.Add(TeamText(Text(workspace, "name")));
        var teamSelector = FolderTeamPicker(client, workspace, organization is null ? null : Text(organization, "id"), false);
        _body.Children.Add(teamSelector);
        _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.cancel"), ActionIcon.Dismiss, async (_, _) => { if (IsLoaded && _view == view) { _folderShareRequest = null; await LoadAsync(); } }));
        if (_organizationsNext is { } offset) _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.more_organizations"), ActionIcon.More, async (_, _) => {
            if (!IsLoaded || _view != view) return;
            try { var page = TeamDirectoryPage.Read(await client.Request("organizations.list", new() { ["page"] = Page100(offset) }), "organizations", offset);
                if (!IsLoaded || _view != view) return; _organizations = TeamCatalogPage.Append(_organizations, page.Rows); _organizationsNext = page.Next; await ShowFolderShareAsync(client, workspace, organization); }
            catch (Exception error) { if (IsLoaded && _view == view) Note(TeamError(error), true); }
        }));
        if (organization is null && _canResumeSharing)
        {
            try
            {
                var pending = (await client.Call("teams.projectSharing.read", new() { ["workspace"] = Text(workspace, "id") }))["setup"] as JsonObject;
                if (!IsLoaded || _view != view) return;
                if (pending is not null)
                {
                    var orgId = Text(pending, "organizationId"); var pages = 0;
                    while (!_organizations.Any(row => Text(row, "id") == orgId) && _organizationsNext is { } next && pages++ < 50)
                    {
                        var page = TeamDirectoryPage.Read(await client.Request("organizations.list", new() { ["page"] = Page100(next) }), "organizations", next);
                        if (!IsLoaded || _view != view) return;
                        _organizations = TeamCatalogPage.Append(_organizations, page.Rows); _organizationsNext = page.Next;
                    }
                    var original = _organizations.SingleOrDefault(row => Text(row, "id") == orgId);
                    if (original is not null && Text(original, "state") == "active" && Flag(original, "eligible"))
                    { await ShowFolderShareAsync(client, workspace, original); return; }
                    Require(_organizationsNext is null || original is not null);
                    teamSelector.IsEnabled = false;
                    Note(L10n.Text("common.teams.project_setup_team_unavailable"), true);
                    _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.project_setup_start_over"), ActionIcon.Refresh, (_, _) => {
                        if (!IsLoaded || _view != view) return;
                        var review = TeamCard(Text(workspace, "name"), L10n.Text("common.teams.project_setup_discard_detail"));
                        TeamEditor(L10n.Text("common.teams.project_setup_start_over"), review, L10n.Text("common.teams.project_setup_start_over"), () => true,
                            () => client.Call("teams.projectSharing.discard", new() { ["setup"] = Text(pending, "id"), ["confirmDiscard"] = true }),
                            () => ShowFolderShareAsync(client, workspace), _ => ShowFolderShareAsync(client, workspace), confirmation: true);
                    }));
                    return;
                }
            }
            catch (Exception error)
            {
                if (!IsLoaded || _view != view) return;
                teamSelector.IsEnabled = false; Note(TeamError(error), true);
                _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => { if (IsLoaded && _view == view) await ShowFolderShareAsync(client, workspace); }));
                return;
            }
        }
        if (organization is null) { Note(L10n.Text("common.teams.choose_team")); return; }
        try { var model = new TeamFolderShareModel(client, workspace, organization, _canResumeSharing); await model.Load(); if (IsLoaded && _view == view) DrawFolderShare(client, model); }
        catch (Exception error)
        {
            if (!IsLoaded || _view != view) return; Note(TeamError(error), true);
            _body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.retry"), ActionIcon.Refresh, async (_, _) => { if (IsLoaded && _view == view) await ShowFolderShareAsync(client, workspace, organization); }));
        }
    }
    private void DrawFolderShare(TeamDirectoryClient client, TeamFolderShareModel model, string? error = null)
    {
        var fields = TeamCard(Text(model.Workspace, "name"), L10n.Text("common.teams.project_sharing_review"));
        // TeamEditor performs the redraw below; bind controls to that view.
        var nextView = _view + 1;
        var picker = FolderTeamPicker(client, model.Workspace, Text(model.Organization, "id"), model.Locked, nextView);
        fields.Children.Add(picker);
        if (_organizationsNext is { } orgOffset && !model.Locked) fields.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.more_organizations"), ActionIcon.More, async (_, _) => {
            if (!IsLoaded || _view != nextView) return;
            try { var page = TeamDirectoryPage.Read(await client.Request("organizations.list", new() { ["page"] = Page100(orgOffset) }), "organizations", orgOffset);
                if (!IsLoaded || _view != nextView) return; _organizations = TeamCatalogPage.Append(_organizations, page.Rows); _organizationsNext = page.Next; DrawFolderShare(client, model); }
            catch (Exception failure) { if (IsLoaded && _view == nextView) DrawFolderShare(client, model, TeamError(failure)); }
        }));
        var name = new TextBox { Header = L10n.Text("common.teams.repository_name"), Text = model.Name, IsEnabled = !model.Locked, MaxLength = 80 };
        var choices = new ComboBox { Header = L10n.Text("common.teams.project_details"), IsEnabled = !model.Locked || model.NeedsRepositoryChoice, HorizontalAlignment = HorizontalAlignment.Stretch };
        choices.Items.Add(new ComboBoxItem { Content = L10n.Text(model.CanCreate && !model.NeedsRepositoryChoice ? "common.teams.new_repository" : "common.teams.choose_repository"), Tag = "" });
        foreach (var repo in model.Repositories.Rows.Where(repo => Text(repo, "role") is "contributor" or "maintainer")) choices.Items.Add(new ComboBoxItem { Content = Text(repo, "name"), Tag = Text(repo, "id") });
        choices.SelectedIndex = model.Existing is null ? 0 : choices.Items.OfType<ComboBoxItem>().ToList().FindIndex(item => (string?)item.Tag == Text(model.Existing, "id"));
        choices.SelectionChanged += (_, _) => { if ((!model.Locked || model.NeedsRepositoryChoice) && IsLoaded && _view == nextView) { var id = (choices.SelectedItem as ComboBoxItem)?.Tag as string; model.ChooseExisting(string.IsNullOrEmpty(id) ? null : id); DrawFolderShare(client, model); } };
        fields.Children.Add(choices);
        if (model.Repositories.Next is not null && (!model.Locked || model.NeedsRepositoryChoice)) fields.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.load_more"), ActionIcon.More, async (_, _) => {
            if (!IsLoaded || _view != nextView) return;
            try { await model.LoadRepositories(true); if (IsLoaded && _view == nextView) DrawFolderShare(client, model); } catch (Exception failure) { if (IsLoaded && _view == nextView) DrawFolderShare(client, model, TeamError(failure)); }
        }));
        if ((model.Existing is null || model.SavedSetup is not null) && model.CanCreate)
        {
            fields.Children.Add(name); name.TextChanged += (_, _) => { if (!model.Locked) model.Name = name.Text; };
            if (model.Collision is { } collision && !model.Locked)
            {
                fields.Children.Add(TeamText(L10n.Text("common.teams.project_already_exists", Text(collision, "name"))));
                if (Text(collision, "role") is "contributor" or "maintainer") fields.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.use_existing_project", Text(collision, "name")), ActionIcon.Connect, (_, _) => {
                    if (IsLoaded && _view == nextView) { model.ChooseExisting(Text(collision, "id")); DrawFolderShare(client, model); }
                }));
            }
            fields.Children.Add(TeamText(L10n.Text("common.teams.project_access_review")));
            var access = TeamRoles(model.AccessRole, ["viewer", "contributor"], L10n.Text("common.teams.repository_access")); access.IsEnabled = !model.Locked;
            access.SelectionChanged += (_, _) => { if (!model.Locked) model.AccessRole = PickedRole(access) ?? "contributor"; }; fields.Children.Add(access);
            foreach (var member in model.Members.Rows.Where(row => Text(row, "id") != client.Person))
            {
                var id = Text(member, "id"); var box = new CheckBox { Content = Text(member, "name"), IsChecked = model.Included.Contains(id), IsEnabled = Flag(member, "eligible") && !model.Locked };
                box.Checked += (_, _) => { if (!model.Locked) model.Included.Add(id); }; box.Unchecked += (_, _) => { if (!model.Locked) model.Included.Remove(id); }; fields.Children.Add(box);
                if (!Flag(member, "eligible")) fields.Children.Add(TeamText(L10n.Text("common.teams.needs_patron")));
            }
        }
        else fields.Children.Add(TeamText(L10n.Text(model.Existing is null ? "common.teams.no_repositories_member" : "common.teams.project_existing_access")));
        if (model.Created is not null) fields.Children.Add(TeamText(L10n.Text("common.teams.project_setup_partial")));
        if (model.SavedSetup is not null)
        {
            fields.Children.Add(TeamText(model.NeedsRepositoryChoice ? L10n.Text("common.teams.project_setup_unknown") : L10n.Text("common.teams.project_setup_saved")));
            fields.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.project_setup_start_over"), ActionIcon.Refresh, (_, _) => {
                if (!IsLoaded || _view != nextView) return;
                var review = TeamCard(L10n.Text("common.teams.project_setup_start_over"), L10n.Text("common.teams.project_setup_discard_detail"));
                TeamEditor(L10n.Text("common.teams.project_setup_start_over"), review, L10n.Text("common.teams.project_setup_start_over"), () => true,
                    async () => { await model.DiscardSetup(); return new JsonObject(); },
                    () => { DrawFolderShare(client, model); return Task.CompletedTask; },
                    _ => { DrawFolderShare(client, model); return Task.CompletedTask; }, confirmation: true);
            }));
        }
        if (error is not null) fields.Children.Add(TeamText(error));
        if (model.Members.Next is not null && !model.Locked) fields.Children.Add(ActionIconGlyph.Button(L10n.Text("common.teams.load_more"), ActionIcon.More, async (_, _) => {
            if (!IsLoaded || _view != nextView) return;
            try { await model.LoadMembers(true); if (IsLoaded && _view == nextView) DrawFolderShare(client, model); } catch (Exception failure) { if (IsLoaded && _view == nextView) DrawFolderShare(client, model, TeamError(failure)); }
        }));
        TeamEditor(L10n.Text("common.teams.share_project"), fields, L10n.Text("common.teams.share_project"), () => model.CanShare, async () => {
            try { var result = await model.Share(); return new JsonObject { ["repository"] = result.Repository.DeepClone(), ["publication"] = result.Publication.DeepClone() }; }
            catch (Exception failure) {
                if (failure is Tokenstat.Host.HostException { Code: "repository_exists" }) try { await model.LoadRepositories(); } catch { }
                if (IsLoaded && _view == nextView) DrawFolderShare(client, model, TeamError(failure)); throw;
            }
        }, async () => { _folderShareRequest = null; await LoadAsync(); }, async result => { _initialProject = result["repository"]!.AsObject(); _folderShareRequest = null; AppServices.NotifyTeamProjectsChanged(); await LoadAsync(); }, confirmation: true);
    }
}
