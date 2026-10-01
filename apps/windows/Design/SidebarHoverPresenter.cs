// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Runtime.InteropServices;
using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Tokenstat.Pages;
using Tokenstat.Navigation;
using Windows.Foundation;
using WinRT.Interop;

namespace Tokenstat.Design;

/// <summary>A nonmodal card that never takes the first click or leaves a timer running after closing.</summary>
internal sealed class SidebarHoverPresenter
{
    private static SidebarHoverPresenter? _active;
    private static readonly ConditionalWeakTable<FrameworkElement, SidebarHoverPresenter> Presenters = new();
    static SidebarHoverPresenter()
    {
        AppServices.AccountChanged += () =>
        { var previous = _active; previous?._row.DispatcherQueue.TryEnqueue(() => previous.Close()); };
        NavigationRows.Reconciled += (from, to) => Transfer(from, to);
    }

    private readonly FrameworkElement _row;
    private Func<CancellationToken, Task<FrameworkElement>> _content;
    private CancellationTokenSource? _pending;
    private DispatcherQueueTimer? _timer;
    private Popup? _popup;
    private FrameworkElement? _root;
    private SidebarHoverState _state = new();
    private HoverRect? _cardBounds;
    private readonly PointerEventHandler _pressed;
    private readonly PointerEventHandler _wheel;
    private readonly KeyEventHandler _key;

    public static void Attach(FrameworkElement row, Func<CancellationToken, Task<FrameworkElement>> content)
    {
        if (Presenters.TryGetValue(row, out var presenter)) presenter._content = content;
        else Presenters.Add(row, new SidebarHoverPresenter(row, content));
    }
    public static void Transfer(FrameworkElement from, FrameworkElement to)
    { if (Presenters.TryGetValue(from, out var presenter)) Attach(to, presenter._content); }
    private SidebarHoverPresenter(FrameworkElement row, Func<CancellationToken, Task<FrameworkElement>> content)
    {
        _row = row; _content = content;
        _pressed = (_, args) =>
        {
            if (_root is null) return;
            var point = args.GetCurrentPoint(_root).Position;
            if (_cardBounds?.Contains(point.X, point.Y, 0) != true) Close();
        };
        _wheel = (_, _) => Close();
        _key = (_, _) => Close();
        row.PointerEntered += (_, args) =>
        { if (args.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Mouse) Begin(); };
        row.PointerExited += (_, _) => { if (_popup is null) CancelPending(); };
        row.Unloaded += (_, _) => Close();
        row.ContextRequested += (_, _) => Close();
        if (row.ContextFlyout is { } menu) menu.Opening += (_, _) => Close();
    }

    private void Begin()
    {
        if (_popup is not null) return;
        CancelPending();
        _pending = new CancellationTokenSource();
        _ = ShowAsync(_pending.Token);
    }
    private async Task ShowAsync(CancellationToken token)
    {
        try
        {
            var account = BrowserProjectMemory.AccountEpoch.Revision;
            await Task.Delay(450, token);
            if (token.IsCancellationRequested || !_row.IsLoaded || !PointerInsideRow() || account != BrowserProjectMemory.AccountEpoch.Revision) return;
            var card = await _content(token);
            if (token.IsCancellationRequested || !_row.IsLoaded || !PointerInsideRow() || account != BrowserProjectMemory.AccountEpoch.Revision) return;
            var root = _row.XamlRoot;
            if (root?.Content is not FrameworkElement host) return;
            var size = root.Size;
            var row = Bounds();
            if (row is null) return;
            _active?.Close(); _active = this;
            card.MaxHeight = Math.Max(80, size.Height - 16);
            card.MaxWidth = Math.Max(80, size.Width - 16);
            card.Measure(new Size(card.MaxWidth, card.MaxHeight));
            var width = Math.Min(card.MaxWidth, card.DesiredSize.Width);
            var height = Math.Min(card.MaxHeight, card.DesiredSize.Height);
            var x = row.Value.Right + 8;
            if (x + width > size.Width - 8) x = row.Value.X - width - 8;
            x = Math.Clamp(x, 8, Math.Max(8, size.Width - width - 8));
            var y = Math.Clamp(row.Value.Y, 8, Math.Max(8, size.Height - height - 8));
            _cardBounds = new HoverRect(x, y, width, height);
            _state = new();
            _popup = new Popup { XamlRoot = root, Child = card, HorizontalOffset = x, VerticalOffset = y, IsLightDismissEnabled = false, ShouldConstrainToRootBounds = true };
            _popup.Closed += (_, _) => Close();
            _root = host;
            host.AddHandler(UIElement.PointerPressedEvent, _pressed, true);
            host.AddHandler(UIElement.PointerWheelChangedEvent, _wheel, true);
            host.AddHandler(UIElement.KeyDownEvent, _key, true);
            _popup.IsOpen = true;
            _timer = _row.DispatcherQueue.CreateTimer();
            _timer.Interval = TimeSpan.FromMilliseconds(80);
            _timer.Tick += (_, _) => CheckPointer();
            _timer.Start();
        }
        catch (OperationCanceledException) { }
        catch { Close(); } // A preview must never break a row's normal navigation.
    }
    private HoverRect? Bounds()
    {
        try
        {
            var point = _row.TransformToVisual(_row.XamlRoot.Content).TransformPoint(new Point());
            return new(point.X, point.Y, _row.ActualWidth, _row.ActualHeight);
        }
        catch { return null; }
    }
    private bool PointerInsideRow() => Pointer(out var point) && Bounds()?.Contains(point.X, point.Y) == true;
    private void CheckPointer()
    {
        if (_popup?.IsOpen != true || !_row.IsLoaded || !Pointer(out var point)) { Close(); return; }
        if (_state.ShouldClose(SidebarHoverState.Contains(point.X, point.Y, Bounds(), _cardBounds), Environment.TickCount64)) Close();
    }
    private bool Pointer(out Point point)
    {
        point = default;
        if (App.CurrentWindow is not { } window || _row.XamlRoot is not { } root) return false;
        var hwnd = WindowNative.GetWindowHandle(window);
        if (GetForegroundWindow() != hwnd || !GetCursorPos(out var native) || !ScreenToClient(hwnd, ref native)) return false;
        var scale = root.RasterizationScale;
        point = new Point(native.X / scale, native.Y / scale);
        return true;
    }
    private void CancelPending() { _pending?.Cancel(); _pending?.Dispose(); _pending = null; }
    private void Close()
    {
        CancelPending(); _timer?.Stop(); _timer = null;
        if (_root is { } root)
        {
            root.RemoveHandler(UIElement.PointerPressedEvent, _pressed);
            root.RemoveHandler(UIElement.PointerWheelChangedEvent, _wheel);
            root.RemoveHandler(UIElement.KeyDownEvent, _key);
            _root = null;
        }
        var popup = _popup; _popup = null;
        if (popup is not null) popup.IsOpen = false;
        _cardBounds = null; _state = new();
        if (ReferenceEquals(_active, this)) _active = null;
    }
    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X; public int Y; }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetCursorPos(out NativePoint point);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ScreenToClient(nint hwnd, ref NativePoint point);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
}
