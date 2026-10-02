// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Markdig;
using Markdig.Extensions.EmphasisExtras;
using Markdig.Extensions.Tables;
using Markdig.Extensions.TaskLists;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>
/// An agent's reply as formatted text, like the Mac chat: headings, lists,
/// quotes, tables, links and code, in native selectable text. Agents write
/// markdown, so plain text left `##` and `**` on screen as punctuation.
///
/// HTML is not rendered and images are not fetched: a reply is read, it
/// does not make requests. Code blocks are drawn by the caller so they keep
/// the chat's own copy menu and horizontal scrolling.
/// </summary>
internal static class ChatMarkdown
{
    private static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder()
        .DisableHtml()
        .UseTaskLists()
        .UsePipeTables()
        .UseEmphasisExtras(EmphasisExtraOptions.Strikethrough)
        .UseAutoLinks()
        .Build();

    private const double BodySize = 14;

    public static UIElement Create(string text, Func<string, UIElement> codeBlock)
    {
        MarkdownDocument document;
        try
        {
            document = Markdown.Parse(text, Pipeline);
        }
        catch
        {
            // A reply that cannot be parsed is still a reply.
            return Plain(text);
        }
        var body = Blocks(document, codeBlock);
        return body.Children.Count == 0 ? Plain(text) : body;
    }

    private static TextBlock Plain(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        IsTextSelectionEnabled = true,
        FontSize = BodySize,
    };

    private static StackPanel Blocks(ContainerBlock blocks, Func<string, UIElement> codeBlock)
    {
        var panel = new StackPanel { Spacing = Theme.SpaceS };
        foreach (var block in blocks)
        {
            switch (block)
            {
                case ListBlock list:
                    panel.Children.Add(ListItems(list, codeBlock));
                    break;
                case QuoteBlock quote:
                    panel.Children.Add(new Border
                    {
                        BorderBrush = Theme.AccentBrush,
                        BorderThickness = new Thickness(3, 0, 0, 0),
                        Padding = new Thickness(Theme.SpaceM, 0, 0, 0),
                        Opacity = 0.85,
                        Child = Blocks(quote, codeBlock),
                    });
                    break;
                case Table table:
                    panel.Children.Add(TableGrid(table, codeBlock));
                    break;
                case CodeBlock code:
                    panel.Children.Add(codeBlock(code.Lines.ToString().TrimEnd()));
                    break;
                case ThematicBreakBlock:
                    panel.Children.Add(new Border { Background = Theme.BorderBrush, Height = 1, Margin = new Thickness(0, 4, 0, 4) });
                    break;
                case LinkReferenceDefinitionGroup:
                    // `[1]: https://…` lines are targets for links above,
                    // not text. Rendering the group left an empty gap.
                    break;
                case LeafBlock leaf when leaf.Inline is not null:
                    panel.Children.Add(ParagraphText(leaf));
                    break;
                case ContainerBlock container:
                    panel.Children.Add(Blocks(container, codeBlock));
                    break;
            }
        }
        return panel;
    }

    private static RichTextBlock ParagraphText(LeafBlock leaf)
    {
        var paragraph = new Paragraph { Margin = new Thickness(0) };
        if (leaf.Inline is not null) Append(leaf.Inline, paragraph.Inlines);
        var text = new RichTextBlock
        {
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.Wrap,
            FontSize = BodySize,
        };
        if (leaf is HeadingBlock heading)
        {
            // The Mac chat's compact scale: a heading in a reply is a label,
            // not a page title.
            text.FontSize = heading.Level switch { 1 => 18, 2 => 16, _ => 15 };
            text.FontWeight = FontWeights.SemiBold;
            text.Margin = new Thickness(0, 4, 0, 0);
        }
        text.Blocks.Add(paragraph);
        return text;
    }

