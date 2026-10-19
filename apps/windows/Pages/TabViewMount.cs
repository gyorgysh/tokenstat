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
    private void Unloaded(object sender, RoutedEventArgs args) { _revision++; _ready = false; }
    private void ScheduleReady()
    {
        var revision = ++_revision;
        _view.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            if (revision != _revision || !_view.IsLoaded) return;
            _ready = true;
            Ready?.Invoke();
        });
    }
    public void Dispose()
    {
        _revision++;
        _ready = false;
        _view.Loaded -= Loaded;
        _view.Unloaded -= Unloaded;
        Ready = null;
    }
}
