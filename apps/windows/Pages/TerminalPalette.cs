// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Windows.UI;

namespace Tokenstat.Pages;

/// <summary>
/// The two surfaces every terminal in this app draws on, taken from the
/// Apple TerminalPalette so both clients paint the same content. A terminal
/// is content rather than chrome, so the background sits a shade off the
/// app background instead of reading as a hole.
/// </summary>
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
}
