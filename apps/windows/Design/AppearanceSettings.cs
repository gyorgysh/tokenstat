// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Tokenstat.Design;

/// <summary>Mode and the built-in themes, as one card. Mirrors the Mac AppearancePicker.</summary>
internal static class AppearanceSettings
{
    public static UIElement Card()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        Build(body);
        return Chrome.Card(L10n.Text("common.appearance.title"), body);
    }

    private static void Build(StackPanel body)
    {
        var appearance = AppAppearance.Shared;
        body.Children.Clear();
        body.Children.Add(SegmentedCapsule.View(
            [
                ("auto", L10n.Text("common.appearance.auto"), null),
                ("light", L10n.Text("common.appearance.light"), null),
                ("dark", L10n.Text("common.appearance.dark"), null),
                ("oled", L10n.Text("common.appearance.oled"), null),
            ],
            AppAppearance.Key(appearance.Mode),
            value =>
            {
                appearance.Choose(AppAppearance.ParseMode(value));
                Build(body);
                return Task.CompletedTask;
            }));
        var grid = new Grid { ColumnSpacing = Theme.SpaceS };
        for (var i = 0; i < AppAppearance.Palettes.Length; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var swatch = Swatch(AppAppearance.Palettes[i], body);
            Grid.SetColumn(swatch, i);
            grid.Children.Add(swatch);
        }
        body.Children.Add(grid);
    }

    private static Button Swatch(AppearancePalette palette, StackPanel body)
    {
        var appearance = AppAppearance.Shared;
        var selected = appearance.Palette.Id == palette.Id;
        var side = Theme.IsDark ? palette.Dark : palette.Light;
        var name = palette.Id == "default" ? L10n.Text("common.appearance.default_theme") : palette.Name;
        var stack = new StackPanel { Spacing = Theme.SpaceS };
        stack.Children.Add(new Border
        {
            Height = 28,
            CornerRadius = new CornerRadius(8),
            Background = new LinearGradientBrush
            {
                StartPoint = new Point(0, 0),
                EndPoint = new Point(1, 1),
                GradientStops =
                {
                    new GradientStop { Color = Theme.Hex(appearance.IsOled ? 0x000000u : side.Background), Offset = 0 },
                    new GradientStop { Color = Theme.Hex(side.Accent), Offset = 0.5 },
                    new GradientStop { Color = Theme.Hex(side.Secondary), Offset = 1 },
                },
            },
        });
        stack.Children.Add(new TextBlock { Text = name, FontSize = 12 });
        var button = new Button
        {
            Content = stack,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(Theme.SpaceS),
            CornerRadius = new CornerRadius(12),
            Background = selected ? Theme.AccentSoftBrush : Theme.PanelBrush,
            BorderBrush = selected ? Theme.AccentBrush : Theme.BorderBrush,
            BorderThickness = new Thickness(1),
        };
        AutomationProperties.SetName(button, name);
        AutomationProperties.SetItemStatus(button, selected ? L10n.Text("common.appearance.selected") : "");
        button.Click += (_, _) =>
        {
            appearance.Choose(palette.Id);
            Build(body);
        };
        return button;
    }
}
