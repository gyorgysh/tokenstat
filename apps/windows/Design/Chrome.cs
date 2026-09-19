// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
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
    public static Border Card(string title, UIElement body, string? subtitle = null, FrameworkElement? accessory = null)
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
                FontSize = 12,
                Opacity = 0.7,
            });
        }

        var stack = new StackPanel { Spacing = Theme.SpaceM };
        if (accessory is null)
        {
            stack.Children.Add(header);
        }
        else
        {
            // The Mac card accessory: a trailing action in the header row,
            // like the ranking cards' View all, rather than below the body.
            var head = new Grid { ColumnSpacing = Theme.SpaceM };
            head.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            head.Children.Add(header);
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

    public static StackPanel Stat(string label, string value, string? note = null)
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
        // A headline number in Manrope with tabular figures, matching the Mac
        // stat tile (26 semibold). Not the terminal face: this is a headline.
        figures.Children.Add(Fonts.Numeric(value));
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

    public static Border Banner(string text, Color tint, Symbol symbol)
    {
        var label = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children =
            {
                new SymbolIcon { Symbol = symbol, Foreground = Theme.Brush(tint) },
                new TextBlock
                {
                    Text = text,
                    TextWrapping = TextWrapping.Wrap,
                    Foreground = Theme.Brush(tint),
                },
            },
        };
        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(30, tint.R, tint.G, tint.B)),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.SpaceM),
            Child = label,
        };
    }

    /// <summary>
    /// An empty state: the mark from the one vocabulary, then the headline
    /// naming what is missing and the line saying what the thing is for. Same
    /// anatomy as EmptyState.View, which owns the shared sizes: the one with
    /// the drawn scene and this one with the glyph must not drift apart.
    /// </summary>
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

    /// <summary>
    /// Show a dialog owned by a page. Returns <see cref="ContentDialogResult.None"/>
    /// when the page is not in the tree yet, rather than throwing.
    /// </summary>
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

    /// <summary>
    /// Uppercase group label with an optional count. Mirrors the Apple
    /// SectionLabel: the text is tertiary, the count is a quiet tabular
    /// number pinned right.
    /// </summary>
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

    /// <summary>
    /// Names the folder a scoped screen is showing. Accent-soft rather than
    /// grey, mirroring the Apple ScopeChip: it answers whose cards these are,
    /// and the same accent already marks the folder in the sidebar.
    /// </summary>
    public static Border ScopeChip(string label, Symbol symbol = Symbol.Folder)
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 5,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(new SymbolIcon
        {
            Symbol = symbol,
            Foreground = Theme.AccentBrush,
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
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(Theme.SpaceS, 3, Theme.SpaceS, 3),
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = row,
        };
        ToolTipService.SetToolTip(chip, "Showing " + label);
        AutomationProperties.SetName(chip, "Showing " + label);
        return chip;
    }

    /// <summary>
    /// The account tier, as a small uppercase pill. Mirrors the Apple
    /// TierBadge: uppercase and tracked out, because a tier is a label and
    /// not a word in a sentence.
    /// </summary>
    public static Border TierBadge(string tier)
    {
        var label = new TextBlock
        {
            Text = tier.ToUpperInvariant(),
            FontSize = 10,
            FontWeight = Microsoft.UI.Text.FontWeights.Bold,
            Foreground = Theme.AccentBrush,
        };
        // Tracking 0.6 on the Apple badge, in thousandths of an em.
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

    /// <summary>
    /// A banner by severity instead of by explicit tint. Tints match the
    /// Apple Banner.Severity, which is the source of truth: info is the
    /// secondary accent, success is the success colour, warning and danger
    /// are their own. Glyphs are WinUI Symbols approximating the SF Symbols.
    /// </summary>
    public static Border Banner(string text, BannerSeverity severity)
    {
        var (tint, symbol) = SeverityLook(severity);
        return Banner(text, tint, symbol);
    }

    /// <summary>
    /// A primary action in content, in the accent capsule family. Same look
    /// as <see cref="ActionIconGlyph.Button"/>, plus the dense variant for
    /// rows and card accessories that the Apple AccentButtonStyle carries.
    /// </summary>
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

    /// <summary>
    /// The secondary action: the same capsule family as the accent button,
    /// but neutral, panel fill with a hairline border and primary text.
    /// Mirrors the Apple SecondaryButtonStyle.
    /// </summary>
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

    /// <summary>
    /// One option in a mutually exclusive set, same capsule as the brand
    /// toggle. Mirrors the Apple ChoiceChip: selected is the accent capsule,
    /// the rest are secondary.
    /// </summary>
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

    /// <summary>
    /// A branded on/off chip. Mirrors the Apple BrandToggleChip: a system
    /// switch next to the accent capsules is a different language on the
    /// same row, so a toggle here is a chip that is accent when on.
    /// </summary>
    public static Button ToggleChip(string title, bool isOn, Func<bool, Task> onFlip) =>
        ChoiceChip(title, isOn, () => onFlip(!isOn));

    /// <summary>
    /// A mutually exclusive set in one capsule. Mirrors the Apple
    /// SegmentedCapsulePicker: the strip is panel with a hairline border,
    /// the selected segment is the accent capsule. Tapping the selected
    /// segment does nothing.
    /// </summary>
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

    /// <summary>
    /// A short-lived confirmation that does not push content down. Mirrors
    /// the Apple TransientToast: a capsule in the severity tint with an
    /// optional way to the thing the message is about, arriving with the
    /// toast motion. The dismiss button lifts the toast out of its parent.
    /// </summary>
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
        ToolTipService.SetToolTip(dismiss, "Dismiss notification");
        AutomationProperties.SetName(dismiss, "Dismiss notification");
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

    /// <summary>
    /// The app's own search box: interface face at body size with a prompt.
    /// Reports every keystroke; the caller decides what a search means.
    /// </summary>
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

    /// <summary>
    /// Unsaved, Saving, Saved, or Not saved next to Save and Cancel. Mirrors
    /// the Apple FieldSaveBar status: a card must never look finished after
    /// a keystroke and revert later.
    /// </summary>
    public static UIElement SaveStatus(FieldSaveState state) => state switch
    {
        FieldSaveState.Dirty => SaveText("Unsaved", Theme.Warning),
        FieldSaveState.Saving => SaveWorking(),
        FieldSaveState.Saved => SaveDone(),
        FieldSaveState.Failed => SaveText("Not saved", Theme.Danger),
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
        var label = SaveText("Saving", Theme.StateIdle);
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
        row.Children.Add(SaveText("Saved", Theme.Success));
        return row;
    }

    /// <summary>
    /// Minutes as a choice, with the field kept for anything else. Mirrors
    /// the Apple TimeLimitChips: these are the values a person actually
    /// picks, and a custom number in the field selects none of them.
    /// </summary>
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
        row.Children.Add(ChoiceChip("No limit", noLimit, () => onPick(minutesText, true)));
        return row;
    }

    /// <summary>
    /// How many jobs may run at once, same chips as the time limit. Mirrors
    /// the Apple ConcurrentChips: 0 is a real host value meaning no cap, so
    /// the chip says that in words and a custom number selects none.
    /// </summary>
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
        row.Children.Add(ChoiceChip("No cap", uncapped, () => onPick("0")));
        return row;
    }

    /// <summary>
    /// A schedule as a shape rather than a sentence. Mirrors the Apple
    /// CadenceGlyph, which is the source of truth: once is a play mark, an
    /// interval is a cycle, and the weekly kinds are seven dots around a
    /// ring with Monday on top running clockwise. The bitmask matches the
    /// host ScheduleSpec, Monday is bit 0. A paused job draws idle.
    /// </summary>
    /// <param name="kind">The schedule kind: once, interval, daily, weekdays, weekly, custom.</param>
    /// <param name="weekdays">The multi-day bitset the host sends.</param>
    /// <param name="weekday">The single weekday for a weekly schedule without a bitset.</param>
    /// <param name="summary">The words this replaces, for the tooltip and the screen reader.</param>
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

    /// <summary>
    /// How much of the wait until the next run is already spent. Mirrors the
    /// Apple CountdownRing: a ring that is nearly closed says soon with no
    /// arithmetic. Without a start the ring cannot show progress, so it
    /// draws empty.
    /// </summary>
    /// <param name="startMs">Usually the last run, as unix milliseconds.</param>
    /// <param name="endMs">The next run, as unix milliseconds.</param>
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
            long total = endMs - startMs.Value;
            if (total <= 0)
            {
                fraction = 1;
            }
            else
            {
                long done = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - startMs.Value;
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
                // XAML dash lengths are multiples of the stroke thickness,
                // not pixels. Both rings share the same centerline diameter.
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

    /// <summary>
    /// Concurrency as places at a table, filled by what is running now.
    /// Mirrors the Apple SlotGauge: past twelve the count is words, not
    /// shapes, and zero concurrent means no cap on the host, which has no
    /// shape at all, so it says so in words.
    /// </summary>
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
                Text = "No cap",
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
            uncapped ? "No limit on jobs at once" : $"{filled} of {total} slots busy");
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
        // The host accepts a weekly schedule either way and sends both, so
        // prefer the bitset when it carries days, matching the Mac glyph and
        // the summary beside it.
        "weekly" => (weekdays & 0x7F) != 0
            ? (weekdays & (1L << day)) != 0
            : day == weekday,
        "custom" => (weekdays & (1L << day)) != 0,
        _ => false,
    };

    private static Color WithAlpha(Color color, double alpha) =>
        Color.FromArgb((byte)(255 * alpha), color.R, color.G, color.B);
}

/// <summary>
/// How serious a banner is. Tints mirror the Apple Banner.Severity, which is
/// the source of truth.
/// </summary>
internal enum BannerSeverity
{
    Info,
    Success,
    Warning,
    Danger,
}

/// <summary>
/// Whether an edited value has reached the host. Mirrors the Apple
/// FieldSaveState.
/// </summary>
internal enum FieldSaveState
{
    Idle,
    Dirty,
    Saving,
    Saved,
    Failed,
}
