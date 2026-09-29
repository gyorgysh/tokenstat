// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Markdig.Syntax;
using Markdig.Syntax.Inlines;
using Markdig.Extensions.TaskLists;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>Read a note with native selectable text and no browser surface.</summary>
internal static class NotePreview
{
    public static UIElement Create(string text)
    {
        var body = Blocks(NoteMarkdown.Parse(text));
        if (body.Children.Count == 0)
            body.Children.Add(new TextBlock { Text = "Start writing to see your note here.", Opacity = 0.65 });
        return body;
    }

    private static StackPanel Blocks(ContainerBlock blocks)
    {
        var panel = new StackPanel { Spacing = Theme.SpaceM };
        foreach (var block in blocks)
        {
            switch (block)
            {
                case ListBlock list:
                    var items = new StackPanel { Spacing = Theme.SpaceS };
                    int number = int.TryParse(list.OrderedStart, out var start) ? start : 1;
                    foreach (var item in list.OfType<ListItemBlock>())
                    {
                        var row = new Grid { ColumnSpacing = Theme.SpaceS };
                        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
                        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                        bool task = item.FirstOrDefault() is ParagraphBlock first && first.Inline?.FirstChild is TaskList;
                        row.Children.Add(new TextBlock { Text = task ? "" : list.IsOrdered ? $"{number++}." : "•" });
                        var content = Blocks(item);
                        Grid.SetColumn(content, 1); row.Children.Add(content); items.Children.Add(row);
                    }
                    panel.Children.Add(items);
                    break;
                case QuoteBlock quote:
                    panel.Children.Add(new Border
                    {
                        BorderBrush = Theme.AccentBrush, BorderThickness = new Thickness(3, 0, 0, 0),
                        Padding = new Thickness(Theme.SpaceM, 0, 0, 0), Child = Blocks(quote),
                    });
                    break;
                case CodeBlock code:
                    panel.Children.Add(new Border
                    {
                        Background = Theme.BackgroundBrush, Padding = new Thickness(Theme.SpaceM),
                        CornerRadius = new CornerRadius(8), Child = new TextBlock
                        {
                            Text = code.Lines.ToString(), IsTextSelectionEnabled = true,
                            FontFamily = new FontFamily("Consolas"), FontSize = 13, TextWrapping = TextWrapping.Wrap,
                        },
                    });
                    break;
                case ThematicBreakBlock:
                    panel.Children.Add(new Border { Background = Theme.BorderBrush, Height = 1 });
                    break;
                case LeafBlock leaf when leaf.Inline is not null:
                    var paragraph = new Paragraph { Margin = new Thickness(0) };
                    Append(leaf.Inline, paragraph.Inlines);
                    var text = new RichTextBlock { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, FontSize = 14 };
                    if (leaf is HeadingBlock heading)
                    {
                        text.FontSize = heading.Level switch { 1 => 26, 2 => 22, 3 => 18, _ => 15 };
                        text.FontWeight = FontWeights.SemiBold;
                    }
                    text.Blocks.Add(paragraph); panel.Children.Add(text);
                    break;
                case ContainerBlock container:
                    panel.Children.Add(Blocks(container));
                    break;
            }
        }
        return panel;
    }

    private static void Append(ContainerInline container, InlineCollection output)
    {
        foreach (var inline in container)
        {
            switch (inline)
            {
                case LiteralInline literal: output.Add(new Run { Text = literal.Content.ToString() }); break;
                case HtmlEntityInline entity: output.Add(new Run { Text = entity.Transcoded.ToString() }); break;
                case LineBreakInline line: output.Add(line.IsHard ? new LineBreak() : new Run { Text = " " }); break;
                case CodeInline code: output.Add(new Run { Text = code.Content, FontFamily = new FontFamily("Consolas") }); break;
                case TaskList task: output.Add(new Run { Text = task.Checked ? "☑ " : "☐ " }); break;
                case EmphasisInline emphasis:
                    Span span = emphasis.DelimiterChar == '~' ? new Span { TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough }
                        : emphasis.DelimiterCount >= 2 ? new Bold() : new Italic();
                    Append(emphasis, span.Inlines); output.Add(span); break;
                case LinkInline link:
                    if (!link.IsImage && NoteMarkdown.Link(link.Url) is { } uri)
                    {
                        var anchor = new Hyperlink { NavigateUri = uri };
                        Append(link, anchor.Inlines); output.Add(anchor);
                    }
                    else
                    {
                        // Image descriptions remain readable without making
                        // background network requests while opening a note.
                        Append(link, output);
                    }
                    break;
                case AutolinkInline link:
                    if (NoteMarkdown.Link(link.IsEmail ? "mailto:" + link.Url : link.Url) is { } destination)
                    {
                        var anchor = new Hyperlink { NavigateUri = destination };
                        anchor.Inlines.Add(new Run { Text = link.Url }); output.Add(anchor);
                    }
                    else output.Add(new Run { Text = link.Url });
                    break;
                case ContainerInline nested: Append(nested, output); break;
            }
        }
    }
}
