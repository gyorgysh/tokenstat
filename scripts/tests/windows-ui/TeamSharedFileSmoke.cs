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
using Tokenstat.Pages;
using static Tokenstat.Pages.TeamManagementModel;

namespace NativeUiTests;

internal static class TeamSharedFileSmoke
{
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            foreach (var child in Descendants(VisualTreeHelper.GetChild(root, i))) yield return child;
    }
    private static async Task Wait(FrameworkElement page, Func<bool> ready, string reason)
    {
        var deadline = DateTime.UtcNow.AddSeconds(6);
        while (!ready() && DateTime.UtcNow < deadline) { page.UpdateLayout(); await Task.Delay(20); }
        if (!ready()) throw new Exception(reason);
    }
    internal static async Task RunAsync(StackPanel body)
    {
        var person = "one"; var reads = 0; var exports = new List<TeamSharedFileData>(); var foreign = false; var hold = false;
        var pending = new TaskCompletionSource<JsonNode>();
        var bytes = System.Text.Encoding.UTF8.GetBytes("Fictional shared document");
        var file = new JsonObject { ["id"] = "file", ["name"] = "../../fictional.txt", ["mediaType"] = "text/plain", ["size"] = (long)bytes.Length };
        JsonNode Reply() => new JsonObject { ["shareId"] = foreign ? "another-share" : "share", ["attachment"] = file.DeepClone(), ["data"] = Convert.ToBase64String(bytes) };
        Task<JsonNode> Host(string method, JsonObject? fields)
        {
            if (method == "account.status") return Task.FromResult<JsonNode>(new JsonObject { ["signedIn"] = true, ["host"] = "https://fixture.invalid", ["handle"] = person, ["accountId"] = person, ["accountSession"] = "session-" + person });
            if (Text(fields, "_accountSession") != "session-" + person) throw new Exception("File request crossed account scope");
            if (method == "teams.capabilities") return Task.FromResult<JsonNode>(new JsonObject { ["enabled"] = true, ["ready"] = true, ["actorId"] = person });
            if (method == "teams.directory") return Task.FromResult<JsonNode>(new JsonObject { ["organizations"] = new JsonArray(), ["nextOffset"] = null });
            if (method != "teams.connection.call" || Text(fields, "method") != "team.chat.attachment" || Text(fields?["params"], "attachment") != "file" || Text(fields?["target"], "share") != "share") throw new Exception("Unexpected file request");
            reads++; return hold ? pending.Task : Task.FromResult(Reply());
        }
        var page = new TeamsPage(Host, saveFile: (data, current) => { if (!current()) throw new Exception("Old file reached Save"); exports.Add(data); return Task.CompletedTask; });
        body.Children.Add(page); body.UpdateLayout();
        bool Shows(string text) => Descendants(page).OfType<TextBlock>().Any(row => row.Text == text);
        async Task Save()
        {
            var button = Descendants(page).OfType<Button>().Single(row => AutomationProperties.GetName(row) == L10n.Text("common.teams.save_file"));
            if (!button.IsEnabled || new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke) is not IInvokeProvider invoke) throw new Exception("File Save is inaccessible"); invoke.Invoke(); await Task.Yield();
        }
        try
        {
            await Wait(page, () => Shows(L10n.Text("common.teams.no_organizations")), "File fixture did not mount account-bound page");
            const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
            var panel = (StackPanel)typeof(TeamsPage).GetField("_body", flags)!.GetValue(page)!;
            var target = new JsonObject { ["organization"] = "org", ["repository"] = "repo", ["checkout"] = "checkout", ["share"] = "share" };
            panel.Children.Add((UIElement)typeof(TeamsPage).GetMethod("SharedFile", flags)!.Invoke(page, [target, file])!); page.UpdateLayout();
            if (reads != 0 || exports.Count != 0 || !Shows("fictional.txt")) throw new Exception("File fetched itself or exposed an unsafe path");
            await Save(); await Wait(page, () => exports.Count == 1 && Shows(L10n.Text("common.teams.file_saved")), "Native Save did not export reviewed bytes");
            if (!exports.Single().Bytes.SequenceEqual(bytes) || exports.Single().Name != "fictional.txt") throw new Exception("Native Save exported the wrong content");
            foreign = true; await Save(); await Wait(page, () => Shows(L10n.Text("common.teams.file_save_failed")), "Foreign-chat attachment reply was accepted");
            if (exports.Count != 1) throw new Exception("Foreign-chat bytes reached Save");
            foreign = false; hold = true; await Save(); await Wait(page, () => reads == 3, "Download was not held");
            person = "two"; AppServices.NotifyAccountChanged();
            await Wait(page, () => !Shows("fictional.txt"), "Account replacement kept the old file control");
            pending.SetResult(Reply()); await Task.Delay(100);
            if (exports.Count != 1) throw new Exception("Old-account download reached Save after replacement");
        }
        finally { body.Children.Remove(page); }
        Program.Log("PASS: production Windows shared-file Save is explicit, rejects another chat and retires pending downloads on account replacement");
    }
}
