// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Tokenstat.Pages;

/// <summary>Native tab additions are safe after Loaded has finished dispatching.</summary>
internal sealed class TabViewMount : IDisposable
{
    private readonly TabView _view;
    private int _revision;
    private bool _ready;
    private bool _disposed;
    public bool IsReady => _ready && _view.IsLoaded;
    public event Action? Ready;

    public TabViewMount(TabView view)
    {
        _view = view;
        view.Loaded += Loaded;
        view.Unloaded += Unloaded;
        if (view.IsLoaded) ScheduleReady();
    }
    private void Loaded(object sender, RoutedEventArgs args) => ScheduleReady();
    // WinUI can deliver an old Unloaded after a quick remove/re-add has
    // already raised Loaded. Reconcile the current tree after either event;
    // blindly cancelling here strands the newly mounted control forever.
    private void Unloaded(object sender, RoutedEventArgs args) => ScheduleReady();
    private void ScheduleReady()
    {
        if (_disposed) return;
        _ready = false;
        var revision = ++_revision;
        _view.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            if (_disposed || revision != _revision || !_view.IsLoaded
                || Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(_view) is null) return;
            _ready = true;
            Ready?.Invoke();
        });
    }
    public void Dispose()
    {
        _disposed = true;
        _revision++;
        _ready = false;
        _view.Loaded -= Loaded;
        _view.Unloaded -= Unloaded;
        Ready = null;
    }
}
