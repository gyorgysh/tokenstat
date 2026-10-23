// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal sealed class ChatLocalSharingPanel : StackPanel
{
    internal ChatLocalSharingPanel(ChatLocalSharingModel model, Func<bool> current, Func<Task> refreshChat)
    {
        Spacing = Theme.SpaceM;
        Children.Add(Text(L10n.Text("common.teams.local_stop_explanation")));
        var note = Text(""); Children.Add(note);
        var confirm = new CheckBox { Content = L10n.Text("common.teams.stop_chat_sharing_confirm") }; Children.Add(confirm);
        ChatLocalSharingModel.Sharing? reviewed = null;
        Button? stop = null; Button? release = null; Button? refresh = null;
        async Task Finish()
        {
            if (current() && model.PrivateReady) await refreshChat();
        }
        stop = ActionIconGlyph.Button(L10n.Text("common.teams.stop_sharing"), ActionIcon.Revoke, async (_, _) => {
            if (!current() || reviewed is null) return;
            await model.StopAsync(reviewed, confirm.IsChecked == true); await Finish();
        });
        release = ActionIconGlyph.Button(L10n.Text("common.teams.release_agent_run"), ActionIcon.Restore, async (_, _) => {
            await model.ReleaseAsync(); await Finish();
        });
        refresh = ActionIconGlyph.Button(L10n.Text("common.refresh"), ActionIcon.Refresh, async (_, _) => {
            confirm.IsChecked = false; reviewed = null; await model.LoadAsync(); await Finish();
        });
        void Update()
        {
            if (!current())
            {
                note.Text = L10n.Text("common.teams.checkout_access_changed");
                confirm.IsEnabled = stop!.IsEnabled = release!.IsEnabled = refresh!.IsEnabled = false; return;
            }
            var messages = new List<string>();
            if (model.Error is { } error) messages.Add(error switch {
                "local_record_unavailable" => L10n.Text("common.teams.local_record_unavailable"),
                "local_recovery_retry" => L10n.Text("common.teams.local_recovery_retry"), _ => error,
            });
            if (model.Result is { } result)
            {
                messages.Add(L10n.Text(result.CleanupPending ? "common.teams.cleanup_pending" : "common.teams.sharing_stopped"));
                if (!result.PrivateReady) messages.Add(L10n.Text("common.teams.local_recovery_retry"));
            }
            else if (model.Snapshot?.SourceOnly == true) messages.Add(L10n.Text("common.teams.local_record_unavailable"));
            else if (model.PrivateReady) messages.Add(L10n.Text("common.teams.sharing_stopped"));
            if (model.CanRelease) messages.Add(L10n.Text("common.teams.agent_run_held"));
            note.Text = string.Join("\n", messages);
            if (reviewed != model.Snapshot) { reviewed = null; confirm.IsChecked = false; }
            confirm.IsEnabled = model.CanStop;
            confirm.Visibility = stop!.Visibility = model.PrivateReady || model.Snapshot?.Withdrawn == true ? Visibility.Collapsed : Visibility.Visible;
            stop.IsEnabled = model.CanStop && reviewed is not null && confirm.IsChecked == true;
            release!.Visibility = model.CanRelease ? Visibility.Visible : Visibility.Collapsed; release.IsEnabled = !model.Busy;
            refresh!.IsEnabled = !model.Busy;
        }
        confirm.Checked += (_, _) => { reviewed = model.Snapshot; Update(); };
        confirm.Unchecked += (_, _) => { reviewed = null; Update(); };
        Children.Add(stop); Children.Add(release); Children.Add(refresh);
        model.Changed = Update;
        void AccountChanged() => DispatcherQueue.TryEnqueue(Update);
        Loaded += async (_, _) => { AppServices.AccountChanged += AccountChanged; await model.LoadAsync(); await Finish(); };
        Unloaded += (_, _) => AppServices.AccountChanged -= AccountChanged;
        Update();
    }
    private static TextBlock Text(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };
}