    private static StackPanel ListItems(ListBlock list, Func<string, UIElement> codeBlock)
    {
        var items = new StackPanel { Spacing = 4 };
        var number = int.TryParse(list.OrderedStart, out var start) ? start : 1;
        foreach (var item in list.OfType<ListItemBlock>())
        {
            var row = new Grid { ColumnSpacing = 6 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var task = item.FirstOrDefault() is ParagraphBlock first && first.Inline?.FirstChild is TaskList;
            row.Children.Add(new TextBlock
            {
                Text = task ? "" : list.IsOrdered ? $"{number++}." : "•",
                FontSize = BodySize,
                Opacity = 0.7,
                HorizontalAlignment = HorizontalAlignment.Right,
            });
            var content = Blocks(item, codeBlock);
            content.Spacing = 4;
            Grid.SetColumn(content, 1);
            row.Children.Add(content);
            items.Children.Add(row);
        }
        return items;
    }

    /// <summary>A pipe table as a grid: a tinted header row and hairlines between rows.</summary>
    private static UIElement TableGrid(Table table, Func<string, UIElement> codeBlock)
    {
        var grid = new Grid();
        var columns = table.OfType<TableRow>().Select(row => row.Count).DefaultIfEmpty(0).Max();
        for (var column = 0; column < columns; column++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        }
        var rowIndex = 0;
        foreach (var row in table.OfType<TableRow>())
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var columnIndex = 0;
            foreach (var cell in row.OfType<TableCell>())
            {
                var content = Blocks(cell, codeBlock);
                if (row.IsHeader)
                {
                    foreach (var child in content.Children.OfType<RichTextBlock>()) child.FontWeight = FontWeights.SemiBold;
                }
                var frame = new Border
                {
                    Padding = new Thickness(Theme.SpaceS, 6, Theme.SpaceS, 6),
                    BorderBrush = Theme.BorderBrush,
                    BorderThickness = new Thickness(0, 0, 0, 1),
                    Background = row.IsHeader ? Theme.AccentSoftBrush : null,
                    Child = content,
                };
                Grid.SetRow(frame, rowIndex);
                Grid.SetColumn(frame, Math.Min(columnIndex, Math.Max(0, columns - 1)));
                grid.Children.Add(frame);
                columnIndex += Math.Max(1, cell.ColumnSpan);
            }
            rowIndex++;
        }
        return new Border
        {
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = grid,
        };
    }

    private static void Append(ContainerInline container, InlineCollection output)
    {
        foreach (var inline in container)
        {
            switch (inline)
            {
                case LiteralInline literal:
                    output.Add(new Run { Text = literal.Content.ToString() });
                    break;
                case HtmlEntityInline entity:
                    output.Add(new Run { Text = entity.Transcoded.ToString() });
                    break;
                case LineBreakInline line:
                    output.Add(line.IsHard ? new LineBreak() : new Run { Text = " " });
                    break;
                case CodeInline code:
                    output.Add(new Run { Text = code.Content, FontFamily = Fonts.Mono, Foreground = Theme.AccentBrush });
                    break;
                case TaskList task:
                    output.Add(new Run { Text = task.Checked ? "☑ " : "☐ " });
                    break;
                case EmphasisInline emphasis:
                    Span span = emphasis.DelimiterChar == '~'
                        ? new Span { TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough }
                        : emphasis.DelimiterCount >= 2 ? new Bold() : new Italic();
                    Append(emphasis, span.Inlines);
                    output.Add(span);
                    break;
                case LinkInline link:
                    if (!link.IsImage && NoteMarkdown.Link(link.Url) is { } uri)
                    {
                        var anchor = new Hyperlink { NavigateUri = uri };
                        Append(link, anchor.Inlines);
                        output.Add(anchor);
                    }
                    else
                    {
                        Append(link, output);
                    }
                    break;
                case AutolinkInline link:
                    if (NoteMarkdown.Link(link.IsEmail ? "mailto:" + link.Url : link.Url) is { } destination)
                    {
                        var anchor = new Hyperlink { NavigateUri = destination };
                        anchor.Inlines.Add(new Run { Text = link.Url });
                        output.Add(anchor);
                    }
                    else
                    {
                        output.Add(new Run { Text = link.Url });
                    }
                    break;
                case ContainerInline nested:
                    Append(nested, output);
                    break;
            }
        }
    }
}
