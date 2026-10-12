// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md

namespace Tokenstat.Pages;

/// <summary>
/// Where the shared browser profile lives. Kept apart from the WebView
/// runtime so the install script can name the folder without that stack.
/// </summary>
internal static class WebViewProfile
{
    public static string Folder => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "tokenstat",
        "WebView2");
    // A failed migration keeps the old directory available for recovery.
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
