// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

using System.Globalization;
using System.Text.Json.Nodes;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Windows.Storage.Pickers;
using Windows.System;
using Windows.UI.Core;
using WinRT.Interop;

namespace Tokenstat.Pages;

/// <summary>
/// Conversations in a folder, over the same host methods the Mac uses.
/// The list comes first. One field picks agent, model and effort. Plan and
/// bypass sit as pills beside it. Enter sends, Shift+Enter inserts a
/// newline, Escape stops a running turn. Approvals sit in the transcript.
/// </summary>
internal sealed class ChatPage : Page
{
    private const int AttachmentCap = 12 * 1024 * 1024;

    private readonly string _workspaceId;
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _transcript = new() { Spacing = Theme.SpaceM };
    private ScrollViewer? _scroll;
    private readonly HashSet<string> _renderedKeys = new();
    private bool _followEnd = true;
    private readonly StackPanel _attachStrip = new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = Theme.SpaceS,
    };
    private readonly TextBox _draft = new()
    {
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        PlaceholderText = "Ask about this folder",
        MinHeight = 44,
    };
    private readonly StackPanel _composerActions = new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = Theme.SpaceS,
    };
    private readonly TextBox _titleBox = new()
    {
        FontSize = 20,
        FontWeight = FontWeights.SemiBold,
    };
    private readonly StackPanel _costHost = new();

    private CancellationTokenSource? _poll;
    private string? _openId;
    private ulong _offset;
    private bool _started;
    private bool _running;
    private bool _setupExpanded;
    private bool _suppress;
    private JsonArray _chats = new();
    private JsonArray _backends = new();
    private JsonArray _personas = new();
    private JsonArray _events = new();
    private JsonArray _approvals = new();
    private readonly List<StagedFile> _attachments = [];
    private JsonNode? _openChat;

    public ChatPage(string workspaceId)
    {
        _workspaceId = workspaceId;
        _draft.PlaceholderText = "Ask about this folder";
        _draft.PreviewKeyDown += DraftOnPreviewKeyDown;
        PreviewKeyDown += PageOnPreviewKeyDown;
        _titleBox.LostFocus += async (_, _) =>
        {
            var next = _titleBox.Text.Trim();
            if (string.IsNullOrEmpty(next) || next == Format.Text(_openChat, "title")) return;
            await UpdateAsync(new JsonObject { ["title"] = next });
        };
        _scroll = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceXl, Theme.SpaceL, Theme.SpaceXl, Theme.SpaceXl),
            Content = new Grid
            {
                MaxWidth = 880,
                HorizontalAlignment = HorizontalAlignment.Center,
                Children = { _root },
            },
        };
        _scroll.ViewChanged += (_, args) =>
        {
            if (args == null || _scroll == null) return;
            // Pinned while at the end; a scroll up hands control to the reader.
            _followEnd = _scroll.ScrollableHeight - _scroll.VerticalOffset < 48;
        };
        Content = _scroll;
        Loaded += async (_, _) => await ShowListAsync();
        Unloaded += (_, _) => _poll?.Cancel();
    }

    private async Task ShowListAsync()
    {
        _poll?.Cancel();
        _openId = null;
        _openChat = null;
        _attachments.Clear();
        _events = new JsonArray();
        _offset = 0;
        _renderedKeys.Clear();
        _transcript.Children.Clear();
        _followEnd = true;
        _root.Children.Clear();
        _root.Children.Add(ListHeader());
        try
        {
            await RefreshCatalogAsync();
            if (_chats.Count == 0)
            {
                _root.Children.Add(Chrome.Empty(
                    "Start a chat",
                    "Ask an agent to explore, plan, or work in this folder.",
                    Symbol.Message,
                    ActionIconGlyph.PrimaryButton("New chat", ActionIcon.Create, async (_, _) => await CreateAsync())));
                return;
            }
            var list = new StackPanel { Spacing = Theme.SpaceS };
            foreach (var chat in _chats)
            {
                if (chat is null) continue;
                list.Children.Add(ChatCard(chat));
            }
            _root.Children.Add(list);
        }
        catch (Exception ex)
        {
            _root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
        }
    }

    private UIElement ListHeader()
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var mark = new Border
        {
            Width = 42,
            Height = 42,
            CornerRadius = new CornerRadius(12),
            Background = Theme.AccentSoftBrush,
            Child = new SymbolIcon
            {
                Symbol = Symbol.Message,
                Foreground = Theme.AccentBrush,
            },
        };
        row.Children.Add(mark);
        var titles = new StackPanel { Spacing = 2, Margin = new Thickness(Theme.SpaceM, 0, 0, 0) };
        titles.Children.Add(new TextBlock
        {
            Text = "Chat",
            FontSize = 24,
            FontWeight = FontWeights.SemiBold,
        });
        titles.Children.Add(new TextBlock
        {
            Text = "Talk to an agent in this folder",
            Opacity = 0.66,
            TextWrapping = TextWrapping.Wrap,
        });
        Grid.SetColumn(titles, 1);
        row.Children.Add(titles);
        var create = ActionIconGlyph.PrimaryButton("New chat", ActionIcon.Create, async (_, _) => await CreateAsync());
        Grid.SetColumn(create, 2);
        row.Children.Add(create);
        return row;
    }

    private UIElement ChatCard(JsonNode chat)
    {
        var id = Format.Text(chat, "id");
        var running = Format.Flag(chat, "running");
        var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        if (running)
        {
            heading.Children.Add(new Border
            {
                Width = 8,
                Height = 8,
                CornerRadius = new CornerRadius(4),
                Background = Theme.AccentBrush,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        heading.Children.Add(new TextBlock
        {
            Text = Format.Text(chat, "title", "New chat"),
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 640,
        });
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(heading);
        body.Children.Add(new TextBlock
        {
            Text = RowDetail(chat),
            FontSize = 12,
            Foreground = Theme.AccentBrush,
            TextWrapping = TextWrapping.Wrap,
        });
        var card = new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.CardPadding),
            Child = body,
        };
        var button = new Button
        {
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = card,
        };
        button.Click += async (_, _) => await OpenAsync(id);
        return button;
    }

    private string RowDetail(JsonNode chat)
    {
        var backend = Backend(Format.Text(chat, "backend"));
        var agent = Format.Text(backend, "label", Format.Text(chat, "backend"));
        var mode = Format.Text(chat, "mode") == "plan" ? "Plan" : "Execute";
        return agent + " · " + mode;
    }

    private async Task CreateAsync()
    {
        try
        {
            await RefreshCatalogAsync();
            var chosen = DefaultBackend();
            var created = await AppServices.Host.CallAsync("chat.create", new JsonObject
            {
                ["workspaceId"] = _workspaceId,
                ["backend"] = Format.Text(chosen, "id", "claude"),
                ["title"] = "New chat",
                ["mode"] = "plan",
                ["autonomy"] = Format.Text(chosen, "gateTier") == "bypassOnly" ? "bypass" : "standard",
            });
            await OpenAsync(Format.Text(created, "id"));
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
    }

    private async Task OpenAsync(string id)
    {
        if (string.IsNullOrEmpty(id)) return;
        _poll?.Cancel();
        _openId = id;
        _offset = 0;
        _events = new JsonArray();
        _attachments.Clear();
        _draft.Text = "";
        try
        {
            await RefreshCatalogAsync();
            _openChat = FindChat(id);
            if (_openChat is null)
            {
                await ShowListAsync();
                return;
            }
            var chunk = await AppServices.Host.CallAsync("chat.events", new JsonObject
            {
                ["id"] = id,
                ["offset"] = 0,
            });
            _events = AsArray(chunk, "events");
            _offset = (ulong)Format.Long(chunk, "nextOffset");
            _approvals = AsArray(await AppServices.Host.CallAsync(
                "chat.approvals", new JsonObject { ["id"] = id }));
            _started = _events.Count > 0 || !string.IsNullOrEmpty(Format.Text(_openChat, "resumeToken"));
            _running = Format.Flag(_openChat, "running");
            PaintConversation();
            StartPoll();
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
    }

    private void PaintConversation()
    {
        Detach(_transcript);
        Detach(_attachStrip);
        Detach(_draft);
        Detach(_composerActions);
        Detach(_titleBox);
        Detach(_costHost);
        _root.Children.Clear();
        var chrome = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        chrome.Children.Add(ActionIconGlyph.Button("Chats", ActionIcon.Back, async (_, _) => await ShowListAsync()));
        chrome.Children.Add(ActionIconGlyph.Button("Delete", ActionIcon.Delete, async (_, _) => await ConfirmDeleteAsync()));
        _root.Children.Add(chrome);

        if (_titleBox.FocusState == FocusState.Unfocused)
        {
            _titleBox.Text = Format.Text(_openChat, "title", "New chat");
        }
        _root.Children.Add(_titleBox);

        _renderedKeys.Clear();
        _transcript.Children.Clear();
        _followEnd = true;
        RebuildTranscript(full: true);
        _root.Children.Add(_transcript);
        RefreshCost();
        _root.Children.Add(_costHost);
        _root.Children.Add(Composer());
    }

    private UIElement SetupCard()
    {
        var chat = _openChat ?? new JsonObject();
        var backendId = Format.Text(chat, "backend");
        var backend = Backend(backendId);
        var gate = Format.Text(backend, "gateTier", "full");
        var bypassOnly = gate == "bypassOnly";
        var running = Format.Flag(chat, "running");
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(ActionIconGlyph.Button("Done", ActionIcon.Done, (_, _) =>)
        {
            _setupExpanded = false;
            PaintConversation();
        }));
        body.Children.Add(Caption("How this chat should work"));
        body.Children.Add(Muted("Agent, model and mode also live on the composer. Personas stay here."));

        body.Children.Add(Labeled("Agent", AgentPicker(backendId, running)));
        if (_personas.Count > 0)
        {
            body.Children.Add(Labeled("Persona", PersonaPicker(Format.Text(chat, "personaId"), running)));
        }
        var models = backend?["models"] as JsonArray;
        if (models is { Count: > 0 })
        {
            body.Children.Add(Labeled("Model", OptionPicker(
                models,
                Format.Text(chat, "model"),
                running,
                async value => await UpdateAsync(new JsonObject { ["model"] = value }))));
        }
        var efforts = backend?["efforts"] as JsonArray;
        if (efforts is { Count: > 0 })
        {
            body.Children.Add(Labeled("Effort", OptionPicker(
                efforts,
                Format.Text(chat, "effort"),
                running,
                async value => await UpdateAsync(new JsonObject { ["effort"] = value }),
                includeDefault: true)));
        }

        body.Children.Add(ModePills(Format.Text(chat, "mode", "plan"), !running));
        var bypass = new CheckBox
        {
            Content = "Work without asking",
            IsChecked = Format.Text(chat, "autonomy") == "bypass" || bypassOnly,
            IsEnabled = !running && !bypassOnly,
            Foreground = Theme.AccentBrush,
        };
        bypass.Checked += async (_, _) => await UpdateAsync(new JsonObject { ["autonomy"] = "bypass" });
        bypass.Unchecked += async (_, _) =>
        {
            if (bypassOnly) return;
            await UpdateAsync(new JsonObject { ["autonomy"] = "standard" });
        };
        body.Children.Add(bypass);
        body.Children.Add(Muted(GateCopy(gate, Format.Text(chat, "autonomy") == "bypass")));
        if (bypassOnly && Format.Text(chat, "autonomy") != "bypass" && !running)
        {
            _ = UpdateAsync(new JsonObject { ["autonomy"] = "bypass" });
        }
        return Card("Setup", body);
    }

    private UIElement AgentPicker(string current, bool disabled)
    {
        var box = new ComboBox { MinWidth = 220, IsEnabled = !disabled };
        foreach (var backend in _backends)
        {
            if (backend is null) continue;
            var id = Format.Text(backend, "id");
            if (id == "sh" && id != current) continue;
            box.Items.Add(new ComboBoxItem
            {
                Content = Format.Text(backend, "label", id),
                Tag = id,
            });
            if (id == current) box.SelectedIndex = box.Items.Count - 1;
        }
        if (box.SelectedIndex < 0 && box.Items.Count > 0) box.SelectedIndex = 0;
        box.SelectionChanged += async (_, _) =>
        {
            if (_suppress || box.SelectedItem is not ComboBoxItem item) return;
            var next = item.Tag as string ?? "";
            var gate = Format.Text(Backend(next), "gateTier");
            var patch = new JsonObject { ["backend"] = next };
            if (gate == "bypassOnly") patch["autonomy"] = "bypass";
            await UpdateAsync(patch);
            PaintConversation();
        };
        return box;
    }

    private UIElement PersonaPicker(string current, bool disabled)
    {
        var box = new ComboBox { MinWidth = 220, IsEnabled = !disabled };
        box.Items.Add(new ComboBoxItem { Content = "No preset", Tag = "" });
        box.SelectedIndex = 0;
        foreach (var persona in _personas)
        {
            if (persona is null) continue;
            var id = Format.Text(persona, "id");
            var mark = Format.Text(persona, "mark");
            var name = Format.Text(persona, "name", "Persona");
            box.Items.Add(new ComboBoxItem
            {
                Content = string.IsNullOrEmpty(mark) ? name : mark + "  " + name,
                Tag = id,
            });
            if (id == current) box.SelectedIndex = box.Items.Count - 1;
        }
        box.SelectionChanged += async (_, _) =>
        {
            if (_suppress || box.SelectedItem is not ComboBoxItem item) return;
            var id = item.Tag as string ?? "";
            if (string.IsNullOrEmpty(id))
            {
                await UpdateAsync(new JsonObject { ["personaId"] = "", ["systemPrompt"] = "" });
                return;
            }
            var persona = FindPersona(id);
            if (persona is null) return;
            await UpdateAsync(new JsonObject
            {
                ["personaId"] = id,
                ["backend"] = Format.Text(persona, "backend"),
                ["model"] = Format.Text(persona, "model"),
                ["effort"] = Format.Text(persona, "effort"),
                ["mode"] = Format.Text(persona, "defaultMode", "plan"),
                ["autonomy"] = Format.Text(persona, "defaultAutonomy", "standard"),
                ["systemPrompt"] = Format.Text(persona, "systemPrompt"),
            });
            PaintConversation();
        };
        return box;
    }

    private UIElement OptionPicker(
        JsonArray options,
        string current,
        bool disabled,
        Func<string, Task> onChange,
        bool includeDefault = false)
    {
        var box = new ComboBox { MinWidth = 180, IsEnabled = !disabled };
        if (includeDefault)
        {
            box.Items.Add(new ComboBoxItem { Content = "Default", Tag = "" });
            if (string.IsNullOrEmpty(current)) box.SelectedIndex = 0;
        }
        foreach (var option in options)
        {
            var value = option is JsonValue v && v.TryGetValue<string>(out var text) ? text : option?.ToString() ?? "";
            if (string.IsNullOrEmpty(value)) continue;
            box.Items.Add(new ComboBoxItem { Content = value, Tag = value });
            if (value == current) box.SelectedIndex = box.Items.Count - 1;
        }
        if (box.SelectedIndex < 0 && box.Items.Count > 0) box.SelectedIndex = 0;
        box.SelectionChanged += async (_, _) =>
        {
            if (_suppress || box.SelectedItem is not ComboBoxItem item) return;
            await onChange(item.Tag as string ?? "");
        };
        return box;
    }

    private UIElement ModePills(string mode, bool enabled)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        row.Children.Add(ModePill("Plan", "plan", mode, enabled));
        row.Children.Add(ModePill("Execute", "execute", mode, enabled));
        return row;
    }

    private UIElement ModePill(string label, string value, string current, bool enabled)
    {
        var selected = value == current;
        var button = new Button
        {
            Content = label,
            IsEnabled = enabled,
            Background = selected ? Theme.AccentBrush : Theme.AccentSoftBrush,
            Foreground = selected
                ? new SolidColorBrush(Colors.White)
                : Theme.AccentBrush,
            BorderBrush = Theme.Brush(Theme.Accent),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
        };
        button.Click += async (_, _) =>
        {
            if (value == current) return;
            await UpdateAsync(new JsonObject { ["mode"] = value });
            PaintConversation();
        };
        return button;
    }

    private void RebuildTranscript(bool full = false)
    {
        if (full)
        {
            _transcript.Children.Clear();
            _renderedKeys.Clear();
        }
        foreach (var item in Coalesce(_events))
        {
            var key = item.Kind + "|" + item.Text.GetHashCode(StringComparison.Ordinal);
            if (!full && !_renderedKeys.Add(key)) continue;
            _transcript.Children.Add(Render(item));
        }
        if (Busy())
        {
            _transcript.Children.Add(new TextBlock
            {
                Text = "Working",
                Foreground = Theme.AccentBrush,
                FontSize = 12,
            });
        }
        else if (full)
        {
            // Keys were rebuilt above; keep the set in sync.
        }
        if (_followEnd) _scroll?.ChangeView(null, _scroll.ScrollableHeight, null, true);
    }

    private UIElement Render(DisplayItem item) => item.Kind switch
    {
        ItemKind.User => UserBubble(item.Text),
        ItemKind.Assistant => AssistantBody(item.Text),
        ItemKind.Thinking => Muted(item.Text),
        ItemKind.Tool => ToolRow(item),
        ItemKind.Edit => EditRow(item),
        ItemKind.Approval => ApprovalCard(item),
        ItemKind.Attachment => AttachmentRow(item),
        ItemKind.Usage => UsageLine(item),
        ItemKind.Failed => new TextBlock
        {
            Text = item.Text,
            Foreground = Theme.Brush(Theme.Danger),
            TextWrapping = TextWrapping.Wrap,
        },
        _ => new Border(),
    };

    private static UIElement UserBubble(string text)
    {
        return new Border
        {
            HorizontalAlignment = HorizontalAlignment.Right,
            MaxWidth = 560,
            Background = Theme.AccentSoftBrush,
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(Theme.SpaceM),
            Child = new TextBlock
            {
                Text = text,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            },
        };
    }

    private static UIElement AssistantBody(string text)
    {
        var stack = new StackPanel { Spacing = Theme.SpaceS };
        var rest = text;
        while (true)
        {
            var start = rest.IndexOf("```", StringComparison.Ordinal);
            if (start < 0)
            {
                if (!string.IsNullOrWhiteSpace(rest))
                {
                    stack.Children.Add(new TextBlock
                    {
                        Text = rest.Trim(),
                        TextWrapping = TextWrapping.Wrap,
                        IsTextSelectionEnabled = true,
                    });
                }
                break;
            }
            var before = rest[..start].Trim();
            if (!string.IsNullOrEmpty(before))
            {
                stack.Children.Add(new TextBlock
                {
                    Text = before,
                    TextWrapping = TextWrapping.Wrap,
                    IsTextSelectionEnabled = true,
                });
            }
            var afterFence = rest[(start + 3)..];
            var nl = afterFence.IndexOf('\n');
            var close = afterFence.IndexOf("```", StringComparison.Ordinal);
            if (close < 0)
            {
                stack.Children.Add(CodeBlock(afterFence.Trim()));
                break;
            }
            var code = nl >= 0 && nl < close ? afterFence[(nl + 1)..close] : afterFence[..close];
            stack.Children.Add(CodeBlock(code.TrimEnd()));
            rest = afterFence[(close + 3)..];
        }
        if (stack.Children.Count == 0)
        {
            stack.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap });
        }
        return stack;
    }

    private static UIElement CodeBlock(string code)
    {
        return new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(Theme.SpaceM),
            Child = new ScrollViewer
            {
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Content = new TextBlock
                {
                    Text = code,
                    FontFamily = new FontFamily("Consolas"),
                    FontSize = 12,
                    IsTextSelectionEnabled = true,
                },
            },
        };
    }

    private static UIElement ToolRow(DisplayItem item)
    {
        var title = item.Verb + (string.IsNullOrEmpty(item.Target) ? "" : "  " + item.Target);
        if (item.Running) title += "  ·  working";
        else if (item.Failed) title += "  ·  failed";
        else if (!string.IsNullOrEmpty(item.Duration)) title += "  ·  " + item.Duration;
        var body = new StackPanel { Spacing = 4 };
        body.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = FontWeights.SemiBold,
            Foreground = item.Failed ? Theme.Brush(Theme.Danger) : Theme.AccentBrush,
            TextWrapping = TextWrapping.Wrap,
        });
        if (!string.IsNullOrEmpty(item.Detail))
        {
            body.Children.Add(new TextBlock
            {
                Text = item.Detail,
                FontFamily = new FontFamily("Consolas"),
                FontSize = 12,
                Opacity = 0.78,
                IsTextSelectionEnabled = true,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        return Card(item.Verb, body);
    }

    private UIElement EditRow(DisplayItem item)
    {
        var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        heading.Children.Add(new TextBlock
        {
            Text = item.Path,
            FontFamily = new FontFamily("Consolas"),
            FontSize = 12,
            Opacity = 0.78,
            TextWrapping = TextWrapping.Wrap,
        });
        heading.Children.Add(new TextBlock
        {
            Text = "+" + item.Added,
            Foreground = Theme.Brush(Theme.DiffAdded),
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
        });
        heading.Children.Add(new TextBlock
        {
            Text = "−" + item.Removed,
            Foreground = Theme.Brush(Theme.DiffRemoved),
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
        });
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(heading);
        if (!string.IsNullOrEmpty(item.Patch))
        {
            var lines = new StackPanel { Spacing = 0 };
            foreach (var line in item.Patch.Replace("\r\n", "\n").Split('\n'))
            {
                var tint = line.StartsWith('+')
                    ? Theme.AccentSoft
                    : line.StartsWith('-')
                        ? ColorFrom(Theme.DiffRemoved, 36)
                        : Theme.Panel;
                lines.Children.Add(new Border
                {
                    Background = Theme.Brush(tint),
                    Padding = new Thickness(8, 2, 8, 2),
                    Child = new TextBlock
                    {
                        Text = line,
                        FontFamily = new FontFamily("Consolas"),
                        FontSize = 12,
                        IsTextSelectionEnabled = true,
                    },
                });
            }
            body.Children.Add(lines);
        }
        return Card("Edit", body);
    }

    private UIElement ApprovalCard(DisplayItem item)
    {
        var approval = item.Approval ?? new JsonObject();
        var pending = item.Pending;
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock
        {
            Text = pending ? "Permission needed" : "Permission answered",
            FontWeight = FontWeights.SemiBold,
        });
        body.Children.Add(Chip(Format.Text(approval, "verb")));
        body.Children.Add(new TextBlock
        {
            Text = Format.Text(approval, "preview"),
            FontFamily = new FontFamily("Consolas"),
            FontSize = 12,
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.Wrap,
        });
        if (pending)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            var id = Format.Text(approval, "id");
            actions.Children.Add(ActionIconGlyph.Button("Allow", ActionIcon.Allow, async (_, _) => await ResolveAsync(id, "allow")));
            actions.Children.Add(ActionIconGlyph.PrimaryButton("Always allow", ActionIcon.Allow, async (_, _) => await ResolveAsync(id, "allowAlways")));
            actions.Children.Add(ActionIconGlyph.Button("Deny", ActionIcon.Deny, async (_, _) => await ResolveAsync(id, "deny")));
            body.Children.Add(actions);
        }
        else
        {
            body.Children.Add(Muted("This request is no longer waiting."));
        }
        var border = (Border)Card("Permission", body);
        border.BorderBrush = pending ? Theme.Brush(Theme.Accent) : Theme.BorderBrush;
        return border;
    }

    private static UIElement AttachmentRow(DisplayItem item)
    {
        var detail = item.MediaType;
        if (item.Size > 0)
        {
            var size = item.Size >= 1024 * 1024
                ? string.Format(CultureInfo.InvariantCulture, "{0:0.#} MB", item.Size / (1024.0 * 1024.0))
                : item.Size >= 1024
                    ? string.Format(CultureInfo.InvariantCulture, "{0:0.#} KB", item.Size / 1024.0)
                    : item.Size + " B";
            detail = string.IsNullOrEmpty(detail) ? size : detail + " · " + size;
        }
        var body = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        body.Children.Add(new SymbolIcon(ActionIcon.Attach.Symbol())
        {
            Foreground = Theme.AccentBrush,
        });
        var text = new StackPanel { Spacing = 2 };
        text.Children.Add(new TextBlock
        {
            Text = item.Name,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        if (!string.IsNullOrEmpty(detail))
        {
            text.Children.Add(new TextBlock
            {
                Text = detail,
                FontSize = 12,
                Opacity = 0.78,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            });
        }
        body.Children.Add(text);
        return Card("Attachment", body);
    }

    private static UIElement UsageLine(DisplayItem item)
    {
        var text = string.Format(
            CultureInfo.InvariantCulture,
            "{0:N0} in · {1:N0} out",
            item.Input,
            item.Output);
        if (item.Cost > 0)
        {
            text += "  ·  " + item.Cost.ToString("C2", CultureInfo.GetCultureInfo("en-US"));
        }
        return new TextBlock
        {
            Text = text,
            FontSize = 12,
            Opacity = 0.66,
        };
    }

    private void RefreshCost()
    {
        _costHost.Children.Clear();
        _costHost.Children.Add(CostMeter());
    }

    private UIElement CostMeter()
    {
        long input = 0, output = 0, cache = 0;
        double cost = 0;
        var any = false;
        foreach (var row in _events)
        {
            var ev = row?["event"];
            if (Format.Text(ev, "kind") != "usage") continue;
            any = true;
            input += Format.Long(ev, "input");
            output += Format.Long(ev, "output");
            cache += Format.Long(ev, "cacheRead") + Format.Long(ev, "cacheWrite");
            cost += Format.Number(ev, "costUsd");
        }
        var body = new StackPanel { Spacing = Theme.SpaceS };
        if (!any)
        {
            body.Children.Add(Muted("Tokens and cost show up after a turn."));
            return Card("This conversation", body);
        }
        var track = new Grid { Height = 6 };
        track.Children.Add(new Border
        {
            Background = Theme.AccentSoftBrush,
            CornerRadius = new CornerRadius(3),
        });
        var split = new Grid();
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(input, GridUnitType.Star) });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(output, GridUnitType.Star) });
        var inn = new Border { Background = Theme.AccentBrush, CornerRadius = new CornerRadius(3, 0, 0, 3) };
        var outn = new Border { Background = Theme.Brush(Theme.Secondary), CornerRadius = new CornerRadius(0, 3, 3, 0) };
        Grid.SetColumn(outn, 1);
        split.Children.Add(inn);
        if (output > 0) split.Children.Add(outn);
        else inn.CornerRadius = new CornerRadius(3);
        track.Children.Add(split);
        body.Children.Add(track);
        var legend = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceM };
        legend.Children.Add(new TextBlock { Text = $"In {input:N0}", FontSize = 12 });
        legend.Children.Add(new TextBlock { Text = $"Out {output:N0}", FontSize = 12 });
        if (cost > 0)
        {
            legend.Children.Add(new TextBlock
            {
                Text = cost.ToString("C2", CultureInfo.GetCultureInfo("en-US")),
                Foreground = Theme.AccentBrush,
                FontWeight = FontWeights.SemiBold,
                FontSize = 12,
            });
        }
        body.Children.Add(legend);
        if (cache > 0) body.Children.Add(Muted($"{cache:N0} cached"));
        return Card("This conversation", body);
    }

    private UIElement Composer()
    {
        var well = new StackPanel { Spacing = Theme.SpaceS };
        well.Children.Add(_setupExpanded ? SetupCard() : CompactSetup());
        RebuildAttachStrip();
        well.Children.Add(_attachStrip);
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var attach = ActionIconGlyph.Button("Attach", ActionIcon.Attach, async (_, _) => await AttachAsync());
        attach.IsEnabled = !Busy();
        Grid.SetColumn(attach, 0);
        Grid.SetColumn(_draft, 1);
        RebuildComposerActions();
        Grid.SetColumn(_composerActions, 2);
        row.Children.Add(attach);
        row.Children.Add(_draft);
        row.Children.Add(_composerActions);
        well.Children.Add(row);
        return new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(10),
            Child = well,
        };
    }

    private void DraftOnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape)
        {
            if (!Busy()) return;
            e.Handled = true;
            _ = StopAsync();
            return;
        }
        if (e.Key != VirtualKey.Enter) return;
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift);
        if (shift.HasFlag(CoreVirtualKeyStates.Down)) return;
        e.Handled = true;
        _ = SendAsync();
    }

    private void PageOnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Escape || !Busy()) return;
        e.Handled = true;
        _ = StopAsync();
    }

    private UIElement CompactSetup()
    {
        var chat = _openChat ?? new JsonObject();
        var locked = Busy();
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        row.Children.Add(CompactAgentMenu(locked));
        row.Children.Add(ModePills(Format.Text(chat, "mode", "plan"), !locked));
        var gate = Format.Text(Backend(Format.Text(chat, "backend")), "gateTier", "full");
        var bypassOnly = gate == "bypassOnly";
        if (bypassOnly)
        {
            row.Children.Add(Chip("Bypass"));
        }
        else
        {
            row.Children.Add(AutonomyPills(Format.Text(chat, "autonomy", "standard"), !locked));
        }
        row.Children.Add(ActionIconGlyph.Button("Setup", ActionIcon.Settings, (_, _) =>
        {
            _setupExpanded = true;
            PaintConversation();
        }));
        return row;
    }

    private UIElement CompactAgentMenu(bool locked)
    {
        var chat = _openChat ?? new JsonObject();
        var backendId = Format.Text(chat, "backend");
        var backend = Backend(backendId);
        var model = Format.Text(chat, "model");
        var effort = Format.Text(chat, "effort");
        var label = Format.Text(backend, "label", backendId);
        label += string.IsNullOrEmpty(model) ? " · Default" : " · " + model;
        if (!string.IsNullOrEmpty(effort)) label += " · " + effort;

        var flyout = new MenuFlyout();
        var agentMenu = new MenuFlyoutSubItem { Text = "Agent" };
        foreach (var item in _backends)
        {
            if (item is null) continue;
            var id = Format.Text(item, "id");
            if (id == "sh" && id != backendId) continue;
            var pick = new MenuFlyoutItem
            {
                Text = Format.Text(item, "label", id),
                Tag = id,
            };
            pick.Click += async (_, _) =>
            {
                if (_suppress) return;
                var next = pick.Tag as string ?? "";
                var patch = new JsonObject { ["backend"] = next };
                if (Format.Text(Backend(next), "gateTier") == "bypassOnly")
                {
                    patch["autonomy"] = "bypass";
                }
                await UpdateAsync(patch);
                PaintConversation();
            };
            agentMenu.Items.Add(pick);
        }
        flyout.Items.Add(agentMenu);

        var models = backend?["models"] as JsonArray;
        if (models is { Count: > 0 })
        {
            var modelMenu = new MenuFlyoutSubItem { Text = "Model" };
            var def = new MenuFlyoutItem { Text = "Default", Tag = "" };
            def.Click += async (_, _) =>
            {
                await UpdateAsync(new JsonObject { ["model"] = "" });
                PaintConversation();
            };
            modelMenu.Items.Add(def);
            foreach (var option in models)
            {
                var value = option is JsonValue v && v.TryGetValue<string>(out var text) ? text : option?.ToString() ?? "";
                if (string.IsNullOrEmpty(value)) continue;
                var pick = new MenuFlyoutItem { Text = value, Tag = value };
                pick.Click += async (_, _) =>
                {
                    await UpdateAsync(new JsonObject { ["model"] = value });
                    PaintConversation();
                };
                modelMenu.Items.Add(pick);
            }
            flyout.Items.Add(modelMenu);
        }

        var efforts = backend?["efforts"] as JsonArray;
        if (efforts is { Count: > 0 })
        {
            var effortMenu = new MenuFlyoutSubItem { Text = "Effort" };
            var def = new MenuFlyoutItem { Text = "Default", Tag = "" };
            def.Click += async (_, _) =>
            {
                await UpdateAsync(new JsonObject { ["effort"] = "" });
                PaintConversation();
            };
            effortMenu.Items.Add(def);
            foreach (var option in efforts)
            {
                var value = option is JsonValue v && v.TryGetValue<string>(out var text) ? text : option?.ToString() ?? "";
                if (string.IsNullOrEmpty(value)) continue;
                var pick = new MenuFlyoutItem { Text = value, Tag = value };
                pick.Click += async (_, _) =>
                {
                    await UpdateAsync(new JsonObject { ["effort"] = value });
                    PaintConversation();
                };
                effortMenu.Items.Add(pick);
            }
            flyout.Items.Add(effortMenu);
        }

        return new Button
        {
            Content = label,
            Flyout = flyout,
            IsEnabled = !locked,
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 6, 10, 6),
        };
    }

    private UIElement AutonomyPills(string current, bool enabled)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        row.Children.Add(AutonomyPill("Ask", "standard", current, enabled));
        row.Children.Add(AutonomyPill("Bypass", "bypass", current, enabled));
        return row;
    }

    private UIElement AutonomyPill(string label, string value, string current, bool enabled)
    {
        var selected = value == current;
        var button = new Button
        {
            Content = label,
            IsEnabled = enabled,
            Background = selected ? Theme.AccentSoftBrush : Theme.PanelBrush,
            Foreground = selected ? Theme.AccentBrush : Theme.Brush(Theme.Secondary),
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 6, 10, 6),
        };
        button.Click += async (_, _) =>
        {
            if (value == current) return;
            await UpdateAsync(new JsonObject { ["autonomy"] = value });
            PaintConversation();
        };
        return button;
    }

    private void RebuildAttachStrip()
    {
        _attachStrip.Children.Clear();
        foreach (var file in _attachments)
        {
            var chip = Chip(file.Name);
            var remove = file;
            var button = new Button
            {
                Content = chip,
                Background = new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0),
            };
            button.Click += (_, _) =>
            {
                _attachments.Remove(remove);
                RebuildAttachStrip();
            };
            _attachStrip.Children.Add(button);
        }
        if (_attachStrip.Children.Count == 0)
        {
            _attachStrip.Children.Add(new Border { Height = 0 });
        }
    }

    private void RebuildComposerActions()
    {
        _composerActions.Children.Clear();
        if (Busy())
        {
            _composerActions.Children.Add(ActionIconGlyph.Button("Stop", ActionIcon.Stop, async (_, _) => await StopAsync()));
        }
        else
        {
            _composerActions.Children.Add(ActionIconGlyph.PrimaryButton("Send", ActionIcon.Send, async (_, _) => await SendAsync()));
        }
    }

    private async Task AttachAsync()
    {
        if (_openId is null) return;
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        if (App.CurrentWindow is { } window)
        {
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
        }
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        var buffer = await Windows.Storage.FileIO.ReadBufferAsync(file);
        var data = new byte[buffer.Length];
        using (var reader = Windows.Storage.Streams.DataReader.FromBuffer(buffer))
        {
            reader.ReadBytes(data);
        }
        if (data.Length > AttachmentCap)
        {
            Banner("An attachment is limited to 12 MB.");
            return;
        }
        try
        {
            var attached = await AppServices.Host.CallAsync("chat.attach", new JsonObject
            {
                ["id"] = _openId,
                ["name"] = file.Name,
                ["data"] = Convert.ToBase64String(data),
            });
            // An id-less reply stages nothing: without it the send-guard
            // below would count an empty chip as content and fire a turn
            // with no content at all.
            var id = Format.Text(attached, "id");
            if (string.IsNullOrEmpty(id))
            {
                Banner("Attachment was rejected.");
                return;
            }
            _attachments.Add(new StagedFile(id, file.Name));
            RebuildAttachStrip();
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
    }

    /// A send is in flight. Set synchronously before the first await so a
    /// second Enter or Send click cannot slip through `Busy()` mid-flight
    /// and double-send the turn.
    private bool _sending;

    private async Task SendAsync()
    {
        if (_openId is null || Busy() || _sending) return;
        var text = _draft.Text.Trim();
        // An attached image is content on its own: text is only mandatory
        // when there is nothing attached. The host substitutes the viewing
        // prompt for an empty caption.
        if (text.Length == 0 && _attachments.Count == 0) return;
        var ids = new JsonArray();
        foreach (var file in _attachments) ids.Add(file.Id);
        _sending = true;
        try
        {
            var updated = await AppServices.Host.CallAsync("chat.send", new JsonObject
            {
                ["id"] = _openId,
                ["text"] = text,
                ["attachmentIds"] = ids,
            });
            _draft.Text = "";
            _attachments.Clear();
            _openChat = updated;
            _started = true;
            _running = true;
            PaintConversation();
            StartPoll();
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
        finally
        {
            _sending = false;
        }
    }

    private async Task StopAsync()
    {
        if (_openId is null) return;
        try
        {
            await AppServices.Host.CallAsync("chat.stop", new JsonObject { ["id"] = _openId });
            StartPoll();
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
    }

    private async Task ResolveAsync(string id, string choice)
    {
        try
        {
            await AppServices.Host.CallAsync("chat.resolveApproval", new JsonObject
            {
                ["id"] = id,
                ["choice"] = choice,
            });
            _approvals = AsArray(await AppServices.Host.CallAsync(
                "chat.approvals", new JsonObject { ["id"] = _openId }));
            RebuildTranscript();
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
    }

    private async Task ConfirmDeleteAsync()
    {
        if (_openId is null) return;
        var dialog = new ContentDialog
        {
            Title = "Delete this chat?",
            Content = "The transcript stays on this computer until you delete it. This cannot be undone.",
            PrimaryButtonText = "Delete chat",
            CloseButtonText = "Keep it",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary) return;
        try
        {
            await AppServices.Host.CallAsync("chat.remove", new JsonObject { ["id"] = _openId });
            await ShowListAsync();
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
    }

    private async Task UpdateAsync(JsonObject patch)
    {
        if (_openId is null) return;
        patch["id"] = _openId;
        try
        {
            _suppress = true;
            _openChat = await AppServices.Host.CallAsync("chat.update", patch);
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
        finally
        {
            _suppress = false;
        }
    }

    private void StartPoll()
    {
        _poll?.Cancel();
        var cts = new CancellationTokenSource();
        _poll = cts;
        _ = PollLoop(cts.Token);
    }

    private async Task PollLoop(CancellationToken token)
    {
        var chatId = _openId;
        if (chatId is null) return;
        while (!token.IsCancellationRequested && _openId == chatId)
        {
            try
            {
                await Task.Delay(400, token);
                var wasBusy = Busy();
                var chunk = await AppServices.Host.CallAsync("chat.events", new JsonObject
                {
                    ["id"] = chatId,
                    ["offset"] = _offset,
                });
                if (token.IsCancellationRequested || _openId != chatId) return;
                var next = AsArray(chunk, "events");
                // Host calls run on the thread pool via Task.Run; the await
                // captures the UI SynchronizationContext so the continuation
                // resumes on the UI thread. Still, guard the UI mutations
                // explicitly so a future ConfigureAwait(false) or a call from a
                // non-UI context cannot trigger RPC_E_WRONG_THREAD.
                void ApplyPoll(JsonArray polled, ulong nextOffset, JsonArray approvals)
                {
                    foreach (var row in polled) _events.Add(row?.DeepClone());
                    _offset = nextOffset;
                    _approvals = approvals;
                }
                var approvals = AsArray(await AppServices.Host.CallAsync(
                    "chat.approvals", new JsonObject { ["id"] = chatId }));
                if (token.IsCancellationRequested || _openId != chatId) return;
                await RefreshCatalogAsync();
                if (token.IsCancellationRequested || _openId != chatId) return;

                // All UI state is mutated on the DispatcherQueue regardless of
                // which thread the awaits resumed on.
                if (!DispatcherQueue.HasThreadAccess)
                {
                    var tcs = new TaskCompletionSource();
                    DispatcherQueue.TryEnqueue(() =>
                    {
                        ApplyPoll(next, (ulong)Format.Long(chunk, "nextOffset"), approvals);
                        _openChat = FindChat(chatId);
                        var running = Format.Flag(_openChat, "running");
                        var started = _events.Count > 0 || !string.IsNullOrEmpty(Format.Text(_openChat, "resumeToken"));
                        _running = running;
                        _started = started;
                        if (_titleBox.FocusState == FocusState.Unfocused)
                        {
                            _titleBox.Text = Format.Text(_openChat, "title", "New chat");
                        }
                        if (wasBusy != Busy())
                        {
                            PaintConversation();
                        }
                        else
                        {
                            RebuildTranscript();
                            RefreshCost();
                        }
                        tcs.SetResult();
                    });
                    await tcs.Task;
                }
                else
                {
                    ApplyPoll(next, (ulong)Format.Long(chunk, "nextOffset"), approvals);
                    _openChat = FindChat(chatId);
                    var running = Format.Flag(_openChat, "running");
                    var started = _events.Count > 0 || !string.IsNullOrEmpty(Format.Text(_openChat, "resumeToken"));
                    _running = running;
                    _started = started;
                    if (_titleBox.FocusState == FocusState.Unfocused)
                    {
                        _titleBox.Text = Format.Text(_openChat, "title", "New chat");
                    }
                    if (wasBusy != Busy())
                    {
                        PaintConversation();
                    }
                    else
                    {
                        RebuildTranscript();
                        RefreshCost();
                    }
                }
                if (!Busy()) return;
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch
            {
                // A dropped poll is retried on the next tick.
            }
        }
    }

    private async Task RefreshCatalogAsync()
    {
        var chats = AppServices.Host.CallAsync("chat.list", new JsonObject { ["workspaceId"] = _workspaceId });
        var backends = AppServices.Host.CallAsync("chat.backends");
        var personas = AppServices.Host.CallAsync(
            "chat.personas",
            new JsonObject { ["workspaceId"] = _workspaceId });
        await Task.WhenAll(chats, backends, personas);
        _chats = AsArray(chats.Result);
        _backends = AsArray(backends.Result);
        _personas = AsArray(personas.Result, "personas");
    }

    private JsonNode? FindChat(string id)
    {
        foreach (var chat in _chats)
        {
            if (Format.Text(chat, "id") == id) return chat;
        }
        return _openChat;
    }

    private JsonNode? Backend(string id)
    {
        foreach (var backend in _backends)
        {
            if (Format.Text(backend, "id") == id) return backend;
        }
        return null;
    }

    private JsonNode? FindPersona(string id)
    {
        foreach (var persona in _personas)
        {
            if (Format.Text(persona, "id") == id) return persona;
        }
        return null;
    }

    private JsonNode? DefaultBackend()
    {
        foreach (var backend in _backends)
        {
            if (Format.Text(backend, "id") != "sh") return backend;
        }
        return _backends.Count > 0 ? _backends[0] : null;
    }

    private List<DisplayItem> Coalesce(JsonArray events)
    {
        var items = new List<DisplayItem>();
        var tools = new Dictionary<string, int>();
        var text = "";
        var textId = "";
        var thinking = "";
        var thinkingId = "";

        void FlushText()
        {
            var body = text.Trim();
            if (body.Length > 0)
            {
                items.Add(new DisplayItem { Id = textId, Kind = ItemKind.Assistant, Text = body });
            }
            text = "";
            textId = "";
        }

        void FlushThinking()
        {
            var body = thinking.Trim();
            if (body.Length > 0)
            {
                items.Add(new DisplayItem { Id = thinkingId, Kind = ItemKind.Thinking, Text = body });
            }
            thinking = "";
            thinkingId = "";
        }

        foreach (var row in events)
        {
            if (row is null) continue;
            var kind = Format.Text(row, "kind");
            if (kind == "user")
            {
                FlushText();
                FlushThinking();
                items.Add(new DisplayItem
                {
                    Id = "user-" + Format.Long(row, "atMs") + "-" + items.Count,
                    Kind = ItemKind.User,
                    Text = Format.Text(row, "text"),
                });
                continue;
            }
            if (kind == "approval" || row["approval"] is not null)
            {
                FlushText();
                FlushThinking();
                var approval = row["approval"] ?? row;
                var id = Format.Text(approval, "id");
                var pending = false;
                foreach (var live in _approvals)
                {
                    if (Format.Text(live, "id") == id && string.IsNullOrEmpty(Format.Text(live, "decision")))
                    {
                        pending = true;
                        break;
                    }
                }
                items.Add(new DisplayItem
                {
                    Id = "approval-" + id,
                    Kind = ItemKind.Approval,
                    Approval = approval,
                    Pending = pending,
                });
                continue;
            }
            var ev = row["event"];
            if (ev is null) continue;
            switch (Format.Text(ev, "kind"))
            {
                case "text":
                    FlushThinking();
                    if (text.Length == 0) textId = "text-" + Format.Long(row, "atMs") + "-" + items.Count;
                    text += Format.Text(ev, "delta");
                    break;
                case "thinking":
                    FlushText();
                    if (thinking.Length == 0) thinkingId = "think-" + Format.Long(row, "atMs") + "-" + items.Count;
                    thinking += Format.Text(ev, "delta");
                    break;
                case "toolStart":
                    FlushText();
                    FlushThinking();
                    var callId = Format.Text(ev, "callId");
                    if (string.IsNullOrEmpty(callId)) callId = "tool-" + items.Count;
                    tools[callId] = items.Count;
                    items.Add(new DisplayItem
                    {
                        Id = "tool-" + callId,
                        Kind = ItemKind.Tool,
                        Verb = Format.Text(ev, "verb", "Tool"),
                        Target = Format.Text(ev, "target"),
                        Running = true,
                        StartedAt = Format.Long(row, "atMs"),
                    });
                    break;
                case "toolEnd":
                    FlushText();
                    FlushThinking();
                    var endId = Format.Text(ev, "callId");
                    if (tools.TryGetValue(endId, out var index))
                    {
                        var tool = items[index];
                        tool.Running = false;
                        if (ev["ok"] is not null)
                        {
                            tool.Failed = !Format.Flag(ev, "ok");
                        }
                        tool.Detail = Format.Text(ev, "detail");
                        var ended = Format.Long(row, "atMs");
                        tool.Duration = Duration(tool.StartedAt, ended);
                        items[index] = tool;
                    }
                    break;
                case "edit":
                    FlushText();
                    FlushThinking();
                    items.Add(new DisplayItem
                    {
                        Id = "edit-" + Format.Text(ev, "callId", items.Count.ToString()),
                        Kind = ItemKind.Edit,
                        Path = Format.Text(ev, "path", "File"),
                        Added = Format.Long(ev, "added"),
                        Removed = Format.Long(ev, "removed"),
                        Patch = Format.Text(ev, "patch"),
                    });
                    break;
                case "usage":
                    FlushText();
                    FlushThinking();
                    items.Add(new DisplayItem
                    {
                        Id = "usage-" + Format.Long(row, "atMs") + "-" + items.Count,
                        Kind = ItemKind.Usage,
                        Input = Format.Long(ev, "input"),
                        Output = Format.Long(ev, "output"),
                        Cost = Format.Number(ev, "costUsd"),
                    });
                    break;
                case "attachment":
                    FlushText();
                    FlushThinking();
                    var attachmentName = Format.Text(ev, "name", "Attachment");
                    items.Add(new DisplayItem
                    {
                        Id = "attachment-" + Format.Text(ev, "id", items.Count.ToString()),
                        Kind = ItemKind.Attachment,
                        Name = string.IsNullOrEmpty(attachmentName) ? "Attachment" : attachmentName,
                        MediaType = Format.Text(ev, "mediaType"),
                        Size = Format.Long(ev, "size"),
                    });
                    break;
                case "failed":
                    FlushText();
                    FlushThinking();
                    CloseRunningTools(items, tools, true, Format.Text(ev, "text"));
                    items.Add(new DisplayItem
                    {
                        Id = "failed-" + items.Count,
                        Kind = ItemKind.Failed,
                        Text = Format.Text(ev, "text", "The turn failed"),
                    });
                    break;
                case "done":
                {
                    FlushText();
                    FlushThinking();
                    var status = Format.Text(ev, "status");
                    var failed = status is "cancelled" or "canceled" or "error";
                    CloseRunningTools(items, tools, failed, failed ? status : "");
                    break;
                }
            }
        }
        FlushText();
        FlushThinking();
        return items;
    }

    private static void CloseRunningTools(List<DisplayItem> items, Dictionary<string, int> tools, bool failed, string detail)
    {
        foreach (var index in tools.Values)
        {
            if (index < 0 || index >= items.Count) continue;
            var tool = items[index];
            if (tool.Kind != ItemKind.Tool || !tool.Running) continue;
            tool.Running = false;
            tool.Failed = failed;
            if (string.IsNullOrEmpty(tool.Detail) && !string.IsNullOrEmpty(detail))
            {
                tool.Detail = detail;
            }
            items[index] = tool;
        }
    }

    private bool Busy()
    {
        if (_running) return true;
        foreach (var item in Coalesce(_events))
        {
            if (item.Kind == ItemKind.Tool && item.Running) return true;
        }
        return false;
    }

    private static string Duration(long start, long end)
    {
        var ms = Math.Max(0, end - start);
        if (ms < 1000) return ms + "ms";
        var seconds = ms / 1000d;
        return seconds < 10 ? seconds.ToString("0.0", CultureInfo.InvariantCulture) + "s" : ((int)Math.Round(seconds)) + "s";
    }

    private static string GateChip(string tier) => tier switch
    {
        "full" => "Approvals",
        "rules" => "Rules",
        "bypassOnly" => "Bypass only",
        _ => "Checking",
    };

    private static string GateCopy(string tier, bool bypass)
    {
        if (bypass) return "This agent can use its backend's bypass mode in this folder.";
        return tier switch
        {
            "full" => "tokenstat asks before every tool action.",
            "rules" => "Saved permission rules run. Anything else is denied.",
            "bypassOnly" => "This backend has no tokenstat approval gate. Use Bypass only if you intend that.",
            _ => "Checking this backend's permission support.",
        };
    }

    private static Border Chip(string text) => new()
    {
        Background = Theme.AccentSoftBrush,
        CornerRadius = new CornerRadius(10),
        Padding = new Thickness(8, 4, 8, 4),
        Child = new TextBlock
        {
            Text = text,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = Theme.AccentBrush,
        },
    };

    private static UIElement Labeled(string label, UIElement control)
    {
        var stack = new StackPanel { Spacing = Theme.SpaceXs };
        stack.Children.Add(Caption(label));
        stack.Children.Add(control);
        return stack;
    }

    private static TextBlock Caption(string text) => new()
    {
        Text = text.ToUpperInvariant(),
        FontSize = 11,
        FontWeight = FontWeights.SemiBold,
        Opacity = 0.58,
    };

    private static TextBlock Muted(string text) => new()
    {
        Text = text,
        FontSize = 12,
        Opacity = 0.7,
        TextWrapping = TextWrapping.Wrap,
    };

    private static Border Card(string title, UIElement body) => Chrome.Card(title, body);

    private static JsonArray AsArray(JsonNode? node, string? key = null)
    {
        if (key is not null && node is JsonObject)
        {
            if (node[key] is JsonArray named) return named;
        }
        if (node is JsonArray array) return array;
        return Format.Items(node) ?? new JsonArray();
    }

    private static Windows.UI.Color ColorFrom(Windows.UI.Color tint, byte alpha) =>
        Windows.UI.Color.FromArgb(alpha, tint.R, tint.G, tint.B);

    private static void Detach(UIElement element)
    {
        if (element.Parent is Panel panel)
        {
            panel.Children.Remove(element);
        }
    }

    private void Banner(string text)
    {
        if (_root.Children.Count == 0)
        {
            _root.Children.Add(Chrome.Banner(text, Theme.Danger, Symbol.Important));
            return;
        }
        _root.Children.Insert(1, Chrome.Banner(text, Theme.Danger, Symbol.Important));
    }

    private enum ItemKind
    {
        User, Assistant, Thinking, Tool, Edit, Approval, Attachment, Usage, Failed,
    }

    private struct DisplayItem
    {
        public string Id;
        public ItemKind Kind;
        public string Text;
        public string Verb;
        public string Target;
        public bool Running;
        public bool Failed;
        public string Detail;
        public string Duration;
        public string Path;
        public long Added;
        public long Removed;
        public string Patch;
        public JsonNode? Approval;
        public bool Pending;
        public string Name;
        public string MediaType;
        public long Size;
        public long Input;
        public long Output;
        public double Cost;
        public long StartedAt;

        public DisplayItem()
        {
            Id = "";
            Text = "";
            Verb = "";
            Target = "";
            Detail = "";
            Duration = "";
            Path = "";
            Patch = "";
            Name = "";
            MediaType = "";
        }
    }

    private readonly record struct StagedFile(string Id, string Name);
}
