// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json;

namespace Tokenstat.Design;

internal enum AppearanceMode { Auto, Light, Dark, Oled }

/// <summary>One side of a theme. The seven colours every client names the same way.</summary>
internal sealed record AppearanceColors(
    uint Background, uint Sidebar, uint Panel, uint Border, uint Accent, uint Secondary, uint Selection);

internal sealed record AppearancePalette(string Id, string Name, AppearanceColors Light, AppearanceColors Dark);

/// <summary>
/// How the app looks on this computer: a mode, and one of the built-in
/// themes. The same values as the Apple and Android apps. Free of WinUI, so
/// the choice and its file can be checked anywhere.
/// </summary>
internal sealed class AppAppearance
{
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

    private sealed record Stored(string? Mode, string? Palette);

    private readonly string _path;

    public AppAppearance(string path)
    {
        _path = path;
        try
        {
            if (File.Exists(path) && JsonSerializer.Deserialize<Stored>(File.ReadAllText(path)) is { } stored)
            {
                Mode = ParseMode(stored.Mode);
                Palette = Find(stored.Palette);
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

    public static AppearancePalette Find(string? id) => Palettes.FirstOrDefault(palette => palette.Id == id) ?? Palettes[0];

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
        var next = Find(palette);
        if (Palette.Id == next.Id) return;
        Palette = next;
        Save();
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(new Stored(Key(Mode), Palette.Id)));
        }
        catch
        {
            // Remembering is a courtesy. This session keeps the choice.
        }
        Changed?.Invoke();
    }
}
