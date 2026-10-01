// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>
/// The reviewed push flow for one workspace, matching the Mac workbench.
/// Opening the dialog restores the pending submission; it never reads a
/// remote and never pushes on its own. One entry per workspace id, so a
/// lost response is reconciled rather than re-sent.
/// </summary>
internal sealed class WorkspacePushSession
{
    private static readonly Dictionary<string, WorkspacePushSession> Sessions = new();

    public static WorkspacePushSession For(string workspaceId)
    {
        if (!Sessions.TryGetValue(workspaceId, out var session))
        {
            session = new WorkspacePushSession();
            Sessions[workspaceId] = session;
        }
        return session;
    }

    public JsonNode? Review;
    public string? SubmittedOperationId;
    public string SubmittedReviewJson = "";
    public string? OutcomeState;
    public string OutcomeMessage = "";
    public bool Working;
    public bool CanRetry;
    public string? Error;

    public string BranchName =>
        WorkspaceGit.ShortBranch(Format.Text(Review, "branch"));

    public string Destination
    {
        get
        {
            var remote = Format.Text(Review, "remote");
            var remoteRef = Format.Text(Review, "remoteRef");
            if (remoteRef.StartsWith("refs/heads/", StringComparison.Ordinal))
            {
                remoteRef = remoteRef["refs/heads/".Length..];
            }
            return string.IsNullOrEmpty(remote) ? remoteRef : remote + "/" + remoteRef;
        }
    }

    public string Head => Format.Text(Review, "head");
    public string? RemoteHead => Review?["remoteHead"]?.GetValue<string>();
    public ulong? Outgoing => Review?["outgoing"]?.GetValue<ulong?>();
    public bool SetUpstream => Format.Flag(Review, "setUpstream");
    public bool UpToDate => RemoteHead == Head;

    public bool CanSubmit =>
        !Working
        && SubmittedOperationId is null
        && Review is not null
        && !UpToDate
        && (Outgoing is null || Outgoing > 0);

    public bool IsDone =>
        OutcomeState == "succeeded" || UpToDate || Outgoing == 0;

    public async Task PrepareAsync(string workspaceId)
    {
        if (Working)
        {
            return;
        }
        await LoadAsync(workspaceId);
        if (Working || SubmittedOperationId is not null)
        {
            return;
        }
        Working = true;
        Error = null;
        try
        {
            Review = await RemoteWorkspaces.CallWorkspaceAsync(
                workspaceId,
                "workspace.pushReview",
                new JsonObject { ["id"] = workspaceId });
            OutcomeState = null;
            OutcomeMessage = "";
        }
        catch (Exception ex)
        {
            Error = ex.Message;
        }
        finally
        {
            Working = false;
        }
    }

    public async Task SubmitAsync(string workspaceId)
    {
        if (!CanSubmit || Review is null)
        {
            return;
        }
        Working = true;
        Error = null;
        var operationId = Guid.NewGuid().ToString("N");
        SubmittedOperationId = operationId;
        SubmittedReviewJson = Review.ToJsonString();
        try
        {
            var receipt = await RemoteWorkspaces.CallWorkspaceAsync(
                workspaceId,
                "workspace.pushReviewed",
                new JsonObject
                {
                    ["id"] = workspaceId,
                    ["operationId"] = operationId,
                    ["review"] = Review.DeepClone(),
                    ["retry"] = false,
                });
            Adopt(receipt);
        }
        catch (Exception ex)
        {
            Error = L10n.Text("windows.workspacepush.the_push_outcome_has_not_been_confirmed_ch.128c6a9f", $"{ex.Message}");
        }
        finally
        {
            Working = false;
        }
    }

