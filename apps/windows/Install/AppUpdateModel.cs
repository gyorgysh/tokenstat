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
    public static readonly string UpToDateMessage = L10n.Text("windows.appupdatemodel.you_are_on_the_latest_version.eeced728");

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
            CheckNotice = L10n.Text("windows.appupdatemodel.update_installed_relaunch_to_finish.d191ced5");
        }
        else if (Failure is not null)
        {
            CheckNotice = Failure;
        }
        else if (IsAvailable && Latest != before)
        {
            CheckNotice = L10n.Text("windows.appupdatemodel.version_0_found.a4c4e509", $"{Latest}");
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
                });
            if (OptLong(found, "retryAt") is long at && at > 0)
            {
                var date = DateTimeOffset.FromUnixTimeSeconds(at);
                RetryAfter = date;
                Current = Stage.Failed;
                Failure = L10n.Text("windows.appupdatemodel.github_is_limiting_update_checks_you_can_t.01b98ce8", $"{date.ToLocalTime():t}");
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
            // A -dev. zip is an Actions artifact, never an update.
            if (Newer && !ChannelAccepts(SelfInstall.IsPreviewChannel, Latest))
            {
                Newer = false;
            }
            // The host reports the older of itself and this app. The zip
            // replaces both, but only a release newer than this app is worth
            // fetching: an outdated helper still holding the pipe would
            // otherwise make an up-to-date app download itself forever.
            if (Newer && AppInstaller.CompareVersions(Latest, AppInfo.Version) <= 0)
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

        // Already downloaded, verified, and waiting from an earlier check or an
        // earlier launch: offer the restart instead of fetching it again.
        if (await Task.Run(AppInstaller.ReadyStagedVersion) is string staged
            && AppInstaller.CompareVersions(staged, Latest) >= 0)
        {
            Current = Stage.ReadyToRelaunch;
            Changed?.Invoke();
            return;
        }

        Current = Stage.Downloading;
        Changed?.Invoke();
        try
        {
            var downloaded = await AppServices.Host.CallAsync(
                "app.updateDownloadWin",
                new JsonObject(),
                patience: TimeSpan.FromMinutes(5));
            var path = Str(downloaded, "path")
                ?? throw new AppInstaller.Failure(L10n.Text("windows.appupdatemodel.the_host_did_not_return_a_download_path.f4dcb739"));
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

    /// <summary>
    /// Restart to update. When work is still running, <paramref name="confirm"/>
    /// is asked first: the swap stops the helper that owns those sessions,
    /// and that is the person's call. A null confirm means nobody is there
    /// to ask, so the restart proceeds. When the swap cannot start, the
    /// failure lands on the card rather than leaving a button that does nothing.
    /// </summary>
    public async Task RelaunchAsync(Func<long, Task<bool>>? confirm = null)
    {
        long live = 0;
        try
        {
            var answer = await AppServices.Host.CallAsync("host.liveWork", null, TimeSpan.FromSeconds(3));
            live = OptLong(answer, "liveWork") ?? 0;
        }
        catch
        {
            // An older helper without the method, or none at all: nothing to ask about.
        }
        if (live > 0 && confirm is not null && !await confirm(live))
        {
            return;
        }
        Relaunch();
    }

    public void Relaunch()
    {
        try
        {
            AppInstaller.Relaunch();
        }
        catch (Exception ex)
        {
            Current = Stage.Failed;
            Failure = ex.Message;
            FailureDismissed = false;
            Changed?.Invoke();
        }
    }

    /// <summary>
    /// A <c>-dev.</c> zip is an Actions artifact, never an update. Both
    /// official installs and unsigned Actions builds read the latest GitHub
    /// Release, so a leftover Preview feed cannot land on anyone.
    /// </summary>
    internal static bool ChannelAccepts(bool previewInstall, string latest)
    {
        if (string.IsNullOrEmpty(latest)) return false;
        _ = previewInstall;
        return !latest.Contains("-dev.", StringComparison.Ordinal);
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
