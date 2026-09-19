// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Tokenstat.Navigation;
using Windows.UI;

namespace Tokenstat.Pages;

/// <summary>
/// Small shared git labels. One place, so the Changes list, the commit
/// composer and the history cards cannot spell the same kind three ways.
/// </summary>
internal static class WorkspaceGit
{
    public static string KindLabel(string raw) => raw switch
    {
        "added" => "Added",
        "modified" => "Modified",
        "deleted" => "Deleted",
        "renamed" => "Renamed",
        "untracked" => "Untracked",
        "conflicted" => "Conflicted",
        _ when !string.IsNullOrEmpty(raw)
            => char.ToUpperInvariant(raw[0]) + raw[1..],
        _ => "Changed",
    };

    public static Color KindTint(string raw) => raw switch
    {
        "added" => Theme.DiffAdded,
        "deleted" => Theme.DiffRemoved,
        "conflicted" => Theme.Warning,
        "untracked" => Theme.ControlGlyph,
        _ => Theme.Secondary,
    };

    public static string ShortBranch(string branch) =>
        branch.StartsWith("refs/heads/", StringComparison.Ordinal)
            ? branch["refs/heads/".Length..]
            : branch;

    public static string ShortId(string id) =>
        id.Length > 7 ? id[..7] : id;
}

/// <summary>
/// The reviewed commit flow for one workspace, matching the Mac workbench.
/// Selection stays local until Commit: checking a file only adds it to this
/// session. The only commit call sends the frozen review back, so the host
/// cannot silently commit a newer worktree snapshot. One entry per workspace
/// id, shared across page instances, so the draft survives navigation.
/// </summary>
internal sealed class WorkspaceCommitSession
{
    private const int MaxMessageBytes = 128 * 1024;

    private static readonly Dictionary<string, WorkspaceCommitSession> Sessions = new();

    public static WorkspaceCommitSession For(string workspaceId)
    {
        if (!Sessions.TryGetValue(workspaceId, out var session))
        {
            session = new WorkspaceCommitSession();
            Sessions[workspaceId] = session;
        }
        return session;
    }

    public string Title = "";
    public string Details = "";
    public readonly HashSet<string> Paths = new(StringComparer.Ordinal);

    public JsonNode? Review;
    public string? SubmittedOperationId;
    public JsonNode? SubmittedReview;
    public string SubmittedMessage = "";
    public string? OutcomeState;
    public string OutcomeMessage = "";
    public string? OutcomeCommit;
    public bool Working;
    public bool CanRetry;
    public string? Error;

    public int SelectedCount => Paths.Count;

    public string Message
    {
        get
        {
            var title = Title.Trim();
            var details = Details.Trim();
            return string.IsNullOrEmpty(details) ? title : title + "\n\n" + details;
        }
    }

    public bool MessageTooLong =>
        System.Text.Encoding.UTF8.GetByteCount(Message) > MaxMessageBytes;

    public bool CanCommit =>
        !Working
        && SubmittedOperationId is null
        && Review is not null
        && Paths.SetEquals(ReviewPaths())
        && !string.IsNullOrWhiteSpace(Title)
        && !MessageTooLong;

    public void Select(string path)
    {
        if (Working || SubmittedOperationId is not null)
        {
            return;
        }
        if (!Paths.Add(path))
        {
            Paths.Remove(path);
        }
        Review = null;
        OutcomeState = null;
        OutcomeMessage = "";
    }

    public void SetAll(IEnumerable<string> paths)
    {
        if (Working || SubmittedOperationId is not null)
        {
            return;
        }
        var next = new HashSet<string>(paths, StringComparer.Ordinal);
        if (Paths.SetEquals(next))
        {
            Paths.Clear();
        }
        else
        {
            Paths.Clear();
            foreach (var path in next)
            {
                Paths.Add(path);
            }
        }
        Review = null;
        OutcomeState = null;
        OutcomeMessage = "";
    }

    public void ClearSelection()
    {
        if (Working || SubmittedOperationId is not null)
        {
            return;
        }
        Paths.Clear();
        Review = null;
        OutcomeState = null;
        OutcomeMessage = "";
    }

    /// <summary>
    /// Drop paths that are no longer changed. Only while nothing is
    /// submitted and no review is frozen: a review names exact paths.
    /// </summary>
    public void Reconcile(IEnumerable<string> available)
    {
        if (Working || SubmittedOperationId is not null || Review is not null)
        {
            return;
        }
        Paths.IntersectWith(available);
    }

