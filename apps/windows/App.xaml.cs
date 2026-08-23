// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Tokenstat.Host;

namespace Tokenstat;

public partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            e.Handled = true;
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        HostOwnerLock.Acquire();
        HostProcess.EnsureRunning();
        _window = new MainWindow();
        _window.Closed += (_, _) =>
        {
            HostOwnerLock.Release();
        };
        _window.Activate();
        _ = AppServices.Update.CheckAndInstallAsync();
    }
}
