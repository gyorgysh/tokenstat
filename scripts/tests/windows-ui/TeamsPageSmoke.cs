// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Reflection;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat;
using Tokenstat.Design;
using Tokenstat.Pages;

namespace NativeUiTests
{
    internal static class TeamsPageSmoke
    {
        internal static async Task RunAsync(StackPanel body)
        {
            var target = new JsonObject { ["organization"] = "org-fixture", ["repository"] = "repo-fixture", ["checkout"] = "checkout-fixture", ["share"] = "share-fixture" };
            var fence = new JsonObject { ["fixture"] = "exact-original-fence" };
            JsonNode? stopped = null;
            var calls = 0;
            var statusReads = 0;
            var stopAttempts = 0;
            Task<JsonNode> Host(string method, JsonObject? fields)
            {
                if (method == "account.status") return Task.FromResult<JsonNode>(new JsonObject());
                if (Format.Text(fields, "method") == "team.chat.details")
                {
                    calls++;
                    throw new Tokenstat.Host.HostException("team_connection_unavailable", "Fictional history read failure");
                }
                if (Format.Text(fields, "method") == "team.chat.ask.stop")
                {
                    if (++stopAttempts == 1) throw new Tokenstat.Host.HostException("team_connection_unavailable", "Fictional Stop request failed");
                    stopped = fields?["params"]?["fence"]?.DeepClone();
                    return Task.FromResult<JsonNode>(new JsonObject());
                }
                if (Format.Text(fields, "method") == "team.chat.ask.status")
                {
                    statusReads++;
                    return Task.FromResult<JsonNode>(new JsonObject());
                }
                throw new Exception("Unexpected fictional host call");
            }
            var page = new TeamsPage(Host);
            body.Children.Add(page); body.UpdateLayout();
            var deadline = DateTime.UtcNow.AddSeconds(3);
            while (!page.IsLoaded && DateTime.UtcNow < deadline) await Task.Delay(20);
            if (!page.IsLoaded) throw new Exception("Teams fixture did not load");
            const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
            var runs = (Dictionary<string, JsonNode>)typeof(TeamsPage).GetField("_activeRuns", flags)!.GetValue(page)!;
            runs[target.ToJsonString()] = fence;
            var show = (Task<bool>)typeof(TeamsPage).GetMethod("ShowChatAsync", flags)!.Invoke(page, [target, "Fictional chat", "Fictional computer", null])!;
            if (await show || calls != 1) throw new Exception("Teams fixture did not exercise the history read failure");
            deadline = DateTime.UtcNow.AddSeconds(7);
            while (statusReads == 0 && DateTime.UtcNow < deadline) await Task.Delay(20);
            if (statusReads == 0 || runs.Count != 1) throw new Exception("An unconfirmed status discarded the known run");
            page.UpdateLayout();
            static IEnumerable<Button> Buttons(DependencyObject root)
            {
                if (root is Button button) yield return button;
                for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
                    foreach (var child in Buttons(VisualTreeHelper.GetChild(root, i))) yield return child;
            }
            var stop = Buttons(page).SingleOrDefault(b => AutomationProperties.GetName(b) == L10n.Text("common.teams.stop_agent"));
            if (stop is null || !stop.IsEnabled) throw new Exception("History failure hid the known Stop control");
            var invoke = new ButtonAutomationPeer(stop).GetPattern(PatternInterface.Invoke) as IInvokeProvider;
            if (invoke is null) throw new Exception("Stop has no accessible invoke action");
            invoke.Invoke();
            deadline = DateTime.UtcNow.AddSeconds(3);
            while (stopAttempts == 0 && DateTime.UtcNow < deadline) await Task.Delay(20);
            if (stopAttempts != 1 || !stop.IsEnabled) throw new Exception("Failed Stop could not be retried");
            invoke.Invoke();
            deadline = DateTime.UtcNow.AddSeconds(3);
            while (stopped is null && DateTime.UtcNow < deadline) await Task.Delay(20);
            if (!JsonNode.DeepEquals(fence, stopped)) throw new Exception("Stop lost the original run fence");
            body.Children.Remove(page);
            Program.Log("PASS: the production Teams reader preserves accessible Stop through malformed status and a history read failure");
        }
    }
}
namespace Tokenstat.Host
{
    internal sealed class HostException(string code, string message) : Exception(message)
    {
        internal string Code { get; } = code;
    }
}
namespace Tokenstat.Pages
{
    internal static class SshVaultScope
    {
        internal static JsonObject? From(JsonNode account) => null;
    }
}
