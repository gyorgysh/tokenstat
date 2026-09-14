// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Text;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;

namespace Tokenstat.Design;

/// <summary>
/// The two bundled typefaces and the Mac type scale, in one place.
/// Mirrors the Mac AppFonts plus the Theme type ladder, at the same sizes:
/// a WinUI effective pixel is a Mac point, so the ladder carries over one
/// to one. Manrope is the interface face, for every word a person reads as
/// language. JetBrains Mono is for text read character by character, where
/// a lowercase l and a digit 1 have to be different pictures: terminals,
/// diffs, paths, commands, and codes.
/// </summary>
internal static class Fonts
{
    /// <summary>
    /// Manrope, loaded from the app folder rather than from the system font
    /// book. The file ships beside the exe as content (see the csproj), so
    /// the per-user install under %LOCALAPPDATA% carries it along, and the
    /// app never installs anything into the person's fonts.
    /// </summary>
    public static FontFamily Interface { get; } =
        new("ms-appx:///Assets/Fonts/Manrope-Variable.ttf#Manrope");

    /// <summary>
    /// JetBrains Mono, loaded from the app folder like <see cref="Interface"/>.
    /// </summary>
    public static FontFamily Mono { get; } =
        new("ms-appx:///Assets/Fonts/JetBrainsMono-Variable.ttf#JetBrains Mono");

    // The Mac ladder, exact values from Theme.swift on macOS: body 13 down
    // to caption 10, titles up to 26, chat prose a step above body.
    public const double LargeTitle = 26;
    public const double Title = 22;
    public const double Title2 = 17;
    public const double Title3 = 15;
    public const double Headline = 13;
    public const double Body = 13;
    public const double Callout = 12;
    public const double Subheadline = 11;
    public const double Footnote = 10;
    public const double Caption = 10;
    public const double ChatBody = 14;
    public const double ChatCode = 12;
    public const double SectionHeader = 12;
    public const double StatValue = 26;

    /// <summary>
    /// Interface text at a scale size. The face comes from here rather than
    /// from the platform default, so a block built with this helper stays in
    /// Manrope even where a theme override does not reach.
    /// </summary>
    public static TextBlock Text(
        string text,
        double size = Body,
        FontWeight? weight = null,
        double opacity = 1)
    {
        var block = new TextBlock
        {
            Text = text,
            FontFamily = Interface,
            FontSize = size,
            Opacity = opacity,
        };
        if (weight.HasValue)
        {
            block.FontWeight = weight.Value;
        }
        return block;
    }

    /// <summary>
    /// Monospaced text at a scale size: terminals, diffs, paths, commands.
    /// </summary>
    public static TextBlock Code(
        string text,
        double size = ChatCode,
        FontWeight? weight = null,
        double opacity = 1)
    {
        var block = Text(text, size, weight, opacity);
        block.FontFamily = Mono;
        return block;
    }

    /// <summary>
    /// A headline number in the interface face with tabular figures, so a
    /// value that updates does not jitter its column. Mirrors the Mac
    /// numeric style, which is Manrope with monospaced digits rather than
    /// the terminal face: a stat tile is a headline, not a readout.
    /// </summary>
    public static TextBlock Numeric(
        string text,
        double size = StatValue,
        FontWeight? weight = null)
    {
        var block = Text(text, size, weight ?? FontWeights.SemiBold);
        return Tabular(block);
    }

    /// <summary>
    /// Tabular figures on an existing block, for numbers that sit in columns
    /// or update in place. Monospaced text needs no call: its digits are a
    /// fixed width by construction.
    /// </summary>
    public static TextBlock Tabular(TextBlock block)
    {
        Typography.SetNumeralAlignment(block, FontNumeralAlignment.Tabular);
        return block;
    }
}
