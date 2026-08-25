// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed class WorkspacePage : Page
{
    private const int HugeChars = 200_000;

    private readonly string _id;
    private readonly WorkspaceSection _section;
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private string _path = "";
    private string _commitDraft = "";

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
                case WorkspaceSection.Sessions:
                    await LoadSessionsAsync();
                    break;
                case WorkspaceSection.Browser:
                    await LoadBrowserAsync();
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
        var chrome = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        if (_path.Length > 0)
        {
            chrome.Children.Add(ActionIconGlyph.Button("Back", ActionIcon.Back, async (_, _) =>
            {
                _path = ParentPath(_path);
                await LoadAsync();
            }));
        }
        chrome.Children.Add(new TextBlock
        {
            Text = _path.Length == 0 ? "Workspace root" : _path,
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
        _root.Children.Add(chrome);

        var tree = await AppServices.Host.CallAsync(
            "workspace.tree",
            new JsonObject { ["id"] = _id, ["path"] = _path });
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
            var entryPath = Format.Text(entry, "path", name);
            var dir = Format.Flag(entry, "isDir") || Format.Flag(entry, "dir");
            var ignored = Format.Flag(entry, "ignored");
            var open = new Button
            {
                Content = (dir ? "▸ " : "") + name,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Opacity = ignored ? 0.55 : 1,
            };
            var capturedPath = entryPath;
            var capturedDir = dir;
            var capturedName = name;
            open.Click += async (_, _) =>
            {
                if (capturedDir)
                {
                    _path = capturedPath;
                    await LoadAsync();
                    return;
                }
                await OpenFileAsync(capturedPath, capturedName);
            };
            list.Children.Add(open);
        }
        _root.Children.Add(Chrome.Card("Files", list));
    }

    private async Task OpenFileAsync(string path, string name)
    {
        JsonNode read;
        try
        {
            read = await AppServices.Host.CallAsync(
                "workspace.read",
                new JsonObject { ["id"] = _id, ["path"] = path });
        }
        catch (Exception ex)
        {
            _root.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }

        var content = Format.Text(read, "content");
        var huge = content.Length > HugeChars;
        var shown = huge ? content[..HugeChars] : content;
        var editor = new TextBox
        {
            Text = shown,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            FontFamily = new FontFamily("Consolas"),
            IsReadOnly = huge,
            Height = 420,
            MinWidth = 640,
        };
        var body = new StackPanel { Spacing = Theme.SpaceS };
        if (huge)
        {
            body.Children.Add(new TextBlock
            {
                Text = "This file is too large to edit here. Showing the start, read-only.",
                TextWrapping = TextWrapping.Wrap,
                Opacity = 0.8,
            });
        }
        body.Children.Add(editor);

        var dialog = new ContentDialog
        {
            Title = name,
            Content = body,
            CloseButtonText = huge ? "Close" : "Cancel",
            DefaultButton = huge ? ContentDialogButton.Close : ContentDialogButton.Primary,
        };
        if (!huge)
        {
            dialog.PrimaryButtonText = "Save";
        }
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary || huge)
        {
            return;
        }
        try
        {
            var outcome = await AppServices.Host.CallAsync(
                "workspace.write",
                new JsonObject
                {
                    ["id"] = _id,
                    ["path"] = path,
                    ["content"] = editor.Text,
                });
            if (!OutcomeOk(outcome, out var message))
            {
                _root.Children.Insert(1, Chrome.Banner(message, Theme.Danger, Symbol.Important));
            }
        }
        catch (Exception ex)
        {
            _root.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
        }
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

        var commitBox = new TextBox
        {
            PlaceholderText = "Commit message",
            Text = _commitDraft,
            MinWidth = 280,
        };
        commitBox.TextChanged += (_, _) => _commitDraft = commitBox.Text;
        var commitRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        commitRow.Children.Add(commitBox);
        commitRow.Children.Add(ActionIconGlyph.Button("Commit", ActionIcon.Commit, async (_, _) =>
        {
            await GitwriteAsync("workspace.commit", new JsonObject
            {
                ["id"] = _id,
                ["message"] = _commitDraft,
            });
        }));
        _root.Children.Add(commitRow);

        if (array is null || array.Count == 0)
        {
            var clean = string.IsNullOrEmpty(branch)
                ? "No uncommitted changes in this folder."
                : $"On {branch}. No uncommitted changes.";
            _root.Children.Add(Chrome.Empty("Clean tree", clean, Symbol.Accept));
            return;
        }

        var list = new StackPanel { Spacing = Theme.SpaceS };
        if (!string.IsNullOrEmpty(branch))
        {
            list.Children.Add(new TextBlock { Text = "On " + branch, Opacity = 0.7 });
        }
        foreach (var entry in array)
        {
            var path = Format.Text(entry, "path", Format.Text(entry, "name"));
            var kind = Format.Text(entry, "kind", Format.Text(entry, "status"));
            if (string.IsNullOrEmpty(path))
            {
                continue;
            }
            var filePath = path;
            var line = new Grid();
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.Children.Add(new TextBlock
            {
                Text = string.IsNullOrEmpty(kind) ? path : $"{kind} {path}",
                TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center,
            });
            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceS,
            };
            actions.Children.Add(ActionIconGlyph.Button("Stage", ActionIcon.Apply, async (_, _) =>
            {
                var paths = new JsonArray { JsonValue.Create(filePath) };
                await GitwriteAsync("workspace.stage", new JsonObject
                {
                    ["id"] = _id,
                    ["paths"] = paths,
                });
            }));
            actions.Children.Add(ActionIconGlyph.Button("Unstage", ActionIcon.Restore, async (_, _) =>
            {
                var paths = new JsonArray { JsonValue.Create(filePath) };
                await GitwriteAsync("workspace.unstage", new JsonObject
                {
                    ["id"] = _id,
                    ["paths"] = paths,
                });
            }));
            Grid.SetColumn(actions, 1);
            line.Children.Add(actions);
            list.Children.Add(line);
        }
        _root.Children.Add(Chrome.Card("Changes", list));
    }

    private async Task GitwriteAsync(string method, JsonObject parameters)
    {
        try
        {
            var outcome = await AppServices.Host.CallAsync(method, parameters);
            if (!OutcomeOk(outcome, out var message))
            {
                _root.Children.Insert(1, Chrome.Banner(message, Theme.Danger, Symbol.Important));
                return;
            }
            if (method == "workspace.commit")
            {
                _commitDraft = "";
            }
        }
        catch (Exception ex)
        {
            _root.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }
        await LoadAsync();
    }

    private async Task LoadSessionsAsync()
    {
        var chrome = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        chrome.Children.Add(ActionIconGlyph.Button("New shell", ActionIcon.Create, (_, _) =>
        {
            var open = AppServices.OpenTerminal;
            if (open is null)
            {
                _root.Children.Insert(1, Chrome.Banner(
                    "Terminals are not wired in this window.",
                    Theme.Danger,
                    Symbol.Important));
                return;
            }
            open(_id, null);
        }));
        _root.Children.Add(chrome);

        var listed = await AppServices.Host.CallAsync("pty.list");
        var array = listed as JsonArray
            ?? listed["sessions"] as JsonArray
            ?? listed["items"] as JsonArray;
        var list = new StackPanel { Spacing = Theme.SpaceS };
        var n = 0;
        if (array is not null)
        {
            foreach (var item in array)
            {
                if (Format.Flag(item, "hidden"))
                {
                    continue;
                }
                var workspace = Format.Text(item, "workspaceId");
                if (workspace != _id)
                {
                    continue;
                }
                var id = Format.Text(item, "id");
                if (string.IsNullOrEmpty(id))
                {
                    continue;
                }
                n++;
                var command = Format.Text(item, "command", "shell");
                var alive = Format.Flag(item, "alive") ? "running" : "exited";
                var open = new Button
                {
                    Content = $"{command} · {alive}",
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Left,
                };
                var sessionId = id;
                open.Click += (_, _) => AppServices.OpenTerminal?.Invoke(_id, sessionId);
                list.Children.Add(open);
            }
        }
        if (n == 0)
        {
            _root.Children.Add(Chrome.Empty(
                "No shells in this folder",
                "Open a new shell. It runs on this PC through the host.",
                Symbol.Play));
            return;
        }
        _root.Children.Add(Chrome.Card("Sessions", list));
    }

    private async Task LoadBrowserAsync()
    {
        var portBox = new TextBox
        {
            PlaceholderText = "Port",
            MinWidth = 120,
        };
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        row.Children.Add(portBox);
        row.Children.Add(ActionIconGlyph.Button("Open", ActionIcon.Browser, async (_, _) =>
        {
            await OpenPortAsync(portBox.Text);
        }));
        _root.Children.Add(row);
        _root.Children.Add(new TextBlock
        {
            Text = "Opens a loopback page on this PC in the in-app browser. Use the port a local dev server is already listening on.",
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
    }

    private async Task OpenPortAsync(string raw)
    {
        if (!ushort.TryParse(raw.Trim(), out var port) || port == 0)
        {
            _root.Children.Insert(1, Chrome.Banner(
                "Enter a port between 1 and 65535.",
                Theme.Danger,
                Symbol.Important));
            return;
        }
        var open = AppServices.OpenBrowser;
        if (open is null)
        {
            _root.Children.Insert(1, Chrome.Banner(
                "The in-app browser is not wired in this window.",
                Theme.Danger,
                Symbol.Important));
            return;
        }

        var host = "127.0.0.1";
        var unlistens = false;
        var url = $"http://{host}:{port}/";
        try
        {
            var listened = await AppServices.Host.CallAsync(
                "proxy.listen",
                new JsonObject
                {
                    ["host"] = host,
                    ["port"] = port,
                });
            var returned = Format.Text(listened, "url");
            if (!string.IsNullOrEmpty(returned))
            {
                url = returned;
            }
            unlistens = true;
        }
        catch (Exception ex)
        {
            var missingPeer = ex.Message.Contains("peer", StringComparison.OrdinalIgnoreCase)
                || ex.Message.Contains("missing field", StringComparison.OrdinalIgnoreCase);
            if (!missingPeer)
            {
                _root.Children.Insert(1, Chrome.Banner(
                    ex.Message + " Opening the port directly on this PC.",
                    Theme.Warning,
                    Symbol.Important));
            }
        }
        open(url, host, port, unlistens);
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

    private static bool OutcomeOk(JsonNode outcome, out string message)
    {
        message = Format.Text(outcome, "message", "The command failed.");
        if (outcome is JsonObject && outcome["ok"] is not null)
        {
            return Format.Flag(outcome, "ok");
        }
        return true;
    }

    private static string ParentPath(string path)
    {
        var i = path.LastIndexOf('/');
        return i <= 0 ? "" : path[..i];
    }
}
