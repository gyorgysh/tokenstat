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
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Tokenstat.Pages;

/// <summary>
/// The dialog behind "Add project". The decision is which folder.
/// Everything else is two facts about that choice: agents work there, and
/// adding it does not upload it. Mirrors the desktop Mac sheet.
/// </summary>
internal static class WorkspaceAddDialog
{
    /// <summary>
    /// Pick a folder, name it, register it. Returns the new workspace id,
    /// or null when the dialog was dismissed or the add failed.
    /// </summary>
    public static async Task<string?> ShowAsync(UIElement owner)
    {
        var pathBox = new TextBox
        {
            PlaceholderText = @"C:\projects\my-app",
            MinWidth = 320,
        };
        var nameBox = new TextBox
        {
            PlaceholderText = "Name for the sidebar",
            MinWidth = 320,
        };
        var form = new StackPanel { Spacing = Theme.SpaceM };
        form.Children.Add(new TextBlock
        {
            Text = "Choose the project folder your agents should work in.",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        form.Children.Add(new TextBlock
        {
            Text = "Pick a repository you actually work in. It is the folder an agent opens, not your home directory and not a system folder.",
            TextWrapping = TextWrapping.Wrap,
        });
        var pathRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        pathRow.Children.Add(pathBox);
        pathRow.Children.Add(ActionIconGlyph.Button(
            "Browse", ActionIcon.Reveal, async (_, _) =>
            {
                var picked = await PickFolderAsync();
                if (!string.IsNullOrEmpty(picked))
                {
                    pathBox.Text = picked;
                    if (string.IsNullOrWhiteSpace(nameBox.Text))
                    {
                        nameBox.Text = DefaultName(picked);
                    }
                }
            }));
        form.Children.Add(pathRow);
        form.Children.Add(nameBox);
        form.Children.Add(InfoRow(
            ActionIcon.Source,
            "Agents work in this folder",
            "They run as their own processes there. tokenstat reads git state so it can show changes, diffs and history."));
        form.Children.Add(InfoRow(
            ActionIcon.Security,
            "Nothing is uploaded",
            "Adding a workspace does not send the folder anywhere. Only usage counters are eligible for sync."));
        var error = new TextBlock
        {
            Foreground = Theme.Brush(static () => Theme.Danger),
            TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
        };
        form.Children.Add(error);

        var dialog = new ContentDialog
        {
            Title = "Add a project",
            Content = form,
            PrimaryButtonText = "Add project",
            SecondaryButtonText = "On another machine…",
            CloseButtonText = "Not now",
            DefaultButton = ContentDialogButton.Primary,
        };
        JsonNode? added = null;
        dialog.Closing += (_, args) => args.Cancel = !dialog.IsPrimaryButtonEnabled && added is null;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var path = pathBox.Text.Trim();
            if (string.IsNullOrEmpty(path) || !Directory.Exists(path))
            {
                error.Text = "Pick a folder that exists. Browse opens the folder picker.";
                error.Visibility = Visibility.Visible;
                return;
            }
            dialog.IsPrimaryButtonEnabled = false;
            dialog.IsSecondaryButtonEnabled = false;
            dialog.PrimaryButtonText = "Adding…";
            error.Visibility = Visibility.Collapsed;
            try
            {
                added = await AppServices.Host.CallAsync(
                    "workspace.add", new JsonObject { ["path"] = path });
                if (string.IsNullOrEmpty(Format.Text(added, "id")))
                    throw new InvalidOperationException("The host did not return the added workspace. Try again.");
                dialog.Hide();
            }
            catch (Exception ex)
            {
                added = null;
                error.Text = FriendlyError.Display(ex.Message);
                error.Visibility = Visibility.Visible;
            }
            finally
            {
                dialog.IsPrimaryButtonEnabled = true;
                dialog.IsSecondaryButtonEnabled = true;
                dialog.PrimaryButtonText = "Add project";
            }
        };
        var result = await Chrome.ShowDialog(owner, dialog);
        if (result == ContentDialogResult.Secondary)
            return await RemoteWorkspaceAddDialog.ShowAsync(owner);
        if (added is null) return null;
        var id = Format.Text(added, "id");
        if (string.IsNullOrEmpty(id))
        {
            return null;
        }
        var name = nameBox.Text.Trim();
        if (!string.IsNullOrEmpty(name) && name != Format.Text(added, "name"))
        {
            try
            {
                await AppServices.Host.CallAsync(
                    "workspace.rename",
                    new JsonObject { ["id"] = id, ["name"] = name });
            }
            catch
            {
                // The folder is added with its default name. Renaming is a
                // nicety, and failing it must not un-add the folder.
            }
        }
        return id;
    }

    private static StackPanel InfoRow(ActionIcon icon, string title, string text)
    {
        var row = new StackPanel { Spacing = 2 };
        var head = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        head.Children.Add(new ContentControl
        {
            Content = icon.Icon(),
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = Theme.AccentBrush,
        });
        head.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            VerticalAlignment = VerticalAlignment.Center,
        });
        row.Children.Add(head);
        row.Children.Add(new TextBlock
        {
            Text = text,
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        return row;
    }

    private static string DefaultName(string path)
    {
        try
        {
            var name = Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            return string.IsNullOrEmpty(name) ? path : name;
        }
        catch
        {
            return path;
        }
    }

    private static async Task<string?> PickFolderAsync()
    {
        try
        {
            var picker = new FolderPicker
            {
                SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            };
            picker.FileTypeFilter.Add("*");
            if (App.CurrentWindow is not null)
            {
                InitializeWithWindow.Initialize(
                    picker, WindowNative.GetWindowHandle(App.CurrentWindow));
            }
            var folder = await picker.PickSingleFolderAsync();
            return folder?.Path;
        }
        catch
        {
            return null;
        }
    }
}

/// Separate branch folders share Git history while preserving each session's files.
internal static class ProjectWorktreeDialog
{
    private static string _namespace = "work";

