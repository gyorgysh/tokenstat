// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Tokenstat.Install;

namespace Tokenstat;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            return Run(args);
        }
        catch (Exception ex)
        {
            // This exe has no console, so without this a failure in the
            // lines below dies with nothing on screen and nothing on disk,
            // which is how a launch bug stays a mystery. app.log covers the
            // UI thread once it runs; this covers everything before that.
            try
            {
                var dir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "tokenstat", "logs");
                Directory.CreateDirectory(dir);
                File.AppendAllText(
                    Path.Combine(dir, "startup.log"),
                    $"{DateTime.UtcNow:o} {ex}{Environment.NewLine}");
            }
            catch
            {
                // Logging must not become a second crash.
            }
            return 1;
        }
    }

    private static int Run(string[] args)
    {
        if (SelfInstall.TryHandleCli(args))
        {
            return 0;
        }

        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(
                DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            new App();
        });
        return 0;
    }
}
