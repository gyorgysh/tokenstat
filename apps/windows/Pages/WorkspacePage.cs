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
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed class WorkspacePage : Page
{
    private readonly string _id;
    private readonly WorkspaceSection _section;
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };

    public WorkspacePage(string id, WorkspaceSection section)
    {
        _id = id;
        _section = section;
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
        _root.Children.Add(new TextBlock
        {
            Text = _section.Label(),
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        try
        {
            switch (_section)
            {
                case WorkspaceSection.Files:
                    await LoadFilesAsync();
                    break;
                case WorkspaceSection.Changes:
                    await LoadChangesAsync();
                    break;
                case WorkspaceSection.Todo:
                    await LoadTodoAsync();
                    break;
                default:
                    _root.Children.Add(Chrome.Empty(
                        _section.Label() + " on Windows",
                        "The Mac app has the full " + _section.Label().ToLowerInvariant()
                        + " surface. This build lists the folder and the shared boards.",
                        Symbol.Folder));
                    break;
            }
        }
        catch (Exception ex)
        {
            _root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
        }
    }

    private async Task LoadFilesAsync()
    {
        var tree = await AppServices.Host.CallAsync(
            "workspace.tree",
            new JsonObject { ["id"] = _id, ["path"] = "" });
        var array = tree as JsonArray ?? tree["entries"] as JsonArray;
        if (array is null || array.Count == 0)
        {
            _root.Children.Add(Chrome.Empty("Empty folder", "Nothing to list here.", Symbol.Folder));
            return;
        }
        var list = new StackPanel { Spacing = 4 };
        foreach (var entry in array)
        {
            var name = Format.Text(entry, "name", Format.Text(entry, "path"));
            var dir = entry?["dir"]?.GetValue<bool>() ?? entry?["isDir"]?.GetValue<bool>() ?? false;
            list.Children.Add(new TextBlock { Text = (dir ? "▸ " : "  ") + name });
        }
        _root.Children.Add(Chrome.Card("Files", list));
    }

    private async Task LoadChangesAsync()
    {
        var status = await AppServices.Host.CallAsync(
            "workspace.status",
            new JsonObject { ["id"] = _id });
        var git = status["git"];
        var array = git?["files"] as JsonArray
            ?? status["files"] as JsonArray
            ?? status as JsonArray;
        var branch = Format.Text(git, "branch", Format.Text(status, "branch"));
        if (array is null || array.Count == 0)
        {
            var clean = string.IsNullOrEmpty(branch)
                ? "No uncommitted changes in this folder."
                : $"On {branch}. No uncommitted changes.";
            _root.Children.Add(Chrome.Empty("Clean tree", clean, Symbol.Accept));
            return;
        }
        var list = new StackPanel { Spacing = 4 };
        if (!string.IsNullOrEmpty(branch))
        {
            list.Children.Add(new TextBlock { Text = "On " + branch, Opacity = 0.7 });
        }
        foreach (var entry in array)
        {
            var path = Format.Text(entry, "path", Format.Text(entry, "name"));
            var kind = Format.Text(entry, "kind", Format.Text(entry, "status"));
            list.Children.Add(new TextBlock { Text = string.IsNullOrEmpty(kind) ? path : $"{kind} {path}" });
        }
        _root.Children.Add(Chrome.Card("Changes", list));
    }

    private async Task LoadTodoAsync()
    {
        var cards = await AppServices.Host.CallAsync("todo.list");
        var array = cards as JsonArray ?? cards["cards"] as JsonArray;
        var list = new StackPanel { Spacing = Theme.SpaceS };
        var n = 0;
        if (array is not null)
        {
            foreach (var card in array)
            {
                var workspace = Format.Text(card, "workspaceId");
                if (!string.IsNullOrEmpty(workspace) && workspace != _id)
                {
                    continue;
                }
                n++;
                list.Children.Add(new TextBlock { Text = Format.Text(card, "title", "(untitled)") });
            }
        }
        if (n == 0)
        {
            _root.Children.Add(Chrome.Empty("No tasks in this folder", "Add one from Tasks.", Symbol.AllApps));
            return;
        }
        _root.Children.Add(Chrome.Card("Tasks", list));
    }
}
