// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.Web.WebView2.Core;

namespace Tokenstat.Pages;

/// <summary>
/// The one WebView2 environment every page shares, with its profile in
/// <c>%LOCALAPPDATA%\tokenstat\WebView2</c>.
///
/// The runtime's default is a folder beside the exe, which for this app is the
/// install folder. An update swaps that folder as a whole, so the default lost
/// every browser sign-in on each update, and the browser processes holding it
/// open blocked the swap itself.
/// </summary>
internal static class WebViewEnvironment
{
    private static readonly object Gate = new();
    private static Task<CoreWebView2Environment>? _environment;

    public static string ProfileFolder => WebViewProfile.Folder;

    public static Task<CoreWebView2Environment> GetAsync()
    {
        lock (Gate)
        {
            // A failed start is not cached: the runtime may be installed or
            // repaired while the app keeps running.
            if (_environment is null || _environment.IsFaulted || _environment.IsCanceled)
            {
                _environment = CreateAsync();
            }
            return _environment;
        }
    }

    private static async Task<CoreWebView2Environment> CreateAsync()
    {
        await Task.Run(MoveLegacyProfile);
        return await CoreWebView2Environment.CreateWithOptionsAsync(
            null, ProfileFolder, new CoreWebView2EnvironmentOptions());
    }

    /// <summary>
    /// Carry an existing profile out of the install folder once, so moving it
    /// does not sign anybody out. Best effort: a profile still in use stays
    /// where it is and a fresh one starts in the new place.
    /// </summary>
    private static void MoveLegacyProfile()
    {
        try
        {
            var target = ProfileFolder;
            if (Directory.Exists(target))
            {
                return;
            }
            // Beside this exe, or beside the previous version an update has
            // just moved aside and has not deleted yet.
            var install = AppContext.BaseDirectory.TrimEnd('\\', '/');
            var legacy = new[]
            {
                Path.Combine(install, "Tokenstat.exe.WebView2"),
                Path.Combine(install + ".prev", "Tokenstat.exe.WebView2"),
            }.FirstOrDefault(Directory.Exists);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            if (legacy is not null)
            {
                Directory.Move(legacy, target);
            }
        }
        catch
        {
            // The runtime creates an empty profile in the new place.
        }
    }
}