    public List<string> ReviewPaths()
    {
        var paths = new List<string>();
        if (Review?["paths"] is JsonArray array)
        {
            foreach (var item in array)
            {
                var path = item?.GetValue<string>();
                if (!string.IsNullOrEmpty(path))
                {
                    paths.Add(path!);
                }
            }
        }
        return paths;
    }

    public List<string> ReviewIncluded()
    {
        var paths = new List<string>();
        if (Review?["includedPaths"] is JsonArray array)
        {
            foreach (var item in array)
            {
                var path = item?.GetValue<string>();
                if (!string.IsNullOrEmpty(path))
                {
                    paths.Add(path!);
                }
            }
        }
        return paths.Count > 0 ? paths : ReviewPaths();
    }

    public string ReviewBranch() =>
        Review?["branch"]?.GetValue<string>() ?? "";

    public async Task PrepareReviewAsync(string workspaceId)
    {
        if (Working || SubmittedOperationId is not null || Paths.Count == 0)
        {
            return;
        }
        Working = true;
        Error = null;
        try
        {
            var sorted = new JsonArray();
            foreach (var path in Paths.OrderBy(p => p, StringComparer.Ordinal))
            {
                sorted.Add(JsonValue.Create(path));
            }
            Review = await RemoteWorkspaces.CallWorkspaceAsync(
                workspaceId,
                "workspace.commitReview",
                new JsonObject { ["id"] = workspaceId, ["paths"] = sorted });
            OutcomeState = null;
            OutcomeMessage = "";
        }
        catch (Exception ex)
        {
            Error = ReviewedError(ex.Message);
        }
        finally
        {
            Working = false;
        }
    }

    public async Task SubmitAsync(string workspaceId)
    {
        if (!CanCommit || Review is null)
        {
            return;
        }
        Working = true;
        CanRetry = false;
        Error = null;
        var operationId = Guid.NewGuid().ToString("N");
        SubmittedOperationId = operationId;
        SubmittedReview = Review;
        SubmittedMessage = Message;
        try
        {
            var receipt = await RemoteWorkspaces.CallWorkspaceAsync(
                workspaceId,
                "workspace.commitSelected",
                new JsonObject
                {
                    ["id"] = workspaceId,
                    ["operationId"] = operationId,
                    ["review"] = Review.DeepClone(),
                    ["message"] = SubmittedMessage,
                });
            Adopt(receipt);
        }
        catch (Exception ex)
        {
            // No rollback, retry or new id follows a lost response. The
            // submission is persisted (in this session), so reconcile it
            // with a receipt check before anything else runs.
            Error = "The commit outcome has not been confirmed. "
                + "Check its outcome before starting another. " + ex.Message;
        }
        finally
        {
            Working = false;
        }
    }

    public async Task CheckOutcomeAsync(string workspaceId, bool recover)
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
                "workspace.commitReceipt",
                new JsonObject
                {
                    ["id"] = workspaceId,
                    ["operationId"] = SubmittedOperationId,
                });
            if (receipt is null)
            {
                CanRetry = true;
                Error = "The computer has no recorded outcome yet. "
                    + "You can retry this same submission.";
            }
            else if (recover && IsUnresolved(Format.Text(receipt, "state")))
            {
                var reconciled = await RemoteWorkspaces.CallWorkspaceAsync(
                    workspaceId,
                    "workspace.commitRecover",
                    new JsonObject
                    {
                        ["id"] = workspaceId,
                        ["operationId"] = SubmittedOperationId,
                    });
                Adopt(reconciled);
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
        if (Working || !CanRetry || SubmittedOperationId is null || SubmittedReview is null)
        {
            return;
        }
        Working = true;
        Error = null;
        CanRetry = false;
        try
        {
            var receipt = await RemoteWorkspaces.CallWorkspaceAsync(
                workspaceId,
                "workspace.commitSelected",
                new JsonObject
                {
                    ["id"] = workspaceId,
                    ["operationId"] = SubmittedOperationId,
                    ["review"] = SubmittedReview.DeepClone(),
                    ["message"] = SubmittedMessage,
                });
            Adopt(receipt);
        }
        catch (Exception ex)
        {
            Error = "Check this commit's outcome before starting another. " + ex.Message;
        }
        finally
        {
            Working = false;
        }
    }

    private void Adopt(JsonNode? receipt)
    {
        if (Format.Text(receipt, "operationId") != SubmittedOperationId)
        {
            return;
        }
        var state = Format.Text(receipt, "state");
        OutcomeState = state;
        OutcomeMessage = Format.Text(receipt, "message");
        OutcomeCommit = Format.Text(receipt, "commit");
        Error = null;
        if (state == "succeeded")
        {
            Title = "";
            Details = "";
            Paths.Clear();
            Review = null;
            SubmittedOperationId = null;
            SubmittedReview = null;
            SubmittedMessage = "";
        }
        else if (state == "failed")
        {
            SubmittedOperationId = null;
            SubmittedReview = null;
            Review = null;
        }
    }

    private static bool IsUnresolved(string state) =>
        state != "succeeded" && state != "failed";

    private static string ReviewedError(string message) =>
        message.Contains("unknown method", StringComparison.OrdinalIgnoreCase)
            ? "Update the connected computer to commit selected files. " + message
            : message;
}

