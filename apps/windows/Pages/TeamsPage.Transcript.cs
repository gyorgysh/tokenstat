// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal sealed partial class TeamsPage
{
    private static string BackendLabel(string backend) => backend switch { "claude" => "Claude Code", "codex" => "Codex", "muse" => "Muse", "" => L10n.Text("common.teams.agent"), _ => backend };
    private static string AuthorLabel(TeamAuthor author) => author.Kind switch
    {
        "localBeforeTeams" => L10n.Text("common.teams.local_before_teams"),
        "formerMember" => L10n.Text("common.teams.former_member"),
        "comment" => author.Name + " · " + L10n.Text("common.teams.comment"),
        "ask" => author.Name + " · " + L10n.Text("common.teams.ask"),
        _ => author.FormerInitiator ? L10n.Text("common.teams.agent_asked_by", BackendLabel(author.Backend), L10n.Text("common.teams.former_member"))
            : author.Name.Length > 0 ? L10n.Text("common.teams.agent_asked_by", BackendLabel(author.Backend), author.Name) : BackendLabel(author.Backend),
    };
    private UIElement TranscriptRow(JsonObject target, TeamBlock block)
    {
        var panel = new StackPanel { Spacing = Theme.SpaceS, Margin = new Thickness(0, 4, 0, 4) };
        if (block.Author is { } author) panel.Children.Add(new TextBlock { Text = AuthorLabel(author), FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
        switch (block.Kind)
        {
            case TeamBlockKind.File:
                if (block.File is not null) panel.Children.Add(SharedFile(target, block.File)); break;
            case TeamBlockKind.User: panel.Children.Add(LiteralText(block.Text)); break;
            case TeamBlockKind.Text:
                var bytes = Encoding.UTF8.GetByteCount(block.Text);
                var chart = block.Text.Trim().StartsWith("```tokenstat-chart\n", StringComparison.Ordinal) && block.Text.TrimEnd().EndsWith("```", StringComparison.Ordinal);
                panel.Children.Add(bytes <= 64 * 1024 || chart && bytes <= 256 * 1024 + 128
                    ? ChatMarkdown.Create(block.Text, code => LiteralText(code, true), allowDesktopActions: false) : LiteralText(block.Text)); break;
            case TeamBlockKind.Tool or TeamBlockKind.Thinking or TeamBlockKind.Edit:
                var title = block.Kind == TeamBlockKind.Thinking ? L10n.Text("common.teams.thinking")
                    : block.Kind == TeamBlockKind.Edit ? L10n.Text("common.teams.recorded_changes") + " · " + block.Title
                    : L10n.Text("common.teams.tool_output") + (block.Title.Length > 0 ? " · " + block.Title : "");
                var detail = new StackPanel { Spacing = Theme.SpaceS, Visibility = Visibility.Collapsed };
                detail.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap });
                detail.Children.Add(LiteralText(block.Text, true));
                var shortTitle = TeamTranscript.TextPages(title, 160)[0] + (title.Length > 160 ? "…" : "");
                panel.Children.Add(ActionIconGlyph.Button(shortTitle, ActionIcon.Preview, (_, _) => detail.Visibility = detail.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible));
                if (block.Ok is { } ok) panel.Children.Add(new TextBlock { Text = ok ? L10n.Text("common.teams.tool_succeeded") : L10n.Text("common.teams.tool_failed"), Opacity = 0.7 });
                panel.Children.Add(detail); break;
            case TeamBlockKind.Error:
                panel.Children.Add(new TextBlock { Text = L10n.Text("common.teams.run_failed"), Foreground = Theme.Brush(static () => Theme.Warning) }); panel.Children.Add(LiteralText(block.Text)); break;
            case TeamBlockKind.Notice:
                panel.Children.Add(new TextBlock { Text = NoticeLabel(block.Title), Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
                if (block.Text.Length > 0) panel.Children.Add(LiteralText(block.Text)); break;
        }
        return panel;
    }
    private static UIElement LiteralText(string text, bool code = false)
    {
        var pages = TeamTranscript.TextPages(text); var index = 0;
        var panel = new StackPanel { Spacing = Theme.SpaceS };
        var words = new TextBlock { Text = pages[0], TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        if (code) words.FontFamily = Fonts.Mono;
        panel.Children.Add(words);
        if (pages.Count <= 1) return panel;
        var label = new TextBlock { Opacity = 0.7 };
        Button? previous = null; Button? next = null;
        void Update() { words.Text = pages[index]; label.Text = L10n.Text("common.teams.text_page", (index + 1).ToString(), pages.Count.ToString()); previous!.IsEnabled = index > 0; next!.IsEnabled = index + 1 < pages.Count; }
        previous = ActionIconGlyph.Button(L10n.Text("common.teams.previous_page"), ActionIcon.Back, (_, _) => { index--; Update(); });
        next = ActionIconGlyph.Button(L10n.Text("common.next"), ActionIcon.Next, (_, _) => { index++; Update(); });
        panel.Children.Add(label); panel.Children.Add(previous); panel.Children.Add(next);
        panel.Children.Add(ActionIconGlyph.Button(L10n.Text("common.copy"), ActionIcon.Copy, (_, _) => CopyDraft(text)));
        Update(); return panel;
    }
    private static string NoticeLabel(string key) => key switch
    {
        "run_finished" => L10n.Text("common.teams.run_finished"), "run_failed" => L10n.Text("common.teams.run_failed"),
        "recorded_question" => L10n.Text("common.teams.recorded_question"), "recorded_message" => L10n.Text("common.teams.recorded_message"),
        "recorded_handoff" => L10n.Text("common.teams.recorded_handoff"), "recorded_approval" => L10n.Text("common.teams.recorded_approval"),
        "answer_withdrawn" => L10n.Text("common.teams.answer_withdrawn"), _ => L10n.Text("common.teams.event_unavailable"),
    };
}
