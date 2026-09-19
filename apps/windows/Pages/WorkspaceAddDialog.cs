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
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Tokenstat.Pages;

/// <summary>
/// The dialog behind "Add workspace". The decision is which folder.
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
            Title = "Add a workspace",
            Content = form,
            PrimaryButtonText = "Add workspace",
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
                dialog.PrimaryButtonText = "Add workspace";
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
