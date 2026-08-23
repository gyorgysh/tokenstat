// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using Microsoft.Win32;
using Tokenstat.Design;

namespace Tokenstat.Install;

/// <summary>
/// Per-user install into %LOCALAPPDATA%\Programs\tokenstat.
/// Click Tokenstat.exe from a zip: it copies itself there, writes Start Menu
/// and HKCU uninstall, then relaunches from the install directory.
/// </summary>
internal static class SelfInstall
{
    public const string UninstallKeyName = "ai.tokenstat.tokenstat";

    public static string InstallDirectory =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Programs",
            "tokenstat");

    public static string InstalledExe => Path.Combine(InstallDirectory, "Tokenstat.exe");

    public static bool IsRunningFromInstall
    {
        get
        {
            var current = Path.GetFullPath(AppContext.BaseDirectory).TrimEnd('\\', '/');
            var dest = Path.GetFullPath(InstallDirectory).TrimEnd('\\', '/');
            return string.Equals(current, dest, StringComparison.OrdinalIgnoreCase);
        }
    }

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

    /// <summary>
    /// Handle --install, --uninstall, --apply-update, and first-run copy.
    /// Returns true when the process should exit instead of opening a window.
    /// </summary>
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
            return false;
        }

        // Clicked from a zip or a download folder: install for this user.
        InstallFromCurrentDirectory();
        LaunchInstalled();
        return true;
    }

    public static void InstallFromCurrentDirectory()
    {
        var source = Path.GetFullPath(AppContext.BaseDirectory);
        var dest = Path.GetFullPath(InstallDirectory);
        StopRelatedProcesses();
        Directory.CreateDirectory(dest);
        CopyTree(source, dest);
        WriteUninstallKey();
        WriteStartMenuShortcut();
        TryRegisterHostTask();
    }

    public static void Uninstall()
    {
        StopRelatedProcesses();
        TryUnregisterHostTask();
        RemoveStartMenuShortcut();
        RemoveUninstallKey();
        // This process is Tokenstat.exe inside the install directory. Delete
        // after we exit, or the copy that Add/Remove Programs launched stays
        // locked and the folder is left behind.
        ScheduleDelete(InstallDirectory);
    }

    /// <summary>
    /// Stop the installed app and hostd. Does not touch a CLI `tokenstat.exe`
    /// living somewhere else: match by path under the install directory.
    /// </summary>
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
                // A process we cannot open is not ours to stop.
            }
            finally
            {
                process.Dispose();
            }
        }
    }

    private static void ScheduleDelete(string dest)
    {
        try
        {
            var helper = Path.Combine(Path.GetTempPath(), "tokenstat-uninstall.ps1");
            var script = string.Join(Environment.NewLine, new[]
            {
                "$ErrorActionPreference = 'SilentlyContinue'",
                "Start-Sleep -Seconds 2",
                $"Remove-Item -LiteralPath '{EscapePs(dest)}' -Recurse -Force",
                "Remove-Item -LiteralPath $PSCommandPath -Force",
            });
            File.WriteAllText(helper, script);
            Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + helper + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
            });
        }
        catch
        {
            // Uninstall key and shortcut are already gone.
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
            // Already gone.
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
                Arguments = "-NoProfile -ExecutionPolicy Bypass -Command " + cmd,
                UseShellExecute = false,
                CreateNoWindow = true,
            })?.WaitForExit(8000);
        }
        catch
        {
            // Start Menu is convenience. The exe in Programs still runs.
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
            // Best effort.
        }
    }

    private static void TryRegisterHostTask()
    {
        var hostd = Path.Combine(InstallDirectory, "tokenstat-hostd.exe");
        var script = Path.Combine(InstallDirectory, "install-host-task.ps1");
        if (!File.Exists(hostd) || !File.Exists(script))
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
            })?.WaitForExit(15000);
        }
        catch
        {
            // HostProcess.EnsureRunning will spawn hostd on next launch.
        }
    }

    private static void TryUnregisterHostTask()
    {
        var script = Path.Combine(InstallDirectory, "install-host-task.ps1");
        if (!File.Exists(script))
        {
            return;
        }
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
            // Ignore.
        }
    }
}
