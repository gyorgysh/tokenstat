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
            PlaceholderText = L10n.Text("windows.workspaceadddialog.c_projects_my_app.867c040d"),
            MinWidth = 320,
        };
        var nameBox = new TextBox
        {
            PlaceholderText = L10n.Text("windows.workspaceadddialog.name_for_the_sidebar.708af5e0"),
            MinWidth = 320,
        };
        var form = new StackPanel { Spacing = Theme.SpaceM };
        form.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.workspaceadddialog.choose_the_project_folder_your_agents_shou.be573e05"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        form.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.workspaceadddialog.pick_a_repository_you_actually_work_in_it.10145fa8"),
            TextWrapping = TextWrapping.Wrap,
        });
        var pathRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        pathRow.Children.Add(pathBox);
        pathRow.Children.Add(ActionIconGlyph.Button(
            L10n.Text("windows.workspaceadddialog.browse.3227aa96"), ActionIcon.Reveal, async (_, _) =>
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
            L10n.Text("windows.workspaceadddialog.agents_work_in_this_folder.384ba364"),
            L10n.Text("windows.workspaceadddialog.they_run_as_their_own_processes_there_toke.ff8fae8f")));
        form.Children.Add(InfoRow(
            ActionIcon.Security,
            L10n.Text("windows.workspaceadddialog.nothing_is_uploaded.3b1a51ef"),
            L10n.Text("windows.workspaceadddialog.adding_a_project_does_not_send_the_folder.7c3c576c")));
        var error = new TextBlock
        {
            Foreground = Theme.Brush(static () => Theme.Danger),
            TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
        };
        form.Children.Add(error);

        var dialog = new ContentDialog
        {
            Title = L10n.Text("windows.workspaceadddialog.add_a_project.69c7be56"),
            Content = form,
            PrimaryButtonText = L10n.Text("common.add_project"),
            SecondaryButtonText = L10n.Text("windows.workspaceadddialog.on_another_machine.6f3387cc"),
            CloseButtonText = L10n.Text("windows.workspaceadddialog.not_now.a0e63d7c"),
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
                error.Text = L10n.Text("windows.workspaceadddialog.pick_a_folder_that_exists_browse_opens_the.2d8e87b7");
                error.Visibility = Visibility.Visible;
                return;
            }
            dialog.IsPrimaryButtonEnabled = false;
            dialog.IsSecondaryButtonEnabled = false;
            dialog.PrimaryButtonText = L10n.Text("windows.workspaceadddialog.adding.c6de6f45");
            error.Visibility = Visibility.Collapsed;
            try
            {
                added = await AppServices.Host.CallAsync(
                    "workspace.add", new JsonObject { ["path"] = path });
                if (string.IsNullOrEmpty(Format.Text(added, "id")))
                    throw new InvalidOperationException(L10n.Text("windows.workspaceadddialog.the_host_did_not_return_the_added_workspac.12096f4a"));
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
                dialog.PrimaryButtonText = L10n.Text("common.add_project");
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
    private static string NamespacePreferencePath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "worktree-namespace");
    private static string _namespace = ReadNamespace();
    private static string ReadNamespace()
    {
        try { return File.ReadAllText(NamespacePreferencePath).Trim(); }
        catch (IOException) { return "work"; }
        catch (UnauthorizedAccessException) { return "work"; }
    }
    private static void RememberNamespace(string value)
    {
        _namespace = value.Trim();
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(NamespacePreferencePath)!);
            File.WriteAllText(NamespacePreferencePath, _namespace);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public static async Task<string?> ShowAsync(UIElement owner, string id, string projectName, string projectPath)
    {
        var remote = RemoteWorkspaces.TrySplit(id, out var peer, out _);
        if (remote)
        {
            var protocol = await RemoteFeatureGate.PeerProtocolAsync(peer);
            if (protocol is not null && protocol < RemoteFeatureGate.WorktreesMinProtocol)
            {
                await Chrome.ShowDialog(owner, new ContentDialog { Title = L10n.Text("windows.workspaceadddialog.worktrees_need_an_updated_computer.671d665a"),
                    Content = L10n.Text("windows.workspaceadddialog.connect_to_this_project_s_computer_and_upd.f890ec34"), CloseButtonText = L10n.Text("common.close") });
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
            await Chrome.ShowDialog(owner, new ContentDialog { Title = L10n.Text("windows.workspaceadddialog.could_not_read_worktrees.6d86f53f"), Content = FriendlyError.Display(ex.Message), CloseButtonText = L10n.Text("common.close") });
            return null;
        }
        var separator = Math.Max(projectPath.LastIndexOf('/'), projectPath.LastIndexOf('\\'));
        var name = new TextBox { Header = L10n.Text("windows.workspaceadddialog.name.dcd1d522"), PlaceholderText = L10n.Text("windows.workspaceadddialog.improved_search.fda070d5") };
        var prefix = new TextBox { Header = L10n.Text("windows.workspaceadddialog.branch_prefix_optional.7797f25d"), Text = _namespace };
        var from = new TextBox { Header = L10n.Text("windows.workspaceadddialog.start_from_branch_or_commit.1ab72550"), Text = L10n.Text("windows.workspaceadddialog.head.b5180223") };
        var parent = new TextBox { Header = L10n.Text("windows.workspaceadddialog.parent_folder.158f5a01"), Text = separator >= 0 ? projectPath[..(separator + 1)] : "" };
        var tabs = new ComboBox { ItemsSource = new[] { L10n.Text("windows.workspaceadddialog.new_worktree.4f210afe"), L10n.Text("windows.workspaceadddialog.working_folders_0.b9b73029", $"{trees.Count}") }, SelectedIndex = 0,
            HorizontalAlignment = HorizontalAlignment.Stretch };
        var body = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 340 };
        body.Children.Add(new TextBlock { Text = L10n.Text("windows.workspaceadddialog.work_on_another_branch_without_interruptin.c1a6919c"), TextWrapping = TextWrapping.Wrap });
        body.Children.Add(tabs);
        var form = new StackPanel { Spacing = Theme.SpaceM };
        form.Children.Add(name); form.Children.Add(prefix); form.Children.Add(from); form.Children.Add(parent);
        var browser = new StackPanel { Spacing = Theme.SpaceS, Visibility = Visibility.Collapsed };
        var existing = new StackPanel { Spacing = Theme.SpaceM, Visibility = Visibility.Collapsed };
        body.Children.Add(form); body.Children.Add(existing);
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Theme.Brush(static () => Theme.Danger) };
        body.Children.Add(error);
        var dialog = new ContentDialog { Title = L10n.Text("windows.workspaceadddialog.worktrees_0.24e10ed8", $"{projectName}"),
            Content = new ScrollViewer { Content = body, MaxHeight = 550 },
            PrimaryButtonText = L10n.Text("windows.workspaceadddialog.create_worktree.fdedbce2"), CloseButtonText = L10n.Text("common.cancel"), DefaultButton = ContentDialogButton.Primary };
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
            if (string.IsNullOrEmpty(inner)) throw new InvalidOperationException(L10n.Text("windows.workspaceadddialog.the_folder_could_not_be_opened_refresh_pro.b3bfa015"));
            if (remote) RemoteWorkspaces.RememberRegisteredProject(peer, RemoteWorkspaces.CachedFolder(id)?.MachineLabel ?? L10n.Text("windows.workspaceadddialog.computer.76ed42d2"), result);
            created = remote ? RemoteWorkspaces.Join(peer, inner) : inner;
            working = false;
            dialog.Hide();
        }
        async Task Browse(string? path)
        {
            if (working || browsing || closed) return;
            browsing = true; UpdateActions(); browser.Visibility = Visibility.Visible; browser.Children.Clear();
            browser.Children.Add(new TextBlock { Text = L10n.Text("windows.workspaceadddialog.loading_folders.d0aa0da7") });
            try
            {
                var listing = await Call("fs.browse", new JsonObject { ["path"] = path });
                if (closed) return;
                browser.Children.Clear();
                var current = Format.Text(listing, "path");
                browser.Children.Add(new TextBlock { Text = current, TextWrapping = TextWrapping.Wrap });
                browser.Children.Add(Buttons.Secondary(L10n.Text("windows.workspaceadddialog.use_this_folder.30cbaeca"), ActionIcon.Reveal, (_, _) =>
                { if (working || browsing) return; parent.Text = current; browser.Visibility = Visibility.Collapsed; }));
                var directories = new StackPanel { Spacing = Theme.SpaceS };
                var up = Format.Text(listing, "parent");
                if (up.Length > 0) directories.Children.Add(Buttons.Secondary(L10n.Text("windows.workspaceadddialog.up_one_folder.ef9a7ae0"), ActionIcon.Back, async (_, _) => await Browse(up)));
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
        form.Children.Add(Buttons.Secondary(L10n.Text("windows.workspaceadddialog.choose_parent_folder.80d064c3"), ActionIcon.Reveal, async (_, _) => await Browse(parent.Text)));
        form.Children.Add(browser);
        var preview = new TextBlock { TextWrapping = TextWrapping.Wrap, Opacity = 0.7 };
        void UpdatePreview()
        {
            preview.Text = L10n.Text("windows.workspaceadddialog.branch_0_1.d08c5340", $"{(prefix.Text.Length == 0 ? L10n.Text("windows.workspaceadddialog..e3b0c442") : prefix.Text + L10n.Text("windows.workspaceadddialog..8a5edab2"))}", $"{name.Text}");
            UpdateActions();
        }
        name.TextChanged += (_, _) => UpdatePreview(); prefix.TextChanged += (_, _) => UpdatePreview();
        parent.TextChanged += (_, _) => UpdateActions(); from.TextChanged += (_, _) => UpdateActions();
        form.Children.Add(preview);
        foreach (var tree in trees)
        {
            var path = Format.Text(tree, "path");
            var row = new StackPanel { Spacing = Theme.SpaceS };
            row.Children.Add(new TextBlock { Text = Format.Text(tree, "branch", L10n.Text("windows.workspaceadddialog.detached_commit.05f9a89e")), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            row.Children.Add(new TextBlock { Text = path, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Opacity = 0.7 });
            if (Format.Flag(tree, "locked")) row.Children.Add(new TextBlock { Text = L10n.Text("windows.workspaceadddialog.locked.a424e33d"), Opacity = 0.7 });
            if (Format.Flag(tree, "prunable")) row.Children.Add(new TextBlock { Text = L10n.Text("windows.workspaceadddialog.folder_no_longer_available.c06a8a39"), Opacity = 0.7 });
            else if (!Format.Flag(tree, "bare")) row.Children.Add(Buttons.Secondary(L10n.Text("windows.workspaceadddialog.open_project.5e5eba7f"), ActionIcon.Reveal, async (_, _) =>
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
            dialog.PrimaryButtonText = tabs.SelectedIndex == 0 ? L10n.Text("windows.workspaceadddialog.create_worktree.fdedbce2") : "";
            UpdateActions();
        };
        dialog.Closing += (_, args) => args.Cancel = working;
        dialog.Closed += (_, _) => closed = true;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (working || browsing || tabs.SelectedIndex != 0) return;
            working = true; UpdateActions(); dialog.PrimaryButtonText = L10n.Text("windows.workspaceadddialog.creating.c79ed949"); error.Text = "";
            try
            {
                var parameters = new JsonObject { ["id"] = id, ["parent"] = parent.Text, ["folderName"] = name.Text,
                    ["namespace"] = prefix.Text, ["branch"] = name.Text, ["from"] = from.Text };
                var result = await RemoteWorkspaces.CallWorkspaceAsync(id, "workspace.createWorktree", parameters, TimeSpan.FromMinutes(5));
                RememberNamespace(prefix.Text);
                OpenResult(result);
            }
            catch (Exception ex) { error.Text = FriendlyError.Display(ex.Message); }
            finally { working = false; UpdateActions(); dialog.PrimaryButtonText = L10n.Text("windows.workspaceadddialog.create_worktree.fdedbce2"); }
        };
        UpdateActions();
        await Chrome.ShowDialog(owner, dialog);
        return created;
    }
}
