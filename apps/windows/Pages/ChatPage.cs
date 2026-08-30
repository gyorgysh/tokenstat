// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

using System.Globalization;
using System.Text.Json.Nodes;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Tokenstat.Pages;

/// <summary>
/// Conversations in a folder, over the same host methods the Mac uses.
/// The list comes first. Setup stays until the first message, then collapses
/// to chips. Approvals sit in the transcript. Bypass is a checkbox in the
/// product violet, never a system switch.
/// </summary>
internal sealed class ChatPage : Page
{
    private const int AttachmentCap = 12 * 1024 * 1024;

    private readonly string _workspaceId;
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _transcript = new() { Spacing = Theme.SpaceM };
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
        MinHeight = 72,
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
        _titleBox.LostFocus += async (_, _) =>
        {
            var next = _titleBox.Text.Trim();
            if (string.IsNullOrEmpty(next) || next == Format.Text(_openChat, "title")) return;
            await UpdateAsync(new JsonObject { ["title"] = next });
        };
        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceXl, Theme.SpaceL, Theme.SpaceXl, Theme.SpaceXl),
            Content = new Grid
            {
                MaxWidth = 880,
                HorizontalAlignment = HorizontalAlignment.Center,
                Children = { _root },
            },
        };
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

        if (_started)
        {
            _root.Children.Add(Chips());
        }
        else
        {
            _root.Children.Add(SetupCard());
        }

        RebuildTranscript();
        _root.Children.Add(_transcript);
        RefreshCost();
        _root.Children.Add(_costHost);
        _root.Children.Add(Composer());
    }

    private UIElement Chips()
    {
        var chat = _openChat ?? new JsonObject();
        var backend = Backend(Format.Text(chat, "backend"));
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        row.Children.Add(Chip(Format.Text(backend, "label", Format.Text(chat, "backend"))));
        row.Children.Add(Chip(Format.Text(chat, "mode") == "plan" ? "Plan" : "Execute"));
        var model = Format.Text(chat, "model");
        if (!string.IsNullOrEmpty(model)) row.Children.Add(Chip(model));
        row.Children.Add(Chip(Format.Text(chat, "autonomy") == "bypass"
            ? "Bypass"
            : GateChip(Format.Text(backend, "gateTier"))));
        var wrap = new StackPanel { Spacing = Theme.SpaceS };
        wrap.Children.Add(row);
        wrap.Children.Add(ActionIconGlyph.Button("Edit setup", ActionIcon.Settings, (_, _) =>
        {
            _started = false;
            PaintConversation();
        }));
        return Card("This chat", wrap);
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
        body.Children.Add(Caption("How this chat should work"));
        body.Children.Add(Muted("These stay here until the first message. After that they collapse, and Edit setup still has them."));

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

    private void RebuildTranscript()
    {
        _transcript.Children.Clear();
        foreach (var item in Coalesce(_events))
        {
            _transcript.Children.Add(Render(item));
        }
        if (_running)
        {
            _transcript.Children.Add(new TextBlock
            {
                Text = "Working",
                Foreground = Theme.AccentBrush,
                FontSize = 12,
            });
        }
    }

    private UIElement Render(DisplayItem item) => item.Kind switch
    {
        ItemKind.User => UserBubble(item.Text),
        ItemKind.Assistant => AssistantBody(item.Text),
        ItemKind.Thinking => Muted(item.Text),
        ItemKind.Tool => ToolRow(item),
        ItemKind.Edit => EditRow(item),
        ItemKind.Approval => ApprovalCard(item),
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
        RebuildAttachStrip();
        well.Children.Add(_attachStrip);
        well.Children.Add(_draft);
        RebuildComposerActions();
        well.Children.Add(_composerActions);
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
        _composerActions.Children.Add(ActionIconGlyph.Button("Attach", ActionIcon.Attach, async (_, _) => await AttachAsync()));
        if (_running)
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
            _attachments.Add(new StagedFile(Format.Text(attached, "id"), file.Name));
            RebuildAttachStrip();
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
    }

    private async Task SendAsync()
    {
        if (_openId is null || _running) return;
        var text = _draft.Text.Trim();
        if (text.Length == 0) return;
        var ids = new JsonArray();
        foreach (var file in _attachments) ids.Add(file.Id);
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
    }

    private async Task StopAsync()
    {
        if (_openId is null) return;
        try
        {
            await AppServices.Host.CallAsync("chat.stop", new JsonObject { ["id"] = _openId });
            _running = false;
            RebuildComposerActions();
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
        while (!token.IsCancellationRequested && _openId is not null)
        {
            try
            {
                await Task.Delay(400, token);
                var chunk = await AppServices.Host.CallAsync("chat.events", new JsonObject
                {
                    ["id"] = _openId,
                    ["offset"] = _offset,
                });
                var next = AsArray(chunk, "events");
                foreach (var row in next) _events.Add(row?.DeepClone());
                _offset = (ulong)Format.Long(chunk, "nextOffset");
                _approvals = AsArray(await AppServices.Host.CallAsync(
                    "chat.approvals", new JsonObject { ["id"] = _openId }));
                await RefreshCatalogAsync();
                _openChat = FindChat(_openId);
                var running = Format.Flag(_openChat, "running");
                var started = _events.Count > 0 || !string.IsNullOrEmpty(Format.Text(_openChat, "resumeToken"));
                var composerChanged = running != _running;
                _running = running;
                _started = started;
                if (_titleBox.FocusState == FocusState.Unfocused)
                {
                    _titleBox.Text = Format.Text(_openChat, "title", "New chat");
                }
                RebuildTranscript();
                RefreshCost();
                if (composerChanged) RebuildComposerActions();
                if (!_running) return;
            }
            catch (TaskCanceledException)
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
        var personas = AppServices.Host.CallAsync("chat.personas");
        await Task.WhenAll(chats, backends, personas);
        _chats = AsArray(chats.Result);
        _backends = AsArray(backends.Result);
        _personas = AsArray(personas.Result);
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
                case "failed":
                    FlushText();
                    FlushThinking();
                    items.Add(new DisplayItem
                    {
                        Id = "failed-" + items.Count,
                        Kind = ItemKind.Failed,
                        Text = Format.Text(ev, "text", "The turn failed"),
                    });
                    break;
            }
        }
        FlushText();
        FlushThinking();
        return items;
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
        User, Assistant, Thinking, Tool, Edit, Approval, Usage, Failed,
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
        }
    }

    private readonly record struct StagedFile(string Id, string Name);
}
