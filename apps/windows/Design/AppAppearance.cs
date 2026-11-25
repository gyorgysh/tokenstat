// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Tokenstat.Design;

internal enum AppearanceMode { Auto, Light, Dark, Oled }
internal enum AppearanceImportError { Size, Version, Name, Color, Contrast, Limit }

internal sealed class AppearanceImportException(AppearanceImportError error) : Exception
{
    public AppearanceImportError Error { get; } = error;
}

/// <summary>One side of a theme. The seven colours every client names the same way.</summary>
internal sealed record AppearanceColors(
    uint Background, uint Sidebar, uint Panel, uint Border, uint Accent, uint Secondary, uint Selection);

internal sealed record AppearancePalette(string Id, string Name, AppearanceColors Light, AppearanceColors Dark);

/// <summary>
/// How the app looks on this computer: a mode and a theme. The same values as the Apple and Android apps. Free of WinUI, so
/// the choice and its file can be checked anywhere.
/// </summary>
internal sealed class AppAppearance
{
    internal const int MaximumImportBytes = 16_384;
    private const int MaximumCustomThemes = 24;
    public static readonly AppearancePalette[] Palettes =
    [
        new("default", "Default",
            new(0xFBFBFD, 0xF3F2F8, 0xFFFFFF, 0xE7E7EE, 0x6A3DFF, 0xA21CAF, 0xF0ECFF),
            new(0x08070D, 0x12101D, 0x100E1A, 0x211D33, 0xA786FF, 0xE879F9, 0x1B1430)),
        new("ink", "Ink",
            new(0xEDF2F7, 0xE3EAF1, 0xF9FBFD, 0xD1DCE7, 0x315B83, 0x2B6578, 0xDCE8F1),
            new(0x0D141C, 0x1B2A37, 0x151F2A, 0x293B4B, 0x79B4E0, 0x63C2CF, 0x1D3848)),
        new("ember", "Ember",
            new(0xFBF1E8, 0xF3E1D2, 0xFFFAF5, 0xEAD4C3, 0xA6431D, 0x8B521E, 0xF6DFCF),
            new(0x1B100D, 0x352019, 0x281814, 0x4B2C22, 0xFF9A63, 0xEDBD67, 0x48271D)),
        new("aurora", "Aurora",
            new(0xEAF7F5, 0xD9EFEB, 0xF8FFFE, 0xC7E2DD, 0x096E67, 0x236798, 0xD2EEEA),
            new(0x081B1B, 0x143836, 0x102928, 0x20504C, 0x65DFC9, 0x81CEF9, 0x17433E)),
    ];

