// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>
/// Notes share the tasks store. A note is a card whose kind is note.
/// Pass a workspace id to scope the board to that folder.
/// </summary>
internal sealed class NotesPage : Page
{
    private readonly string? _workspaceId;
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly TextBox _title = new() { PlaceholderText = "New note" };

    public NotesPage(string? workspaceId = null)
    {
        _workspaceId = workspaceId;
        var add = ActionIconGlyph.Button("Add", ActionIcon.Create, async (_, _) => await CreateAsync());
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(add, 1);
        row.Children.Add(_title);
        row.Children.Add(add);
        _root.Children.Add(row);
        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL),
            Content = _root,
        };
        Loaded += async (_, _) => await LoadAsync();
    }

    private async Task CreateAsync()
    {
        var title = _title.Text.Trim();
        if (title.Length == 0)
        {
            return;
        }
        try
        {
            await AppServices.Host.CallAsync(
                "todo.create",
                new JsonObject
                {
                    ["title"] = title,
                    ["kind"] = "note",
                    ["notes"] = "",
                    ["column"] = "backlog",
                    ["backend"] = "",
                    ["workspaceId"] = _workspaceId ?? "",
                    ["budgetSeconds"] = 0,
                });
            _title.Text = "";
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private async Task LoadAsync()
    {
        while (_root.Children.Count > 1)
        {
            _root.Children.RemoveAt(1);
        }
        JsonNode cards;
        try
        {
            cards = await AppServices.Host.CallAsync("todo.list");
        }
        catch (Exception ex)
        {
            _root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }

        var array = Format.Items(cards);
        var list = new StackPanel { Spacing = Theme.SpaceS };
        if (array is not null)
        {
            foreach (var card in array)
            {
                if (Format.Text(card, "kind") != "note")
                {
                    continue;
                }
                if (!Format.InWorkspace(card, _workspaceId, includeUnscoped: true))
                {
                    continue;
                }
                var title = Format.Text(card, "title", "(untitled)");
                var column = Format.Text(card, "column");
                var id = Format.Text(card, "id");
                var line = new Grid();
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                line.Children.Add(new TextBlock
                {
                    Text = string.IsNullOrEmpty(column) ? title : $"{title} · {column}",
                    TextWrapping = TextWrapping.Wrap,
                    VerticalAlignment = VerticalAlignment.Center,
                });
                if (!string.IsNullOrEmpty(id))
                {
                    var remove = ActionIconGlyph.Button("Remove", ActionIcon.Delete, async (_, _) =>
                    {
                        try
                        {
                            await AppServices.Host.CallAsync("todo.remove", new JsonObject { ["id"] = id });
                        }
                        catch (Exception ex)
                        {
                            Banner(ex.Message);
                            return;
                        }
                        await LoadAsync();
                    });
                    Grid.SetColumn(remove, 1);
                    line.Children.Add(remove);
                }
                list.Children.Add(line);
            }
        }
        if (list.Children.Count == 0)
        {
            _root.Children.Add(Chrome.Empty(
                "No notes yet",
                "A note is text kept beside the folder it belongs to.",
                Symbol.OpenFile));
            return;
        }
        _root.Children.Add(Chrome.Card("Notes", list));
    }

    private void Banner(string text)
    {
        if (_root.Children.Count > 1)
        {
            _root.Children.Insert(1, Chrome.Banner(text, Theme.Danger, Symbol.Important));
        }
        else
        {
            _root.Children.Add(Chrome.Banner(text, Theme.Danger, Symbol.Important));
        }
    }
}
