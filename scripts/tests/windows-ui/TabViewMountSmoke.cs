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
        var work = new List<int>();
        var betweenActions = false;
        mount.Enqueue(() => {
            work.Add(1);
            view.DispatcherQueue.TryEnqueue(() => betweenActions = true);
        });
        mount.Enqueue(() => {
            if (!betweenActions) throw new Exception("Queued tab actions ran in one native layout turn");
            work.Add(2);
        });
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
            await Settle(() => work.Count == 2);
            if (!work.SequenceEqual(new[] { 1, 2 })) throw new Exception("Deferred tab actions lost their order");
            var selected = view.SelectedItem;
            host.Children.Remove(view);
            await Settle(() => !view.IsLoaded && !mount.IsReady);
            mount.Enqueue(() => work.Add(3));
            await Task.Delay(50);
            if (work.Count != 2) throw new Exception("Deferred tab work ran while unloaded");
            host.Children.Add(view);
            await Settle(() => mount.IsReady && ready == 2 && work.Count == 3);
            if (view.TabItems.Count != 4 || !ReferenceEquals(view.SelectedItem, selected))
                throw new Exception("Remounting the workbench duplicated tabs or lost its selected native surface");
            var abandoned = false;
            mount.Enqueue(() => throw new Exception("Disposed tab work ran"), () => abandoned = true);
            mount.Dispose();
            if (!abandoned) throw new Exception("Disposed tab work was not retired");
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
