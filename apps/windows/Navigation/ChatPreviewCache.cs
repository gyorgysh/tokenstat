// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;

namespace Tokenstat.Navigation;

/// <summary>Read-only, short-lived previews shared by the sidebar and chat list.</summary>
internal static class ChatPreviewCache
{
    private static readonly ChatPreviewStore Store = new();
    private static readonly HashSet<(string Workspace, string Chat)> Reading = new();

    private sealed class Binding
    {
        internal string? Workspace;
        internal string? Chat;
        internal CancellationTokenSource? Hover;
        internal void Cancel() { Hover?.Cancel(); Hover?.Dispose(); Hover = null; }
    }
    private static readonly ConditionalWeakTable<FrameworkElement, Binding> Bindings = new();

    static ChatPreviewCache()
    {
        AppServices.AccountChanged += Store.Clear;
        NavigationRows.Retiring += row =>
        {
            if (!Bindings.TryGetValue(row, out var binding)) return;
            binding.Cancel(); binding.Workspace = null; binding.Chat = null;
        };
        NavigationRows.Reconciled += (fresh, retained) =>
        {
            if (Bindings.TryGetValue(fresh, out var binding) && binding.Workspace is { } workspace && binding.Chat is { } chat)
                Attach(retained, workspace, chat);
        };
    }

    public static void Attach(FrameworkElement row, string workspace, string chat)
    {
        var binding = Bindings.GetValue(row, owner =>
        {
            var state = new Binding();
            owner.PointerEntered += async (_, _) =>
            {
                state.Cancel();
                if (state.Workspace is not { } currentWorkspace || state.Chat is not { } currentChat) return;
                state.Hover = new CancellationTokenSource();
                var token = state.Hover.Token;
                try
                {
                    await Task.Delay(180, token);
                    await WarmAsync(currentWorkspace, currentChat, token);
                }
                catch (OperationCanceledException) { }
            };
            owner.PointerExited += (_, _) => state.Cancel();
            owner.Unloaded += (_, _) => state.Cancel();
            return state;
        });
        binding.Cancel(); binding.Workspace = workspace; binding.Chat = chat;
    }

    public static JsonNode? Take(string workspace, string chat) => Store.Take(workspace, chat);

    private static async Task WarmAsync(string workspace, string chat, CancellationToken token)
    {
        var key = (workspace, chat);
        if (Store.Contains(workspace, chat)) return;
        if (Reading.Count >= 2 || !Reading.Add(key)) return;
        var generation = Store.Generation;
        try
        {
            var args = new JsonObject { ["id"] = chat, ["limit"] = 160, ["stablePositions"] = true };
            var chunk = RemoteWorkspaces.TrySplit(workspace, out var peer, out _)
                ? await RemoteWorkspaces.CallOnPeerAsync(peer, "chat.eventPage", args)
                : await AppServices.Host.CallAsync("chat.eventPage", args);
            if (!token.IsCancellationRequested) Store.Store(workspace, chat, chunk, generation);
        }
        catch { /* Speculation must never surface an error or start a turn. */ }
        finally { Reading.Remove(key); }
    }
}
