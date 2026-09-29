// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;

namespace Tokenstat.Navigation;

/// <summary>Read-only, short-lived previews shared by the sidebar and chat list.</summary>
internal static class ChatPreviewCache
{
    private static readonly ChatPreviewStore Store = new();
    private static readonly HashSet<(string Workspace, string Chat)> Reading = new();

    static ChatPreviewCache() { AppServices.AccountChanged += Store.Clear; }

    public static void Attach(FrameworkElement row, string workspace, string chat)
    {
        CancellationTokenSource? hover = null;
        void Cancel() { hover?.Cancel(); hover?.Dispose(); hover = null; }
        row.PointerEntered += async (_, _) =>
        {
            Cancel();
            hover = new CancellationTokenSource();
            var token = hover.Token;
            try
            {
                await Task.Delay(180, token);
                await WarmAsync(workspace, chat, token);
            }
            catch (OperationCanceledException) { }
        };
        row.PointerExited += (_, _) => Cancel();
        row.Unloaded += (_, _) => Cancel();
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
