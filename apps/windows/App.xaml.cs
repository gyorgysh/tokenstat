// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using System.IO;
using Microsoft.UI.Xaml;
using Tokenstat.Host;

namespace Tokenstat;

public partial class App : Application
{
    private MainWindow? _window;

    /// <summary>
    /// The live window, so a file picker can attach to it. Unpackaged WinUI
    /// pickers need an HWND and have no other way to find one.
    /// </summary>
    public static Window? CurrentWindow { get; private set; }

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            Debug.WriteLine(e.Exception);
            try
            {
                var dir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "tokenstat", "logs");
                Directory.CreateDirectory(dir);
                File.AppendAllText(
                    Path.Combine(dir, "app.log"),
                    $"{DateTime.UtcNow:o} {e.Exception}{Environment.NewLine}");
            }
            catch
            {
                // Logging must not become a second crash.
            }
            e.Handled = true;
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        HostOwnerLock.Acquire();
        _window = new MainWindow();
        CurrentWindow = _window;
        _window.Closed += (_, _) =>
        {
            CurrentWindow = null;
            HostOwnerLock.Release();
        };
        _window.Activate();
        _ = Task.Run(async () =>
        {
            HostProcess.EnsureRunning();
            await AppServices.Update.CheckAndInstallAsync();
        });
    }
}
