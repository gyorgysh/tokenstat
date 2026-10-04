// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal static class WorkspacePullCreate
{
    private sealed class Draft
    {
        public string Title = "";
        public string Body = "";
        public string Base = "";
        public bool IsDraft = true;
        public string BranchName = "";
    }
    private static readonly Dictionary<string, Draft> Drafts = new();

    public static async Task ShowAsync(UIElement owner, string workspaceId, string folderName,
        Func<string, JsonNode?, Task<JsonNode>> call)
    {
        try
        {
            var spoken = await RemoteWorkspaces.CallWorkspaceAsync(workspaceId, "protocol");
            if (!int.TryParse(Format.Text(spoken, "protocolVersion"), out var version) || version < 28)
            {
                await Chrome.ShowDialog(owner, new ContentDialog { Title = L10n.Text("windows.pullcreate.new"),
                    Content = Copy(L10n.Text("windows.pullcreate.update_host")), CloseButtonText = L10n.Text("common.close") });
                return;
            }
        }
        catch (Exception ex)
        {
            await Chrome.ShowDialog(owner, new ContentDialog { Title = L10n.Text("windows.pullcreate.new"),
                Content = Copy(ex.Message), CloseButtonText = L10n.Text("common.close") });
            return;
        }
        var ownerIdentity = await BrowserProjectMemory.ForAsync(workspaceId);
        var draftKey = ownerIdentity?.Owner;
        var draft = draftKey is not null && Drafts.TryGetValue(draftKey, out var saved) ? saved : new Draft();
        if (draftKey is not null) Drafts[draftKey] = draft;
        string? error = null;
        JsonNode? context = null;
        while (true)
        {
            if (ownerIdentity is not null && !ownerIdentity.IsCurrent) return;
            try { context = await call("pulls.prepareCreate", new JsonObject { ["workspaceId"] = workspaceId }); }
            // A failed check must not leave the last branch and commit in
            // place, or Create would offer a state nobody just confirmed.
            catch (Exception ex) { error = ex.Message; context = null; }
            if (draft.Base.Length == 0) draft.Base = Format.Text(context, "defaultBase");
            var branch = Format.Text(context, "branch");
            var published = context?["published"]?.GetValue<bool>() == true;
            var files = context?["files"] as JsonArray;
            var name = new TextBox { PlaceholderText = L10n.Text("windows.pullcreate.branch_name"), Text = draft.BranchName };
            var title = new TextBox { Header = L10n.Text("windows.pullcreate.title"), Text = draft.Title };
            var body = new TextBox { Header = L10n.Text("windows.pullcreate.description"), Text = draft.Body, AcceptsReturn = true, MinHeight = 100, TextWrapping = TextWrapping.Wrap };
            var target = new TextBox { Header = L10n.Text("windows.pullcreate.base"), Text = draft.Base };
            var isDraft = new CheckBox { Content = L10n.Text("windows.pullcreate.draft"), IsChecked = draft.IsDraft };
            string action = "";
            var stack = new StackPanel { Spacing = Theme.SpaceM };
            var dialog = new ContentDialog
            {
                Title = L10n.Text("windows.pullcreate.new"),
                Content = new ScrollViewer { Content = stack, MaxHeight = 620 },
                CloseButtonText = L10n.Text("common.close"),
                PrimaryButtonText = L10n.Text("windows.pullcreate.create"),
            };
            void Save() { draft.Title = title.Text; draft.Body = body.Text; draft.Base = target.Text.Trim(); draft.IsDraft = isDraft.IsChecked == true; draft.BranchName = name.Text; }
            void Choose(string next) { Save(); action = next; dialog.Hide(); }
            void Enable() => dialog.IsPrimaryButtonEnabled = published && branch.Length > 0 && target.Text.Trim().Length > 0 && branch != target.Text.Trim() && !string.IsNullOrWhiteSpace(title.Text);
            title.TextChanged += (_, _) => Enable();
            target.TextChanged += (_, _) => Enable();
            stack.Children.Add(Copy(L10n.Text("windows.pullcreate.step_branch")));
            stack.Children.Add(Copy(L10n.Text("windows.pullcreate.branch_help", branch)));
            stack.Children.Add(name);
            stack.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.pullcreate.make_branch"), ActionIcon.Create, (_, _) => { if (!string.IsNullOrWhiteSpace(name.Text)) Choose("branch"); }));
            stack.Children.Add(Copy(L10n.Text("windows.pullcreate.step_commit")));
            stack.Children.Add(Copy(L10n.Text("windows.pullcreate.files_help", (files?.Count ?? 0).ToString())));
            var selection = WorkspaceCommitSession.For(workspaceId);
            var commit = ActionIconGlyph.Button(L10n.Text("windows.pullcreate.review_commit"), ActionIcon.Commit, (_, _) => Choose("commit"));
            void EnableCommit() => commit.IsEnabled = branch.Length > 0 && branch != target.Text.Trim()
                && (selection.SubmittedOperationId is not null || (files?.Count > 0 && selection.Paths.Count > 0));
            foreach (var file in files ?? new JsonArray())
            {
                var path = Format.Text(file, "path");
                var toggle = new CheckBox { Content = path, IsChecked = selection.Paths.Contains(path), IsEnabled = selection.SubmittedOperationId is null };
                toggle.Checked += (_, _) => { if (!selection.Paths.Contains(path)) selection.Select(path); EnableCommit(); };
                toggle.Unchecked += (_, _) => { if (selection.Paths.Contains(path)) selection.Select(path); EnableCommit(); };
                stack.Children.Add(toggle);
            }
            EnableCommit();
            stack.Children.Add(commit);
            stack.Children.Add(Copy(L10n.Text("windows.pullcreate.step_publish")));
            stack.Children.Add(Copy(published ? L10n.Text("windows.pullcreate.published") : L10n.Text("windows.pullcreate.publish_help")));
            var push = ActionIconGlyph.Button(L10n.Text("windows.pullcreate.publish"), ActionIcon.Upload, (_, _) => Choose("push"));
            void EnablePush() => push.IsEnabled = branch.Length > 0 && branch != target.Text.Trim();
            EnablePush();
            target.TextChanged += (_, _) => { EnableCommit(); EnablePush(); };
            stack.Children.Add(push);
            stack.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.pullcreate.check"), ActionIcon.Refresh, (_, _) => Choose("check")));
            stack.Children.Add(Copy(L10n.Text("windows.pullcreate.step_describe")));
            stack.Children.Add(target); stack.Children.Add(title); stack.Children.Add(body); stack.Children.Add(isDraft);
            stack.Children.Add(Copy(L10n.Text("windows.pullcreate.final_help")));
            var problem = error ?? Format.Text(context, "problem");
            if (!string.IsNullOrEmpty(problem)) stack.Children.Add(Copy(problem));
            Enable();
            var result = await Chrome.ShowDialog(owner, dialog);
            Save();
            if (ownerIdentity is not null && !ownerIdentity.IsCurrent) return;
            if (result == ContentDialogResult.Primary) action = "create";
            if (action.Length == 0) return;
            error = null;
            try
            {
                switch (action)
                {
                    case "branch":
                        var made = await RemoteWorkspaces.CallWorkspaceAsync(workspaceId, "workspace.createBranch", new JsonObject { ["id"] = workspaceId, ["branch"] = name.Text.Trim() });
                        if (made?["ok"]?.GetValue<bool>() != true) error = Format.Text(made, "message");
                        else draft.BranchName = "";
                        break;
                    case "commit":
                        var session = WorkspaceCommitSession.For(workspaceId);
                        await session.PrepareReviewAsync(workspaceId);
                        await WorkspaceCommitComposer.ShowAsync(owner, workspaceId, folderName, branch);
                        break;
                    case "push": await WorkspacePushDialog.ShowAsync(owner, workspaceId, folderName); break;
                    case "create":
                        var created = await call("pulls.create", new JsonObject {
                            ["workspaceId"] = workspaceId, ["branch"] = branch, ["expectedHead"] = Format.Text(context, "head"),
                            ["expectedRepository"] = Format.Text(context, "repository"),
                            ["base"] = draft.Base, ["title"] = draft.Title, ["body"] = draft.Body, ["draft"] = draft.IsDraft,
                        });
                        var url = Format.Text(created, "url");
                        var existing = Format.Flag(created, "existing");
                        var open = true;
                        if (existing)
                        {
                            var kept = new StackPanel { Spacing = Theme.SpaceM };
                            kept.Children.Add(Copy(L10n.Text("windows.pullcreate.existing_help")));
                            kept.Children.Add(Copy(draft.Title));
                            kept.Children.Add(Copy(draft.Body));
                            var confirmation = await Chrome.ShowDialog(owner, new ContentDialog {
                                Title = L10n.Text("windows.pullcreate.existing", Format.Text(created, "number")),
                                Content = new ScrollViewer { Content = kept, MaxHeight = 450 },
                                PrimaryButtonText = L10n.Text("windows.pullcreate.open"), CloseButtonText = L10n.Text("common.close"),
                            });
                            open = confirmation == ContentDialogResult.Primary;
                        }
                        if (open && Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme == "https") await Windows.System.Launcher.LaunchUriAsync(uri);
                        if (!existing && draftKey is not null) Drafts.Remove(draftKey);
                        return;
                }
            }
            catch (Exception ex) { error = ex.Message; }
        }
    }

    private static TextBlock Copy(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
}