/// <summary>
/// The review composer: title and description over a frozen selection,
/// with the branch and folder in the subtitle. Every commit goes through
/// here, never past it.
/// </summary>
internal static class WorkspaceCommitComposer
{
    /// <summary>Shows the composer. Returns true when a commit landed.</summary>
    public static async Task<bool> ShowAsync(UIElement owner, string workspaceId, string folderName, string branch)
    {
        var session = WorkspaceCommitSession.For(workspaceId);
        var committed = false;
        while (true)
        {
            var review = session.Review;
            var submitted = session.SubmittedOperationId is not null;
            var succeeded = session.OutcomeState == "succeeded";
            string primary;
            if (succeeded)
            {
                primary = "Done";
            }
            else if (submitted)
            {
                primary = session.CanRetry ? "Retry same submission" : "Check outcome";
            }
            else if (review is null)
            {
                primary = "Review selected files";
            }
            else
            {
                var count = session.ReviewPaths().Count;
                primary = $"Commit {count} {(count == 1 ? "file" : "files")}";
            }
            var body = BuildBody(owner, workspaceId, folderName, branch, session);
            var dialog = new ContentDialog
            {
                Title = "Review and commit",
                Content = body,
                PrimaryButtonText = primary,
                CloseButtonText = succeeded ? null : "Close",
                DefaultButton = ContentDialogButton.Primary,
            };
            if (submitted && session.CanRetry)
            {
                dialog.SecondaryButtonText = "Check outcome";
            }
            var result = await Chrome.ShowDialog(owner, dialog);
            if (result == ContentDialogResult.None)
            {
                return committed;
            }
            if (result == ContentDialogResult.Secondary)
            {
                await session.CheckOutcomeAsync(workspaceId, recover: false);
                if (session.OutcomeState == "succeeded")
                {
                    return true;
                }
                continue;
            }
            if (result != ContentDialogResult.Primary)
            {
                return committed;
            }
            if (succeeded)
            {
                return true;
            }
            if (submitted)
            {
                if (session.CanRetry)
                {
                    await session.RetryAsync(workspaceId);
                }
                else
                {
                    await session.CheckOutcomeAsync(workspaceId, recover: true);
                }
                if (session.OutcomeState == "succeeded")
                {
                    committed = true;
                    continue;
                }
                continue;
            }
            if (review is null)
            {
                await session.PrepareReviewAsync(workspaceId);
                continue;
            }
            await session.SubmitAsync(workspaceId);
            if (session.OutcomeState == "succeeded")
            {
                committed = true;
                continue;
            }
            continue;
        }
    }

