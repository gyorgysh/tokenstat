// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography.X509Certificates;

namespace Tokenstat.Install;

/// <summary>
/// Put a verified Windows app zip in place of the running install.
///
/// The host already checked SHA256SUMS. This checks Authenticode only when
/// the running Tokenstat.exe is signed, the same rule as the Mac installer
/// reading Developer ID from the running bundle. Preview builds are unsigned,
/// so they skip the publisher check.
/// </summary>
internal static class AppInstaller
{
    public sealed class Failure : Exception
    {
        public Failure(string message) : base(message) { }
    }

    public static void Install(string zipPath)
    {
        if (!File.Exists(zipPath))
        {
            throw new Failure("The download is missing.");
        }
        var current = CurrentExe();
        VerifyPublisher(current, zipPath);

        var dest = SelfInstall.IsRunningFromInstall
            ? SelfInstall.InstallDirectory
            : Path.GetDirectoryName(current) ?? AppContext.BaseDirectory;
        var staging = dest.TrimEnd('\\') + ".next";
        if (Directory.Exists(staging))
        {
            Directory.Delete(staging, recursive: true);
        }
        Directory.CreateDirectory(staging);
        ZipFile.ExtractToDirectory(zipPath, staging, overwriteFiles: true);
        FlattenExtractedTree(staging);

        var stagedExe = Path.Combine(staging, "Tokenstat.exe");
        if (!File.Exists(stagedExe))
        {
            throw new Failure("The download did not contain tokenstat.");
        }
        VerifyPublisher(current, stagedExe);
        WritePending(dest, staging);
    }

    public static string StagingDirectory
    {
        get
        {
            var dest = SelfInstall.IsRunningFromInstall
                ? SelfInstall.InstallDirectory
                : Path.GetDirectoryName(CurrentExe()) ?? AppContext.BaseDirectory;
            return dest.TrimEnd('\\') + ".next";
        }
    }

    public static bool StagingReady => File.Exists(Path.Combine(StagingDirectory, "Tokenstat.exe"));

