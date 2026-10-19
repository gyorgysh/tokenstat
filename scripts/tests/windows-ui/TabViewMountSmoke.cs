// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Pages;

namespace NativeUiTests;

internal static class TabViewMountSmoke
{
    internal static async Task Run(StackPanel host)
    {
        var strip = new WorkspaceTabStrip();
        var view = strip.View;
        view.Width = 320;
        view.Height = 44;
        using var mount = new TabViewMount(view);
        var loads = 0;
        var unloads = 0;
        var ready = 0;
        view.Loaded += (_, _) =>
        {
            loads++;
            Program.Log($"Tab mount Loaded: loads={loads}, unloads={unloads}, ready={ready}, isLoaded={view.IsLoaded}");
            if (mount.IsReady) throw new Exception("Native tabs became mutable inside Loaded");
        };
        view.Unloaded += (_, _) =>
        {
            unloads++;
            Program.Log($"Tab mount Unloaded: loads={loads}, unloads={unloads}, ready={ready}, isLoaded={view.IsLoaded}");
        };
        mount.Ready += () =>
        {
            ready++;
            Program.Log($"Tab mount ready: loads={loads}, unloads={unloads}, ready={ready}");
            foreach (var name in new[] { "Changes", "Browser", "Terminal", "Inspector" })
                strip.Open(name, name, () => new Grid());
        };
        async Task Settle(Func<bool> condition)
        {
            for (var attempt = 0; attempt < 150; attempt++)
            {
                host.UpdateLayout();
                if (condition()) return;
                await Task.Delay(20);
            }
            throw new Exception($"Native tab mount did not settle: loads={loads}, unloads={unloads}, ready={ready}, tabs={view.TabItems.Count}, isLoaded={view.IsLoaded}, isReady={mount.IsReady}, attached={Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(view) is not null}");
        }
        try
        {
            host.Children.Add(view);
            await Settle(() => mount.IsReady && ready == 1 && view.TabItems.Count == 4);
            var selected = view.SelectedItem;
            host.Children.Remove(view);
            await Settle(() => !view.IsLoaded && !mount.IsReady);
            host.Children.Add(view);
            await Settle(() => mount.IsReady && ready == 2);
            if (view.TabItems.Count != 4 || !ReferenceEquals(view.SelectedItem, selected))
                throw new Exception("Remounting the workbench duplicated tabs or lost its selected native surface");
            mount.Dispose();
            host.Children.Remove(view);
            await Settle(() => !view.IsLoaded);
            host.Children.Add(view);
            await Settle(() => loads == 3);
            await Task.Delay(100);
            if (mount.IsReady || ready != 2) throw new Exception("Disposed browser tabs resumed deferred mounting");
            Program.Log("PASS: native tool tabs populate after Loaded, retain surfaces on remount, and retire queued work");
        }
        finally { host.Children.Remove(view); }
    }
}
