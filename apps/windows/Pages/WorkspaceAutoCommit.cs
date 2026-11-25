// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal static class WorkspaceAutoCommit
{
    private const string JobName = "Auto commit";
    private static readonly HashSet<(long Account, string Workspace)> Open = [];
    private sealed record PendingLaunch(string OperationId, string JobId);

    internal static async Task ShowAsync(UIElement owner, string workspace, string folderName)
    {
        var accountGeneration = AppServices.AccountGeneration;
        var lease = (accountGeneration, workspace);
        if (!Open.Add(lease)) return;
        bool Current() => owner.XamlRoot is not null && accountGeneration == AppServices.AccountGeneration;
        var remote = RemoteWorkspaces.TrySplit(workspace, out var peer, out var inner);
        var workspaceId = remote ? inner : workspace;
        Task<JsonNode> Call(string method, JsonObject? parameters = null)
        {
            if (!Current()) throw new OperationCanceledException();
            return remote ? RemoteWorkspaces.CallOnPeerAsync(peer, method, parameters) : AppServices.Host.CallAsync(method, parameters);
        }
        var title = L10n.Text("windows.autocommit.title");
        try
        {
            var protocol = RemoteFeatureGate.ProtocolOf(await Call("protocol"));
            if (!Current()) return;
            if (!WorkbenchOps.AutomationReceipts(protocol))
                throw new InvalidOperationException(L10n.Text("windows.autocommit.update_host"));
            var account = await AppServices.Host.CallAsync("account.status");
            if (!Current()) return;
            var signedIn = Format.Flag(account, "signedIn");
            var identity = signedIn ? Format.Text(account, "accountId", Format.Text(account, "handle")) : "local";
            if (identity.Length == 0) throw new InvalidOperationException(L10n.Text("windows.autocommit.account_unavailable"));
            var host = remote ? peer : Format.Text(await Call("machine.identity"), "key");
            if (!Current()) return;
            if (host.Length == 0) throw new InvalidOperationException(L10n.Text("windows.autocommit.account_unavailable"));
            var ownerKey = ChatOutbox.Key(Format.Text(account, "host") + ":" + identity, host, workspaceId);
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "tokenstat", "auto-commit", ownerKey + ".json");
            PendingLaunch? pending = null;
            if (File.Exists(path))
            {
                if (new FileInfo(path).Length > 4096) throw new InvalidDataException(L10n.Text("windows.autocommit.bad_pending"));
                pending = JsonSerializer.Deserialize<PendingLaunch>(File.ReadAllText(path));
                if (pending is null || string.IsNullOrWhiteSpace(pending.JobId) || string.IsNullOrWhiteSpace(pending.OperationId))
                    throw new InvalidDataException(L10n.Text("windows.autocommit.bad_pending"));
            }
            var backendList = Format.Items(await Call("automation.backends")) ?? new JsonArray();
            var backends = backendList.OfType<JsonObject>()
                .Where(backend => Format.Text(backend, "id") is not ("" or "sh") && backend["models"] is JsonArray { Count: > 0 }).ToArray();
            var backend = new ComboBox { Header = L10n.Text("windows.autocommit.agent"), HorizontalAlignment = HorizontalAlignment.Stretch,
                ItemsSource = backends.Select(item => Format.Text(item, "label", Format.Text(item, "id"))).ToArray() };
            var model = new ComboBox { Header = L10n.Text("windows.autocommit.model"), HorizontalAlignment = HorizontalAlignment.Stretch };
            var notice = new TextBlock { TextWrapping = TextWrapping.Wrap };
            var stack = new StackPanel { Spacing = Theme.SpaceM, Children =
            {
                new TextBlock { Text = folderName, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = L10n.Text("windows.autocommit.explanation"), TextWrapping = TextWrapping.Wrap },
                backend, model, notice,
            } };
            var dialog = new ContentDialog
            {
                Title = title, Content = stack, CloseButtonText = L10n.Text("common.close"), DefaultButton = ContentDialogButton.Close,
            };
            var check = new Button { Content = L10n.Text("windows.autocommit.check"), HorizontalAlignment = HorizontalAlignment.Left };
            stack.Children.Add(check);
            JsonObject? job = null;
            JsonNode? lastRun = null;
            var retry = false;
            var busy = false;
            var closed = false;
            var checkedStatus = false;
            void Render()
            {
                var running = WorkbenchOps.IsRunning(lastRun);
                backend.IsEnabled = model.IsEnabled = !busy && pending is null && !running;
                check.IsEnabled = !busy;
                dialog.PrimaryButtonText = pending is not null ? L10n.Text("windows.autocommit.retry") : L10n.Text("windows.autocommit.start");
                dialog.IsPrimaryButtonEnabled = !busy && checkedStatus && !running &&
                    (pending is not null ? retry : backend.SelectedIndex >= 0 && model.SelectedIndex >= 0);
            }
            backend.SelectionChanged += (_, _) =>
            {
                var models = backend.SelectedIndex >= 0 && backends[backend.SelectedIndex]["models"] is JsonArray values
                    ? values.OfType<JsonValue>().Select(value => value.ToString()).ToArray() : [];
                model.ItemsSource = models;
                var preferred = Array.IndexOf(models, Format.Text(job, "model"));
                if (preferred < 0) preferred = Array.IndexOf(models, "haiku");
                model.SelectedIndex = models.Length > 0 ? Math.Max(0, preferred) : -1;
                Render();
            };
            model.SelectionChanged += (_, _) => Render();
            async Task RefreshAsync()
            {
                var jobsTask = Call("automation.list");
                var runsTask = Call("automation.runs");
                await Task.WhenAll(jobsTask, runsTask);
                if (!Current()) return;
                var jobs = Format.Items(await jobsTask) ?? throw new InvalidDataException(L10n.Text("windows.autocommit.status_unavailable"));
                var runs = Format.Items(await runsTask) ?? throw new InvalidDataException(L10n.Text("windows.autocommit.status_unavailable"));
                job = jobs.OfType<JsonObject>().FirstOrDefault(item => Format.Text(item, "workspaceId") == workspaceId
                    && Format.Text(item, "name").Equals(JobName, StringComparison.OrdinalIgnoreCase));
                var id = Format.Text(job, "id");
                lastRun = id.Length > 0 ? WorkbenchOps.OrderedRuns(runs).FirstOrDefault(run => Format.Text(run, "jobId") == id) : null;
                checkedStatus = true;
                if (lastRun is not null) notice.Text = WorkbenchOps.RunLabel(Format.Text(lastRun, "status"));
                else notice.Text = backends.Length == 0 ? L10n.Text("windows.autocommit.no_agents") : "";
            }
            bool Adopt(JsonNode response, PendingLaunch submission)
            {
                var run = response["run"] as JsonObject;
                if (Format.Text(response, "operationId") != submission.OperationId || Format.Text(response, "jobId") != submission.JobId
                    || Format.Text(run, "jobId") != submission.JobId || Format.Text(run, "id") is not { Length: > 0 } runId
                    || runId != Format.Text(response, "runId")) return false;
                lastRun = run;
                File.Delete(path);
                pending = null;
                retry = false;
                return true;
            }
            async Task CheckAsync()
            {
                if (pending is { } submission)
                {
                    var receipt = await Call("automation.runReceipt", new JsonObject { ["operationId"] = submission.OperationId });
                    if (!Current()) return;
                    if (receipt is JsonObject { Count: 0 }) retry = true;
                    else if (!Adopt(receipt, submission)) throw new InvalidDataException(L10n.Text("windows.autocommit.unconfirmed"));
                }
                await RefreshAsync();
                if (retry) notice.Text = L10n.Text("windows.autocommit.retry_help");
            }
            async Task LaunchAsync(PendingLaunch submission)
            {
                retry = false;
                var response = await Call("automation.runOnce", new JsonObject { ["id"] = submission.JobId, ["operationId"] = submission.OperationId });
                if (!Current()) return;
                if (!Adopt(response, submission)) throw new InvalidDataException(L10n.Text("windows.autocommit.unconfirmed"));
                await RefreshAsync();
            }
            async Task StartAsync()
            {
                if (pending is { } submission)
                {
                    if (retry) await LaunchAsync(submission);
                    return;
                }
                if (backend.SelectedIndex < 0 || model.SelectedItem is not string chosenModel) return;
                var agent = Format.Text(backends[backend.SelectedIndex], "id");
                await RefreshAsync();
                if (!Current() || WorkbenchOps.IsRunning(lastRun)) return;
                var payload = WorkbenchOps.PreserveUnknown(job, new JsonObject
                {
                    ["id"] = Format.Text(job, "id"), ["name"] = JobName, ["workspaceId"] = workspaceId,
                    ["backend"] = agent, ["model"] = chosenModel, ["enabled"] = true,
                    ["prompt"] = L10n.Text("windows.autocommit.prompt", folderName), ["budgetSeconds"] = 900, ["schedule"] = new JsonObject { ["kind"] = "once" },
                });
                JsonNode saved;
                if (job is null)
                    saved = await Call("automation.create", new JsonObject { ["job"] = payload });
                else
                {
                    var revision = WorkbenchOps.Revision(job) ?? throw new InvalidDataException(L10n.Text("windows.autocommit.status_unavailable"));
                    saved = await Call("automation.edit", new JsonObject { ["job"] = payload, ["expectedRevision"] = revision });
                }
                if (!Current()) return;
                var jobId = Format.Text(saved, "id");
                if (jobId.Length == 0) throw new InvalidDataException(L10n.Text("windows.autocommit.status_unavailable"));
                var operation = new PendingLaunch(WorkbenchOps.NewOperationId("automation-run"), jobId);
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                try
                {
                    using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        JsonSerializer.Serialize(stream, operation);
                        stream.Flush(flushToDisk: true);
                    }
                    File.Move(temporary, path);
                }
                finally { File.Delete(temporary); }
                pending = operation;
                await LaunchAsync(operation);
            }
            async Task RunAsync(Func<Task> action)
            {
                if (busy || closed || !Current()) return;
                busy = true;
                notice.Text = L10n.Text("common.loading");
                Render();
                try { await action(); }
                catch (Exception error)
                {
                    if (Current()) notice.Text = pending is null ? FriendlyError.Display(error.Message)
                        : L10n.Text("windows.autocommit.check_before_retry", FriendlyError.Display(error.Message));
                }
                finally { busy = false; if (!closed && Current()) Render(); }
            }
            check.Click += async (_, _) => await RunAsync(CheckAsync);
            dialog.PrimaryButtonClick += async (_, args) => { args.Cancel = true; await RunAsync(StartAsync); };
            dialog.Closing += (_, args) => args.Cancel = busy && Current();
            dialog.Closed += (_, _) => closed = true;
            dialog.Opened += async (_, _) =>
            {
                await RunAsync(CheckAsync);
                if (Current() && !closed && backend.SelectedIndex < 0 && backends.Length > 0)
                {
                    var stored = Array.FindIndex(backends, item => Format.Text(item, "id") == Format.Text(job, "backend"));
                    backend.SelectedIndex = Math.Max(0, stored);
                }
            };
            Render();
            await Chrome.ShowDialog(owner, dialog);
        }
        catch (Exception error)
        {
            if (Current()) await Chrome.ShowDialog(owner, new ContentDialog
            {
                Title = title, Content = new TextBlock { Text = FriendlyError.Display(error.Message), TextWrapping = TextWrapping.Wrap },
                CloseButtonText = L10n.Text("common.close"),
            });
        }
        finally { Open.Remove(lease); }
    }
}
