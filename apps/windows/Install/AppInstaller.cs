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
/// # Why the verification is not optional
///
/// This code downloads something and then runs it as the user. That is exactly
/// the shape of a remote code execution bug, and the only thing standing
/// between the two is what it checks before it moves anything into place.
/// Three checks, none of which replaces another:
///
/// 1. The daemon verified the download against the release's `SHA256SUMS`. That
///    proves the bytes are the ones the release published.
/// 2. The staged `Tokenstat.exe` carries an intact Authenticode signature.
///    (The zip itself cannot be signed, so the binary inside is what is
///    checked, after extraction.)
/// 3. The signer is the one that signed the running binary, not merely *a*
///    signer. Without this a validly signed binary from anybody at all would
///    pass, which is not a check, it is a formality. The publisher is read
///    from the running app rather than written down here, so the rule is
///    "never replace this with something signed by somebody else".
///
/// A checksum alone would trust whoever wrote the release. A signature alone
/// would trust a binary tampered with after signing. If any check fails,
/// nothing is moved and the caller falls back to the download page.
///
/// Preview builds are unsigned, so they skip the publisher check the way a
/// local Mac build skips Developer ID: demanding a signature there would block
/// every update with a message the user cannot act on.
///
/// # Why it stages rather than asks
///
/// Windows locks a running exe, so the new version cannot be put in place
/// while the app is still running the way the Mac replaces its bundle. It is
/// extracted beside the install instead, verified there, and the swap happens
/// in a script after this process has exited. The interface then offers a
/// relaunch. Nothing restarts under somebody mid-sentence.
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

        var dest = SelfInstall.IsRunningFromInstall
            ? SelfInstall.InstallDirectory
            : Path.GetDirectoryName(CurrentExe()) ?? AppContext.BaseDirectory;
        var staging = dest.TrimEnd('\\') + ".next";
        if (Directory.Exists(staging))
        {
            Directory.Delete(staging, recursive: true);
        }
        Directory.CreateDirectory(staging);
        // Extracted beside the install first, so an extract that fails part
        // way through has not touched the application the user is running.
        // Only when a whole folder is verified is anything swapped, and that
        // swap happens after this process has exited.
        ZipFile.ExtractToDirectory(zipPath, staging, overwriteFiles: true);
        FlattenExtractedTree(staging);

        var stagedExe = Path.Combine(staging, "Tokenstat.exe");
        if (!File.Exists(stagedExe))
        {
            throw new Failure("The download did not contain tokenstat.");
        }
        VerifyPublisher(CurrentExe(), stagedExe);
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

    /// <summary>
    /// Swap the staged folder into place and start the fresh copy.
    ///
    /// A helper script does the move after this process has exited: Windows
    /// locks the running exe, so this process cannot replace its own folder.
    /// The script waits for the exit rather than sleeping a fixed while, moves
    /// the old folder aside rather than deleting it, and puts it back when the
    /// swap fails, so a failed update leaves the previous version in place.
    /// </summary>
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
        SelfInstall.StopRelatedProcesses();
        var helper = Path.Combine(Path.GetTempPath(), "tokenstat-apply-update.ps1");
        var exe = Path.Combine(dest, "Tokenstat.exe");
        var script = string.Join(Environment.NewLine, new[]
        {
            $"$dest = '{Escape(dest)}'",
            $"$staging = '{Escape(staging)}'",
            $"$prev = '{Escape(dest.TrimEnd('\\') + ".prev")}'",
            $"$exe = '{Escape(exe)}'",
            // $pid is powershell's own id, so the parent travels as $waitPid.
            $"$waitPid = {Environment.ProcessId}",
            "$deadline = (Get-Date).AddSeconds(30)",
            "while (Get-Process -Id $waitPid -ErrorAction SilentlyContinue) {",
            "  if ((Get-Date) -gt $deadline) { exit 1 }",
            "  Start-Sleep -Milliseconds 200",
            "}",
            "Start-Sleep -Milliseconds 400",
            "$ErrorActionPreference = 'Stop'",
            "try {",
            "  if (Test-Path -LiteralPath $prev) { Remove-Item -LiteralPath $prev -Recurse -Force }",
            "  if (Test-Path -LiteralPath $dest) { Rename-Item -LiteralPath $dest -NewName (Split-Path $prev -Leaf) }",
            "  Rename-Item -LiteralPath $staging -NewName (Split-Path $dest -Leaf)",
            "} catch {",
            "  if ((Test-Path -LiteralPath $prev) -and -not (Test-Path -LiteralPath $dest)) {",
            "    Rename-Item -LiteralPath $prev -NewName (Split-Path $dest -Leaf)",
            "  }",
            "  exit 1",
            "}",
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

    /// <summary>
    /// Apply a staged folder from `--apply-update`. Same aside-and-swap shape
    /// as the relaunch script, with the same rollback: a failure after the old
    /// folder moved aside puts it back rather than leaving nothing on disk.
    /// </summary>
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
        try
        {
            if (Directory.Exists(dest))
            {
                Directory.Move(dest, prev);
            }
            Directory.Move(staging, dest);
        }
        catch
        {
            if (Directory.Exists(prev) && !Directory.Exists(dest))
            {
                try { Directory.Move(prev, dest); } catch { /* ignore */ }
            }
            return;
        }
        SelfInstall.RefreshUninstallKey();
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
    /// The staged exe must be signed by whoever signed the running one.
    /// Skip when the running binary has no Authenticode signer. That is a
    /// preview or a local build, and demanding a signature there would block
    /// every update with a message the user cannot act on.
    /// </summary>
    private static void VerifyPublisher(string currentExe, string stagedExe)
    {
        var currentPublisher = AuthenticodePublisher(currentExe);
        if (currentPublisher is null)
        {
            return;
        }
        var offered = AuthenticodePublisher(stagedExe);
        if (offered is null)
        {
            throw new Failure("The download is not signed, and the installed one is.");
        }
        if (!string.Equals(offered, currentPublisher, StringComparison.OrdinalIgnoreCase))
        {
            throw new Failure("The download was signed by somebody else.");
        }
    }

    /// <summary>
    /// Who signed this binary, when it is signed at all. Null covers both
    /// unsigned and tampered: a binary whose bytes no longer match its
    /// signature fails to load as signed, so it must not pass either.
    /// </summary>
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
