// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json;

namespace Tokenstat.Design;

/// <summary>Only panel sizes are stored. A drag writes once, when it finishes.</summary>
internal sealed class ShellWidths
{
    public const double Rail = 64;
    public const double Default = 272;
    public const double SidebarMinimum = 220;
    public const double SidebarMaximum = 440;
    public const double InspectorDefault = 400;
    public const double Minimum = 300;
    public const double InspectorMaximum = 640;
    public const double ContentMinimum = 420;
    private static readonly Lazy<ShellWidths> Saved = new(() => new ShellWidths(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "shell-widths.json")));
    public static ShellWidths Shared => Saved.Value;
    private readonly string _path;
    public double Sidebar { get; private set; } = Default;
    public double Inspector { get; private set; } = InspectorDefault;

    public ShellWidths(string path)
    {
        _path = path;
        try
        {
            using var saved = JsonDocument.Parse(File.ReadAllText(path));
            if (saved.RootElement.TryGetProperty("sidebar", out var sidebar)
                && sidebar.ValueKind == JsonValueKind.Number && sidebar.TryGetDouble(out var left))
                Sidebar = BoundSidebar(left);
            if (saved.RootElement.TryGetProperty("inspector", out var inspector)
                && inspector.ValueKind == JsonValueKind.Number && inspector.TryGetDouble(out var right))
                Inspector = BoundInspector(right);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        catch (JsonException) { }
        catch (InvalidOperationException) { }
    }

    public static double BoundSidebar(double width) => Bound(width, SidebarMinimum, SidebarMaximum, Default);
    public static double BoundInspector(double width) => Bound(width, Minimum, InspectorMaximum, InspectorDefault);
    private static double Bound(double width, double minimum, double maximum, double fallback) => double.IsFinite(width)
        ? Math.Clamp(width, minimum, maximum) : fallback;
    public static double InspectorFitEdge(double width) => ContentMinimum + 6 + BoundInspector(width);

    public void RememberSidebar(double width) { Sidebar = BoundSidebar(width); Save(); }
    public void RememberInspector(double width) { Inspector = BoundInspector(width); Save(); }
    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(new { sidebar = Sidebar, inspector = Inspector }));
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
