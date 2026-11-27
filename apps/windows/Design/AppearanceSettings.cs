// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Tokenstat.Design;

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
        foreach (var palette in appearance.Custom)
        {
            var row = new Grid { ColumnSpacing = Theme.SpaceS };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(Swatch(palette, body));
            var remove = ActionIconGlyph.Button(L10n.Text("windows.appearance.remove_theme", palette.Name), ActionIcon.Delete, (_, _) =>
            {
                appearance.RemoveTheme(palette.Id);
                Build(body);
            });
            remove.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(remove, 1);
            row.Children.Add(remove);
            body.Children.Add(row);
        }
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed,
            Foreground = Theme.Brush(static () => Theme.Danger) };
        var import = ActionIconGlyph.Button(L10n.Text("windows.appearance.import_theme"), ActionIcon.Upload,
            async (sender, _) => await ImportAsync(body, (Button)sender, error));
        body.Children.Add(import);
        body.Children.Add(error);
    }

    private static async Task ImportAsync(StackPanel body, Button button, TextBlock error)
    {
        if (App.CurrentWindow is not { } window) return;
        button.IsEnabled = false;
        error.Visibility = Visibility.Collapsed;
        try
        {
            var picker = new FileOpenPicker();
            picker.FileTypeFilter.Add(".json");
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
            if (await picker.PickSingleFileAsync() is not { } file) return;
            using Stream stream = await file.OpenStreamForReadAsync();
            var buffer = new byte[AppAppearance.MaximumImportBytes + 1];
            var size = await stream.ReadAtLeastAsync(buffer, buffer.Length, false);
            AppAppearance.Shared.ImportTheme(buffer.AsSpan(0, size));
            Build(body);
        }
        catch (Exception exception) when (exception is AppearanceImportException or System.Text.Json.JsonException
            or IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            error.Text = (exception as AppearanceImportException)?.Error switch
            {
                AppearanceImportError.Size => L10n.Text("windows.appearance.theme_size"),
                AppearanceImportError.Version => L10n.Text("windows.appearance.theme_version"),
                AppearanceImportError.Name => L10n.Text("windows.appearance.theme_name"),
                AppearanceImportError.Color => L10n.Text("windows.appearance.theme_color"),
                AppearanceImportError.Contrast => L10n.Text("windows.appearance.theme_contrast"),
                AppearanceImportError.Limit => L10n.Text("windows.appearance.theme_limit"),
                _ => L10n.Text("windows.appearance.theme_json"),
            };
            error.Visibility = Visibility.Visible;
        }
        finally { button.IsEnabled = true; }
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
        stack.Children.Add(new TextBlock { Text = name, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis });
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
