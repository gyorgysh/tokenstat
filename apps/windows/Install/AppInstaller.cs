// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using System.Text.Json.Nodes;
using Tokenstat.Design;

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
/// A checksum alone trusts whoever wrote the release. Extracting a signing
/// certificate alone does not validate the executable's bytes. If any check fails,
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
            throw new Failure(L10n.Text("windows.appinstaller.the_download_is_missing.9c5859b5"));
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
        try
        {
            ZipFile.ExtractToDirectory(zipPath, staging, overwriteFiles: true);
            FlattenExtractedTree(staging);
            // An archive must not supply its own successful-verification marker.
            File.Delete(Path.Combine(staging, "PENDING-UPDATE.txt"));
            var stagedExe = Path.Combine(staging, "Tokenstat.exe");
            if (!File.Exists(stagedExe) || !File.Exists(Path.Combine(staging, "tokenstat-hostd.exe")))
            {
                throw new Failure(L10n.Text("windows.appinstaller.the_download_did_not_contain_the_complete.484b8f83"));
            }
            // A stale host can hand back an older release than this app. Staging
            // it would turn the next restart into a downgrade.
            var staged = VersionOf(stagedExe);
            if (staged is null || CompareVersions(staged, AppInfo.Version) <= 0)
            {
                throw new Failure(L10n.Text("windows.appinstaller.the_download_is_not_newer.5b1e0c2a", staged ?? "?", AppInfo.Version));
            }
            VerifyPublisher(CurrentExe(), stagedExe);
            WritePending(dest, staging);
        }
        catch
        {
            try { Directory.Delete(staging, recursive: true); } catch { /* Preserve the original failure. */ }
            throw;
        }
        finally
        {
            DeleteDownload(zipPath);
        }
    }

    /// <summary>
    /// The zip is about 100 MB and is never read again once extracted or
    /// refused: a retry downloads afresh. Its folder goes too when it is the
    /// host's own per-download temp folder.
    /// </summary>
    private static void DeleteDownload(string zipPath)
    {
        try
        {
            File.Delete(zipPath);
            var folder = Path.GetDirectoryName(zipPath);
            if (folder is not null
                && Path.GetFileName(folder).StartsWith("tokenstat-update-", StringComparison.Ordinal)
                && !Directory.EnumerateFileSystemEntries(folder).Any())
            {
                Directory.Delete(folder);
            }
        }
        catch
        {
            // Temp files are the system's to sweep if this cannot.
        }
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

    public static bool StagingReady => IsStagingReady(StagingDirectory);

    /// <summary>
    /// The version already verified and waiting beside the install, when it is
    /// newer than this app. A staged folder that is not newer is leftover from
    /// an earlier cycle and is removed, so a restart can never downgrade.
    /// </summary>
    public static string? ReadyStagedVersion()
    {
        var staging = StagingDirectory;
        if (!IsStagingReady(staging))
        {
            return null;
        }
        var version = VersionOf(Path.Combine(staging, "Tokenstat.exe"));
        if (version is not null && CompareVersions(version, AppInfo.Version) > 0)
        {
            return version;
        }
        try { Directory.Delete(staging, recursive: true); } catch { /* Retried on the next check. */ }
        return null;
    }

    private static bool IsStagingReady(string staging) =>
        File.Exists(Path.Combine(staging, "Tokenstat.exe"))
        && File.Exists(Path.Combine(staging, "tokenstat-hostd.exe"))
        && File.Exists(Path.Combine(staging, "PENDING-UPDATE.txt"));

    /// <summary>The release version stamped into an app executable, without build metadata.</summary>
    internal static string? VersionOf(string exe)
    {
        try
        {
            var product = FileVersionInfo.GetVersionInfo(exe).ProductVersion;
            var version = product?.Split('+')[0].Trim();
            return string.IsNullOrEmpty(version) ? null : version;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Semantic version order: numeric major.minor.patch, then a release sorts
    /// above any prerelease of the same numbers. Build metadata is ignored.
    /// </summary>
    internal static int CompareVersions(string left, string right)
    {
        static (int[] numbers, string? pre) Parse(string value)
        {
            var core = value.Trim().TrimStart('v', 'V').Split('+')[0];
            var dash = core.IndexOf('-');
            var pre = dash >= 0 ? core[(dash + 1)..] : null;
            var parts = (dash >= 0 ? core[..dash] : core).Split('.');
            var numbers = new int[3];
            for (var i = 0; i < 3 && i < parts.Length; i++)
            {
                _ = int.TryParse(parts[i], out numbers[i]);
            }
            return (numbers, pre);
        }
        var (a, aPre) = Parse(left);
        var (b, bPre) = Parse(right);
        for (var i = 0; i < 3; i++)
        {
            if (a[i] != b[i]) return a[i].CompareTo(b[i]);
        }
        if (aPre is null) return bPre is null ? 0 : 1;
        if (bPre is null) return -1;
        var aIds = aPre.Split('.');
        var bIds = bPre.Split('.');
        for (var i = 0; i < Math.Min(aIds.Length, bIds.Length); i++)
        {
            var aNumeric = long.TryParse(aIds[i], out var aNumber);
            var bNumeric = long.TryParse(bIds[i], out var bNumber);
            var order = (aNumeric, bNumeric) switch
            {
                (true, true) => aNumber.CompareTo(bNumber),
                (true, false) => -1,
                (false, true) => 1,
                _ => string.CompareOrdinal(aIds[i], bIds[i]),
            };
            if (order != 0) return order;
        }
        return aIds.Length.CompareTo(bIds.Length);
    }

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
        if (!IsStagingReady(staging))
        {
            RestartCurrent();
            return;
        }
        var helper = Path.Combine(Path.GetTempPath(), $"tokenstat-apply-update-{Guid.NewGuid():N}.ps1");
        var exe = Path.Combine(dest, "Tokenstat.exe");
        var log = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "logs", "update.log");
        // A folder cannot be renamed while anything holds a file inside it.
        // The scheduled task can restart hostd from the old folder mid-swap,
        // and WebView2 browser processes outlive the app by a moment (older
        // builds kept their profile inside the install folder). So the swap
        // stops whatever still runs from either folder and retries for a
        // while, rather than giving up on the first sharing violation and
        // relaunching the old version.
        var script = string.Join(Environment.NewLine, new[]
        {
            $"$dest = '{Escape(dest.TrimEnd('\\'))}'",
            $"$staging = '{Escape(staging)}'",
            $"$prev = '{Escape(dest.TrimEnd('\\') + ".prev")}'",
            $"$exe = '{Escape(exe)}'",
            $"$log = '{Escape(log)}'",
            // $pid is powershell's own id, so the parent travels as $waitPid.
            $"$waitPid = {Environment.ProcessId}",
            "function Log($message) { try { Add-Content -LiteralPath $log -Value ((Get-Date).ToString('o') + ' ' + $message) } catch { } }",
            "function Stop-Stragglers {",
            "  $roots = @($dest + '\\', $prev + '\\')",
            "  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {",
            "    $p = $_",
            "    $roots | Where-Object {",
            "      ($p.ExecutablePath -and $p.ExecutablePath.StartsWith($_, [StringComparison]::OrdinalIgnoreCase)) -or",
            "      ($p.Name -eq 'msedgewebview2.exe' -and $p.CommandLine -and $p.CommandLine.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0)",
            "    }",
            "  } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }",
            "}",
            "$deadline = (Get-Date).AddSeconds(30)",
            "while (Get-Process -Id $waitPid -ErrorAction SilentlyContinue) {",
            "  if ((Get-Date) -gt $deadline) { Log 'app did not exit; update not applied'; exit 1 }",
            "  Start-Sleep -Milliseconds 200",
            "}",
            "Log ('applying ' + $staging)",
            "$moved = $false",
            "$deadline = (Get-Date).AddSeconds(30)",
            "while ($true) {",
            "  Stop-Stragglers",
            "  try {",
            "    if (Test-Path -LiteralPath $prev) { Remove-Item -LiteralPath $prev -Recurse -Force -ErrorAction Stop }",
            "    if (Test-Path -LiteralPath $dest) { Rename-Item -LiteralPath $dest -NewName (Split-Path $prev -Leaf) -ErrorAction Stop }",
            "    $moved = $true",
            "    break",
            "  } catch {",
            "    Log ('old folder busy: ' + $_.Exception.Message)",
            "    if ((Get-Date) -gt $deadline) { break }",
            "    Start-Sleep -Milliseconds 500",
            "  }",
            "}",
            "if ($moved) {",
            "  try {",
            "    Rename-Item -LiteralPath $staging -NewName (Split-Path $dest -Leaf) -ErrorAction Stop",
            "  } catch {",
            "    Log ('could not move the new version in: ' + $_.Exception.Message)",
            "    $moved = $false",
            "    if ((Test-Path -LiteralPath $prev) -and -not (Test-Path -LiteralPath $dest)) {",
            "      Rename-Item -LiteralPath $prev -NewName (Split-Path $dest -Leaf) -ErrorAction SilentlyContinue",
            "    }",
            "  }",
            "}",
            "if ($moved) { Log 'update applied' } else { Log 'update not applied; restarting the installed version' }",
            "if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe -WorkingDirectory $dest }",
            // Older builds kept the browser profile inside the install folder.
            // Carry it out before the old folder goes, so an update does not
            // sign anybody out of the sites they use in the app.
            $"$profile = '{Escape(Tokenstat.Pages.WebViewProfile.Folder)}'",
            "$legacy = Join-Path $prev 'Tokenstat.exe.WebView2'",
            "if ($moved -and (Test-Path -LiteralPath $legacy) -and -not (Test-Path -LiteralPath $profile)) {",
            "  try { Move-Item -LiteralPath $legacy -Destination $profile -ErrorAction Stop } catch { Log ('browser profile kept in place: ' + $_.Exception.Message) }",
            "}",
            "if ($moved -and (Test-Path -LiteralPath $prev)) { Remove-Item -LiteralPath $prev -Recurse -Force -ErrorAction SilentlyContinue }",
            "Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue",
        });
        File.WriteAllText(helper, script);
        SelfInstall.StopRelatedProcesses();
        using var helperProcess = Process.Start(new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{helper}\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            // Never the app's own working directory, which is the install
            // folder: a process whose current directory is inside a folder
            // keeps that folder from being renamed, so the helper would block
            // the very swap it exists to make.
            WorkingDirectory = Path.GetTempPath(),
        }) ?? throw new Failure(L10n.Text("windows.appinstaller.could_not_start_the_update_helper_please_t.e9b2275b"));
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
        if (!IsStagingReady(staging))
        {
            return;
        }
        var stagedExe = Path.Combine(staging, "Tokenstat.exe");
        // Never a downgrade: the staged version must be newer than the one
        // installed, the same rule the relaunch path applies.
        var installedVersion = VersionOf(Path.Combine(dest, "Tokenstat.exe"));
        var stagedVersion = VersionOf(stagedExe);
        if (stagedVersion is null
            || (installedVersion is not null && CompareVersions(stagedVersion, installedVersion) <= 0))
        {
            return;
        }
        VerifyPublisher(CurrentExe(), stagedExe);
        var prev = dest.TrimEnd('\\') + ".prev";
        if (Directory.Exists(prev))
        {
            try { Directory.Delete(prev, true); } catch { /* ignore */ }
        }
        // Same patience as the relaunch script: a helper the task scheduler
        // restarts, or a browser process still closing, can hold the folder
        // for a moment.
        var moved = false;
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (!moved)
        {
            SelfInstall.StopRelatedProcesses();
            try
            {
                if (Directory.Exists(dest))
                {
                    Directory.Move(dest, prev);
                }
                moved = true;
            }
            catch (IOException) when (DateTime.UtcNow < deadline)
            {
                Thread.Sleep(500);
            }
            catch
            {
                return;
            }
        }
        try
        {
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
            throw new Failure(L10n.Text("windows.appinstaller.the_download_is_not_signed_and_the_install.28926973"));
        }
        if (!string.Equals(offered, currentPublisher, StringComparison.OrdinalIgnoreCase))
        {
            throw new Failure(L10n.Text("windows.appinstaller.the_download_was_signed_by_somebody_else.976f71f6"));
        }
    }

    /// <summary>
    /// Validate Authenticode before trusting its publisher. Reading a signing
    /// certificate alone does not verify the executable's digest. Only a truly
    /// unsigned local build may skip the publisher check; invalid signatures
    /// and verification failures must fail closed.
    /// </summary>
    public static string? AuthenticodePublisher(string path)
    {
        var command = "$ErrorActionPreference = 'Stop'; [Console]::OutputEncoding = [Text.Encoding]::UTF8; "
            + "$s = Get-AuthenticodeSignature -LiteralPath '" + Escape(path) + "'; "
            + "@{ status = [string]$s.Status; subject = $s.SignerCertificate.Subject } | ConvertTo-Json -Compress";
        using var process = Process.Start(new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -NonInteractive -EncodedCommand "
                + Convert.ToBase64String(Encoding.Unicode.GetBytes(command)),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            StandardOutputEncoding = Encoding.UTF8,
            RedirectStandardError = true,
        }) ?? throw new Failure(L10n.Text("windows.appinstaller.could_not_verify_the_update_signature.b4c48a1c"));
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(30000))
        {
            try { process.Kill(entireProcessTree: true); } catch { /* Already exited. */ }
            throw new Failure(L10n.Text("windows.appinstaller.signature_verification_timed_out_please_tr.a59201e9"));
        }
        if (process.ExitCode != 0)
        {
            throw new Failure(L10n.Text("windows.appinstaller.could_not_verify_the_update_signature_plea.7cfc799a"));
        }
        return ReadVerifiedPublisher(output.GetAwaiter().GetResult());
    }

    internal static string? ReadVerifiedPublisher(string json)
    {
        var result = JsonNode.Parse(json);
        var status = result?["status"]?.GetValue<string>();
        if (status == "NotSigned")
        {
            return null;
        }
        var subject = result?["subject"]?.GetValue<string>();
        if (status != "Valid" || string.IsNullOrWhiteSpace(subject))
        {
            throw new Failure(L10n.Text("windows.appinstaller.the_app_signature_could_not_be_verified_do.75facb06"));
        }
        return subject;
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
