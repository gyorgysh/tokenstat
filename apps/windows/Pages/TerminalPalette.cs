// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Windows.UI;

namespace Tokenstat.Pages;

internal static class TerminalPalette
{
    public static uint BackgroundHex(bool dark) => dark ? 0x0A0A0Bu : 0xF7F7F8u;

    public static uint ForegroundHex(bool dark) => dark ? 0xDCDCE0u : 0x1C1C1Fu;

    public static Color FromHex(uint hex) => Color.FromArgb(
        255,
        (byte)((hex >> 16) & 0xFF),
        (byte)((hex >> 8) & 0xFF),
        (byte)(hex & 0xFF));

    public static Color Background(bool dark) => FromHex(BackgroundHex(dark));

    public static Color Foreground(bool dark) => FromHex(ForegroundHex(dark));

    public static Color Surface(bool dark) => Background(dark);
}
