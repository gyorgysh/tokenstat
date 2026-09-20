// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using System.Runtime.InteropServices;
using Tokenstat.Install;

namespace Tokenstat;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        LogStartup($"Starting GUI; build={typeof(Program).Assembly.GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false).OfType<System.Reflection.AssemblyInformationalVersionAttribute>().FirstOrDefault()?.InformationalVersion}");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => LogStartup($"Unhandled exception; terminating={e.IsTerminating}: {e.ExceptionObject}");
        AppDomain.CurrentDomain.ProcessExit += (_, _) => LogStartup($"Process exit; code={Environment.ExitCode}");
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            LogStartup($"Unobserved task exception: {e.Exception}");
            e.SetObserved();
        };
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
            try
            {
                // XAML may not have initialized yet. A native dialog still
                // gives a double-click launch failure somewhere to go.
                MessageBoxW(IntPtr.Zero,
                    "tokenstat couldn't start. Try opening it again.\n\n" +
                    "If the problem continues, details are in " +
                    "%LOCALAPPDATA%\\tokenstat\\logs\\startup.log.\n\n" + ex.Message,
                    "tokenstat", 0x10);
            }
            catch
            {
                // Keep the original nonzero exit if Windows cannot show UI.
            }
            return 1;
        }
    }

    internal static void LogStartup(string message)
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "logs");
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, "startup.log");
            lock (StartupLogGate)
            {
                if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024)
                    File.Move(path, Path.Combine(dir, "startup.previous.log"), overwrite: true);
                File.AppendAllText(path, $"{DateTime.UtcNow:o} pid={Environment.ProcessId} {message}{Environment.NewLine}");
            }
        }
        catch { /* Preserve the original failure if diagnostics cannot be written. */ }
    }

    private static readonly object StartupLogGate = new();

    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int MessageBoxW(IntPtr owner, string text, string caption, uint type);

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