    public static async Task<string?> ShowAsync(UIElement owner, string id, string projectName, string projectPath)
    {
        var remote = RemoteWorkspaces.TrySplit(id, out var peer, out _);
        if (remote)
        {
            var protocol = await RemoteFeatureGate.PeerProtocolAsync(peer);
            if (protocol is null || protocol < RemoteFeatureGate.WorktreesMinProtocol)
            {
                await Chrome.ShowDialog(owner, new ContentDialog { Title = "Worktrees need an updated computer",
                    Content = "Connect to this project's computer and update tokenstat there to manage worktrees.", CloseButtonText = "Close" });
                return null;
            }
        }
        Task<JsonNode> Call(string method, JsonObject parameters) => remote
            ? RemoteWorkspaces.CallOnPeerAsync(peer, method, parameters)
            : AppServices.Host.CallAsync(method, parameters);
        JsonArray trees;
        try
        {
            trees = Format.Items(await RemoteWorkspaces.CallWorkspaceAsync(id, "workspace.worktrees", new JsonObject { ["id"] = id })) ?? new();
        }
        catch (Exception ex)
        {
            await Chrome.ShowDialog(owner, new ContentDialog { Title = "Could not read worktrees", Content = FriendlyError.Display(ex.Message), CloseButtonText = "Close" });
            return null;
        }
        var separator = Math.Max(projectPath.LastIndexOf('/'), projectPath.LastIndexOf('\\'));
        var name = new TextBox { Header = "Name", PlaceholderText = "improved-search" };
        var prefix = new TextBox { Header = "Branch prefix (optional)", Text = _namespace };
        var from = new TextBox { Header = "Start from branch or commit", Text = "HEAD" };
        var parent = new TextBox { Header = "Parent folder", Text = separator >= 0 ? projectPath[..(separator + 1)] : "" };
        var tabs = new ComboBox { ItemsSource = new[] { "New worktree", $"Working folders ({trees.Count})" }, SelectedIndex = 0,
            HorizontalAlignment = HorizontalAlignment.Stretch };
        var body = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 340 };
        body.Children.Add(new TextBlock { Text = "Work on another branch without interrupting this project's chats or terminals.", TextWrapping = TextWrapping.Wrap });
        body.Children.Add(tabs);
        var form = new StackPanel { Spacing = Theme.SpaceM };
        form.Children.Add(name); form.Children.Add(prefix); form.Children.Add(from); form.Children.Add(parent);
        var browser = new StackPanel { Spacing = Theme.SpaceS, Visibility = Visibility.Collapsed };
        var existing = new StackPanel { Spacing = Theme.SpaceM, Visibility = Visibility.Collapsed };
        body.Children.Add(form); body.Children.Add(existing);
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Theme.Brush(static () => Theme.Danger) };
        body.Children.Add(error);
        var dialog = new ContentDialog { Title = "Worktrees · " + projectName,
            Content = new ScrollViewer { Content = body, MaxHeight = 550 },
            PrimaryButtonText = "Create worktree", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
        var working = false;
        var browsing = false;
        var closed = false;
        string? created = null;
        void UpdateActions()
        {
            name.IsEnabled = prefix.IsEnabled = from.IsEnabled = parent.IsEnabled = tabs.IsEnabled = !working;
            dialog.IsPrimaryButtonEnabled = !working && !browsing && tabs.SelectedIndex == 0
                && !string.IsNullOrWhiteSpace(name.Text) && !string.IsNullOrWhiteSpace(parent.Text) && !string.IsNullOrWhiteSpace(from.Text);
        }
        void OpenResult(JsonNode result)
        {
            var inner = Format.Text(result, "id");
            if (string.IsNullOrEmpty(inner)) throw new InvalidOperationException("The folder could not be opened. Refresh Projects and try again.");
            if (remote) RemoteWorkspaces.RememberRegisteredProject(peer, RemoteWorkspaces.CachedFolder(id)?.MachineLabel ?? "Computer", result);
            created = remote ? RemoteWorkspaces.Join(peer, inner) : inner;
            working = false;
            dialog.Hide();
        }
        async Task Browse(string? path)
        {
            if (working || browsing || closed) return;
            browsing = true; UpdateActions(); browser.Visibility = Visibility.Visible; browser.Children.Clear();
            browser.Children.Add(new TextBlock { Text = "Loading folders…" });
            try
            {
                var listing = await Call("fs.browse", new JsonObject { ["path"] = path });
                if (closed) return;
                browser.Children.Clear();
                var current = Format.Text(listing, "path");
                browser.Children.Add(new TextBlock { Text = current, TextWrapping = TextWrapping.Wrap });
                browser.Children.Add(Buttons.Secondary("Use this folder", ActionIcon.Reveal, (_, _) =>
                { if (working || browsing) return; parent.Text = current; browser.Visibility = Visibility.Collapsed; }));
                var directories = new StackPanel { Spacing = Theme.SpaceS };
                var up = Format.Text(listing, "parent");
                if (up.Length > 0) directories.Children.Add(Buttons.Secondary("Up one folder", ActionIcon.Back, async (_, _) => await Browse(up)));
                foreach (var entry in Format.Items(listing, "entries") ?? new JsonArray())
                {
                    var destination = Format.Text(entry, "path");
                    if (Format.Text(entry, "kind") != "directory" || Format.Flag(entry, "hidden") || destination.Length == 0) continue;
                    directories.Children.Add(Buttons.Secondary(Format.Text(entry, "name"), ActionIcon.Reveal, async (_, _) => await Browse(destination)));
                }
                browser.Children.Add(new ScrollViewer { Content = directories, MaxHeight = 180 });
            }
            catch (Exception ex)
            {
                if (!closed) { browser.Children.Clear(); error.Text = FriendlyError.Display(ex.Message); }
            }
            finally { browsing = false; if (!closed) UpdateActions(); }
        }
        form.Children.Add(Buttons.Secondary("Choose parent folder…", ActionIcon.Reveal, async (_, _) => await Browse(parent.Text)));
        form.Children.Add(browser);
        var preview = new TextBlock { TextWrapping = TextWrapping.Wrap, Opacity = 0.7 };
        void UpdatePreview()
        {
            preview.Text = "Branch: " + (prefix.Text.Length == 0 ? "" : prefix.Text + "/") + name.Text;
            UpdateActions();
        }
        name.TextChanged += (_, _) => UpdatePreview(); prefix.TextChanged += (_, _) => UpdatePreview();
        parent.TextChanged += (_, _) => UpdateActions(); from.TextChanged += (_, _) => UpdateActions();
        form.Children.Add(preview);
        foreach (var tree in trees)
        {
            var path = Format.Text(tree, "path");
            var row = new StackPanel { Spacing = Theme.SpaceS };
            row.Children.Add(new TextBlock { Text = Format.Text(tree, "branch", "Detached commit"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            row.Children.Add(new TextBlock { Text = path, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Opacity = 0.7 });
            if (Format.Flag(tree, "locked")) row.Children.Add(new TextBlock { Text = "Locked", Opacity = 0.7 });
            if (Format.Flag(tree, "prunable")) row.Children.Add(new TextBlock { Text = "Folder no longer available", Opacity = 0.7 });
            else if (!Format.Flag(tree, "bare")) row.Children.Add(Buttons.Secondary("Open project", ActionIcon.Reveal, async (_, _) =>
            {
                if (working) return;
                working = true; error.Text = ""; UpdateActions();
                try { OpenResult(await Call("workspace.add", new JsonObject { ["path"] = path })); }
                catch (Exception ex) { error.Text = FriendlyError.Display(ex.Message); }
                finally { working = false; UpdateActions(); }
            }));
            existing.Children.Add(row);
        }
        tabs.SelectionChanged += (_, _) =>
        {
            form.Visibility = tabs.SelectedIndex == 0 ? Visibility.Visible : Visibility.Collapsed;
            existing.Visibility = tabs.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
            dialog.PrimaryButtonText = tabs.SelectedIndex == 0 ? "Create worktree" : "";
            UpdateActions();
        };
        dialog.Closing += (_, args) => args.Cancel = working;
        dialog.Closed += (_, _) => closed = true;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (working || browsing || tabs.SelectedIndex != 0) return;
            working = true; UpdateActions(); dialog.PrimaryButtonText = "Creating…"; error.Text = "";
            try
            {
                var parameters = new JsonObject { ["id"] = id, ["parent"] = parent.Text, ["folderName"] = name.Text,
                    ["namespace"] = prefix.Text, ["branch"] = name.Text, ["from"] = from.Text };
                var result = await RemoteWorkspaces.CallWorkspaceAsync(id, "workspace.createWorktree", parameters, TimeSpan.FromMinutes(5));
                _namespace = prefix.Text;
                OpenResult(result);
            }
            catch (Exception ex) { error.Text = FriendlyError.Display(ex.Message); }
            finally { working = false; UpdateActions(); dialog.PrimaryButtonText = "Create worktree"; }
        };
        UpdateActions();
        await Chrome.ShowDialog(owner, dialog);
        return created;
    }
}
