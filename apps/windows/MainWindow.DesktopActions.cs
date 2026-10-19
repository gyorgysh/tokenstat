// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Windowing;
using Tokenstat.Navigation;
using Tokenstat.Pages;

namespace Tokenstat;

public sealed partial class MainWindow
{
    private readonly Queue<(DesktopOpenRequest Request, long Account)> _desktopActions = new();
    private readonly InfoBar _desktopActionError = new() { IsClosable = true, Severity = InfoBarSeverity.Warning };

    private void InitializeDesktopActions()
    {
        _desktopActionError.VerticalAlignment = VerticalAlignment.Top;
        _desktopActionError.Margin = new Thickness(12);
        Grid.SetRow(_desktopActionError, 1); Grid.SetColumn(_desktopActionError, 1);
        RootGrid.Children.Add(_desktopActionError);
        AppServices.OpenDesktopAction = request => DispatcherQueue.TryEnqueue(() => QueueDesktopAction(request));
        DesktopActivation.Changed += DesktopActivated;
        RootGrid.Loaded += (_, _) => CollectDesktopActions();
        Closed += (_, _) => DesktopActivation.Changed -= DesktopActivated;
    }
    private void DesktopActivated() => DispatcherQueue.TryEnqueue(() =>
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter) presenter.Restore();
        Activate();
        CollectDesktopActions();
    });
    private void CollectDesktopActions()
    {
        while (DesktopActivation.TryTake(out var request)) if (request is not null) QueueDesktopAction(request);
        ResolveDesktopActions();
    }
    private void QueueDesktopAction(DesktopOpenRequest request)
    {
        Program.LogStartup("Desktop action queued; tool=" + request.Tool);
        while (_desktopActions.Count >= 16) _desktopActions.Dequeue();
        _desktopActions.Enqueue((request, AppServices.AccountGeneration));
        ResolveDesktopActions();
    }
    private void ResolveDesktopActions()
    {
        if (!_foldersLoaded || !RootGrid.IsLoaded) return;
        while (_desktopActions.TryDequeue(out var item))
        {
            if (item.Account != AppServices.AccountGeneration) continue;
            var request = item.Request;
            if (!_localFolders.Any(folder => Format.Text(folder, "id") == request.WorkspaceId)
                && RemoteWorkspaces.CachedFolder(request.WorkspaceId) is null)
            {
                Program.LogStartup("Desktop action rejected; project unavailable");
                _desktopActionError.Message = L10n.Text("windows.desktop_actions.project_missing");
                _desktopActionError.IsOpen = true;
                continue;
            }
            _desktopActionError.IsOpen = false;
            NavigateTo("ws:" + request.WorkspaceId + ":Chat");
            var workbench = WorkspaceTabs(request.WorkspaceId);
            var account = item.Account;
            workbench.WhenLoaded(() =>
            {
                if (account == AppServices.AccountGeneration)
                {
                    Program.LogStartup("Desktop action applied; tool=" + request.Tool);
                    workbench.OpenDesktopAction(request);
                }
            });
        }
    }
}
