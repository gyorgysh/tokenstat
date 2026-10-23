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
    private bool _workScheduled;
    private bool _executing;
    private readonly Queue<(Action Run, Action? Abandon, DateTime Queued)> _pending = new();
    private static readonly TimeSpan DeferLimit = TimeSpan.FromSeconds(10);
    public bool IsReady => _ready && _view.IsLoaded;
    public bool HasPending => !_executing && _pending.Count > 0;
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
            ScheduleWork();
        });
    }

    /// <summary>
    /// Keep actions ordered across loading and remounting. Each action gets
    /// its own dispatcher turn so tabs created by it can finish loading before
    /// the next action changes their native selection or companion content.
    /// </summary>
    public void Enqueue(Action run, Action? abandon = null)
    {
        if (_disposed) { abandon?.Invoke(); return; }
        while (_pending.Count >= 64) _pending.Dequeue().Abandon?.Invoke();
        _pending.Enqueue((run, abandon, DateTime.UtcNow));
        ScheduleWork();
    }

    private void ScheduleWork()
    {
        if (_disposed || _workScheduled || !IsReady || _pending.Count == 0) return;
        _workScheduled = true;
        if (!_view.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            _workScheduled = false;
            if (_disposed || !IsReady || !_pending.TryDequeue(out var work)) return;
            _executing = true;
            try
            {
                if (DateTime.UtcNow - work.Queued <= DeferLimit) work.Run();
                else work.Abandon?.Invoke();
            }
            finally { _executing = false; ScheduleWork(); }
        }))
        {
            _workScheduled = false;
            while (_pending.TryDequeue(out var work)) work.Abandon?.Invoke();
        }
    }
    public void Dispose()
    {
        _disposed = true;
        _revision++;
        _ready = false;
        _view.Loaded -= Loaded;
        _view.Unloaded -= Unloaded;
        Ready = null;
        while (_pending.TryDequeue(out var work)) work.Abandon?.Invoke();
    }
}
