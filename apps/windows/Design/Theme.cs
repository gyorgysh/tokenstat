// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Tokenstat.Design;

/// <summary>
/// Brand colours from tokenstat.ai. Same tokens as the Mac Theme.
/// </summary>
internal static class Theme
{
    public static bool IsDark =>
        Application.Current?.RequestedTheme == ApplicationTheme.Dark;

    public static Color Accent => Hex(IsDark ? 0x8B5CF6 : 0x6A3DFF);
    public static Color Secondary => Hex(IsDark ? 0xE879F9 : 0xC026D3);
    public static Color Background => Hex(IsDark ? 0x08070D : 0xFBFBFD);
    public static Color Sidebar => Hex(IsDark ? 0x12101D : 0xF3F2F8);
    public static Color Panel => IsDark ? Hex(0x100E1A) : Color.FromArgb(255, 255, 255, 255);
    public static Color Border => Hex(IsDark ? 0x211D33 : 0xE7E7EE);
    public static Color RowHighlight => Hex(IsDark ? 0x1B1430 : 0xF0ECFF);
    public static Color AccentSoft => Hex(IsDark ? 0x1B1430 : 0xF0ECFF);
    public static Color ControlGlyph => Hex(IsDark ? 0xA8A5B5 : 0x6B6876);
    public static Color Success => Accent;
    public static Color Warning => Color.FromArgb(255, 0xE0, 0xA9, 0x3B);
    public static Color Danger => Color.FromArgb(255, 0xD6, 0x45, 0x3F);
    public static Color StateIdle => Hex(IsDark ? 0x6E6A80 : 0x9A97A6);

    public static Color[] Heat { get; } =
    [
        Hex(0xECEAF2),
        Hex(0xD6C9FF),
        Hex(0xA98CFF),
        Hex(0x7C4DFF),
        Hex(0xC026D3),
    ];

    public static Color[] HeatDark { get; } =
    [
        Hex(0x191627),
        Hex(0x3B2A6B),
        Hex(0x5F3FB8),
        Hex(0x8B5CF6),
        Hex(0xE879F9),
    ];

    public static Color HeatLevel(int level)
    {
        var ramp = IsDark ? HeatDark : Heat;
        var i = Math.Clamp(level, 0, ramp.Length - 1);
        return ramp[i];
    }

    public static SolidColorBrush Brush(Color color) => new(color);
    public static SolidColorBrush AccentBrush => Brush(Accent);
    public static SolidColorBrush BackgroundBrush => Brush(Background);
    public static SolidColorBrush SidebarBrush => Brush(Sidebar);
    public static SolidColorBrush PanelBrush => Brush(Panel);
    public static SolidColorBrush BorderBrush => Brush(Border);
    public static SolidColorBrush AccentSoftBrush => Brush(AccentSoft);

    public const double CardRadius = 14;
    public const double CardPadding = 16;
    public const double SpaceXs = 4;
    public const double SpaceS = 8;
    public const double SpaceM = 12;
    public const double SpaceL = 20;
    public const double SpaceXl = 32;

    public static Color Hex(uint value) =>
        Color.FromArgb(
            255,
            (byte)((value >> 16) & 0xFF),
            (byte)((value >> 8) & 0xFF),
            (byte)(value & 0xFF));
}
