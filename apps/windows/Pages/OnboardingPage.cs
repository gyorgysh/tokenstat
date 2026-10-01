// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>
/// Whether the first-run tour has been seen. A file under the per-user app
/// data rather than a registry key, so it survives reinstalls of the
/// per-user folder layout and reads the same from any window.
/// </summary>
internal static class OnboardingState
{
    private static string FlagPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "tokenstat",
        "onboarded");

    public static bool HasOnboarded
    {
        get
        {
            try
            {
                return File.Exists(FlagPath);
            }
            catch
            {
                return true;
            }
        }
        set
        {
            if (!value)
            {
                return;
            }
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FlagPath)!);
                File.WriteAllText(FlagPath, "1");
            }
            catch
            {
                // The tour simply shows again next launch.
            }
        }
    }
}

/// <summary>
/// The first thing a new install sees. The pitch before the sign-in: what
/// the app does, where the work lives, and the privacy boundary, then a
/// deliberate next step. One scrolling desktop page rather than phone
/// swipe pages, with the same words as the Mac client tour. First-run only,
/// skippable, and re-openable from About.
/// </summary>
internal sealed class OnboardingPage : Page
{
    private readonly Action _done;
    private readonly StackPanel _signSlot = new() { Spacing = Theme.SpaceL };

    public OnboardingPage(Action done)
    {
        _done = done;
        var root = new StackPanel { Spacing = Theme.SpaceL, MaxWidth = 640 };
        root.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.onboardingpage.tokenstat.63d30539"),
            FontSize = 26,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        root.Children.Add(Section(
            L10n.Text("windows.onboardingpage.welcome.0e2226b5"),
            L10n.Text("windows.onboardingpage.your_coding_agents_within_reach.f425119b"),
            L10n.Text("windows.onboardingpage.run_coding_agents_on_your_computer_or_a_se.4eb96eb3")));
        root.Children.Add(Section(
            L10n.Text("windows.onboardingpage.agents.279b44d2"),
            L10n.Text("windows.onboardingpage.keep_the_conversation_going.4656fe2c"),
            L10n.Text("windows.onboardingpage.give_an_agent_a_task_follow_its_progress_a.1c37d4c6")));
        root.Children.Add(Section(
            L10n.Text("common.projects"),
            L10n.Text("windows.onboardingpage.go_from_the_chat_to_the_code.e1a5a08a"),
            L10n.Text("windows.onboardingpage.open_a_folder_or_clone_a_repository_read_a.1ff55f95")));
        root.Children.Add(Section(
            L10n.Text("windows.onboardingpage.machines.c061da19"),
            L10n.Text("windows.onboardingpage.choose_where_the_work_runs.0e0fe3ac"),
            L10n.Text("windows.onboardingpage.use_this_pc_or_a_cloud_server_with_guided.dce35897")));
        root.Children.Add(Section(
            L10n.Text("windows.onboardingpage.usage.8d59829c"),
            L10n.Text("windows.onboardingpage.know_where_the_tokens_go.fc548566"),
            L10n.Text("windows.onboardingpage.see_activity_and_estimated_cost_by_tool_mo.feb3684a")));
        root.Children.Add(Section(
            L10n.Text("windows.onboardingpage.privacy.54a57c31"),
            L10n.Text("windows.onboardingpage.your_machines_your_say.6ae0dc0d"),
            L10n.Text("windows.onboardingpage.remote_work_travels_over_an_end_to_end_enc.6cfdbc5b")));
        root.Children.Add(_signSlot);
        root.Children.Add(Footer());
        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL),
            Content = root,
        };
    }

    private static UIElement Section(string topic, string title, string body)
    {
        var content = new StackPanel { Spacing = Theme.SpaceS };
        content.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 17,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        content.Children.Add(new TextBlock
        {
            Text = body,
            Opacity = 0.75,
            TextWrapping = TextWrapping.Wrap,
        });
        return Chrome.Card(topic, content);
    }

    private UIElement Footer()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.onboardingpage.next_sign_in_you_can_connect_a_machine_whe.71155587"),
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        row.Children.Add(ActionIconGlyph.PrimaryButton(
            L10n.Text("windows.onboardingpage.get_started.61e8d44a"), ActionIcon.Next, (_, _) => _done()));
        row.Children.Add(ActionIconGlyph.Button(
            L10n.Text("common.sign_in"), ActionIcon.SignIn,
            async (_, _) => await SignInFlow.RunAsync(this, _signSlot, () =>
            {
                _done();
                return Task.CompletedTask;
            })));
        row.Children.Add(ActionIconGlyph.Button(
            L10n.Text("common.skip"), ActionIcon.Dismiss, (_, _) => _done()));
        body.Children.Add(row);
        return Chrome.Card(L10n.Text("windows.onboardingpage.ready_when_you_are.34ef5704"), body);
    }
}
