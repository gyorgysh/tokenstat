// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal static class AgentSignInDialog
{
    public static bool Supported(JsonNode backend) => backend["signIn"] is JsonNode flow
        ? Format.Flag(flow, "supported") : Format.Text(backend, "launcherId") is "claude_code" or "codex";
    private static string Kind(JsonNode backend) => backend["signIn"] is JsonNode flow
        ? Format.Text(flow, "kind") : Format.Text(backend, "launcherId") == "codex" ? "deviceCode" : "browserCode";
    public static async Task<string> CheckAsync(JsonNode backend, Func<string, JsonNode?, Task<JsonNode>> call)
    {
        if (Format.Flag(backend, "canCheckSignIn"))
        {
            var status = await call("launcher.checkSignIn", new JsonObject { ["id"] = Format.Text(backend, "launcherId") });
            // Whether the CLI answered itself, which is what a send may trust.
            backend["signInVerified"] = Format.Flag(status, "checked");
            return Format.Text(status, "readiness", "unknown");
        }
        backend["signInVerified"] = false;
        var backends = await call("chat.backends", new JsonObject());
        var fresh = (backends as JsonArray)?.FirstOrDefault(item => Format.Text(item, "id") == Format.Text(backend, "id"));
        return Format.Text(fresh, "readiness", "unknown");
    }

    public static async Task<string?> ShowAsync(UIElement owner, string workspaceId, JsonNode backend,
        Func<string, JsonNode?, Task<JsonNode>> call)
    {
        var id = Format.Text(backend, "launcherId");
        if (id.Length == 0) return null;
        var info = await call("launcher.signIn", new JsonObject { ["id"] = id, ["rows"] = 24, ["cols"] = 100, ["dark"] = Theme.IsDark });
        var sessionId = Format.Text(info, "id");
        if (sessionId.Length == 0) throw new InvalidOperationException(L10n.Text("windows.agentsetup.no_terminal"));
        var terminalId = RemoteWorkspaces.TrySplit(workspaceId, out var peer, out _) ? $"remote:{peer}:{sessionId}" : sessionId;
        var terminal = new TerminalPage("", terminalId) { Height = 360, MinWidth = 520 };
        var stack = new StackPanel { Spacing = Theme.SpaceM };
        if (RemoteWorkspaces.IsRemote(workspaceId)) stack.Children.Add(Copy(L10n.Text("windows.agentsetup.remote")));
        stack.Children.Add(Copy(L10n.Text("windows.agentsetup.step_open")));
        stack.Children.Add(Copy(Kind(backend) == "deviceCode"
            ? L10n.Text("windows.agentsetup.step_device") : Kind(backend) == "browserCode"
            ? L10n.Text("windows.agentsetup.step_browser") : L10n.Text("windows.agentsetup.step_cli")));
        stack.Children.Add(Copy(L10n.Text("windows.agentsetup.step_return")));
        stack.Children.Add(terminal);
        try
        {
            var result = await Chrome.ShowDialog(owner, new ContentDialog
            {
                Title = L10n.Text("windows.agentsetup.setup_title", Format.Text(backend, "label", id)),
                Content = stack, PrimaryButtonText = L10n.Text("windows.agentsetup.finished"),
                CloseButtonText = L10n.Text("common.close"),
            });
            if (result != ContentDialogResult.Primary) return null;
            return await CheckAsync(backend, call);
        }
        finally
        {
            try { await call("pty.close", new JsonObject { ["id"] = sessionId }); }
            catch { /* A disconnected host must not hide the sign-in result. */ }
        }
    }

    private static TextBlock Copy(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };
}
