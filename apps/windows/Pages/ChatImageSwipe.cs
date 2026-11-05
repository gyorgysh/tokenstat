// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

/// <summary>One fitted-image swipe; a second contact belongs to native zoom.</summary>
internal sealed class ChatImageSwipe
{
    internal enum Start { Native, Observe, HandOff }
    private readonly HashSet<uint> _contacts = [];
    private uint? _pointer;
    private double _x, _y, _width;
    private int _revision;
    private bool _system, _manual, _nativeActive;

    internal Start Press(uint id, double x, double y, double zoom, double width, int revision, bool ready)
    {
        if (!_contacts.Add(id) || _system) return Start.Native;
        if (_contacts.Count > 1) {
            var result = _manual ? Start.HandOff : Start.Native;
            _system = true; _manual = false; _pointer = null;
            return result;
        }
        if (!ready || !Fitted(zoom) || !double.IsFinite(x) || !double.IsFinite(y)
            || !double.IsFinite(width) || width <= 0) return Start.Native;
        _pointer = id; _x = x; _y = y; _width = width; _revision = revision; _manual = true;
        return Start.Observe;
    }

    internal int Release(uint id, double x, double y, double zoom, int revision)
    {
        _contacts.Remove(id);
        var direction = 0;
        if (_pointer == id) {
            var dx = x - _x; var dy = y - _y;
            if (!_system && _contacts.Count == 0 && revision == _revision && Fitted(zoom)
                && double.IsFinite(dx) && double.IsFinite(dy)
                && Math.Abs(dx) >= Math.Clamp(_width * .15, 48, 120) && Math.Abs(dx) > Math.Abs(dy) * 1.25)
                direction = dx < 0 ? 1 : -1;
            _pointer = null;
        }
        // If releases reach us, the completed contact sequence can reset immediately.
        if (_contacts.Count == 0) Reset();
        return direction;
    }
    internal void Cancel(uint id)
    {
        if (_contacts.Remove(id)) _pointer = null;
        if (_contacts.Count == 0 && !_nativeActive) Reset();
    }
    internal void Invalidate() => _pointer = null;
    internal void NativeStarted()
    {
        // CancelDirectManipulations can finish an earlier system interaction
        // while a fitted swipe is starting. That must not cancel the swipe.
        if (_manual && _pointer.HasValue) return;
        _system = true; _manual = false; _nativeActive = true; _pointer = null;
    }
    internal bool NativeCompleted()
    {
        if (!_system) return false;
        Reset(); return true;
    }
    internal void NativeFailed()
    {
        _nativeActive = false;
        if (_contacts.Count == 0) Reset();
    }
    internal void Reset()
    {
        _contacts.Clear(); _pointer = null; _system = _manual = _nativeActive = false;
    }
    private static bool Fitted(double zoom) => double.IsFinite(zoom) && zoom > 0 && zoom <= 1.001;
}
