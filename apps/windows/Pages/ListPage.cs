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

internal sealed class ListPage : Page
{
    private readonly string _method;
    private readonly string _title;
    private readonly string _empty;
    private readonly string _hint;
    private readonly ActionIcon _symbol;
    private readonly string _itemKey;
    private readonly string? _kindEquals;
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };

    public ListPage(
        string method,
        string title,
        string empty,
        string hint,
        ActionIcon symbol,
        string itemKey = "title",
        string? kindEquals = null)
    {
        _method = method;
        _title = title;
        _empty = empty;
        _hint = hint;
        _symbol = symbol;
        _itemKey = itemKey;
        _kindEquals = kindEquals;
        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL),
            Content = _root,
        };
        Loaded += async (_, _) => await LoadAsync();
    }

    private async Task LoadAsync()
    {
        _root.Children.Clear();
        JsonNode result;
        try
        {
            result = await AppServices.Host.CallAsync(_method);
        }
        catch (Exception ex)
        {
            _root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }

        var array = result as JsonArray
            ?? result["items"] as JsonArray
            ?? result["jobs"] as JsonArray
            ?? result["workflows"] as JsonArray
            ?? result["notes"] as JsonArray;
        if (array is null || array.Count == 0)
        {
            _root.Children.Add(Chrome.Empty(_empty, _hint, _symbol));
            return;
        }

        var list = new StackPanel { Spacing = Theme.SpaceS };
        foreach (var item in array)
        {
            if (_kindEquals is not null && Format.Text(item, "kind") != _kindEquals)
            {
                continue;
            }
            list.Children.Add(Row(item));
        }
        if (list.Children.Count == 0)
        {
            _root.Children.Add(Chrome.Empty(_empty, _hint, _symbol));
            return;
        }
        _root.Children.Add(Chrome.Card(_title, list));
    }

    /// <summary>
    /// One row in the Mac folder and session anatomy: a leading accent tile,
    /// the name, one secondary line, an optional accent line, and a trailing
    /// chevron. The figure is what the row is for, so the title keeps the
    /// same left edge on every row and the mark fills the tile in front.
    /// </summary>
    private Border Row(JsonNode? item)
    {
        var label = Format.Text(item, _itemKey, Format.Text(item, "id", "(item)"));
        var lines = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        lines.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        var subtitle = Format.Text(item, "subtitle", Format.Text(item, "status"));
        if (!string.IsNullOrEmpty(subtitle))
        {
            lines.Children.Add(new TextBlock
            {
                Text = subtitle,
                FontSize = 11,
                Opacity = 0.65,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
        }
        var branch = Format.Text(item, "branch");
        if (!string.IsNullOrEmpty(branch))
        {
            lines.Children.Add(new TextBlock
            {
                Text = branch,
                FontSize = 11,
                Foreground = Theme.AccentBrush,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
        }

        var glyph = _symbol.Icon();
        glyph.Foreground = Theme.AccentBrush;
        var tile = new Border
        {
            Width = 26,
            Height = 26,
            CornerRadius = new CornerRadius(7),
            Background = Theme.AccentSoftBrush,
            VerticalAlignment = VerticalAlignment.Top,
            Child = new Viewbox
            {
                Width = 13,
                Height = 13,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Child = glyph,
            },
        };

        var grid = new Grid { ColumnSpacing = Theme.SpaceS };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(tile, 0);
        Grid.SetColumn(lines, 1);
        grid.Children.Add(tile);
        grid.Children.Add(lines);
        var chevron = new FontIcon
        {
            Glyph = "\uE972",
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
            FontSize = 12,
            Opacity = 0.4,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(chevron, 2);
        grid.Children.Add(chevron);

        return new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.SpaceM),
            Child = grid,
        };
    }
}
