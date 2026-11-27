// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using Microsoft.Win32;
using Tokenstat.Design;

namespace Tokenstat.Install;

internal static class SelfInstall
{
    private static int _hostPolicyGeneration;
    private static readonly object HostPolicyGate = new();

    public const string UninstallKeyName = "ai.tokenstat.tokenstat";

    /// <summary>
    /// The per-user scheduled task that runs hostd. A task, never a Windows
    /// Service: it runs as you, reads your logs, and has no business running
    /// as SYSTEM or existing before you log in.
    /// </summary>
    public const string HostTaskName = "ai.tokenstat.hostd";

    public static string InstallDirectory =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Programs",
            "tokenstat");

    public static string InstalledExe => Path.Combine(InstallDirectory, "Tokenstat.exe");

    /// <summary>
    /// Where hostd runs from: its data folder, never the install folder. A
    /// child hostd starts without a directory of its own inherits this one,
    /// and anything still sitting in the install folder keeps an update from
    /// swapping it. Vendor installers that compile C# also resolve
    /// references from here first, and the install folder's .NET facades
    /// break them.
    /// </summary>
    public static string HostWorkingDirectory
    {
        get
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat");
            try { Directory.CreateDirectory(dir); } catch { }
            return Directory.Exists(dir) ? dir : Path.GetTempPath();
        }
    }

    public static bool IsRunningFromInstall
    {
        get
        {
            var current = Path.GetFullPath(AppContext.BaseDirectory).TrimEnd('\\', '/');
            var dest = Path.GetFullPath(InstallDirectory).TrimEnd('\\', '/');
            return string.Equals(current, dest, StringComparison.OrdinalIgnoreCase);
        }
    }

    /// <summary>
    /// Unsigned Actions artifacts drop <c>PREVIEW.txt</c> next to the exe.
    /// Authenticode is skipped there. Auto-update still reads the latest
    /// GitHub Release.
    /// </summary>
    public static bool IsPreviewChannel =>
        File.Exists(Path.Combine(AppContext.BaseDirectory, "PREVIEW.txt"));

    public static bool IsDevBuild
    {
        get
        {
            if (Environment.GetEnvironmentVariable("TOKENSTAT_DEV") == "1")
            {
                return true;
            }
            var dir = AppContext.BaseDirectory;
            return dir.Contains(@"\apps\windows\", StringComparison.OrdinalIgnoreCase)
                || dir.Contains(@"\bin\Debug\", StringComparison.OrdinalIgnoreCase)
                || dir.Contains(@"\bin\Release\", StringComparison.OrdinalIgnoreCase)
                || dir.Contains(@"\bin\x64\", StringComparison.OrdinalIgnoreCase)
                || dir.Contains(@"\bin\ARM64\", StringComparison.OrdinalIgnoreCase);
        }
    }

    public static bool TryHandleCli(string[] args)
    {
        for (var i = 0; i < args.Length; i++)
        {
            if (string.Equals(args[i], "--uninstall", StringComparison.OrdinalIgnoreCase))
            {
                Uninstall();
                return true;
            }
            if (string.Equals(args[i], "--install", StringComparison.OrdinalIgnoreCase))
            {
                InstallFromCurrentDirectory();
                LaunchInstalled();
                return true;
            }
            if (string.Equals(args[i], "--apply-update", StringComparison.OrdinalIgnoreCase)
                && i + 1 < args.Length)
            {
                AppInstaller.ApplyStaged(args[i + 1]);
                return true;
            }
        }

        if (IsRunningFromInstall || IsDevBuild)
        {
            if (IsRunningFromInstall)
            {
                // An update swaps the folder under a script, outside this
                // process. Refresh the Add/Remove Programs entry on the way
                // in, so it names the version that is actually on disk.
                RefreshUninstallKey();
            }
            return false;
        }

        InstallFromCurrentDirectory();
        LaunchInstalled();
        return true;
    }

    public static void InstallFromCurrentDirectory()
    {
        var source = Path.GetFullPath(AppContext.BaseDirectory);
        var dest = Path.GetFullPath(InstallDirectory);
        if (string.Equals(source.TrimEnd('\\', '/'), dest.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase))
        {
            RefreshUninstallKey();
            WriteStartMenuShortcut();
            return;
        }
        InstallTree(source, dest, StopRelatedProcesses);
        WriteUninstallKey();
        WriteStartMenuShortcut();
        TryRegisterHostTask();
    }

    internal static void InstallTree(string source, string dest, Action stopProcesses)
    {
        var staging = dest.TrimEnd('\\', '/') + ".install-" + Guid.NewGuid().ToString("N");
        var previous = dest.TrimEnd('\\', '/') + ".previous-" + Guid.NewGuid().ToString("N");
        try
        {
            Directory.CreateDirectory(staging);
            CopyTree(source, staging);
            if (!File.Exists(Path.Combine(staging, "Tokenstat.exe"))
                || !File.Exists(Path.Combine(staging, "tokenstat-hostd.exe")))
            {
                throw new IOException(L10n.Text("windows.selfinstall.the_download_is_incomplete_extract_the_ent.2dd71042"));
            }
            stopProcesses();
            if (Directory.Exists(dest))
            {
                Directory.Move(dest, previous);
            }
            try
            {
                Directory.Move(staging, dest);
            }
            catch
            {
                if (Directory.Exists(previous) && !Directory.Exists(dest))
                {
                    Directory.Move(previous, dest);
                }
                throw;
            }
        }
        finally
        {
            try { if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true); } catch { }
            try { if (Directory.Exists(dest) && Directory.Exists(previous)
                && Tokenstat.Pages.WebViewProfile.MoveLegacyFrom(previous)) Directory.Delete(previous, recursive: true); } catch { }
        }
    }

    public static void Uninstall()
    {
        StopRelatedProcesses();
        TryUnregisterHostTask();
        RemoveStartMenuShortcut();
        RemoveUninstallKey();
        RemoveProtocolRegistration();
        // This process is Tokenstat.exe inside the install directory. Delete
        // after we exit, or the copy that Add/Remove Programs launched stays
        // locked and the folder is left behind.
        ScheduleDelete(InstallDirectory);
    }

    private static void RemoveProtocolRegistration()
    {
        try
        {
            using var command = Registry.CurrentUser.OpenSubKey(@"Software\Classes\tokenstat\shell\open\command");
            if (command?.GetValue(null) is string value
                && value.StartsWith("\"" + InstalledExe + "\"", StringComparison.OrdinalIgnoreCase))
                Registry.CurrentUser.DeleteSubKeyTree(@"Software\Classes\tokenstat", throwOnMissingSubKey: false);
        }
        catch { }
    }

    public static void StopRelatedProcesses()
    {
        var self = Environment.ProcessId;
        var dest = Path.GetFullPath(InstallDirectory)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        foreach (var process in Process.GetProcesses())
        {
            try
            {
                if (process.Id == self)
                {
                    continue;
                }
                string? path;
                try
                {
                    path = process.MainModule?.FileName;
                }
                catch
                {
                    continue;
                }
                if (string.IsNullOrEmpty(path))
                {
                    continue;
                }
                var full = Path.GetFullPath(path);
                if (full.StartsWith(dest + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                    || full.StartsWith(dest + Path.AltDirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                    || string.Equals(full, dest, StringComparison.OrdinalIgnoreCase))
                {
                    process.Kill(entireProcessTree: true);
                    process.WaitForExit(4000);
                }
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

    public static void ApplyAlwaysOn(bool alwaysOn)
    {
        lock (HostPolicyGate)
        {
            var generation = Interlocked.Increment(ref _hostPolicyGeneration);
            if (alwaysOn)
            {
                var hostd = Path.Combine(InstallDirectory, "tokenstat-hostd.exe");
                if (!File.Exists(hostd))
                {
                    hostd = Path.Combine(AppContext.BaseDirectory, "tokenstat-hostd.exe");
                }
                if (File.Exists(hostd))
                {
                    RegisterHostTask(hostd, allowLogonFallback: true);
                }
                return;
            }
            UnregisterHostTask();
            _ = Task.Run(async () =>
            {
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(5));
                    lock (HostPolicyGate)
                    {
                        if (_hostPolicyGeneration == generation)
                        {
                            UnregisterHostTask();
                        }
                    }
                }
                catch
                {
                }
            });
        }
    }

    public static void RegisterHostTask(string hostdExe, bool allowLogonFallback = false)
    {
        var script = BundledHostScript();
        if (script is not null)
        {
            try
            {
                using var registration = Process.Start(new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{script}\" -Bin \"{hostdExe}\"",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                });
                if (registration is not null && registration.WaitForExit(15000) && registration.ExitCode == 0)
                {
                    return;
                }
                if (registration is not null && !registration.HasExited)
                {
                    registration.Kill(entireProcessTree: true);
                }
            }
            catch
            {
            }
        }
        if (!allowLogonFallback)
        {
            return;
        }
        // Same hidden shape as the script: hostd is a console binary, and a
        // task action that runs it directly opens a visible console window.
        // schtasks cannot express restart-on-failure, so this fallback stays
        // degraded next to the script; it only runs when the script is gone.
        var quoted = hostdExe.Replace("'", "''");
        var work = HostWorkingDirectory.Replace("'", "''");
        var launch = $"powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command \\\"$child = Start-Process -FilePath '{quoted}' -WorkingDirectory '{work}' -WindowStyle Hidden -PassThru; $null = $child.Handle; $child.WaitForExit(); exit $child.ExitCode\\\"";
        RunSchTasks($"/Create /TN \"{HostTaskName}\" /TR \"{launch}\" /SC ONLOGON /RL LIMITED /F");
        RunSchTasks($"/Run /TN \"{HostTaskName}\"");
    }

    /// <summary>
    /// Remove the per-user hostd task. schtasks directly rather than the
    /// script, so it works when the install directory is already gone.
    /// </summary>
    public static void UnregisterHostTask()
    {
        RunSchTasks($"/Delete /TN \"{HostTaskName}\" /F");
    }

    /// <summary>
    /// Rewrite the Add/Remove Programs entry for the version on disk.
    /// </summary>
    public static void RefreshUninstallKey()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + UninstallKeyName,
                writable: true);
            if (key is null)
            {
                WriteUninstallKey();
                return;
            }
            if (string.Equals(key.GetValue("DisplayVersion") as string, AppInfo.Version, StringComparison.Ordinal))
            {
                return;
            }
        }
        catch
        {
            return;
        }
        WriteUninstallKey();
    }

    private static void ScheduleDelete(string dest)
    {
        try
        {
            var helper = Path.Combine(Path.GetTempPath(), $"tokenstat-uninstall-{Guid.NewGuid():N}.ps1");
            var script = string.Join(Environment.NewLine, new[]
            {
                "$ErrorActionPreference = 'SilentlyContinue'",
                $"$waitPid = {Environment.ProcessId}",
                "$deadline = (Get-Date).AddSeconds(30)",
                "while (Get-Process -Id $waitPid -ErrorAction SilentlyContinue) {",
                "  if ((Get-Date) -gt $deadline) { exit 1 }",
                "  Start-Sleep -Milliseconds 200",
                "}",
                $"Remove-Item -LiteralPath '{EscapePs(dest)}' -Recurse -Force",
                "Remove-Item -LiteralPath $PSCommandPath -Force",
            });
            File.WriteAllText(helper, script);
            Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"{helper}\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = Path.GetTempPath(),
            });
        }
        catch
        {
        }
    }

    private static void LaunchInstalled()
    {
        if (!File.Exists(InstalledExe))
        {
            return;
        }
        Process.Start(new ProcessStartInfo
        {
            FileName = InstalledExe,
            WorkingDirectory = InstallDirectory,
            UseShellExecute = true,
        });
    }

    private static void CopyTree(string source, string dest)
    {
        foreach (var dir in Directory.EnumerateDirectories(source, "*", SearchOption.AllDirectories))
        {
            var rel = Path.GetRelativePath(source, dir);
            Directory.CreateDirectory(Path.Combine(dest, rel));
        }
        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            var name = Path.GetFileName(file);
            if (name.EndsWith(".pdb", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            var rel = Path.GetRelativePath(source, file);
            var target = Path.Combine(dest, rel);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            CopyFileRetry(file, target);
        }
    }

    private static void CopyFileRetry(string source, string dest)
    {
        for (var i = 0; i < 5; i++)
        {
            try
            {
                File.Copy(source, dest, overwrite: true);
                return;
            }
            catch (IOException)
            {
                Thread.Sleep(200);
            }
        }
        File.Copy(source, dest, overwrite: true);
    }

    private static void WriteUninstallKey()
    {
        using var key = Registry.CurrentUser.CreateSubKey(
            @"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + UninstallKeyName);
        if (key is null)
        {
            return;
        }
        var version = AppInfo.Version;
        key.SetValue("DisplayName", "tokenstat");
        key.SetValue("DisplayVersion", version);
        key.SetValue("Publisher", AppInfo.Company);
        key.SetValue("URLInfoAbout", "https://tokenstat.ai");
        key.SetValue("HelpLink", "https://tokenstat.ai");
        key.SetValue("InstallLocation", InstallDirectory);
        key.SetValue("DisplayIcon", InstalledExe);
        key.SetValue("UninstallString", $"\"{InstalledExe}\" --uninstall");
        key.SetValue("QuietUninstallString", $"\"{InstalledExe}\" --uninstall");
        key.SetValue("NoModify", 1, RegistryValueKind.DWord);
        key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        key.SetValue("EstimatedSize", EstimatedSizeKb(), RegistryValueKind.DWord);
        key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
        key.SetValue("Comments", "Unified token usage for AI coding agents and LLM tools.");
    }

    private static int EstimatedSizeKb()
    {
        try
        {
            long bytes = 0;
            foreach (var file in Directory.EnumerateFiles(InstallDirectory, "*", SearchOption.AllDirectories))
            {
                bytes += new FileInfo(file).Length;
            }
            return (int)Math.Min(bytes / 1024, int.MaxValue);
        }
        catch
        {
            return 0;
        }
    }

    private static void RemoveUninstallKey()
    {
        try
        {
            Registry.CurrentUser.DeleteSubKeyTree(
                @"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + UninstallKeyName,
                throwOnMissingSubKey: false);
        }
        catch
        {
        }
    }

    private static string StartMenuShortcutPath
    {
        get
        {
            var programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
            var folder = Path.Combine(programs, "tokenstat");
            Directory.CreateDirectory(folder);
            return Path.Combine(folder, "tokenstat.lnk");
        }
    }

    private static void WriteStartMenuShortcut()
    {
        try
        {
            var path = EscapePs(StartMenuShortcutPath);
            var exe = EscapePs(InstalledExe);
            var dir = EscapePs(InstallDirectory);
            var cmd =
                "$s = (New-Object -ComObject WScript.Shell).CreateShortcut('" + path + "'); " +
                "$s.TargetPath = '" + exe + "'; " +
                "$s.WorkingDirectory = '" + dir + "'; " +
                "$s.IconLocation = '" + exe + "'; " +
                "$s.Description = 'tokenstat'; " +
                "$s.Save()";
            Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -NonInteractive -EncodedCommand "
                    + Convert.ToBase64String(System.Text.Encoding.Unicode.GetBytes(cmd)),
                UseShellExecute = false,
                CreateNoWindow = true,
            })?.WaitForExit(8000);
        }
        catch
        {
        }
    }

    private static string EscapePs(string value) => value.Replace("'", "''");

    private static void RemoveStartMenuShortcut()
    {
        try
        {
            var programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
            var folder = Path.Combine(programs, "tokenstat");
            if (Directory.Exists(folder))
            {
                Directory.Delete(folder, recursive: true);
            }
        }
        catch
        {
        }
    }

    private static void TryRegisterHostTask()
    {
        var hostd = Path.Combine(InstallDirectory, "tokenstat-hostd.exe");
        if (!File.Exists(hostd))
        {
            return;
        }
        try
        {
            RegisterHostTask(hostd);
        }
        catch
        {
        }
    }

    private static void TryUnregisterHostTask()
    {
        var script = Path.Combine(InstallDirectory, "install-host-task.ps1");
        if (File.Exists(script))
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{script}\" -Uninstall",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                })?.WaitForExit(10000);
            }
            catch
            {
            }
        }
        try
        {
            UnregisterHostTask();
        }
        catch
        {
        }
    }

    private static string? BundledHostScript()
    {
        var nextToApp = Path.Combine(AppContext.BaseDirectory, "install-host-task.ps1");
        if (File.Exists(nextToApp))
        {
            return nextToApp;
        }
        var installed = Path.Combine(InstallDirectory, "install-host-task.ps1");
        return File.Exists(installed) ? installed : null;
    }

    private static void RunSchTasks(string arguments)
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "schtasks.exe",
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
            })?.WaitForExit(10000);
        }
        catch
        {
        }
    }
}
