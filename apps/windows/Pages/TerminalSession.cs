// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed class TerminalSession
{
    private static readonly ConcurrentDictionary<string, TerminalSession> ByWorkspace = new();
    private static readonly ConcurrentDictionary<string, TerminalSession> ById = new();

    private static string Slot(string workspaceId, string? sessionId) =>
        workspaceId + "\0" + (sessionId ?? "");

    public event Action<byte[]>? Output;

    public event Action? Changed;

    public string Id { get; private set; }

    public string WorkspaceId { get; }

    public long Offset { get; private set; }

    public bool Alive { get; private set; } = true;

    public bool HasOutput { get; private set; }

    public bool Closed { get; private set; }

    public long Dropped { get; private set; }

    public bool Paused { get; private set; }

    public int Rows { get; private set; } = 30;

    public int Cols { get; private set; } = 100;

    public string Command { get; private set; } = "";

    public SessionIdentities NativeSessionIdentities { get; private set; } = SessionIdentities.Read(null);

    public int? ExitCode { get; private set; }

    public string LastError { get; private set; } = "";

    private CancellationTokenSource? _poll;

    private int _failures;

    private int _readsSinceInfo;

    private bool _starting;

    private readonly SemaphoreSlim _lifecycle = new(1, 1);

    private string _slot;

    private TerminalSession(string workspaceId, string? sessionId)
    {
        WorkspaceId = workspaceId;
        Id = sessionId ?? "";
        _slot = Slot(workspaceId, sessionId);
    }

    public static TerminalSession For(string workspaceId, string? sessionId)
    {
        if (!string.IsNullOrEmpty(sessionId)
            && ById.TryGetValue(sessionId, out var known)
            && known.WorkspaceId == workspaceId
            && !known.Closed)
        {
            return known;
        }
        return ByWorkspace.GetOrAdd(
            Slot(workspaceId, sessionId),
            _ => new TerminalSession(workspaceId, sessionId));
    }

    public static bool IsRemoteId(string id) =>
        id.StartsWith("remote:", StringComparison.Ordinal);

    public Task AttachAsync(int rows, int cols) => InLifecycleAsync(() => AttachCoreAsync(rows, cols));

    private async Task InLifecycleAsync(Func<Task> action)
    {
        await _lifecycle.WaitAsync();
        try { await action(); }
        finally { _lifecycle.Release(); }
    }

    private async Task AttachCoreAsync(int rows, int cols)
    {
        if (Closed)
        {
            return;
        }
        if (string.IsNullOrEmpty(Id))
        {
            await SpawnAsync(rows, cols);
            if (string.IsNullOrEmpty(Id))
            {
                return;
            }
        }
        else
        {
            await RefreshInfoAsync();
            if (Closed)
            {
                return;
            }
        }
        if (_poll is not null || _starting)
        {
            return;
        }
        _starting = true;
        try
        {
            await ResizeAsync(rows, cols);
        }
        finally
        {
            _starting = false;
        }
        if (_poll is not null || Closed)
        {
            return;
        }
        Offset = 0;
        Dropped = 0;
        HasOutput = false;
        _poll = new CancellationTokenSource();
        _ = PollAsync(_poll.Token);
    }

    public Task DetachAsync() => InLifecycleAsync(DetachCoreAsync);

    private async Task DetachCoreAsync()
    {
        _poll?.Cancel();
        _poll = null;
        var id = Id;
        if (string.IsNullOrEmpty(id) || Closed)
        {
            return;
        }
        try
        {
            await AppServices.Host.CallAsync(
                "pty.detach",
                new JsonObject
                {
                    ["id"] = id,
                    ["viewer"] = TerminalViewer.Id,
                });
        }
        catch
        {
        }
    }

    public Task KillAsync() => InLifecycleAsync(KillCoreAsync);

    private async Task KillCoreAsync()
    {
        var id = Id;
        if (string.IsNullOrEmpty(id))
        {
            return;
        }
        try
        {
            await AppServices.Host.CallAsync("pty.kill", new JsonObject { ["id"] = id });
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
        }
        await RefreshInfoAsync();
    }

    public Task CloseAsync() => InLifecycleAsync(CloseCoreAsync);

    private async Task CloseCoreAsync()
    {
        await DetachCoreAsync();
        var id = Id;
        if (!string.IsNullOrEmpty(id))
        {
            try
            {
                await AppServices.Host.CallAsync("pty.close", new JsonObject { ["id"] = id });
            }
            catch (Exception ex)
            {
                LastError = ex.Message;
            }
        }
        Closed = true;
        if (!string.IsNullOrEmpty(id))
        {
            ById.TryRemove(id, out _);
        }
        ByWorkspace.TryRemove(_slot, out _);
        RaiseChanged();
    }

    public Task RespawnAsync(int rows, int cols) => InLifecycleAsync(() => RespawnCoreAsync(rows, cols));

    private async Task RespawnCoreAsync(int rows, int cols)
    {
        await DetachCoreAsync();
        var oldId = Id;
        if (!string.IsNullOrEmpty(oldId)) ById.TryRemove(oldId, out _);
        ByWorkspace.TryRemove(_slot, out _);
        Id = "";
        Offset = 0;
        Alive = true;
        HasOutput = false;
        Closed = false;
        Dropped = 0;
        Paused = false;
        Command = "";
        NativeSessionIdentities = SessionIdentities.Read(null);
        ExitCode = null;
        LastError = "";
        _failures = 0;
        await SpawnAsync(rows, cols);
        if (!string.IsNullOrEmpty(Id))
        {
            _slot = Slot(WorkspaceId, Id);
            ByWorkspace[_slot] = this;
        }
        if (!string.IsNullOrEmpty(Id) && _poll is null)
        {
            _poll = new CancellationTokenSource();
            _ = PollAsync(_poll.Token);
        }
        RaiseChanged();
    }

    public async Task WriteAsync(byte[] bytes)
    {
        var id = Id;
        if (string.IsNullOrEmpty(id) || bytes.Length == 0 || Closed)
        {
            return;
        }
        try
        {
            await AppServices.Host.CallAsync(
                "pty.write",
                new JsonObject
                {
                    ["id"] = id,
                    ["data"] = Convert.ToBase64String(bytes),
                });
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            RaiseChanged();
        }
    }

    public async Task ResizeAsync(int rows, int cols)
    {
        var id = Id;
        if (string.IsNullOrEmpty(id) || Closed)
        {
            return;
        }
        rows = Math.Clamp(rows, 5, 200);
        cols = Math.Clamp(cols, 20, 400);
        try
        {
            var answer = await AppServices.Host.CallAsync(
                "pty.resize",
                new JsonObject
                {
                    ["id"] = id,
                    ["rows"] = rows,
                    ["cols"] = cols,
                    ["viewer"] = TerminalViewer.Id,
                });
            var actualRows = Format.Long(answer, "rows");
            var actualCols = Format.Long(answer, "cols");
            if (actualRows > 0)
            {
                Rows = (int)actualRows;
            }
            if (actualCols > 0)
            {
                Cols = (int)actualCols;
            }
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
        }
        RaiseChanged();
    }

    private async Task SpawnAsync(int rows, int cols)
    {
        try
        {
            var catalog = RemoteWorkspaces.TrySplit(WorkspaceId, out var peer, out _)
                ? await RemoteWorkspaces.CallOnPeerAsync(peer, "launcher.catalog")
                : await AppServices.Host.CallAsync("launcher.catalog");
            var shell = Format.Items(catalog)?.FirstOrDefault(item => Format.Text(item, "id") == "shell")
                ?? throw new InvalidOperationException(L10n.Text("windows.terminalsession.the_host_did_not_advertise_an_available_sh.9e1e6520"));
            var command = Format.Text(shell, "command");
            if (string.IsNullOrEmpty(command)) throw new InvalidOperationException(L10n.Text("windows.terminalsession.the_host_shell_has_no_command.65bc59e3"));
            var spawned = await AppServices.Host.CallAsync(
                "pty.spawn",
                new JsonObject
                {
                    ["workspaceId"] = WorkspaceId,
                    ["command"] = command,
                    ["args"] = shell?["args"]?.DeepClone() ?? new JsonArray(),
                    ["rows"] = Math.Clamp(rows, 5, 200),
                    ["cols"] = Math.Clamp(cols, 20, 400),
                    ["dark"] = Theme.IsDark,
                });
            Id = Format.Text(spawned, "id");
            NativeSessionIdentities = SessionIdentities.Read(spawned["sessionIdentities"]);
            Command = Format.Text(spawned, "command", command);
            var rowsNow = Format.Long(spawned, "rows");
            var colsNow = Format.Long(spawned, "cols");
            if (rowsNow > 0)
            {
                Rows = (int)rowsNow;
            }
            if (colsNow > 0)
            {
                Cols = (int)colsNow;
            }
            Offset = 0;
            Alive = true;
            HasOutput = false;
            Closed = false;
            LastError = string.IsNullOrEmpty(Id) ? L10n.Text("windows.terminalsession.the_host_did_not_return_a_session_id.834cef2f") : "";
            if (!string.IsNullOrEmpty(Id))
            {
                ById[Id] = this;
            }
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
        }
        RaiseChanged();
    }

    private async Task RefreshInfoAsync(CancellationToken token = default)
    {
        var id = Id;
        if (string.IsNullOrEmpty(id))
        {
            return;
        }
        JsonNode info;
        try
        {
            info = await AppServices.Host.CallAsync(
                "pty.info",
                new JsonObject
                {
                    ["id"] = id,
                    ["viewer"] = TerminalViewer.Id,
                });
        }
        catch (Exception ex)
        {
            if (token.IsCancellationRequested || id != Id || Closed) return;
            LastError = ex.Message;
            RaiseChanged();
            return;
        }
        if (token.IsCancellationRequested || id != Id || Closed) return;
        ApplyInfo(info);
    }

    private void ApplyInfo(JsonNode info)
    {
        NativeSessionIdentities = SessionIdentities.Read(info["sessionIdentities"]);
        var rows = Format.Long(info, "rows");
        var cols = Format.Long(info, "cols");
        if (rows > 0)
        {
            Rows = (int)rows;
        }
        if (cols > 0)
        {
            Cols = (int)cols;
        }
        var command = Format.Text(info, "command");
        if (!string.IsNullOrEmpty(command))
        {
            Command = command;
        }
        if (info["exitCode"] is not null
            && info["exitCode"]?.GetValueKind() != System.Text.Json.JsonValueKind.Null)
        {
            ExitCode = (int)Format.Long(info, "exitCode");
        }
        var alive = Format.Flag(info, "alive");
        var explicitlyDead = Format.Flag(info, "exited")
            || (info["running"] is JsonNode running
                && running.GetValueKind() == System.Text.Json.JsonValueKind.False);
        Alive = explicitlyDead ? false : (info["alive"] is null ? Alive : alive);
        if (ExitCode.HasValue)
        {
            Alive = false;
        }
        RaiseChanged();
    }

    private async Task PollAsync(CancellationToken token)
    {
        var id = Id;
        if (string.IsNullOrEmpty(id))
        {
            return;
        }
        var backoffMs = 50;
        while (!token.IsCancellationRequested)
        {
            JsonNode chunk;
            try
            {
                chunk = await RemoteWorkspaces.CallWorkspaceAsync(id,
                    "pty.read",
                    new JsonObject
                    {
                        ["id"] = id,
                        ["offset"] = Offset,
                        ["waitMs"] = 400,
                        ["viewer"] = TerminalViewer.Id,
                    });
            }
            catch (Exception ex)
            {
                if (token.IsCancellationRequested)
                {
                    return;
                }
                _failures++;
                LastError = ex.Message;
                RaiseChanged();
                if (_failures % 8 == 0 && !await StillThereAsync(id, token))
                {
                    return;
                }
                try
                {
                    await Task.Delay(backoffMs, token);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                backoffMs = Math.Min(backoffMs * 2, 2_000);
                continue;
            }
            if (token.IsCancellationRequested)
            {
                return;
            }
            _failures = 0;
            if (LastError.Length > 0) { LastError = ""; RaiseChanged(); }
            backoffMs = 50;
            var next = Format.Long(chunk, "nextOffset");
            if (next > Offset)
            {
                Offset = next;
            }
            var dropped = Format.Long(chunk, "dropped");
            if (dropped > 0)
            {
                Dropped += dropped;
            }
            var paused = Format.Flag(chunk, "paused");
            if (Paused != paused || dropped > 0)
            {
                Paused = paused;
                RaiseChanged();
            }
            var encoded = Format.Text(chunk, "data");
            if (encoded.Length != 0)
            {
                try
                {
                    var bytes = Convert.FromBase64String(encoded);
                    HasOutput = true;
                    Output?.Invoke(bytes);
                }
                catch
                {
                }
            }
            if (encoded.Length == 0)
            {
                try { await Task.Delay(50, token); }
                catch (OperationCanceledException) { return; }
            }
            _readsSinceInfo++;
            if (_readsSinceInfo >= 40)
            {
                _readsSinceInfo = 0;
                await RefreshInfoAsync(token);
                if (Closed || token.IsCancellationRequested)
                {
                    return;
                }
                id = Id;
            }
        }
    }

    private async Task<bool> StillThereAsync(string id, CancellationToken token)
    {
        try
        {
            var info = await AppServices.Host.CallAsync(
                "pty.info",
                new JsonObject
                {
                    ["id"] = id,
                    ["viewer"] = TerminalViewer.Id,
                });
            if (token.IsCancellationRequested || id != Id || Closed) return true;
            ApplyInfo(info);
            return Alive;
        }
        catch
        {
        }
        if (_failures < 40)
        {
            return true;
        }
        try
        {
            var listed = await AppServices.Host.CallAsync("pty.list");
            if (token.IsCancellationRequested || id != Id || Closed) return true;
            var items = Format.Items(listed);
            if (items is null)
            {
                return true;
            }
            foreach (var item in items)
            {
                if (Format.Text(item, "id") == id)
                {
                    return true;
                }
            }
            Alive = false;
            RaiseChanged();
            return false;
        }
        catch
        {
            return true;
        }
    }

    private void RaiseChanged() => Changed?.Invoke();
}
