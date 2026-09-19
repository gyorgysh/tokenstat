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
/// Switch branches without leaving the workspace. Local work first:
/// remote branches create a tracking branch. Matches the Mac picker,
/// minus the unsaved-buffers prompt: the Windows editor is modal, so
/// there are no open buffers holding another branch's text.
/// </summary>
internal static class WorkspaceBranches
{
    private sealed class Choice
    {
        public string Name = "";
        public bool Current;
        public bool Remote;
        public long Ahead;
        public long Behind;
        public long LastCommit;
    }

    public static async Task ShowAsync(UIElement owner, string workspaceId, string current)
    {
        var choices = new List<Choice>();
        string? error = null;
        try
        {
            var branches = await AppServices.Host.CallAsync(
                "workspace.branches",
                new JsonObject { ["id"] = workspaceId });
            var items = branches as JsonArray ?? new JsonArray();
            foreach (var item in items)
            {
                var name = Format.Text(item, "name");
                if (string.IsNullOrEmpty(name))
                {
                    continue;
                }
                choices.Add(new Choice
                {
                    Name = name,
                    Current = Format.Flag(item, "current"),
                    Remote = Format.Flag(item, "remote"),
                    Ahead = Format.Long(item, "ahead"),
                    Behind = Format.Long(item, "behind"),
                    LastCommit = Format.Long(item, "lastCommit"),
                });
            }
        }
        catch (Exception ex)
        {
            error = ex.Message;
        }

        var query = "";
        var creating = false;
        var createName = "";
        var working = false;
        Choice? picked = null;
        ContentDialog? open = null;
        void Pick(Choice choice)
        {
            picked = choice;
            open?.Hide();
        }
        while (true)
        {
            picked = null;
            var stack = new StackPanel { Spacing = Theme.SpaceS, MinWidth = 440 };
            stack.Children.Add(new TextBlock
            {
                Text = "Local work first. Remote branches create a tracking branch.",
                FontSize = 12,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
            var list = new StackPanel { Spacing = 2 };
            void RefreshList()
            {
                list.Children.Clear();
                var filtered = choices.Where(choice =>
                    query.Length == 0
                    || choice.Name.Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
                if (filtered.Count == 0)
                {
                    list.Children.Add(new TextBlock
                    {
                        Text = query.Length == 0 ? "No branches" : "No matching branches",
                        Opacity = 0.7,
                    });
                }
                else
                {
                    AddSection(list, "Local", filtered.Where(choice => !choice.Remote).ToList(), working, Pick);
                    AddSection(list, "Remote", filtered.Where(choice => choice.Remote).ToList(), working, Pick);
                }
            }
            var filter = new TextBox
            {
                PlaceholderText = "Filter branches",
                Text = query,
            };
            filter.TextChanged += (_, _) =>
            {
                query = filter.Text;
                RefreshList();
            };
            stack.Children.Add(filter);
            if (!string.IsNullOrEmpty(error))
            {
                stack.Children.Add(Chrome.Banner(error, Theme.Danger, Symbol.Important));
            }
            RefreshList();
            stack.Children.Add(new ScrollViewer { MaxHeight = 320, Content = list });
            if (creating)
            {
                var nameBox = new TextBox
                {
                    PlaceholderText = "feature/name",
                    Text = createName,
                    MinWidth = 280,
                };
                nameBox.TextChanged += (_, _) => createName = nameBox.Text;
                stack.Children.Add(nameBox);
            }
            else
            {
                var createRow = new Button
                {
                    Content = new TextBlock { Text = $"New branch from {current}" },
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Left,
                };
                createRow.Click += (_, _) =>
                {
                    creating = true;
                    open?.Hide();
                };
                stack.Children.Add(createRow);
            }
            var dialog = new ContentDialog
            {
                Title = "Switch branch",
                Content = new ScrollViewer { MaxHeight = 560, Content = stack },
                PrimaryButtonText = creating ? "Create branch" : null,
                SecondaryButtonText = creating ? "Cancel" : null,
                CloseButtonText = "Close",
                DefaultButton = ContentDialogButton.Primary,
            };
            open = dialog;
            var result = await Chrome.ShowDialog(owner, dialog);
            open = null;
            if (picked is not null && !working)
            {
                working = true;
                error = await CheckoutAsync(workspaceId, picked);
                working = false;
                if (error is null)
                {
                    return;
                }
                continue;
            }
            if (result == ContentDialogResult.Primary && creating)
            {
                var trimmed = createName.Trim();
                if (trimmed.Length == 0)
                {
                    continue;
                }
                working = true;
                error = await CreateAsync(workspaceId, trimmed, current);
                working = false;
                if (error is null)
                {
                    return;
                }
                continue;
            }
            if (result == ContentDialogResult.Secondary && creating)
            {
                creating = false;
                createName = "";
                continue;
            }
            return;
        }
    }

    private static void AddSection(
        StackPanel list, string title, List<Choice> rows, bool working, Action<Choice> onPick)
    {
        if (rows.Count == 0)
        {
            return;
        }
        list.Children.Add(new TextBlock
        {
            Text = title.ToUpperInvariant(),
            FontSize = 11,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Opacity = 0.55,
        });
        foreach (var choice in rows)
        {
            var captured = choice;
            var row = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceS,
            };
            row.Children.Add(new TextBlock
            {
                Text = captured.Current ? "✓" : "○",
                Foreground = Theme.AccentBrush,
                VerticalAlignment = VerticalAlignment.Center,
            });
            var name = new TextBlock
            {
                Text = captured.Name,
                FontFamily = Fonts.Mono,
                FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
            };
            row.Children.Add(name);
            var meta = new List<string>();
            if (captured.Ahead > 0)
            {
                meta.Add("↑" + captured.Ahead);
            }
            if (captured.Behind > 0)
            {
                meta.Add("↓" + captured.Behind);
            }
            if (captured.LastCommit > 0)
            {
                meta.Add(Format.Relative(
                    DateTimeOffset.FromUnixTimeSeconds(captured.LastCommit).ToString("o")));
            }
            if (meta.Count > 0)
            {
                row.Children.Add(new TextBlock
                {
                    Text = string.Join(" · ", meta),
                    FontSize = 11,
                    Opacity = 0.55,
                    VerticalAlignment = VerticalAlignment.Center,
                });
            }
            if (captured.Remote)
            {
                row.Children.Add(new Border
                {
                    Background = Theme.AccentSoftBrush,
                    CornerRadius = new CornerRadius(999),
                    Padding = new Thickness(7, 3, 7, 3),
                    VerticalAlignment = VerticalAlignment.Center,
                    Child = new TextBlock
                    {
                        Text = "TRACK",
                        FontSize = 10,
                        FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                        Foreground = Theme.AccentBrush,
                    },
                });
                ToolTipService.SetToolTip(row, "Creates a local tracking branch");
            }
            var button = new Button
            {
                Content = row,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                IsEnabled = !working && !captured.Current,
            };
            button.Click += (_, _) => onPick(captured);
            list.Children.Add(button);
        }
    }

    private static async Task<string?> CheckoutAsync(string workspaceId, Choice choice)
    {
        try
        {
            var outcome = await AppServices.Host.CallAsync(
                "workspace.checkout",
                new JsonObject
                {
                    ["id"] = workspaceId,
                    ["branch"] = choice.Name,
                    ["remote"] = choice.Remote,
                });
            if (outcome is JsonObject && outcome["ok"] is not null && !Format.Flag(outcome, "ok"))
            {
                return Format.Text(outcome, "message", "The branch could not be switched.");
            }
            return null;
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }

    private static async Task<string?> CreateAsync(string workspaceId, string name, string current)
    {
        try
        {
            var outcome = await AppServices.Host.CallAsync(
                "workspace.createBranch",
                new JsonObject
                {
                    ["id"] = workspaceId,
                    ["branch"] = name,
                    ["from"] = current,
                });
            if (outcome is JsonObject && outcome["ok"] is not null && !Format.Flag(outcome, "ok"))
            {
                return Format.Text(outcome, "message", "The branch could not be created.");
            }
            return null;
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }
}
