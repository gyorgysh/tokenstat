// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using Tokenstat.Install;

namespace Tokenstat.Host;

internal static class HostProcess
{
    private const string ExpectedProtocolVersion = "57";

    public static void EnsureRunning() => EnsureRunning(replaceOld: true);

    public static void RecoverIfMissing() => EnsureRunning(replaceOld: false);

    private static void EnsureRunning(bool replaceOld)
    {
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
            Log("Host executable not found beside the app or in the install directories.");
            return;
        }

        if (answering)
        {
            StopOldHelper();
        }

        Log($"Starting host: {hostd}; pipe={HostClient.PipeName}");
        TryInstallTask(hostd);
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = hostd,
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = SelfInstall.HostWorkingDirectory,
            });
        }
        catch (Exception ex)
        {
            Log("Direct host launch failed: " + ex.Message);
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
        Log("Host startup deadline expired without a compatible pipe response. See hostd.log.");
    }

    private static void Log(string message)
    {
        try
        {
            var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "logs");
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, "app-host.log");
            if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024)
                File.Move(path, Path.Combine(directory, "app-host.previous.log"), overwrite: true);
            File.AppendAllText(path, DateTimeOffset.Now.ToString("O") + " " + message + Environment.NewLine);
        }
        catch { }
    }

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
                try { query.Kill(entireProcessTree: true); } catch { }
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
            var expected = "-WorkingDirectory '" + SelfInstall.HostWorkingDirectory.TrimEnd('\\').Replace("'", "''") + "'";
            var current = xml.Contains(expected, StringComparison.OrdinalIgnoreCase)
                || xml.Contains(System.Security.SecurityElement.Escape(expected), StringComparison.OrdinalIgnoreCase);
            return command.Trim().EndsWith("tokenstat-hostd.exe", StringComparison.OrdinalIgnoreCase)
                || (command.Trim().EndsWith("powershell.exe", StringComparison.OrdinalIgnoreCase)
                    && (!xml.Contains("$child.WaitForExit()", StringComparison.OrdinalIgnoreCase) || !current));
        }
        catch
        {
            return false;
        }
    }

    private static void StopOldHelper()
    {
        if (PipeServerProcessId() is int owner)
        {
            try
            {
                using var process = Process.GetProcessById(owner);
                var path = process.MainModule?.FileName;
                if (string.Equals(process.ProcessName, "tokenstat-hostd", StringComparison.OrdinalIgnoreCase)
                    && path is not null && (IsManagedHelper(path) || IsDevelopmentBuild(path)))
                {
                    process.Kill(entireProcessTree: true);
                    process.WaitForExit(4000);
                }
            }
            catch
            {
            }
        }
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
            }
            finally
            {
                process.Dispose();
            }
        }
    }

    private static bool IsDevelopmentBuild(string path) =>
        path.Contains(@"\apps\windows\bin\", StringComparison.OrdinalIgnoreCase)
        || path.Contains(@"\target\debug\", StringComparison.OrdinalIgnoreCase)
        || path.Contains(@"\target\release\", StringComparison.OrdinalIgnoreCase)
        || path.Contains(@"-pc-windows-msvc\", StringComparison.OrdinalIgnoreCase);

    private static bool IsManagedHelper(string path)
    {
        var full = Path.GetFullPath(path);
        var legacy = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "tokenstat", "bin", "tokenstat-hostd.exe");
        return new[] { FindHostd(), Path.Combine(SelfInstall.InstallDirectory, "tokenstat-hostd.exe"), legacy }
            .Any(candidate => candidate is not null
                && string.Equals(full, Path.GetFullPath(candidate), StringComparison.OrdinalIgnoreCase));
    }

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

    private static int? PipeServerProcessId()
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", HostClient.PipeName, PipeDirection.InOut);
            pipe.Connect(500);
            return GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var pid) && pid != 0 ? (int)pid : null;
        }
        catch
        {
            return null;
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint serverProcessId);

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
        }
    }
}
