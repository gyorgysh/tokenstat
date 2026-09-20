// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Tokenstat.Design;

namespace Tokenstat.Install;

/// <summary>
/// Finding a new version, fetching it, and putting it in place.
///
/// The whole thing happens without being asked, and then stops. Downloading
/// and verifying is work nobody wants to watch, so it runs quietly.
/// Restarting is not: an application that relaunches itself under somebody
/// who is halfway through a sentence has taken a decision that was not its
/// to take. So the last step is a button, and the account page carries it
/// until it is pressed. Mirrors the Mac model stage for stage.
/// </summary>
internal sealed class AppUpdateModel
{
    public const string UpToDateMessage = "You are on the latest version.";

    public enum Stage
    {
        Idle,
        Checking,
        /// <summary>Fetching the zip. The host checks its checksum.</summary>
        Downloading,
        /// <summary>Verifying the staged app and putting it in place.</summary>
        Installing,
        ReadyToRelaunch,
        Failed,
    }

    public Stage Current { get; private set; } = Stage.Idle;
    public string Latest { get; private set; } = "";
    public string CurrentVersion { get; private set; } = AppInfo.Version;
    public string HtmlUrl { get; private set; } = "";
    public string? WinZipUrl { get; private set; }
    public string? Failure { get; private set; }
    public string? CheckNotice { get; private set; }
    public bool IsRetrying { get; private set; }
    public bool Newer { get; private set; }
    public DateTimeOffset? RetryAfter { get; private set; }
    public bool FailureDismissed { get; private set; }

    public bool IsAvailable => Newer;
    public bool IsReady => Current == Stage.ReadyToRelaunch;

    public bool IsChecking => Current is Stage.Checking or Stage.Downloading or Stage.Installing;

    public bool IsRateLimited => RetryAfter is not null && RetryAfter > DateTimeOffset.Now;

    /// <summary>Hide this notice without skipping a release or clearing the cooldown.</summary>
    public void DismissFailure()
    {
        FailureDismissed = true;
        CheckNotice = null;
        Changed?.Invoke();
    }

    public event Action? Changed;

    private int _noticeGeneration;
    private int _checkInProgress;

    /// <summary>
    /// Check because a person asked. Separate from the quiet check only in
    /// that it forgets the skipped version first: pressing Check means now.
    /// A check somebody pressed says what happened and then goes away, or the
    /// button reads as broken.
    /// </summary>
    public async Task CheckNowAsync()
    {
        if (IsChecking || IsReady)
        {
            return;
        }
        FailureDismissed = false;
        if (IsRateLimited)
        {
            return;
        }
        _noticeGeneration += 1;
        var generation = _noticeGeneration;
        CheckNotice = null;
        var before = Latest;
        ClearSkipped();
        if (!await TryCheckAndInstallAsync())
        {
            return;
        }

        if (IsReady)
        {
            CheckNotice = "Update installed. Relaunch to finish.";
        }
        else if (Failure is not null)
        {
            CheckNotice = Failure;
        }
        else if (IsAvailable && Latest != before)
        {
            CheckNotice = $"Version {Latest} found.";
        }
        else
        {
            CheckNotice = UpToDateMessage;
        }
        Changed?.Invoke();
        _ = ClearNoticeLater(generation);
    }

    /// <summary>
    /// Check, and install what is found. Failure is quiet in the sense that it
    /// never interrupts, but it is not swallowed: the card offers the manual
    /// download instead, so an update that cannot be automated still reaches
    /// the user.
    /// </summary>
    public async Task CheckAndInstallAsync() => await TryCheckAndInstallAsync();

    private async Task<bool> TryCheckAndInstallAsync()
    {
        if (Interlocked.CompareExchange(ref _checkInProgress, 1, 0) != 0)
        {
            return false;
        }
        try
        {
            await CheckAndInstallCoreAsync();
            return true;
        }
        finally
        {
            Volatile.Write(ref _checkInProgress, 0);
        }
    }

