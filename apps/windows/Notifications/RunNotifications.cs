// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Tokenstat.Pages;
using Windows.Storage;

namespace Tokenstat.Notifications;

/// <summary>
/// Local toasts for agent runs that ended on this computer. Mirrors the Mac
/// RunNotifications: fed from the same run lists the pages already read, so
/// there is no second source of truth, and only transitions are reported, and
/// only after the first read, so a launch that finds finished runs from last
/// night posts nothing.
/// </summary>
/// <remarks>
/// Fixed titles only, and the body names the run the way the list already
/// does. Folder paths, prompts, commands, and anything else from the work
/// itself are never composed into a notification, local or otherwise: the
/// push reason rule (a reason from a fixed list and a machine id, never
/// content) holds here by keeping content out entirely. Toasts stay on this
/// machine and need no account and no network.
/// <para/>
/// Off until asked for. A permission prompt on first launch, for a feature
/// nobody has asked for yet, is the reason people say no forever.
/// </remarks>
internal sealed class RunNotifications
{
    public static RunNotifications Shared { get; } = new();

    private const string OnKey = "notifications.runsFinished";
    private const string Group = "runs";

    private enum Feed
    {
        Automations,
        Workflows,
    }

    /// <summary>Run id to the status it last had, per feed. The whole state this needs.</summary>
    private readonly Dictionary<Feed, Dictionary<string, string>> _lastStatus = new();

    /// <summary>Feeds read once. Before that, everything is history.</summary>
    private readonly HashSet<Feed> _primed = new();

    private bool _registered;

    private RunNotifications()
    {
    }

    /// <summary>Off until asked for. Persisted locally, never synced.</summary>
    public bool IsOn
    {
        get => ApplicationData.Current.LocalSettings.Values[OnKey] as bool? ?? false;
        set
        {
            ApplicationData.Current.LocalSettings.Values[OnKey] = value;
            if (value)
            {
                EnsureRegistered();
            }
        }
    }

    /// <summary>
    /// Declare the toast capability. Called at launch when the switch is on
    /// and when the switch turns on, so an unpackaged Show has somewhere to go.
    /// </summary>
    public void EnsureRegistered()
    {
        if (_registered || !IsOn)
        {
            return;
        }
        try
        {
            AppNotificationManager.Default.Register();
            _registered = true;
        }
        catch
        {
            // A toast that cannot register is quiet, not fatal. The run list
            // on screen still says what happened.
        }
    }

    /// <summary>
    /// Agent runs, as of this refresh. Steps stay quiet: a workflow node
    /// starts an ordinary automation run, and machinery under something the
    /// person started does not report to them. The workflow speaks for its
    /// own steps.
    /// </summary>
    public void SettleAutomations(JsonArray runs)
    {
        var top = new JsonArray();
        foreach (var run in runs)
        {
            if (!string.IsNullOrEmpty(Format.Text(run, "id"))
                && string.IsNullOrEmpty(Format.Text(run, "parentRunId")))
            {
                top.Add(run?.DeepClone());
            }
        }
        Settle(top, Feed.Automations, workflows: false);
    }

    /// <summary>
    /// Workflow runs, as of this refresh. A workflow that is waiting has hit
    /// a gate, which is a person's turn and worth saying so.
    /// </summary>
    public void SettleWorkflows(JsonArray runs) => Settle(runs, Feed.Workflows, workflows: true);

    private void Settle(JsonArray runs, Feed feed, bool workflows)
    {
        if (!_lastStatus.TryGetValue(feed, out var before))
        {
            before = new Dictionary<string, string>();
        }
        var current = new Dictionary<string, string>();
        foreach (var run in runs)
        {
            var id = Format.Text(run, "id");
            if (string.IsNullOrEmpty(id))
            {
                continue;
            }
            current[id] = Format.Text(run, "status");
        }
        var primed = _primed.Contains(feed);
        _lastStatus[feed] = current;
        _primed.Add(feed);
        if (!IsOn || !primed)
        {
            return;
        }
        foreach (var run in runs)
        {
            var id = Format.Text(run, "id");
            if (string.IsNullOrEmpty(id)
                || !before.TryGetValue(id, out var previous)
                || previous == current[id])
            {
                continue;
            }
            // Only a live run can produce news. A record rewritten by a
            // reconcile is not something that just happened.
            if (previous != "running" && previous != "queued")
            {
                continue;
            }
            var name = Format.Text(run, "name", "Run");
            switch (current[id])
            {
                case "ok":
                    Post(id, "Run finished", $"{name} is done.");
                    break;
                case "error":
                    Post(id, "Run failed", $"{name} did not finish cleanly{ExitCode(run)}.");
                    break;
                case "waiting" when workflows:
                    Post(id, "Waiting for you", $"{name} needs an answer to carry on.");
                    break;
                default:
                    // Stopped is somebody at this keyboard. They know.
                    break;
            }
        }
    }

    private static string ExitCode(JsonNode? run)
    {
        var code = run?["exitCode"];
        if (code is null || code.GetValueKind() is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            return "";
        }
        return $" (exit {Format.Long(run, "exitCode")})";
    }

    /// <summary>
    /// The settings button. Posts through the same path a real run would, so
    /// a test that arrives proves the real one will.
    /// </summary>
    public void SendTest()
    {
        EnsureRegistered();
        Post("test", "Notifications are on", "This is the only test notification.");
    }

    private static void Post(string runId, string title, string body)
    {
        try
        {
            var notification = new AppNotificationBuilder()
                .AddText(title)
                .AddText(body)
                .SetTag("run." + runId)
                .SetGroup(Group)
                .BuildNotification();
            AppNotificationManager.Default.Show(notification);
        }
        catch
        {
            // A toast must never break the refresh that noticed the news.
        }
    }
}
