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

internal sealed class TodoPage : Page
{
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly TextBox _title = new() { PlaceholderText = "New task" };

    public TodoPage()
    {
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
            await AppServices.Host.CallAsync("todo.create", new JsonObject { ["title"] = title });
            _title.Text = "";
        }
        catch (Exception ex)
        {
            _root.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
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

        var array = cards as JsonArray ?? cards["cards"] as JsonArray ?? cards["items"] as JsonArray;
        if (array is null || array.Count == 0)
        {
            _root.Children.Add(Chrome.Empty(
                "No tasks yet",
                "Add a task to run it with an agent in a folder.",
                Symbol.AllApps));
            return;
        }

        var list = new StackPanel { Spacing = Theme.SpaceS };
        foreach (var card in array)
        {
            var title = Format.Text(card, "title", "(untitled)");
            var column = Format.Text(card, "column", "");
            var id = Format.Text(card, "id");
            var line = new Grid();
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.Children.Add(new TextBlock
            {
                Text = string.IsNullOrEmpty(column) ? title : $"{title} · {column}",
                TextWrapping = TextWrapping.Wrap,
            });
            if (!string.IsNullOrEmpty(id))
            {
                var remove = ActionIconGlyph.Button("Remove", ActionIcon.Delete, async (_, _) =>
                {
                    try
                    {
                        await AppServices.Host.CallAsync("todo.remove", new JsonObject { ["id"] = id });
                    }
                    catch
                    {
                        // Keep the row if the host refused.
                    }
                    await LoadAsync();
                });
                Grid.SetColumn(remove, 1);
                line.Children.Add(remove);
            }
            list.Children.Add(line);
        }
        _root.Children.Add(Chrome.Card("Tasks", list));
    }
}
