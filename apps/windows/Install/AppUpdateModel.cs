// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Tokenstat.Design;

namespace Tokenstat.Install;

internal sealed class AppUpdateModel
{
    public const string UpToDateMessage = "You are on the latest version.";

    public enum Stage
    {
        Idle,
        Checking,
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

    public bool IsAvailable => Newer;
    public bool IsReady => Current == Stage.ReadyToRelaunch;
    public bool IsChecking => Current is Stage.Checking or Stage.Installing;

    public event Action? Changed;

    public async Task CheckNowAsync()
    {
        if (IsChecking)
        {
            return;
        }
        CheckNotice = null;
        Current = Stage.Idle;
        await CheckAndInstallAsync();
        CheckNotice = IsReady
            ? "Update installed. Relaunch to finish."
            : Failure ?? (IsAvailable ? $"Version {Latest} found." : UpToDateMessage);
        Changed?.Invoke();
        _ = ClearNoticeLater();
    }

    public async Task CheckAndInstallAsync()
    {
        if (Current is not Stage.Idle && Current is not Stage.Failed)
        {
            return;
        }
        Current = Stage.Checking;
        Failure = null;
        Changed?.Invoke();
        try
        {
            var found = await AppServices.Host.CallAsync("app.updateCheck");
            CurrentVersion = AppInfo.Version;
            Latest = Str(found, "latest") ?? "";
            HtmlUrl = Str(found, "htmlUrl") ?? "";
            WinZipUrl = Str(found, "winZipUrl");
            Newer = found["newer"] is JsonValue flag && flag.GetValue<bool>();
            if (!Newer || string.IsNullOrEmpty(Latest))
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

        Current = Stage.Installing;
        Changed?.Invoke();
        try
        {
            var downloaded = await AppServices.Host.CallAsync(
                "app.updateDownloadWin",
                patience: TimeSpan.FromMinutes(5));
            var path = Str(downloaded, "path")
                ?? throw new AppInstaller.Failure("The host did not return a download path.");
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
        if (Current != Stage.Failed || IsChecking || IsRetrying)
        {
            return;
        }
        IsRetrying = true;
        Changed?.Invoke();
        try
        {
            Current = Stage.Idle;
            await CheckAndInstallAsync();
        }
        finally
        {
            IsRetrying = false;
            Changed?.Invoke();
        }
    }

    public void Relaunch() => AppInstaller.Relaunch();

    private static string? Str(JsonNode node, string name)
    {
        var value = node[name];
        if (value is null || value.GetValueKind() == System.Text.Json.JsonValueKind.Null)
        {
            return null;
        }
        return value.GetValue<string>();
    }

    private async Task ClearNoticeLater()
    {
        await Task.Delay(TimeSpan.FromSeconds(6));
        CheckNotice = null;
        Changed?.Invoke();
    }
}
