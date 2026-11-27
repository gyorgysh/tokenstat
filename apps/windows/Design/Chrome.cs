// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace Tokenstat.Design;

internal static class Chrome
{
    public static ComboBox BudgetUnits(string unit)
    {
        var choices = new ComboBox { MinWidth = 110, SelectedValuePath = "Tag" };
        choices.Items.Add(new ComboBoxItem { Content = L10n.Text("windows.chrome.minutes"), Tag = "minutes" });
        choices.Items.Add(new ComboBoxItem { Content = L10n.Text("windows.chrome.seconds"), Tag = "seconds" });
        choices.SelectedValue = unit;
        return choices;
    }

    public static Border Card(string title, UIElement body, string? subtitle = null, FrameworkElement? accessory = null, FrameworkElement? mark = null)
    {
        var header = new StackPanel { Spacing = 2 };
        header.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            FontSize = 13,
        });
        if (!string.IsNullOrEmpty(subtitle))
        {
            header.Children.Add(new TextBlock
            {
                Text = subtitle,
                TextWrapping = TextWrapping.Wrap,
                FontSize = 12,
                Opacity = 0.7,
            });
        }

        UIElement heading = header;
        if (mark is not null)
        {
            var marked = new Grid { ColumnSpacing = Theme.SpaceS };
            marked.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            marked.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            mark.VerticalAlignment = VerticalAlignment.Center;
            marked.Children.Add(mark);
            Grid.SetColumn(header, 1);
            marked.Children.Add(header);
            heading = marked;
        }
        var stack = new StackPanel { Spacing = Theme.SpaceM };
        if (accessory is null)
        {
            stack.Children.Add(heading);
        }
        else
        {
            var head = new Grid { ColumnSpacing = Theme.SpaceM };
            head.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            head.Children.Add(heading);
            accessory.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(accessory, 1);
            head.Children.Add(accessory);
            stack.Children.Add(head);
        }
        stack.Children.Add(body);

        return new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.CardPadding),
            Child = stack,
        };
    }

    public static Border CardMark(ActionIcon action)
    {
        var icon = action.Icon();
        icon.Foreground = Theme.AccentBrush;
        return new Border { Width = 24, Height = 24, CornerRadius = new CornerRadius(7),
            Background = Theme.AccentSoftBrush, Child = new Viewbox { Width = 13, Height = 13, Child = icon } };
    }

    public static StackPanel Stat(string label, string value, string? note = null, bool accent = false)
    {
        var row = new StackPanel { Spacing = Theme.SpaceXs };
        row.Children.Add(new TextBlock
        {
            Text = label.ToUpperInvariant(),
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Opacity = 0.55,
        });
        var figures = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceXs };
        var number = Fonts.Numeric(value);
        if (accent) number.Foreground = Theme.AccentBrush;
        figures.Children.Add(number);
        if (!string.IsNullOrEmpty(note))
        {
            figures.Children.Add(new TextBlock
            {
                Text = note,
                FontSize = 12,
                Opacity = 0.7,
                VerticalAlignment = VerticalAlignment.Bottom,
            });
        }
        row.Children.Add(figures);
        return row;
    }

    public static StackPanel InspectorField(string label, string value, string? note = null)
    {
        var field = new StackPanel { Spacing = 4 };
        field.Children.Add(new TextBlock { Text = label, FontSize = 11, Opacity = 0.6 });
        field.Children.Add(new TextBlock
        {
            Text = value,
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            TextWrapping = TextWrapping.Wrap,
        });
        if (!string.IsNullOrEmpty(note))
            field.Children.Add(new TextBlock { Text = note, FontSize = 11, Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
        return field;
    }

    public static Border Banner(string text, Color tint, Symbol symbol)
    {
        var label = new Grid { ColumnSpacing = 8 };
        label.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        label.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        label.Children.Add(new SymbolIcon { Symbol = symbol, Foreground = Theme.Brush(tint), VerticalAlignment = VerticalAlignment.Top });
        var message = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Foreground = Theme.Brush(tint), FontSize = 13 };
        Grid.SetColumn(message, 1);
        label.Children.Add(message);
        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(30, tint.R, tint.G, tint.B)),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.SpaceM),
            Child = label,
        };
    }

    public static StackPanel Empty(string title, string message, ActionIcon icon, UIElement? action = null)
    {
        var stack = new StackPanel
        {
            Spacing = Theme.SpaceS,
            HorizontalAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(Theme.SpaceL, Theme.SpaceXl, Theme.SpaceL, Theme.SpaceXl),
        };
        var mark = icon.Icon();
        mark.Foreground = Theme.Brush(static () => WithAlpha(Theme.Accent, 0.7));
        stack.Children.Add(new Viewbox
        {
            Width = EmptyState.EmptyMark,
            Height = EmptyState.EmptyMark,
            HorizontalAlignment = HorizontalAlignment.Center,
            Child = mark,
        });
        var headline = Fonts.Text(title, EmptyState.EmptyHeadline, Microsoft.UI.Text.FontWeights.SemiBold);
        headline.HorizontalAlignment = HorizontalAlignment.Center;
        headline.TextAlignment = TextAlignment.Center;
        headline.TextWrapping = TextWrapping.Wrap;
        stack.Children.Add(headline);
        var body = Fonts.Text(message, EmptyState.EmptyBody, opacity: 0.7);
        body.TextWrapping = TextWrapping.Wrap;
        body.MaxWidth = EmptyState.EmptyBodyWidth;
        body.HorizontalAlignment = HorizontalAlignment.Center;
        body.TextAlignment = TextAlignment.Center;
        stack.Children.Add(body);
        if (action is not null)
        {
            if (action is FrameworkElement framed)
            {
                framed.HorizontalAlignment = HorizontalAlignment.Center;
                var margin = framed.Margin;
                if (margin.Top == 0)
                {
                    margin.Top = Theme.SpaceXs;
                    framed.Margin = margin;
                }
            }
            stack.Children.Add(action);
        }
        AutomationProperties.SetName(stack, title);
        return stack;
    }

    public static Rectangle HeatCell(int level, double size = 12)
    {
        return new Rectangle
        {
            Width = size,
            Height = size,
            RadiusX = 2,
            RadiusY = 2,
            Fill = Theme.Brush(() => Theme.HeatLevel(level)),
            Margin = new Thickness(1),
        };
    }

    public static async Task<ContentDialogResult> ShowDialog(UIElement owner, ContentDialog dialog)
    {
        var root = owner.XamlRoot;
        if (root is null)
        {
            return ContentDialogResult.None;
        }
        dialog.XamlRoot = root;
        dialog.RequestedTheme = Theme.IsDark ? ElementTheme.Dark : ElementTheme.Light;
        dialog.Background = Theme.PanelBrush;
        dialog.BorderBrush = Theme.BorderBrush;
        dialog.Resources["ContentDialogBackground"] = Theme.PanelBrush;
        dialog.Resources["ContentDialogTopOverlay"] = Theme.PanelBrush;
        dialog.Resources["ContentDialogBorderBrush"] = Theme.BorderBrush;
        dialog.Resources["ContentDialogSeparatorBorderBrush"] = Theme.BorderBrush;
        dialog.Resources["TextControlBackground"] = Theme.BackgroundBrush;
        dialog.Resources["TextControlBackgroundPointerOver"] = Theme.SidebarBrush;
        dialog.Resources["TextControlBackgroundFocused"] = Theme.BackgroundBrush;
        dialog.Resources["ButtonBackground"] = Theme.AccentSoftBrush;
        try
        {
            return await dialog.ShowAsync();
        }
        catch
        {
            return ContentDialogResult.None;
        }
    }

    public static Grid SectionLabel(string text, int? count = null)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new TextBlock
        {
            Text = text.ToUpperInvariant(),
            FontSize = Fonts.SectionHeader,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Opacity = 0.55,
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (count.HasValue)
        {
            var number = Fonts.Tabular(new TextBlock
            {
                Text = count.Value.ToString(),
                FontSize = 11,
                Opacity = 0.4,
                VerticalAlignment = VerticalAlignment.Center,
            });
            Grid.SetColumn(number, 1);
            grid.Children.Add(number);
        }
        return grid;
    }

    public static Border ScopeChip(string label, Symbol symbol = Symbol.Folder)
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 5,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(new Viewbox
        {
            Width = 11,
            Height = 11,
            Child = new SymbolIcon
            {
                Symbol = symbol,
                Foreground = Theme.AccentBrush,
            },
        });
        row.Children.Add(new TextBlock
        {
            Text = label,
            FontFamily = Fonts.Interface,
            FontSize = 11,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Foreground = Theme.AccentBrush,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var chip = new Border
        {
            Background = Theme.AccentSoftBrush,
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(Theme.SpaceS, 3, Theme.SpaceS, 3),
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = row,
        };
        ToolTipService.SetToolTip(chip, L10n.Text("windows.chrome.showing_0.ee1f5b6a", $"{label}"));
        AutomationProperties.SetName(chip, L10n.Text("windows.chrome.showing_0.ee1f5b6a", $"{label}"));
        return chip;
    }

    public static Border TierBadge(string tier)
    {
        var label = new TextBlock
        {
            Text = PlanName.Title(tier).ToUpperInvariant(),
            FontSize = 10,
            FontWeight = Microsoft.UI.Text.FontWeights.Bold,
            Foreground = Theme.AccentBrush,
        };
        label.CharacterSpacing = 60;
        return new Border
        {
            Background = Theme.AccentSoftBrush,
            BorderBrush = Theme.Brush(static () => WithAlpha(Theme.Accent, 0.28)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(7, 3, 7, 3),
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = label,
        };
    }

    public static Border Banner(string text, BannerSeverity severity)
    {
        var (tint, symbol) = SeverityLook(severity);
        return Banner(text, tint, symbol);
    }

    public static Button AccentButton(
        string title,
        ActionIcon icon,
        RoutedEventHandler click,
        bool small = false)
    {
        var button = ActionIconGlyph.Button(title, icon, click);
        if (small)
        {
            button.FontSize = 12;
            button.Padding = new Thickness(10, 4, 10, 4);
        }
        return button;
    }

    public static Button SecondaryButton(
        string title,
        ActionIcon icon,
        RoutedEventHandler click,
        bool small = false)
    {
        var button = ActionIconGlyph.Button(title, icon, click);
        button.Background = Theme.PanelBrush;
        button.BorderBrush = Theme.BorderBrush;
        button.ClearValue(Control.ForegroundProperty);
        if (small)
        {
            button.FontSize = 12;
            button.Padding = new Thickness(10, 4, 10, 4);
        }
        return button;
    }

    public static Button ChoiceChip(string title, bool isSelected, Func<Task> onTap)
    {
        var chip = new Button
        {
            Content = new TextBlock
            {
                Text = title,
                FontSize = 12,
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                VerticalAlignment = VerticalAlignment.Center,
            },
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(10, 4, 10, 4),
        };
        if (isSelected)
        {
            chip.Background = Theme.AccentSoftBrush;
            chip.Foreground = Theme.AccentBrush;
            chip.BorderBrush = Theme.Brush(static () => Theme.Accent);
        }
        else
        {
            chip.Background = Theme.PanelBrush;
            chip.BorderBrush = Theme.BorderBrush;
            chip.ClearValue(Control.ForegroundProperty);
        }
        chip.Click += async (_, _) => await onTap();
        return chip;
    }

    public static Button ToggleChip(string title, bool isOn, Func<bool, Task> onFlip) =>
        ChoiceChip(title, isOn, () => onFlip(!isOn));

    public static Grid SettingSwitch(string title, bool isOn, Func<bool, Task> onFlip)
    {
        var row = new Grid { ColumnSpacing = Theme.SpaceM };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(new TextBlock { Text = title, FontSize = 14, TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center });
        var toggle = new ToggleSwitch { IsOn = isOn, OnContent = "", OffContent = "", MinWidth = 0 };
        AutomationProperties.SetName(toggle, title);
        toggle.Toggled += async (_, _) =>
        {
            if (!toggle.IsEnabled) return;
            toggle.IsEnabled = false;
            try { await onFlip(toggle.IsOn); }
            finally { toggle.IsEnabled = true; }
        };
        Grid.SetColumn(toggle, 1);
        row.Children.Add(toggle);
        return row;
    }

    public static Border Segmented(
        IList<(string Value, string Label)> options,
        string selected,
        Func<string, Task> onSelect,
        bool enabled = true)
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 4,
        };
        foreach (var option in options)
        {
            var value = option.Value;
            var chip = ChoiceChip(
                option.Label,
                value == selected,
                () => value == selected ? Task.CompletedTask : onSelect(value));
            chip.IsEnabled = enabled;
            row.Children.Add(chip);
        }
        return new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(3),
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = row,
        };
    }

    public static Border Toast(
        string message,
        BannerSeverity severity = BannerSeverity.Success,
        string? actionLabel = null,
        Action? action = null,
        Action? onDismiss = null)
    {
        var (tint, symbol) = SeverityLook(severity);
        Border? toast = null;
        void Dismiss()
        {
            if (toast is not null)
            {
                (toast.Parent as Panel)?.Children.Remove(toast);
            }
            onDismiss?.Invoke();
        }
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(new SymbolIcon
        {
            Symbol = symbol,
            Foreground = Theme.Brush(tint),
            VerticalAlignment = VerticalAlignment.Center,
        });
        row.Children.Add(new TextBlock
        {
            Text = message,
            FontFamily = Fonts.Interface,
            FontSize = Fonts.Callout,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Foreground = Theme.Brush(tint),
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
        });
        if (!string.IsNullOrEmpty(actionLabel) && action is not null)
        {
            var go = new Button
            {
                Content = new TextBlock
                {
                    Text = actionLabel,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                },
                Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0)),
                BorderThickness = new Thickness(0),
                Foreground = Theme.AccentBrush,
                Padding = new Thickness(4, 0, 4, 0),
                VerticalAlignment = VerticalAlignment.Center,
            };
            go.Click += (_, _) =>
            {
                Dismiss();
                action();
            };
            row.Children.Add(go);
        }
        var dismiss = new Button
        {
            Content = new SymbolIcon { Symbol = Symbol.Cancel },
            Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0)),
            BorderThickness = new Thickness(0),
            Opacity = 0.6,
            Padding = new Thickness(4, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        dismiss.Click += (_, _) => Dismiss();
        ToolTipService.SetToolTip(dismiss, L10n.Text("windows.chrome.dismiss_notification.b7bb3f34"));
        AutomationProperties.SetName(dismiss, L10n.Text("windows.chrome.dismiss_notification.b7bb3f34"));
        row.Children.Add(dismiss);
        toast = new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.Brush(WithAlpha(tint, 0.35)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(Theme.SpaceM, Theme.SpaceS, Theme.SpaceM, Theme.SpaceS),
            HorizontalAlignment = HorizontalAlignment.Right,
            Child = row,
        };
        Motion.ToastIn(toast);
        return toast;
    }

    public static TextBox SearchField(string placeholder, Action<string> onChange)
    {
        var box = new TextBox
        {
            PlaceholderText = placeholder,
            FontFamily = Fonts.Interface,
            FontSize = Fonts.Body,
        };
        box.TextChanged += (_, _) => onChange(box.Text);
        return box;
    }

    public static UIElement SaveStatus(FieldSaveState state) => state switch
    {
        FieldSaveState.Dirty => SaveText(L10n.Text("windows.chrome.unsaved.6250d572"), Theme.Warning),
        FieldSaveState.Saving => SaveWorking(),
        FieldSaveState.Saved => SaveDone(),
        FieldSaveState.Failed => SaveText(L10n.Text("windows.chrome.not_saved.22b3467c"), Theme.Danger),
        _ => new TextBlock { Visibility = Visibility.Collapsed },
    };

    private static TextBlock SaveText(string text, Color color) => new()
    {
        Text = text,
        FontFamily = Fonts.Interface,
        FontSize = Fonts.Caption,
        FontWeight = Microsoft.UI.Text.FontWeights.Medium,
        Foreground = Theme.Brush(color),
        VerticalAlignment = VerticalAlignment.Center,
    };

    private static StackPanel SaveWorking()
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(new ProgressRing { Width = 12, Height = 12, IsActive = true });
        var label = SaveText(L10n.Text("windows.chrome.saving.096b7362"), Theme.StateIdle);
        row.Children.Add(label);
        return row;
    }

    private static StackPanel SaveDone()
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(new SymbolIcon
        {
            Symbol = Symbol.Accept,
            Foreground = Theme.Brush(static () => Theme.Success),
            VerticalAlignment = VerticalAlignment.Center,
        });
        row.Children.Add(SaveText(L10n.Text("windows.chrome.saved.b5c120b3"), Theme.Success));
        return row;
    }

    public static StackPanel TimeLimitChips(
        string minutesText,
        bool noLimit,
        Func<string, bool, Task> onPick)
    {
        (int Minutes, string Title)[] presets =
        [
            (15, "15m"), (30, "30m"), (60, "1h"), (180, "3h"), (480, "8h"),
        ];
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
        };
        foreach (var preset in presets)
        {
            var minutes = preset.Minutes;
            bool selected = !noLimit
                && (int.TryParse(minutesText, out var current) ? current : 0) == minutes;
            row.Children.Add(ChoiceChip(
                preset.Title,
                selected,
                () => onPick(minutes.ToString(), false)));
        }
        row.Children.Add(ChoiceChip(L10n.Text("windows.chrome.no_limit.f7fcff0d"), noLimit, () => onPick(minutesText, true)));
        return row;
    }

    public static StackPanel ConcurrentChips(string countText, Func<string, Task> onPick)
    {
        static uint? Parse(string text) =>
            uint.TryParse(text.Trim(), out var number) ? number : null;
        bool uncapped = (Parse(countText) ?? 1) == 0;
        (uint Count, string Title)[] presets =
        [
            (1, "1"), (2, "2"), (4, "4"), (8, "8"),
        ];
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
        };
        foreach (var preset in presets)
        {
            var count = preset.Count;
            bool selected = !uncapped && (Parse(countText) ?? 0) == count;
            row.Children.Add(ChoiceChip(
                preset.Title,
                selected,
                () => onPick(count.ToString())));
        }
        row.Children.Add(ChoiceChip(L10n.Text("windows.chrome.no_cap.59db2115"), uncapped, () => onPick("0")));
        return row;
    }

    public static FrameworkElement CadenceGlyph(
        string kind,
        long weekdays,
        int weekday,
        bool enabled = true,
        double size = 22,
        string summary = "")
    {
        Color tint = enabled ? Theme.Accent : Theme.StateIdle;
        FrameworkElement glyph = kind switch
        {
            "once" => SymbolGlyph(Symbol.Play, tint, size),
            "interval" => SymbolGlyph(Symbol.Refresh, tint, size),
            _ => WeekRing(kind, weekdays, weekday, tint, size),
        };
        string name = string.IsNullOrEmpty(summary) ? kind : summary;
        ToolTipService.SetToolTip(glyph, name);
        AutomationProperties.SetName(glyph, name);
        return glyph;
    }

    public static FrameworkElement CountdownRing(
        long? startMs,
        long endMs,
        double size = 18,
        double lineWidth = 2.5,
        string? label = null)
    {
        double fraction = 0;
        if (startMs.HasValue)
        {
            double total = (double)endMs - startMs.Value;
            if (total <= 0)
            {
                fraction = 1;
            }
            else
            {
                double done = (double)DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - startMs.Value;
                fraction = Math.Clamp(done / (double)total, 0, 1);
            }
        }
        var grid = new Grid { Width = size, Height = size };
        grid.Children.Add(new Ellipse
        {
            Width = size,
            Height = size,
            Stroke = Theme.BorderBrush,
            StrokeThickness = lineWidth,
        });
        if (fraction > 0)
        {
            double diameter = size - lineWidth;
            double circumference = Math.PI * diameter;
            var arc = new Ellipse
            {
                Width = size,
                Height = size,
                Stroke = Theme.AccentBrush,
                StrokeThickness = lineWidth,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
                StrokeDashArray = new DoubleCollection
                {
                    fraction * circumference / lineWidth,
                    circumference / lineWidth,
                },
                RenderTransform = new RotateTransform
                {
                    Angle = -90,
                    CenterX = size / 2,
                    CenterY = size / 2,
                },
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            grid.Children.Add(arc);
        }
        if (!string.IsNullOrEmpty(label))
        {
            ToolTipService.SetToolTip(grid, label);
            AutomationProperties.SetName(grid, label);
        }
        return grid;
    }

    public static StackPanel SlotGauge(int filled, int total, bool uncapped = false, double tile = 10)
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 3,
        };
        if (uncapped)
        {
            row.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.chrome.no_cap.59db2115"),
                FontFamily = Fonts.Interface,
                FontSize = Fonts.Caption,
                Opacity = 0.7,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        else
        {
            int drawn = Math.Min(Math.Max(total, 1), 12);
            for (int index = 0; index < drawn; index++)
            {
                row.Children.Add(new Border
                {
                    Width = tile,
                    Height = tile,
                    CornerRadius = new CornerRadius(3),
                    Background = index < filled ? Theme.AccentBrush : Theme.BorderBrush,
                });
            }
            if (total > drawn)
            {
                row.Children.Add(new TextBlock
                {
                    Text = "+" + (total - drawn),
                    FontFamily = Fonts.Interface,
                    FontSize = Fonts.Caption,
                    Opacity = 0.7,
                    VerticalAlignment = VerticalAlignment.Center,
                });
            }
        }
        AutomationProperties.SetName(
            row,
            uncapped ? L10n.Text("windows.chrome.no_limit_on_jobs_at_once.76b43c57") : L10n.Text("windows.chrome.0_of_1_slots_busy.2b6c328d", $"{filled}", $"{total}"));
        return row;
    }

    private static (Color Tint, Symbol Glyph) SeverityLook(BannerSeverity severity) => severity switch
    {
        BannerSeverity.Info => (Theme.Secondary, Symbol.Help),
        BannerSeverity.Success => (Theme.Success, Symbol.Accept),
        BannerSeverity.Warning => (Theme.Warning, Symbol.Important),
        _ => (Theme.Danger, Symbol.Important),
    };

    private static FrameworkElement SymbolGlyph(Symbol symbol, Color tint, double size)
    {
        var view = new Viewbox
        {
            Width = size * 0.82,
            Height = size * 0.82,
        };
        view.Child = new SymbolIcon
        {
            Symbol = symbol,
            Foreground = Theme.Brush(tint),
        };
        return view;
    }

    private static Canvas WeekRing(string kind, long weekdays, int weekday, Color tint, double size)
    {
        var canvas = new Canvas { Width = size, Height = size };
        canvas.Children.Add(new Ellipse
        {
            Width = size,
            Height = size,
            Stroke = Theme.BorderBrush,
            StrokeThickness = 1,
        });
        double dot = Math.Max(3, size * 0.19);
        double radius = (size - dot) / 2;
        double center = size / 2;
        for (int day = 0; day < 7; day++)
        {
            double angle = day / 7.0 * 2 * Math.PI;
            double x = center + radius * Math.Sin(angle);
            double y = center - radius * Math.Cos(angle);
            var mark = new Ellipse
            {
                Width = dot,
                Height = dot,
                Fill = Theme.Brush(FiresOn(kind, weekdays, weekday, day)
                    ? tint
                    : WithAlpha(Theme.StateIdle, 0.28)),
            };
            Canvas.SetLeft(mark, x - dot / 2);
            Canvas.SetTop(mark, y - dot / 2);
            canvas.Children.Add(mark);
        }
        return canvas;
    }

    private static bool FiresOn(string kind, long weekdays, int weekday, int day) => kind switch
    {
        "daily" => true,
        "weekdays" => day < 5,
        "weekly" => (weekdays & 0x7F) != 0
            ? (weekdays & (1L << day)) != 0
            : day == weekday,
        "custom" => (weekdays & (1L << day)) != 0,
        _ => false,
    };

    private static Color WithAlpha(Color color, double alpha) =>
        Color.FromArgb((byte)(255 * alpha), color.R, color.G, color.B);
}

internal enum BannerSeverity
{
    Info,
    Success,
    Warning,
    Danger,
}

internal enum FieldSaveState
{
    Idle,
    Dirty,
    Saving,
    Saved,
    Failed,
}
