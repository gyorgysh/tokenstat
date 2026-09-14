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
            Text = "tokenstat",
            FontSize = 26,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        root.Children.Add(Section(
            "Welcome",
            "Your coding agents, within reach.",
            "Run coding agents on your computer or a server. Pick up the "
            + "conversation, work on your projects, and see your AI usage "
            + "on this PC."));
        root.Children.Add(Section(
            "Agents",
            "Keep the conversation going",
            "Give an agent a task, follow its progress, and reply when it "
            + "needs you. Return to the same chat later, or open a live "
            + "terminal when you want to work directly."));
        root.Children.Add(Section(
            "Projects",
            "Go from the chat to the code",
            "Open a folder or clone a repository. Read and edit files, "
            + "review changes, and keep tasks beside the code. Your "
            + "projects stay on the machine that runs them."));
        root.Children.Add(Section(
            "Machines",
            "Choose where the work runs",
            "Use this PC or a cloud server. That machine needs to be awake "
            + "while you work. Sign in to see every device on one account."));
        root.Children.Add(Section(
            "Usage",
            "Know where the tokens go",
            "See activity and estimated cost by tool, model, and project, "
            + "plus supported plans' usage and reset times. Synced numbers "
            + "stay available with every computer asleep. Plan usage is "
            + "shown separately from cost."));
        root.Children.Add(Section(
            "Privacy",
            "Your machines. Your say.",
            "Remote work travels over an end-to-end encrypted connection. "
            + "You choose which devices can open your work and which usage "
            + "totals to sync. Your account stays private unless you turn "
            + "on a public profile."));
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
            Text = "Next, sign in. You can connect a machine whenever you are ready.",
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        row.Children.Add(ActionIconGlyph.PrimaryButton(
            "Get started", ActionIcon.Next, (_, _) => _done()));
        row.Children.Add(ActionIconGlyph.Button(
            "Sign in", ActionIcon.SignIn,
            async (_, _) => await SignInFlow.RunAsync(this, _signSlot, () =>
            {
                _done();
                return Task.CompletedTask;
            })));
        row.Children.Add(ActionIconGlyph.Button(
            "Skip", ActionIcon.Dismiss, (_, _) => _done()));
        body.Children.Add(row);
        return Chrome.Card("Ready when you are", body);
    }
}
