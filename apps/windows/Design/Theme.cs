// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Tokenstat.Design;

/// <summary>
/// What a run of source text is. Mirrors the Mac SyntaxKind, which mirrors
/// the highlight kinds from the core. The highlighter sends kinds and never
/// colours, which is what lets the theme switch for free.
/// </summary>
internal enum SyntaxKind
{
    Keyword,
    String,
    Number,
    Comment,
    Type,
    Function,
    Constant,
    Attribute,
    Property,
    Variable,
    Operator,
    Punctuation,
    Markup,
    /// <summary>A kind this build does not know. Newer core, older app: colour it as plain text.</summary>
    Unknown,
}

/// <summary>
/// Brand colours from tokenstat.ai. Same tokens as the Mac Theme.
/// </summary>
internal static class Theme
{
    // RequestedTheme is the app preference; ActualTheme follows system
    // changes while the window is alive. The shell supplies its current root.
    private static ElementTheme? _windowTheme;
    private static readonly List<WeakReference<SolidColorBrush>> LiveBrushes = new();
    private static readonly ConditionalWeakTable<SolidColorBrush, Func<Color>> BrushColors = new();
    private static int _brushesSincePrune;

    public static ElementTheme? WindowTheme
    {
        get => _windowTheme;
        set
        {
            if (_windowTheme == value)
            {
                return;
            }
            _windowTheme = value;
            // Called by the window's ActualThemeChanged handler on the UI
            // thread. Recolor in place so controls retain drafts and focus.
            for (var index = LiveBrushes.Count - 1; index >= 0; index--)
            {
                if (LiveBrushes[index].TryGetTarget(out var brush))
                {
                    if (BrushColors.TryGetValue(brush, out var color))
                    {
                        brush.Color = color();
                    }
                }
                else
                {
                    LiveBrushes.RemoveAt(index);
                }
            }
            _brushesSincePrune = 0;
        }
    }

    public static bool IsDark => WindowTheme switch
    {
        ElementTheme.Dark => true,
        ElementTheme.Light => false,
        _ => Application.Current?.RequestedTheme == ApplicationTheme.Dark,
    };

    public static Color Accent => Hex(IsDark ? 0x8B5CF6u : 0x6A3DFFu);
    public static Color Secondary => Hex(IsDark ? 0xE879F9u : 0xC026D3u);
    public static Color Background => Hex(IsDark ? 0x08070Du : 0xFBFBFDu);
    public static Color Sidebar => Hex(IsDark ? 0x12101Du : 0xF3F2F8u);
    public static Color Panel => IsDark ? Hex(0x100E1Au) : Color.FromArgb(255, 255, 255, 255);
    /// <summary>Behind a tab strip. A step darker than the pane under it, so the strip reads as chrome.</summary>
    public static Color TabStrip => Hex(IsDark ? 0x08070Du : 0xF3F2F8u);
    public static Color Border => Hex(IsDark ? 0x211D33u : 0xE7E7EEu);
    public static Color RowHighlight => Hex(IsDark ? 0x1B1430u : 0xF0ECFFu);
    /// <summary>The row that is actually selected. Tinted with the accent at 18 percent opacity, matching the Mac rowSelected.</summary>
    public static Color RowSelected => IsDark
        ? Color.FromArgb(46, 0x8B, 0x5C, 0xF6)
        : Color.FromArgb(46, 0x6A, 0x3D, 0xFF);
    /// <summary>A selected row nested inside a selected one. Neutral, not tinted, matching the Mac rowSelectedNested.</summary>
    public static Color RowSelectedNested => Hex(IsDark ? 0x26213Du : 0xE8E7F0u);
    public static Color AccentSoft => Hex(IsDark ? 0x1B1430u : 0xF0ECFFu);
    /// <summary>Quiet circular seat behind a small chrome glyph. Black at 6 percent in light mode, white at 9 percent in dark mode, matching the Mac controlSeat.</summary>
    public static Color ControlSeat => IsDark
        ? Color.FromArgb(23, 255, 255, 255)
        : Color.FromArgb(15, 0, 0, 0);
    public static Color ControlGlyph => Hex(IsDark ? 0xA8A5B5u : 0x6B6876u);
    /// <summary>The same glyph while the pointer is over it.</summary>
    public static Color ControlGlyphHover => Hex(IsDark ? 0xE9E7F0u : 0x2A2831u);
    /// <summary>
    /// Caption button pressed fill. Hover reuses ControlSeat, a press wants a
    /// deeper neutral at about twice the hover weight, in both themes.
    /// Translucent like the hover: it lands on the content tone the buttons sit
    /// over, and the OS caption painter only honors these colors where that
    /// composition works.
    /// </summary>
    public static Color CaptionPressed => IsDark
        ? Color.FromArgb(46, 255, 255, 255)
        : Color.FromArgb(31, 0, 0, 0);
    public static Color Success => Accent;
    public static Color Warning => Color.FromArgb(255, 0xE0, 0xA9, 0x3B);
    public static Color Danger => Color.FromArgb(255, 0xD6, 0x45, 0x3F);
    /// <summary>A session that is doing something right now. The accent, like success, but named separately so the two can diverge.</summary>
    public static Color StateWorking => Accent;
    public static Color StateIdle => Hex(IsDark ? 0x6E6A80u : 0x9A97A6u);
    /// <summary>Muted green for added lines. A diff is the one place this colour is not a traffic light.</summary>
    public static Color DiffAdded => Hex(IsDark ? 0x5FBF8Bu : 0x2E8B57u);
    /// <summary>Muted red for removed lines, matching the Mac Theme.</summary>
    public static Color DiffRemoved => Hex(IsDark ? 0xE8827Cu : 0xC2453Fu);

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

