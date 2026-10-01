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
using Tokenstat.Notifications;

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
        UnhandledException += (_, e) =>
        {
            Program.LogStartup(L10n.Text("windows.app_xaml.xaml_unhandled_exception_0.33c34383", $"{e.Message}"));
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
        InitializeComponent();
        Program.LogStartup(L10n.Text("windows.app_xaml.application_resources_initialized.483da808"));
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        RunNotifications.Shared.EnsureRegistered();
        HostOwnerLock.Acquire();
        Program.LogStartup(L10n.Text("windows.app_xaml.creating_main_window.a841d7fe"));
        _window = new MainWindow();
        Program.LogStartup(L10n.Text("windows.app_xaml.main_window_created.977d73de"));
        if (_window.Content is FrameworkElement root)
            root.Loaded += (_, _) => Program.LogStartup(L10n.Text("windows.app_xaml.main_window_content_loaded.20d9af28"));
        CurrentWindow = _window;
        _window.Closed += (_, _) =>
        {
            Program.LogStartup(L10n.Text("windows.app_xaml.main_window_closed.75546c33"));
            CurrentWindow = null;
            HostOwnerLock.Release();
        };
        _window.Activate();
        Program.LogStartup(L10n.Text("windows.app_xaml.main_window_activated.8696990f"));
        _ = Task.Run(async () =>
        {
            HostProcess.EnsureRunning();
            await AppServices.Update.CheckAndInstallAsync();
        });
    }
}
