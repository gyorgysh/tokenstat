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
    /// <summary>
    /// Kept next to <c>tokenstat_host::PROTOCOL_VERSION</c>. Bump both in the
    /// same change, or this app will restart a helper that already speaks the
    /// methods it was built for, or leave one that does not.
    /// </summary>
    private const string ExpectedProtocolVersion = "22";

    public static void EnsureRunning() => EnsureRunning(replaceOld: true);

    // An ordinary request timeout is not evidence of an outdated helper.
    // Recovery must never terminate a busy helper and its running terminals.
    public static void RecoverIfMissing() => EnsureRunning(replaceOld: false);

    private static void EnsureRunning(bool replaceOld)
    {
        // A pipe that answers is not enough: the scheduled task can be running
        // a helper from an older install, and every method added since would
        // come back as "unknown method".
        var answering = PipeUp();
        if (answering && !replaceOld) return;
        if (answering && SpeaksThisVersion())
        {
            RefreshTaskShape();
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
            if (PipeUp() && SpeaksThisVersion())
            {
                return;
            }
            Thread.Sleep(150);
        }
    }

    /// <summary>
    /// Re-register legacy task actions. Direct actions show a console;
    /// detached wrappers lose failure status, and tree waits can block
    /// recovery on surviving terminals. The current wrapper tracks hostd. The task itself is
    /// the source of truth, so this heals exactly once: after re-registering,
    /// the action reads back hidden and this becomes a quiet query per
    /// launch. It never touches the running helper, only the registration.
    /// </summary>
    private static void RefreshTaskShape()
    {
        try
        {
            var hostd = FindHostd();
            if (hostd is null || !TaskNeedsRepair())
            {
                return;
            }
            TryInstallTask(hostd);
        }
        catch
        {
            // A visible helper still answers the pipe. Leave it.
        }
    }

    private static bool TaskNeedsRepair()
    {
        try
        {
            using var query = Process.Start(new ProcessStartInfo
            {
                FileName = "schtasks.exe",
                Arguments = $"/Query /TN \"{SelfInstall.HostTaskName}\" /XML",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
            });
            if (query is null)
            {
                return false;
            }
            var output = query.StandardOutput.ReadToEndAsync();
            if (!query.WaitForExit(8000))
            {
                try { query.Kill(entireProcessTree: true); } catch { /* Already exited. */ }
                return false;
            }
            if (query.ExitCode != 0)
            {
                return false;
            }
            var xml = output.GetAwaiter().GetResult();
            var open = xml.IndexOf("<Command>", StringComparison.OrdinalIgnoreCase);
            var close = xml.IndexOf("</Command>", StringComparison.OrdinalIgnoreCase);
            if (open < 0 || close <= open)
            {
                return false;
            }
            var command = xml.Substring(open + "<Command>".Length, close - open - "<Command>".Length);
            // Repair both old direct actions and hidden wrappers that exit
            // before hostd or wait for its surviving descendants. Both can
            // prevent restart-on-failure from working.
            return command.Trim().EndsWith("tokenstat-hostd.exe", StringComparison.OrdinalIgnoreCase)
                || (command.Trim().EndsWith("powershell.exe", StringComparison.OrdinalIgnoreCase)
                    && !xml.Contains("$child.WaitForExit()", StringComparison.OrdinalIgnoreCase));
        }
        catch
        {
            return false;
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
                var path = process.MainModule?.FileName;
                if (path is null || !IsManagedHelper(path))
                {
                    continue;
                }
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

    private static bool IsManagedHelper(string path)
    {
        var full = Path.GetFullPath(path);
        var legacy = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "tokenstat", "bin", "tokenstat-hostd.exe");
        return new[] { FindHostd(), Path.Combine(SelfInstall.InstallDirectory, "tokenstat-hostd.exe"), legacy }
            .Any(candidate => candidate is not null
                && string.Equals(full, Path.GetFullPath(candidate), StringComparison.OrdinalIgnoreCase));
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
            var answer = new HostClient().Call("protocol", null, TimeSpan.FromSeconds(5));
            var spoken = answer["protocolVersion"]?.GetValue<string>();
            return spoken == ExpectedProtocolVersion;
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
