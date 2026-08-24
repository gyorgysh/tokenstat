// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using System.Runtime.InteropServices;
using Tokenstat.Install;

namespace Tokenstat.Host;

internal static class HostProcess
{
    public static void EnsureRunning()
    {
        // A pipe that answers is not enough: the scheduled task can be running
        // a helper from an older install, and every method added since would
        // come back as "unknown method".
        var answering = PipeUp();
        if (answering && SpeaksThisVersion())
        {
            return;
        }

        var hostd = FindHostd();
        if (hostd is null)
        {
            // Nothing to replace it with. An old helper still answering is
            // better than no helper at all.
            return;
        }

        if (answering)
        {
            // Unregistering the task does not stop what it already started, and
            // the replacement cannot bind a pipe the old helper still holds. So
            // stop it first, and only once there is something to put in its
            // place. This ends its terminals, which is the same price the Mac
            // pays for `kickstart -k`, and the alternative is an app that never
            // sees the methods it was built for.
            StopOldHelper();
        }

        TryInstallTask(hostd);
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = hostd,
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = Path.GetDirectoryName(hostd) ?? SelfInstall.InstallDirectory,
            });
        }
        catch
        {
            // The scheduled task may already have started it.
        }

        var deadline = DateTime.UtcNow.AddSeconds(8);
        while (DateTime.UtcNow < deadline)
        {
            if (PipeUp())
            {
                return;
            }
            Thread.Sleep(150);
        }
    }

    /// <summary>
    /// Stop a helper from an earlier install so a current one can take the pipe.
    /// </summary>
    private static void StopOldHelper()
    {
        foreach (var process in Process.GetProcessesByName("tokenstat-hostd"))
        {
            try
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(4000);
            }
            catch
            {
                // Another user's helper, or one already gone. Either way there
                // is nothing here to do about it.
            }
            finally
            {
                process.Dispose();
            }
        }
    }

    /// <summary>
    /// Whether the helper answering the pipe was built from this release.
    /// </summary>
    /// <remarks>
    /// Cheap: <c>protocol</c> is answered without opening an archive. Anything
    /// that is not a clear match, including a helper too old to know the
    /// method, counts as a mismatch, which is the right reading of both.
    /// </remarks>
    private static bool SpeaksThisVersion()
    {
        try
        {
            var answer = AppServices.Host.Call("protocol", null, TimeSpan.FromSeconds(5));
            var spoken = answer["coreVersion"]?.GetValue<string>();
            var mine = typeof(HostProcess).Assembly.GetName().Version?.ToString(3);
            return spoken is not null && mine is not null && spoken == mine;
        }
        catch
        {
            return false;
        }
    }

    public static string? FindHostd()
    {
        var sibling = Path.Combine(AppContext.BaseDirectory, "tokenstat-hostd.exe");
        if (File.Exists(sibling))
        {
            return sibling;
        }
        var installed = Path.Combine(SelfInstall.InstallDirectory, "tokenstat-hostd.exe");
        if (File.Exists(installed))
        {
            return installed;
        }
        var legacy = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "tokenstat", "bin", "tokenstat-hostd.exe");
        return File.Exists(legacy) ? legacy : null;
    }

    private static bool PipeUp()
    {
        try
        {
            // WaitNamedPipe does not consume a client slot the way Connect does.
            return WaitNamedPipe(@"\\.\pipe\" + HostClient.PipeName, 200);
        }
        catch
        {
            return false;
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WaitNamedPipe(string lpNamedPipeName, uint nTimeOut);

    private static void TryInstallTask(string hostd)
    {
        var script = Path.Combine(AppContext.BaseDirectory, "install-host-task.ps1");
        if (!File.Exists(script))
        {
            script = Path.Combine(AppContext.BaseDirectory, "scripts", "install-host-task.ps1");
        }
        if (!File.Exists(script))
        {
            return;
        }
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{script}\" -Bin \"{hostd}\"",
                UseShellExecute = false,
                CreateNoWindow = true,
            })?.WaitForExit(8000);
        }
        catch
        {
            // First launch still works if we spawned hostd ourselves.
        }
    }
}