    /// <summary>
    /// Default text colour for explicitly colored glyphs and syntax ranges.
    /// Follow the window theme rather than the application resource lookup,
    /// which can still resolve the launch theme during a system change.
    /// </summary>
    public static Color DefaultText => Hex(IsDark ? 0xFFFFFFu : 0x000000u);

    /// <summary>
    /// Colour for a syntax kind. The whole palette in one place, transcribed
    /// from the Mac Theme. Variables, operators and punctuation stay the text
    /// colour: colouring every token is how a file ends up unreadable, so most
    /// of it must not be coloured.
    /// </summary>
    public static Color Syntax(SyntaxKind kind) => kind switch
    {
        SyntaxKind.Keyword => Accent,
        SyntaxKind.String => Hex(IsDark ? 0xD8A657u : 0x8F5C1Eu),
        SyntaxKind.Number or SyntaxKind.Constant => Hex(IsDark ? 0x7FD1B9u : 0x1F6F5Cu),
        SyntaxKind.Comment => Hex(IsDark ? 0x6B6B76u : 0x8A8A93u),
        SyntaxKind.Type => Secondary,
        SyntaxKind.Function => Hex(IsDark ? 0x89B4FAu : 0x2D62C4u),
        SyntaxKind.Attribute => Hex(IsDark ? 0xC79BF0u : 0x9A5CC4u),
        SyntaxKind.Property => Hex(IsDark ? 0x9CC5E0u : 0x1F5F8Fu),
        SyntaxKind.Markup => Hex(IsDark ? 0x8FD6BEu : 0x1F6F5Cu),
        _ => DefaultText,
    };

    public static SolidColorBrush Brush(Color color) => new(color);
    /// <summary>
    /// A private brush whose semantic color follows the window theme. Keep
    /// providers static or capture only value data, never a page or control.
    /// Weak ownership lets a discarded visual tree and its providers collect.
    /// </summary>
    public static SolidColorBrush Brush(Func<Color> color)
    {
        var brush = new SolidColorBrush(color());
        BrushColors.Add(brush, color);
        if (++_brushesSincePrune >= 128)
        {
            LiveBrushes.RemoveAll(reference => !reference.TryGetTarget(out _));
            _brushesSincePrune = 0;
        }
        LiveBrushes.Add(new WeakReference<SolidColorBrush>(brush));
        return brush;
    }

    public static SolidColorBrush AccentBrush => Brush(static () => Accent);
    public static SolidColorBrush BackgroundBrush => Brush(static () => Background);
    public static SolidColorBrush SidebarBrush => Brush(static () => Sidebar);
    public static SolidColorBrush PanelBrush => Brush(static () => Panel);
    public static SolidColorBrush TabStripBrush => Brush(static () => TabStrip);
    public static SolidColorBrush BorderBrush => Brush(static () => Border);
    public static SolidColorBrush ControlSeatBrush => Brush(static () => ControlSeat);
    public static SolidColorBrush AccentSoftBrush => Brush(static () => AccentSoft);

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
