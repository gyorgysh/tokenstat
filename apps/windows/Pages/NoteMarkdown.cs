// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Markdig;
using Markdig.Syntax;
using Markdig.Extensions.EmphasisExtras;

namespace Tokenstat.Pages;

internal static class NoteMarkdown
{
    private static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder()
        .DisableHtml().UseTaskLists().UseEmphasisExtras(EmphasisExtraOptions.Strikethrough).Build();
    public static MarkdownDocument Parse(string text) => Markdown.Parse(text, Pipeline);
    public static Uri? Link(string? value) => Uri.TryCreate(value, UriKind.Absolute, out var uri)
        && uri.Scheme is "https" or "http" or "mailto" ? uri : null;
}