    public async Task CheckOutcomeAsync(string workspaceId)
    {
        if (Working || SubmittedOperationId is null)
        {
            return;
        }
        Working = true;
        Error = null;
        try
        {
            var receipt = await RemoteWorkspaces.CallWorkspaceAsync(
                workspaceId,
                "workspace.pushReceipt",
                new JsonObject
                {
                    ["id"] = workspaceId,
                    ["operationId"] = SubmittedOperationId,
                });
            if (receipt is null)
            {
                CanRetry = true;
                Error = L10n.Text("windows.workspacepush.this_computer_has_no_receipt_for_the_submi.cadba34a");
            }
            else if (!IsFinished(Format.Text(receipt, "state")))
            {
                var recovered = await RemoteWorkspaces.CallWorkspaceAsync(
                    workspaceId,
                    "workspace.pushRecover",
                    new JsonObject
                    {
                        ["id"] = workspaceId,
                        ["operationId"] = SubmittedOperationId,
                    });
                Adopt(recovered);
            }
            else
            {
                Adopt(receipt);
            }
        }
        catch (Exception ex)
        {
            Error = ex.Message;
        }
        finally
        {
            Working = false;
        }
    }

    public async Task RetryAsync(string workspaceId)
    {
        if (Working || !CanRetry || SubmittedOperationId is null || SubmittedReviewJson.Length == 0)
        {
            return;
        }
        Working = true;
        Error = null;
        CanRetry = false;
        try
        {
            var review = JsonNode.Parse(SubmittedReviewJson);
            var receipt = await RemoteWorkspaces.CallWorkspaceAsync(
                workspaceId,
                "workspace.pushReviewed",
                new JsonObject
                {
                    ["id"] = workspaceId,
                    ["operationId"] = SubmittedOperationId,
                    ["review"] = review,
                    ["retry"] = true,
                });
            Adopt(receipt);
        }
        catch (Exception ex)
        {
            Error = L10n.Text("windows.workspacepush.the_push_outcome_has_not_been_confirmed_ch.128c6a9f", $"{ex.Message}");
        }
        finally
        {
            Working = false;
        }
    }

    private async Task LoadAsync(string workspaceId)
    {
        // No disk store on Windows: the static session is the store, and it
        // already holds the pending submission. Kept as a step so a later
        // persistent draft has one place to land.
        await Task.CompletedTask;
    }

    private void Adopt(JsonNode? receipt)
    {
        if (Format.Text(receipt, "operationId") != SubmittedOperationId)
        {
            return;
        }
        if (receipt?["review"]?.ToJsonString() != SubmittedReviewJson)
        {
            return;
        }
        var state = Format.Text(receipt, "state");
        OutcomeState = state;
        OutcomeMessage = Format.Text(receipt, "message");
        Error = null;
        CanRetry = Format.Flag(receipt, "retryAllowed");
        if (IsFinished(state))
        {
            SubmittedOperationId = null;
            SubmittedReviewJson = "";
            Review = null;
        }
    }

    private static bool IsFinished(string state) =>
        state == "succeeded" || state == "failed";
}

/// <summary>
/// The push dialog: branch, destination and outgoing commits, then one
/// explicit push. Staging and pushing are real features behind buttons,
/// never on a timer.
/// </summary>
internal static class WorkspacePushDialog
{
    public static async Task ShowAsync(UIElement owner, string workspaceId, string folderName)
    {
        var session = WorkspacePushSession.For(workspaceId);
        await session.PrepareAsync(workspaceId);
        while (true)
        {
            var submitted = session.SubmittedOperationId is not null;
            var succeeded = session.OutcomeState == "succeeded";
            var done = !submitted && (succeeded || (session.Review is not null && session.IsDone));
            string primary;
            if (submitted)
            {
                primary = L10n.Text("windows.workspacepush.check_outcome.9200a2fd");
            }
            else if (done)
            {
                primary = L10n.Text("common.done");
            }
            else if (session.Review is null)
            {
                primary = L10n.Text("windows.workspacepush.check_branch.8128e71f");
            }
            else
            {
                primary = session.RemoteHead is null ? L10n.Text("windows.workspacepush.publish_branch.e1f5968c") : L10n.Text("windows.workspacepush.push_branch.97deb7c0");
            }
            var dialog = new ContentDialog
            {
                Title = L10n.Text("windows.workspacepush.push_branch.97deb7c0"),
                Content = BuildBody(folderName, session),
                PrimaryButtonText = primary,
                CloseButtonText = (succeeded || session.IsDone) && !submitted ? null : L10n.Text("common.close"),
                DefaultButton = ContentDialogButton.Primary,
            };
            if (submitted && session.CanRetry)
            {
                dialog.SecondaryButtonText = L10n.Text("windows.workspacepush.retry_same_push.d4ab8f02");
            }
            var result = await Chrome.ShowDialog(owner, dialog);
            if (result == ContentDialogResult.None)
            {
                return;
            }
            if (result == ContentDialogResult.Secondary)
            {
                await session.RetryAsync(workspaceId);
                continue;
            }
            if (result != ContentDialogResult.Primary)
            {
                return;
            }
            if (done)
            {
                return;
            }
            if (submitted)
            {
                await session.CheckOutcomeAsync(workspaceId);
                continue;
            }
            if (session.Review is null)
            {
                await session.PrepareAsync(workspaceId);
                continue;
            }
            await session.SubmitAsync(workspaceId);
        }
    }