    public static readonly AppAppearance Shared = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "appearance.json"));

    private sealed record Stored(string? Mode, string? Palette, AppearancePalette[]? Custom);

    private readonly string _path;
    private readonly List<AppearancePalette> _custom = [];

    public AppAppearance(string path)
    {
        _path = path;
        try
        {
            if (File.Exists(path) && JsonSerializer.Deserialize<Stored>(File.ReadAllText(path)) is { } stored)
            {
                Mode = ParseMode(stored.Mode);
                _custom.AddRange((stored.Custom ?? []).Where(IsValidCustom).DistinctBy(theme => theme.Id).Take(MaximumCustomThemes));
                Palette = Find(stored.Palette) ?? Palettes[0];
            }
        }
        catch
        {
            // A damaged file only costs the remembered look.
        }
    }

    public event Action? Changed;

    public AppearanceMode Mode { get; private set; }
    public AppearancePalette Palette { get; private set; } = Palettes[0];
    public IReadOnlyList<AppearancePalette> Custom => _custom;

    /// <summary>A theme other than the brand's own.</summary>
    public bool IsThemed => Palette.Id != "default";
    public bool IsOled => Mode == AppearanceMode.Oled;

    /// <summary>Null follows the system.</summary>
    public bool? Dark => Mode switch
    {
        AppearanceMode.Light => false,
        AppearanceMode.Dark or AppearanceMode.Oled => true,
        _ => null,
    };

    private AppearancePalette? Find(string? id) => Palettes.FirstOrDefault(palette => palette.Id == id)
        ?? _custom.FirstOrDefault(palette => palette.Id == id);

    public static AppearanceMode ParseMode(string? mode) => mode switch
    {
        "light" => AppearanceMode.Light,
        "dark" => AppearanceMode.Dark,
        "oled" => AppearanceMode.Oled,
        _ => AppearanceMode.Auto,
    };

    public static string Key(AppearanceMode mode) => mode.ToString().ToLowerInvariant();

    public void Choose(AppearanceMode mode)
    {
        if (Mode == mode) return;
        Mode = mode;
        Save();
    }

    public void Choose(string palette)
    {
        var next = Find(palette) ?? Palettes[0];
        if (Palette.Id == next.Id) return;
        Palette = next;
        Save();
    }

    public void ImportTheme(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length > MaximumImportBytes) throw new AppearanceImportException(AppearanceImportError.Size);
        using var json = JsonDocument.Parse(bytes.ToArray());
        var root = json.RootElement;
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("version", out var version)
            || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var number) || number != 1)
            throw new AppearanceImportException(AppearanceImportError.Version);
        var name = ReadString(root, "name")?.Trim();
        if (!ValidName(name)) throw new AppearanceImportException(AppearanceImportError.Name);
        var light = ReadColors(root, "light");
        var dark = ReadColors(root, "dark");
        if (!ValidContrast(light, dark)) throw new AppearanceImportException(AppearanceImportError.Contrast);

        var index = _custom.FindIndex(theme => string.Equals(theme.Name, name, StringComparison.OrdinalIgnoreCase));
        if (index < 0 && _custom.Count >= MaximumCustomThemes)
            throw new AppearanceImportException(AppearanceImportError.Limit);
        var id = index < 0 ? Guid.NewGuid().ToString("D") : _custom[index].Id;
        var imported = new AppearancePalette(id, name!, light, dark);
        if (index < 0) _custom.Add(imported);
        else _custom[index] = imported;
        Palette = imported;
        Save();
    }

    public void RemoveTheme(string id)
    {
        if (_custom.RemoveAll(theme => theme.Id == id) == 0) return;
        if (Palette.Id == id) Palette = Palettes[0];
        Save();
    }

    private static string? ReadString(JsonElement value, string field) =>
        value.TryGetProperty(field, out var entry) && entry.ValueKind == JsonValueKind.String ? entry.GetString() : null;

    private static AppearanceColors ReadColors(JsonElement root, string side)
    {
        if (!root.TryGetProperty(side, out var colors) || colors.ValueKind != JsonValueKind.Object)
            throw new AppearanceImportException(AppearanceImportError.Color);
        uint Read(string key)
        {
            var value = ReadString(colors, key);
            if (value is { Length: 7 } && value[0] == '#' && value.AsSpan(1).IndexOfAnyExcept("0123456789abcdefABCDEF") < 0
                && uint.TryParse(value.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var color)) return color;
            throw new AppearanceImportException(AppearanceImportError.Color);
        }
        return new(Read("background"), Read("sidebar"), Read("panel"), Read("border"), Read("accent"), Read("secondary"), Read("selection"));
    }

    private static bool ValidName(string? name) => !string.IsNullOrWhiteSpace(name)
        && new StringInfo(name).LengthInTextElements <= 40 && Encoding.UTF8.GetByteCount(name) <= 160
        && !name.Any(char.IsControl);

    private static bool IsValidCustom(AppearancePalette? theme) => theme is not null && Guid.TryParseExact(theme.Id, "D", out _)
        && ValidName(theme.Name) && theme.Light is not null && theme.Dark is not null && ValidContrast(theme.Light, theme.Dark);

    private static bool ValidContrast(AppearanceColors light, AppearanceColors dark)
    {
        static double Luminance(uint value)
        {
            static double Linear(uint channel)
            {
                var level = channel / 255d;
                return level <= 0.04045 ? level / 12.92 : Math.Pow((level + 0.055) / 1.055, 2.4);
            }
            return 0.2126 * Linear((value >> 16) & 255) + 0.7152 * Linear((value >> 8) & 255) + 0.0722 * Linear(value & 255);
        }
        static bool ValidSide(AppearanceColors side, bool dark)
        {
            uint[] colors = [side.Background, side.Sidebar, side.Panel, side.Selection, side.Border, side.Accent, side.Secondary];
            if (colors.Any(color => color > 0xFFFFFF)) return false;
            var surfaces = colors.Take(4).Select(Luminance).ToArray();
            var accent = Luminance(side.Accent);
            var secondary = Luminance(side.Secondary);
            static double Contrast(double a, double b) => (Math.Max(a, b) + 0.05) / (Math.Min(a, b) + 0.05);
            return surfaces.All(surface => dark ? surface <= 0.065 : surface >= 0.64)
                && surfaces.Take(3).All(surface => Contrast(accent, surface) >= 4.5 && Contrast(secondary, surface) >= 4.5);
        }
        return ValidSide(light, dark: false) && ValidSide(dark, dark: true);
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(new Stored(Key(Mode), Palette.Id, _custom.ToArray())));
        }
        catch
        {
            // Remembering is a courtesy. This session keeps the choice.
        }
        Changed?.Invoke();
    }
}
