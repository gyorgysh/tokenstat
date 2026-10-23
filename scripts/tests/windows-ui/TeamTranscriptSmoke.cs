// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Tokenstat.Pages;

namespace NativeUiTests
{
    internal static class TeamTranscriptSmoke
    {
        private static IEnumerable<Hyperlink> Links(InlineCollection inlines)
        {
            foreach (var inline in inlines)
            {
                if (inline is Hyperlink link) yield return link;
                if (inline is Span span) foreach (var child in Links(span.Inlines)) yield return child;
            }
        }
        private static IEnumerable<Hyperlink> Links(UIElement element)
        {
            if (element is RichTextBlock rich)
                foreach (var paragraph in rich.Blocks.OfType<Paragraph>()) foreach (var link in Links(paragraph.Inlines)) yield return link;
            if (element is Panel panel)
                foreach (var child in panel.Children) foreach (var link in Links(child)) yield return link;
            if (element is Border { Child: { } nested }) foreach (var link in Links(nested)) yield return link;
            if (element is ScrollViewer { Content: UIElement content }) foreach (var link in Links(content)) yield return link;
        }
        internal static void Run(StackPanel body)
        {
            const string source = "[Private workbench](tokenstat://workbench/open?workspace=fictional&tool=terminal&new=1) [Web](https://example.invalid/fictional) ![Remote image](https://example.invalid/image.png)";
            var shared = ChatMarkdown.Create(source, code => new TextBlock { Text = code }, allowDesktopActions: false);
            body.Children.Add(shared); body.UpdateLayout();
            var links = Links(shared).ToList();
            if (links.Count != 1 || links[0].NavigateUri?.Scheme != "https") throw new Exception("Shared Markdown exposed a personal desktop action");
            body.Children.Remove(shared);
            var personal = ChatMarkdown.Create(source, code => new TextBlock { Text = code });
            if (Links(personal).Count() != 2) throw new Exception("Personal Markdown lost its explicit desktop action");
            Program.Log("PASS: shared Markdown keeps web links and rejects personal desktop actions without fetching images");
        }
    }
}
namespace Tokenstat
{
    // The fixture never opens a real workspace or terminal.
    internal static class AppServices
    {
        internal static Action<Tokenstat.Navigation.DesktopOpenRequest>? OpenDesktopAction { get; set; }
        internal static FixtureHost Host { get; } = new();
        internal static void NotifyTeamProjectsChanged() { }
    }
    internal sealed class FixtureHost
    {
        internal Task<System.Text.Json.Nodes.JsonNode> CallAsync(string method, System.Text.Json.Nodes.JsonNode? fields = null) =>
            throw new InvalidOperationException("The fixture requires an injected host");
    }
}
