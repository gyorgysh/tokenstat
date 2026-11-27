// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Tokenstat.Design;

namespace Tokenstat.Install;

internal sealed class AppUpdateModel
{
    public static readonly string UpToDateMessage = L10n.Text("windows.appupdatemodel.you_are_on_the_latest_version.eeced728");

    public enum Stage
    {
        Idle,
        Checking,
        Downloading,
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

    public void DismissFailure()
    {
        FailureDismissed = true;
        CheckNotice = null;
        Changed?.Invoke();
    }

    public event Action? Changed;

    private int _noticeGeneration;
    private int _checkInProgress;

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
            CurrentVersion = Str(found, "current") ?? AppInfo.Version;
            Latest = Str(found, "latest") ?? "";
            HtmlUrl = Str(found, "htmlUrl") ?? "";
            WinZipUrl = Str(found, "winZipUrl");
            Newer = found["newer"] is JsonValue flag && flag.GetValue<bool>();
            if (Newer && !ChannelAccepts(SelfInstall.IsPreviewChannel, Latest))
            {
                Newer = false;
            }
            if (Newer && AppInstaller.CompareVersions(Latest, AppInfo.Version) <= 0)
            {
                Newer = false;
            }
            if (!Newer || string.IsNullOrEmpty(Latest) || IsSkipped)
            {
                Current = Stage.Idle;
                Changed?.Invoke();
                return;
            }
        }
        catch (Exception ex)
        {
            Current = Stage.Failed;
            Failure = ex.Message;
            Changed?.Invoke();
            return;
        }

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