    public static void Relaunch()
    {
        var dest = SelfInstall.IsRunningFromInstall
            ? SelfInstall.InstallDirectory
            : Path.GetDirectoryName(CurrentExe()) ?? AppContext.BaseDirectory;
        var staging = dest.TrimEnd('\\') + ".next";
        if (!Directory.Exists(staging))
        {
            RestartCurrent();
            return;
        }
        var helper = Path.Combine(Path.GetTempPath(), "tokenstat-apply-update.ps1");
        var exe = Path.Combine(dest, "Tokenstat.exe");
        var script = string.Join(Environment.NewLine, new[]
        {
            "$ErrorActionPreference = 'Stop'",
            $"$dest = '{Escape(dest)}'",
            $"$staging = '{Escape(staging)}'",
            $"$prev = '{Escape(dest.TrimEnd('\\') + ".prev")}'",
            $"$exe = '{Escape(exe)}'",
            // hostd holds files in dest. A folder rename fails while it is open.
            "Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($dest) } | Stop-Process -Force -ErrorAction SilentlyContinue",
            "Start-Sleep -Seconds 2",
            "if (Test-Path -LiteralPath $prev) { Remove-Item -LiteralPath $prev -Recurse -Force }",
            "if (Test-Path -LiteralPath $dest) { Rename-Item -LiteralPath $dest -NewName (Split-Path $prev -Leaf) }",
            "Rename-Item -LiteralPath $staging -NewName (Split-Path $dest -Leaf)",
            "Start-Process -FilePath $exe -WorkingDirectory $dest",
            "if (Test-Path -LiteralPath $prev) { Remove-Item -LiteralPath $prev -Recurse -Force -ErrorAction SilentlyContinue }",
            "Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue",
        });
        File.WriteAllText(helper, script);
        Process.Start(new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{helper}\"",
            UseShellExecute = false,
            CreateNoWindow = true,
        });
        Environment.Exit(0);
    }

    public static void ApplyStaged(string staging)
    {
        var dest = SelfInstall.InstallDirectory;
        if (!Directory.Exists(staging))
        {
            return;
        }
        var prev = dest.TrimEnd('\\') + ".prev";
        if (Directory.Exists(prev))
        {
            try { Directory.Delete(prev, true); } catch { /* ignore */ }
        }
        if (Directory.Exists(dest))
        {
            Directory.Move(dest, prev);
        }
        Directory.Move(staging, dest);
        Launch(Path.Combine(dest, "Tokenstat.exe"), dest);
        try { Directory.Delete(prev, true); } catch { /* ignore */ }
    }

    private static void RestartCurrent()
    {
        var exe = CurrentExe();
        Launch(exe, Path.GetDirectoryName(exe) ?? AppContext.BaseDirectory);
        Environment.Exit(0);
    }

    private static void Launch(string exe, string work)
    {
        if (!File.Exists(exe))
        {
            return;
        }
        Process.Start(new ProcessStartInfo
        {
            FileName = exe,
            WorkingDirectory = work,
            UseShellExecute = true,
        });
    }

    private static void WritePending(string dest, string staging)
    {
        File.WriteAllText(
            Path.Combine(staging, "PENDING-UPDATE.txt"),
            $"replace {dest}{Environment.NewLine}");
    }

    private static void FlattenExtractedTree(string staging)
    {
        var exe = Directory.EnumerateFiles(staging, "Tokenstat.exe", SearchOption.AllDirectories)
            .FirstOrDefault();
        if (exe is null)
        {
            return;
        }
        var root = Path.GetDirectoryName(exe)!;
        if (string.Equals(Path.GetFullPath(root), Path.GetFullPath(staging), StringComparison.OrdinalIgnoreCase))
        {
            return;
        }
        foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            var rel = Path.GetRelativePath(root, file);
            var target = Path.Combine(staging, rel);
            if (string.Equals(Path.GetFullPath(file), Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target, overwrite: true);
        }
        var nested = root;
        while (true)
        {
            var parent = Path.GetDirectoryName(nested);
            if (string.IsNullOrEmpty(parent)
                || string.Equals(Path.GetFullPath(parent), Path.GetFullPath(staging), StringComparison.OrdinalIgnoreCase))
            {
                break;
            }
            nested = parent;
        }
        if (!string.Equals(Path.GetFullPath(nested), Path.GetFullPath(staging), StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                Directory.Delete(nested, recursive: true);
            }
            catch
            {
                // Extra nested copy is waste, not a failed update.
            }
        }
    }

    /// <summary>
    /// Skip when the running binary has no Authenticode signer. That is a
    /// preview or a local build, and demanding a signature there would block
    /// every update with a message the user cannot act on.
    /// </summary>
    private static void VerifyPublisher(string currentExe, string candidate)
    {
        var currentPublisher = AuthenticodePublisher(currentExe);
        if (currentPublisher is null)
        {
            return;
        }
        if (candidate.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }
        var offered = AuthenticodePublisher(candidate);
        if (offered is null)
        {
            throw new Failure("The download is not signed, and the installed one is.");
        }
        if (!string.Equals(offered, currentPublisher, StringComparison.OrdinalIgnoreCase))
        {
            throw new Failure("The download was signed by somebody else.");
        }
    }

    public static string? AuthenticodePublisher(string path)
    {
        try
        {
            using var cert = X509Certificate.CreateFromSignedFile(path);
            var subject = cert.Subject;
            return string.IsNullOrWhiteSpace(subject) ? null : subject;
        }
        catch
        {
            return null;
        }
    }

    private static string CurrentExe()
    {
        var process = Environment.ProcessPath;
        if (!string.IsNullOrEmpty(process) && File.Exists(process))
        {
            return process;
        }
        return Path.Combine(AppContext.BaseDirectory, "Tokenstat.exe");
    }

    private static string Escape(string value) => value.Replace("'", "''");
}
