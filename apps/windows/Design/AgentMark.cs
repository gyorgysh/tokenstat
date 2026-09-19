// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Xml.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;

namespace Tokenstat.Design;

/// <summary>The same template brand artwork as the Mac launcher, tinted by our theme.</summary>
internal static class AgentMark
{
    private static readonly string[] Known = ["claude_code", "codex", "grok", "opencode", "cline", "openclaw", "muse", "devin", "pi", "dsh", "zed", "copilot", "antigravity", "cursor", "gemini", "hermes", "kilo", "kimi", "qwen"];
    public static string Canonical(string value)
    {
        var id = value.Replace('\\', '/').Split('/').Last().ToLowerInvariant().Replace('-', '_').Replace(' ', '_');
        if (id.Contains("claude")) return "claude_code";
        if (id.Contains("deepseek")) return "dsh";
        return Known.FirstOrDefault(brand => id == brand || id.StartsWith(brand + "_") || id == brand + "2") ?? "shell";
    }

    public static FrameworkElement View(string id, double size = 36)
    {
        var key = Canonical(id);
        var icon = key == "shell" ? ActionIcon.Run.Icon() : ActionIcon.Persona.Icon();
        icon.Foreground = Theme.AccentBrush;
        var body = new Grid { Children = { icon } };
        var image = new Image { Width = size * 0.58, Height = size * 0.58 };
        body.Children.Add(image);
        var box = new Border
        {
            Width = size, Height = size, CornerRadius = new CornerRadius(9),
            Background = Theme.AccentSoftBrush, Child = body,
        };
        async Task PaintAsync()
        {
            if (key == "shell") return;
            try
            {
                var xml = XDocument.Parse(await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory, "Assets", "Brands", key + ".svg")));
                var color = Theme.Accent;
                var tint = $"#{color.R:X2}{color.G:X2}{color.B:X2}";
                xml.Root!.SetAttributeValue("fill", tint);
                foreach (var attribute in xml.Descendants().Attributes().Where(a => (a.Name == "fill" || a.Name == "stroke") && a.Value != "none")) attribute.Value = tint;
                using var stream = new InMemoryRandomAccessStream();
                using var writer = new DataWriter(stream.GetOutputStreamAt(0));
                writer.WriteBytes(System.Text.Encoding.UTF8.GetBytes(xml.ToString()));
                await writer.StoreAsync();
                stream.Seek(0);
                var source = new SvgImageSource();
                await source.SetSourceAsync(stream);
                image.Source = source;
                icon.Visibility = Visibility.Collapsed;
            }
            catch { /* A missing brand keeps the accessible generic agent mark. */ }
        }
        box.Loaded += async (_, _) => await PaintAsync();
        box.ActualThemeChanged += async (_, _) => await PaintAsync();
        return box;
    }

    public static UIElement Row(string id, FrameworkElement content)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(View(id, 30));
        Grid.SetColumn(content, 1);
        row.Children.Add(content);
        return row;
    }
}
