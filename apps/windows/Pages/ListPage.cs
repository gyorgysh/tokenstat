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
    private readonly Symbol _symbol;
    private readonly string _itemKey;
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };

    public ListPage(string method, string title, string empty, string hint, Symbol symbol, string itemKey = "title")
    {
        _method = method;
        _title = title;
        _empty = empty;
        _hint = hint;
        _symbol = symbol;
        _itemKey = itemKey;
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
            var label = Format.Text(item, _itemKey, Format.Text(item, "id", "(item)"));
            var extra = Format.Text(item, "enabled") is { Length: > 0 }
                ? ""
                : Format.Text(item, "status");
            list.Children.Add(new TextBlock
            {
                Text = string.IsNullOrEmpty(extra) ? label : $"{label} · {extra}",
                TextWrapping = TextWrapping.Wrap,
            });
        }
        _root.Children.Add(Chrome.Card(_title, list));
    }
}