    private async Task CheckAndInstallCoreAsync()
    {
        if (Current is not Stage.Idle && Current is not Stage.Failed)
        {
            return;
        }
        if (IsRateLimited)
        {
            return;
        }
        Current = Stage.Checking;
        Failure = null;
        RetryAfter = null;
        FailureDismissed = false;
        Changed?.Invoke();
        try
        {
            var found = await AppServices.Host.CallAsync(
                "app.updateCheck",
                new JsonObject
                {
                    ["appVersion"] = AppInfo.Version,
                    ["supportsRetryAfter"] = true,
                    ["preview"] = SelfInstall.IsPreviewChannel,
                });
            if (OptLong(found, "retryAt") is long at && at > 0)
            {
                var date = DateTimeOffset.FromUnixTimeSeconds(at);
                RetryAfter = date;
                Current = Stage.Failed;
                Failure = $"GitHub is limiting update checks. You can try again after {date.ToLocalTime():t}.";
                Changed?.Invoke();
                return;
            }
            // Host returns the older of app and hostd as `current`, so a tip
            // hostd cannot hide an older app (or the reverse).
            CurrentVersion = Str(found, "current") ?? AppInfo.Version;
            Latest = Str(found, "latest") ?? "";
            HtmlUrl = Str(found, "htmlUrl") ?? "";
            WinZipUrl = Str(found, "winZipUrl");
            Newer = found["newer"] is JsonValue flag && flag.GetValue<bool>();
            // Preview stays on Preview. Stable never fetches a -dev. build.
            if (Newer && !ChannelAccepts(SelfInstall.IsPreviewChannel, Latest))
            {
                Newer = false;
            }
            // Compare the skip against the fresh release, so skipping one
            // version still lets automatic checks discover later versions.
            if (!Newer || string.IsNullOrEmpty(Latest) || IsSkipped)
            {
                Current = Stage.Idle;
                Changed?.Invoke();
                return;
            }
        }
        catch (Exception ex)
        {
            // A failed request cannot truthfully report "up to date".
            Current = Stage.Failed;
            Failure = ex.Message;
            Changed?.Invoke();
            return;
        }

        Current = Stage.Downloading;
        Changed?.Invoke();
        try
        {
            var downloaded = await AppServices.Host.CallAsync(
                "app.updateDownloadWin",
                new JsonObject { ["preview"] = SelfInstall.IsPreviewChannel },
                patience: TimeSpan.FromMinutes(5));
            var path = Str(downloaded, "path")
                ?? throw new AppInstaller.Failure("The host did not return a download path.");
            Current = Stage.Installing;
            Changed?.Invoke();
            await Task.Run(() => AppInstaller.Install(path));
            Current = Stage.ReadyToRelaunch;
        }
        catch (Exception ex)
        {
            Current = Stage.Failed;
            Failure = ex.Message;
        }
        Changed?.Invoke();
    }

    /// <summary>
    /// Try the automatic path again after a failure. The card shows progress
    /// and the button cannot be pressed twice. Failure keeps the card with
    /// both actions on it.
    /// </summary>
    public async Task RetryAsync()
    {
        if (Current != Stage.Failed || IsChecking || IsRetrying || IsRateLimited)
        {
            return;
        }
        IsRetrying = true;
        Changed?.Invoke();
        try
        {
            await CheckAndInstallAsync();
        }
        finally
        {
            IsRetrying = false;
            Changed?.Invoke();
        }
    }

    public void Relaunch() => AppInstaller.Relaunch();

    /// <summary>
    /// Preview installs only accept a <c>-dev.</c> latest. Stable installs
    /// never do. That is what stops an unsigned beta jumping onto a Release
    /// and a signed build fetching Preview bits.
    /// </summary>
    internal static bool ChannelAccepts(bool previewInstall, string latest)
    {
        if (string.IsNullOrEmpty(latest)) return false;
        var previewLatest = latest.Contains("-dev.", StringComparison.Ordinal);
        return previewInstall ? previewLatest : !previewLatest;
    }

    /// <summary>
    /// A release the user said they did not want to hear about again. Per
    /// version rather than a blanket stop: somebody skipping one version has
    /// not asked to be kept off the next. A plain file, not LocalSettings:
    /// this app is unpackaged, and ApplicationData.Current throws there.
    /// </summary>
    private static string SkippedPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "tokenstat",
        "update-skipped");

    public bool IsSkipped
    {
        get
        {
            if (string.IsNullOrEmpty(Latest))
            {
                return false;
            }
            try
            {
                return File.Exists(SkippedPath)
                    && File.ReadAllText(SkippedPath).Trim() == Latest;
            }
            catch
            {
                return false;
            }
        }
    }

    public void SkipThisVersion()
    {
        if (string.IsNullOrEmpty(Latest))
        {
            return;
        }
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(SkippedPath)!);
            File.WriteAllText(SkippedPath, Latest);
        }
        catch
        {
            // Skipping is a courtesy. The check still runs.
        }
        Current = Stage.Idle;
        Changed?.Invoke();
    }

    private static void ClearSkipped()
    {
        try
        {
            if (File.Exists(SkippedPath))
            {
                File.Delete(SkippedPath);
            }
        }
        catch
        {
            // A stale skip only hides one version from quiet checks.
        }
    }

    private static string? Str(JsonNode node, string name)
    {
        var value = node[name];
        if (value is null || value.GetValueKind() == System.Text.Json.JsonValueKind.Null)
        {
            return null;
        }
        return value.GetValue<string>();
    }

    /// <summary>An optional counter that may be absent. Absent is null, not zero.</summary>
    private static long? OptLong(JsonNode node, string name)
    {
        var value = node[name];
        if (value is null || value.GetValueKind() == System.Text.Json.JsonValueKind.Null)
        {
            return null;
        }
        try
        {
            return value.GetValue<long>();
        }
        catch
        {
            return null;
        }
    }

    private async Task ClearNoticeLater(int generation)
    {
        await Task.Delay(TimeSpan.FromSeconds(6));
        if (generation == _noticeGeneration)
        {
            CheckNotice = null;
            Changed?.Invoke();
        }
    }
}
