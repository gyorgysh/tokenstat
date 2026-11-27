// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md

namespace Tokenstat.Pages;

internal static class WebViewProfile
{
    public static string Folder => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "tokenstat",
        "WebView2");
    internal static bool MoveLegacyFrom(string installation, string? profile = null)
    {
        var legacy = Path.Combine(installation, "Tokenstat.exe.WebView2");
        if (!Directory.Exists(legacy)) return true;
        profile ??= Folder;
        if (Directory.Exists(profile)) return false;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(profile)!);
            Directory.Move(legacy, profile);
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }
}