    private static UIElement BuildBody(
        UIElement owner, string workspaceId, string folderName, string branch,
        WorkspaceCommitSession session)
    {
        var stack = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 480 };
        var context = folderName;
        var reviewBranch = session.ReviewBranch();
        var shownBranch = string.IsNullOrEmpty(reviewBranch) ? branch : reviewBranch;
        if (!string.IsNullOrEmpty(shownBranch))
        {
            var shortBranch = WorkspaceGit.ShortBranch(shownBranch);
            context = string.IsNullOrEmpty(context)
                ? shortBranch
                : context + " · " + shortBranch;
        }
        if (!string.IsNullOrEmpty(context))
        {
            stack.Children.Add(new TextBlock
            {
                Text = context,
                FontSize = 12,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        if (!string.IsNullOrEmpty(session.Error))
        {
            stack.Children.Add(Chrome.Banner(session.Error, Theme.Danger, Symbol.Important));
        }
        if (!string.IsNullOrEmpty(session.OutcomeMessage))
        {
            var ok = session.OutcomeState == "succeeded";
            var text = session.OutcomeMessage;
            if (ok && !string.IsNullOrEmpty(session.OutcomeCommit))
            {
                text += " (" + WorkspaceGit.ShortId(session.OutcomeCommit) + ")";
            }
            stack.Children.Add(Chrome.Banner(
                text, ok ? Theme.Success : Theme.Danger, Symbol.Important));
        }
        if (session.MessageTooLong)
        {
            stack.Children.Add(Chrome.Banner(
                "Shorten the commit message to 128 KiB or less before committing.",
                Theme.Danger, Symbol.Important));
        }
        var frozen = session.SubmittedOperationId is not null;
        var titleBox = new TextBox
        {
            Header = "Commit title",
            PlaceholderText = "Describe the change",
            Text = session.Title,
            IsEnabled = !session.Working && !frozen,
        };
        titleBox.TextChanged += (_, _) => session.Title = titleBox.Text;
        stack.Children.Add(titleBox);
        var detailsBox = new TextBox
        {
            Header = "Description (optional)",
            Text = session.Details,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 120,
            IsEnabled = !session.Working && !frozen,
        };
        detailsBox.TextChanged += (_, _) => session.Details = detailsBox.Text;
        stack.Children.Add(detailsBox);
        if (session.Review is not null)
        {
            var included = session.ReviewIncluded();
            stack.Children.Add(new TextBlock
            {
                Text = $"{included.Count} selected {(included.Count == 1 ? "file" : "files")}",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
            var files = new StackPanel { Spacing = 4 };
            foreach (var path in included)
            {
                var captured = path;
                var row = new Button
                {
                    Content = new TextBlock
                    {
                        Text = captured,
                        TextWrapping = TextWrapping.Wrap,
                        FontFamily = Fonts.Mono,
                        FontSize = 12,
                    },
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Left,
                };
                row.Click += async (_, _) =>
                    await ShowReviewedDiffAsync(owner, workspaceId, session, captured);
                files.Children.Add(row);
            }
            stack.Children.Add(files);
            stack.Children.Add(ActionIconGlyph.Button("Review all", ActionIcon.Compare, async (_, _) =>
            {
                var all = included
                    .Select(path => (path, "", (long?)null, (long?)null))
                    .ToList();
                await WorkspaceDiff.ShowReviewAllAsync(
                    owner, all, reviewedPath => LoadReviewedAsync(workspaceId, session, reviewedPath));
            }));
        }
        else if (session.Working)
        {
            stack.Children.Add(new ProgressRing { IsActive = true });
        }
        else if (!frozen)
        {
            stack.Children.Add(new TextBlock
            {
                Text = $"{session.SelectedCount} selected "
                    + $"{(session.SelectedCount == 1 ? "file" : "files")}. "
                    + "Review freezes this selection: files changed afterwards are not included.",
                FontSize = 12,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        else
        {
            stack.Children.Add(new TextBlock
            {
                Text = "This submission is waiting on the computer. "
                    + "Check its outcome before starting another.",
                FontSize = 12,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        return new ScrollViewer { MaxHeight = 560, Content = stack };
    }

    private static async Task ShowReviewedDiffAsync(
        UIElement owner, string workspaceId, WorkspaceCommitSession session, string path)
    {
        JsonNode? diff;
        try
        {
            diff = await LoadReviewedAsync(workspaceId, session, path);
        }
        catch (Exception ex)
        {
            var failed = new ContentDialog
            {
                Title = path,
                Content = Chrome.Banner(
                    FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important),
                CloseButtonText = "Close",
            };
            await Chrome.ShowDialog(owner, failed);
            return;
        }
        await WorkspaceDiff.ShowFileDiffAsync(owner, path, diff);
    }

    private static async Task<JsonNode?> LoadReviewedAsync(
        string workspaceId, WorkspaceCommitSession session, string path)
    {
        var review = session.SubmittedReview ?? session.Review;
        if (review is null)
        {
            return null;
        }
        return await RemoteWorkspaces.CallWorkspaceAsync(
            workspaceId,
            "workspace.commitReviewDiff",
            new JsonObject
            {
                ["id"] = workspaceId,
                ["review"] = review.DeepClone(),
                ["path"] = path,
            });
    }
}
