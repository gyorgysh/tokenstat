// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Tokenstat.Pages;

internal static class TerminalPaneSelectionTests
{
    internal static void Run(string directory)
    {
        static void Check(bool value, string message) { if (!value) throw new Exception(message); }
        const string cli = "codex", ssh = "ssh:server", other = "ssh:other";
        foreach (var endpoint in new[] { "192.0.2.8", "192.0.2.8:22", "2001:db8::8", "[2001:db8::8]:22", "admin@server.example", "ssh://192.0.2.8:22", " 192.0.2.8 " })
            Check(SshDisplayName.Private(endpoint, "SSH session") == "SSH session", "An SSH endpoint escaped a connection title");
        Check(SshDisplayName.Private(" Production server ", "SSH session") == "Production server", "A friendly SSH name was hidden");
        var selection = new TerminalPaneSelection { Selected = cli };
        selection.SetSplit(true, new[] { cli });
        Check(selection.Leading == cli && selection.Trailing is null, "An empty split moved its CLI");
        selection.Select(ssh, new[] { cli, ssh }, true);
        Check(selection.Leading == cli && selection.Trailing == ssh && selection.Selected == ssh, "SSH did not fill the empty half");
        selection.Select(cli, new[] { cli, ssh }, true);
        selection.SendToOtherHalf(other, new[] { cli, ssh, other });
        Check(selection.Leading == cli && selection.Trailing == other && selection.Selected == cli, "Open in split replaced the focused CLI");
        selection.Swap(new[] { cli, ssh, other });
        Check(selection.Leading == other && selection.Trailing == cli && selection.Selected == cli, "Swap changed the focused session or included an offscreen tab");
        selection.Swap(new[] { cli, ssh, other });
        Check(selection.Leading == cli && selection.Trailing == other, "Double swap did not restore the pair");
        selection.Select(ssh, new[] { cli, ssh, other }, true);
        Check(selection.Leading == ssh && selection.Trailing == other, "Selecting a third tab left keyboard focus offscreen");
        Check(!selection.Reconcile(new[] { ssh, other }), "Closing an offscreen tab collapsed the split");
        Check(selection.Reconcile(new[] { other }) && selection.Selected == other && selection.Leading is null && selection.Trailing is null,
            "Closing a visible half duplicated its survivor");
        selection = new() { Selected = ssh, Leading = "gone", Trailing = ssh };
        var panes = selection.Panes(new[] { ssh }, true);
        Check(panes.Leading == ssh && panes.Trailing is null, "Stale pins attached one emulator twice");
        selection = new() { Selected = cli, Leading = cli };
        selection.Swap(new[] { cli, ssh });
        Check(selection.Leading == cli && selection.Trailing is null && selection.Selected == cli, "An empty half was swapped");
        selection.Select("connecting:pending", new[] { cli, "connecting:pending" }, true);
        selection.Rename("connecting:pending", ssh);
        Check(selection.Leading == cli && selection.Trailing == ssh && selection.Selected == ssh, "A new SSH connection lost split placement when its ID arrived");
        selection = new() { Selected = ssh, Leading = cli, Trailing = ssh };
        selection.Rename(cli, "fresh-shell");
        Check(selection.Selected == ssh && selection.Leading == "fresh-shell" && selection.Trailing == ssh,
            "Respawning the other half changed SSH focus or left its obsolete CLI ID pinned");
        var path = Path.Combine(directory, "ssh-tabs.json");
        File.WriteAllText(path, "{\"workspace-a\":null,\"workspace-b\":[null,\"\",\"ssh-id\",\"ssh-id\"]}");
        var associations = WorkspaceSshTabs.Read(path);
        Check(associations["workspace-a"].Count == 0 && associations["workspace-b"].SequenceEqual(new[] { "ssh-id" }), "Malformed saved SSH associations blocked restoration");
        associations["workspace-a"].Add("ssh-id");
        associations["workspace-b"].Add("keep-running");
        Check(WorkspaceSshTabs.Remove(associations, "ssh-id") && associations["workspace-a"].Count == 0
            && associations["workspace-b"].SequenceEqual(new[] { "keep-running" }), "Closing SSH retained project tabs or removed another running session");
        Check(!WorkspaceSshTabs.Remove(associations, "missing"), "Removing an absent SSH session changed associations");
        Console.WriteLine("Mixed terminals: SSH/CLI splits, focused replacement, swaps, close recovery and saved association recovery passed");
    }
}
