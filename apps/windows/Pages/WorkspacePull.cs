// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>
/// The reviewed pull for one workspace, matching the Mac. Opening the dialog
/// is what fetches, because a person pressed Pull. Applying moves the branch
/// to exactly the reviewed commit, fast-forward only, and never merges,
/// rebases or touches uncommitted work.
/// </summary>
internal static class WorkspacePullDialog
{
    public static async Task ShowAsync(UIElement owner, string workspaceId, string folderName)
    {
        var account = AppServices.AccountGeneration;
        bool Current() => owner.XamlRoot is not null && account == AppServices.AccountGeneration;
        try
        {
            var spoken = await RemoteWorkspaces.CallWorkspaceAsync(workspaceId, "protocol");
            if (RemoteFeatureGate.ProtocolOf(spoken) is not long version || version < RemoteFeatureGate.ReviewedPullMinProtocol)
            {
                await Chrome.ShowDialog(owner, new ContentDialog
                {
                    Title = L10n.Text("windows.gitpull.title"),
                    Content = Text(L10n.Text("windows.gitpull.update_host")),
                    CloseButtonText = L10n.Text("common.close"),
                });
                return;
            }
        }
        catch (Exception ex)
        {
            await Chrome.ShowDialog(owner, new ContentDialog
            {
                Title = L10n.Text("windows.gitpull.title"),
                Content = Text(ex.Message),
                CloseButtonText = L10n.Text("common.close"),
            });
            return;
        }

        JsonNode? review = null;
        JsonNode? outcome = null;
        string? error = null;

        async Task CheckAsync()
        {
            error = null;
            outcome = null;
            try
            {
                review = await RemoteWorkspaces.CallWorkspaceAsync(
                    workspaceId, "workspace.pullReview", new JsonObject { ["id"] = workspaceId });
            }
            catch (Exception ex)
            {
                review = null;
                error = ex.Message;
            }
        }

        await CheckAsync();
        while (Current())
        {
            var state = Format.Text(review, "state");
            var pulled = Format.Flag(outcome, "ok");
            var lfs = outcome is null ? WorkspaceGitLfs.Read(review) : null;
            var done = pulled || (state == "upToDate" && lfs?.Ready != false);
            var canPull = review is not null && outcome is null && state == "fastForward" && lfs?.Ready != false;
            var canSetup = lfs?.CanSetup == true;
            var incoming = Count(review, "incoming");
            var dialog = new ContentDialog
            {
                Title = L10n.Text("windows.gitpull.title"),
                Content = Body(folderName, review, outcome, error, lfs),
                PrimaryButtonText = done
                    ? L10n.Text("common.done")
                    : canSetup ? lfs!.SetupLabel : canPull
                        ? (incoming == 1 ? L10n.Text("windows.gitpull.pull_commits.one", "1") : L10n.Text("windows.gitpull.pull_commits.other", $"{incoming}"))
                        : L10n.Text("windows.gitpull.check_again"),
                CloseButtonText = done ? null : L10n.Text("common.close"),
                SecondaryButtonText = canSetup ? L10n.Text("windows.gitpull.check_again") : null,
                DefaultButton = canSetup ? ContentDialogButton.Close : ContentDialogButton.Primary,
            };
            var result = await Chrome.ShowDialog(owner, dialog);
            if (!Current()) return;
            if (result == ContentDialogResult.Secondary && canSetup)
            {
                await CheckAsync();
                continue;
            }
            if (result != ContentDialogResult.Primary || done)
            {
                return;
            }
            if (canSetup)
            {
                try
                {
                    await lfs!.SetupAsync(workspaceId);
                    if (Current()) await CheckAsync();
                }
                catch (Exception exception) { error = FriendlyError.Display(exception.Message); }
                continue;
            }
            if (!canPull)
            {
                await CheckAsync();
                continue;
            }
            try
            {
                outcome = await RemoteWorkspaces.CallWorkspaceAsync(workspaceId, "workspace.pullReviewed",
                    new JsonObject { ["id"] = workspaceId, ["review"] = review!.DeepClone() });
                error = null;
            }
            catch (Exception ex)
            {
                // A refused pull would refuse again with the same review.
                // Drop it so the dialog offers Check again, not the same Pull.
                review = null;
                error = ex.Message;
            }
        }
    }

    private static ulong Count(JsonNode? review, string key) =>
        ulong.TryParse(Format.Text(review, key), out var value) ? value : 0;

    private static UIElement Body(string folderName, JsonNode? review, JsonNode? outcome, string? error, WorkspaceGitLfs? lfs)
    {
        var stack = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 420 };
        if (!string.IsNullOrEmpty(folderName))
        {
            stack.Children.Add(new TextBlock { Text = folderName, FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
        }
        if (review is not null)
        {
            stack.Children.Add(new TextBlock
            {
                Text = WorkspaceGit.ShortBranch(Format.Text(review, "branch")),
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                FontSize = 16,
            });
            var remoteRef = Format.Text(review, "remoteRef");
            if (remoteRef.StartsWith("refs/heads/", StringComparison.Ordinal)) remoteRef = remoteRef["refs/heads/".Length..];
            stack.Children.Add(Text(L10n.Text("windows.gitpull.from", Format.Text(review, "remote") + "/" + remoteRef), 0.7));
            if (outcome is null)
            {
                var incoming = Count(review, "incoming");
                stack.Children.Add(Text(Format.Text(review, "state") switch
                {
                    "upToDate" => L10n.Text("windows.gitpull.up_to_date"),
                    "ahead" => L10n.Text("windows.gitpull.ahead"),
                    "fastForward" => incoming == 1
                        ? L10n.Text("windows.gitpull.incoming.one", "1")
                        : L10n.Text("windows.gitpull.incoming.other", $"{incoming}"),
                    "diverged" => L10n.Text("windows.gitpull.diverged", $"{incoming}", $"{Count(review, "outgoing")}"),
                    _ => L10n.Text("windows.gitpull.missing"),
                }));
            }
        }
        if (outcome is not null)
        {
            stack.Children.Add(Chrome.Banner(Format.Text(outcome, "message"),
                Format.Flag(outcome, "ok") ? Theme.Accent : Theme.Danger,
                Format.Flag(outcome, "ok") ? Symbol.Accept : Symbol.Important));
        }
        if (!string.IsNullOrEmpty(error))
        {
            stack.Children.Add(Chrome.Banner(error, Theme.Danger, Symbol.Important));
        }
        if (lfs is not null) stack.Children.Add(lfs.Card());
        stack.Children.Add(Text(L10n.Text("windows.gitpull.help"), 0.7, 12));
        return stack;
    }

    private static TextBlock Text(string text, double opacity = 1, double size = 14) => new()
    {
        Text = text,
        Opacity = opacity,
        FontSize = size,
        TextWrapping = TextWrapping.Wrap,
    };
}