    private static UIElement BuildBody(string folderName, WorkspacePushSession session)
    {
        var stack = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 420 };
        if (!string.IsNullOrEmpty(folderName))
        {
            stack.Children.Add(new TextBlock
            {
                Text = folderName,
                FontSize = 12,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        if (session.Review is not null)
        {
            stack.Children.Add(new TextBlock
            {
                Text = session.BranchName,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                FontSize = 16,
            });
            if (!string.IsNullOrEmpty(session.Destination))
            {
                stack.Children.Add(new TextBlock
                {
                    Text = L10n.Text("windows.workspacepush.to_0.e7bc111d", $"{session.Destination}"),
                    Opacity = 0.7,
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            if (!string.IsNullOrEmpty(session.Head))
            {
                var head = session.Head;
                stack.Children.Add(new TextBlock
                {
                    Text = head.Length > 10 ? head[..10] : head,
                    FontFamily = Fonts.Mono,
                    FontSize = 12,
                    Opacity = 0.7,
                });
            }
            if (session.UpToDate)
            {
                stack.Children.Add(new TextBlock
                {
                    Text = L10n.Text("windows.workspacepush.this_branch_is_up_to_date.01b49ce3"),
                    Foreground = Theme.AccentBrush,
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            else if (session.Outgoing == 0)
            {
                stack.Children.Add(new TextBlock
                {
                    Text = L10n.Text("windows.workspacepush.no_outgoing_commits_the_remote_branch_is_a.7072ceca"),
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            else if (session.RemoteHead is null)
            {
                stack.Children.Add(new TextBlock
                {
                    Text = L10n.Text("windows.workspacepush.publish_this_branch_to_0.e623bfa9", $"{Format.Text(session.Review, "remote")}"),
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            else if (session.Outgoing is ulong count)
            {
                stack.Children.Add(new TextBlock
                {
                    Text = L10n.Text("windows.workspacepush.0_1_to_push.190b18e2", $"{count}", $"{(count == 1 ? L10n.Text("windows.workspacepush.commit.9505cacb") : L10n.Text("windows.workspacepush.commits.02686016"))}"),
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            else
            {
                stack.Children.Add(new TextBlock
                {
                    Text = L10n.Text("windows.workspacepush.the_computer_will_check_whether_the_remote.2c0a07ce"),
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            if (session.SetUpstream)
            {
                stack.Children.Add(new TextBlock
                {
                    Text = L10n.Text("windows.workspacepush.this_will_also_set_the_branch_s_tracking_d.95dfeac0"),
                    FontSize = 12,
                    Opacity = 0.7,
                    TextWrapping = TextWrapping.Wrap,
                });
            }
        }
        if (!string.IsNullOrEmpty(session.OutcomeMessage))
        {
            var ok = session.OutcomeState == "succeeded";
            stack.Children.Add(Chrome.Banner(
                session.OutcomeMessage, ok ? Theme.Success : Theme.Danger, Symbol.Important));
        }
        if (!string.IsNullOrEmpty(session.Error))
        {
            stack.Children.Add(Chrome.Banner(session.Error, Theme.Danger, Symbol.Important));
        }
        if (session.Working)
        {
            stack.Children.Add(new TextBlock
            {
                Text = session.SubmittedOperationId is null ? L10n.Text("windows.workspacepush.checking_the_branch.3733503a") : L10n.Text("windows.workspacepush.checking_push.00fa6ce0"),
                Opacity = 0.7,
            });
            stack.Children.Add(new ProgressRing { IsActive = true });
        }
        return new ScrollViewer { MaxHeight = 480, Content = stack };
    }
}
