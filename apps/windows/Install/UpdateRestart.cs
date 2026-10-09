// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Install;

/// <summary>
/// The restart question, kept out of <see cref="AppUpdateModel"/> so the
/// install tests can compile that model without the UI stack.
/// </summary>
internal static class UpdateRestart
{
    public static Task AskAsync(AppUpdateModel update, XamlRoot? root) =>
        update.RelaunchAsync(live => ConfirmAsync(root, live));

    private static async Task<bool> ConfirmAsync(XamlRoot? root, long live)
    {
        if (root is null)
        {
            return true;
        }
        var confirm = new ContentDialog
        {
            XamlRoot = root,
            Title = L10n.Text("windows.appupdatemodel.restart_ends_running_work.title"),
            Content = live == 1
                ? L10n.Text("windows.appupdatemodel.restart_ends_running_work.body.one")
                : L10n.Text("windows.appupdatemodel.restart_ends_running_work.body.other", $"{live}"),
            PrimaryButtonText = L10n.Text("windows.updatecard.restart.6b983a81"),
            CloseButtonText = L10n.Text("common.cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await confirm.ShowAsync() == ContentDialogResult.Primary;
    }
}
