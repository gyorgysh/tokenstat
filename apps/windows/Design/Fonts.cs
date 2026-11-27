// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Text;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;

namespace Tokenstat.Design;

internal static class Fonts
{
    public static FontFamily Interface { get; } =
        new("ms-appx:///Assets/Fonts/Manrope-Variable.ttf#Manrope");

    public static FontFamily Mono { get; } =
        new("ms-appx:///Assets/Fonts/JetBrainsMono-Variable.ttf#JetBrains Mono");

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
    public const double PageTitle = 24;
    public const double SignInCode = 25;

    public static TextBlock Text(
        string text,
        double size = Body,
        Windows.UI.Text.FontWeight? weight = null,
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

    public static TextBlock Code(
        string text,
        double size = ChatCode,
        Windows.UI.Text.FontWeight? weight = null,
        double opacity = 1)
    {
        var block = Text(text, size, weight, opacity);
        block.FontFamily = Mono;
        return block;
    }

    public static TextBlock Numeric(
        string text,
        double size = StatValue,
        Windows.UI.Text.FontWeight? weight = null)
    {
        var block = Text(text, size, weight ?? FontWeights.SemiBold);
        return Tabular(block);
    }

    public static TextBlock Tabular(TextBlock block)
    {
        // The enum lives in Microsoft.UI.Xaml in WinUI 3 (Windows.UI.Text
        // is the UWP-era home and carries no numeral alignment type).
        Typography.SetNumeralAlignment(block, Microsoft.UI.Xaml.FontNumeralAlignment.Tabular);
        return block;
    }
}
