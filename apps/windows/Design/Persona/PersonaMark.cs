// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Tokenstat.Design.Persona;

internal sealed class PersonaMark : Canvas
{
    private readonly PersonaEngine _engine;
    private readonly PersonaScene _scene;
    private readonly DispatcherTimer _timer = new();
    private readonly Stopwatch _clock = Stopwatch.StartNew();

    private ulong _seed;
    private double _size;
    private PersonaMood _state;
    private Windows.UI.ViewManagement.UISettings? _settings;
    private bool _needsRedraw = true;
    private bool _wasMoving;
    private bool _inViewport = true;
    private double _startedAt;

    public PersonaMark(ulong seed = 0, double size = 28, PersonaMood state = PersonaMood.Idle, bool pokeable = false,
        double? settlesAfter = null)
    {
        SettlesAfter = settlesAfter;
        _seed = seed;
        _size = size;
        _state = state;
        Pokeable = pokeable;
        _engine = new PersonaEngine(seed, state);
        _scene = new PersonaScene(this);
        Width = size;
        Height = size;
        AutomationProperties.SetAccessibilityView(this, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        _timer.Tick += (_, _) => Tick();
        PointerPressed += OnPointerPressed;
        Loaded += (_, _) => Start();
        Unloaded += (_, _) => Stop();
        ActualThemeChanged += (_, _) =>
        {
            _needsRedraw = true;
            if (!_timer.IsEnabled && IsLoaded && _inViewport) Tick();
        };
        EffectiveViewportChanged += (_, args) =>
        {
            var viewport = args.EffectiveViewport;
            bool visible = viewport.Width > 0 && viewport.Height > 0
                && viewport.Right > 0 && viewport.Bottom > 0
                && viewport.Left < ActualWidth && viewport.Top < ActualHeight;
            if (_inViewport == visible) return;
            _inViewport = visible;
            _engine.SuspendClock();
            if (visible && IsLoaded) Start();
            else
            {
                _timer.Stop();
                _scene.ReleaseClips();
                _needsRedraw = true;
            }
        };
    }

    public ulong Seed
    {
        get => _seed;
        set
        {
            if (value == _seed)
            {
                return;
            }
            _seed = value;
            _engine.Reseed(value);
            _needsRedraw = true;
        }
    }

    public double Size
    {
        get => _size;
        set
        {
            _size = value;
            _needsRedraw = true;
            Width = value;
            Height = value;
        }
    }

    public PersonaMood State
    {
        get => _state;
        set
        {
            _needsRedraw |= _state != value;
            _state = value;
            _timer.Interval = FrameInterval;
        }
    }

    public bool Pokeable { get; set; }

    public double? SettlesAfter { get; set; }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!Pokeable || _size <= 0)
        {
            return;
        }
        var at = e.GetCurrentPoint(this).Position;
        _engine.Poke(new PPoint(at.X / _size, at.Y / _size));
    }

    private void Start()
    {
        if (!_inViewport) return;
        _timer.Interval = FrameInterval;
        _engine.SuspendClock();
        _startedAt = _clock.Elapsed.TotalSeconds;
        _timer.Start();
        Tick();
    }

    private void Stop()
    {
        _timer.Stop();
        _engine.SuspendClock();
        _scene.ReleaseClips();
        _needsRedraw = true;
    }

    private void Tick()
    {
        if (MainWindow.MotionSuspended || Visibility != Visibility.Visible)
        {
            _engine.SuspendClock();
            _timer.Interval = TimeSpan.FromMilliseconds(250);
            return;
        }
        if (SettlesAfter is { } settle && _clock.Elapsed.TotalSeconds - _startedAt > settle && !_needsRedraw)
        {
            _timer.Stop();
            _engine.SuspendClock();
            return;
        }
        bool moving = Moving();
        _timer.Interval = moving ? FrameInterval : TimeSpan.FromMilliseconds(250);
        if (!moving && !_wasMoving && !_needsRedraw)
        {
            return;
        }
        _engine.AdvanceTo(_clock.Elapsed.TotalSeconds, _state, moving);
        PersonaRenderer.Draw(_engine, _scene, _size, _size);
        _needsRedraw = false;
        _wasMoving = moving;
    }

    private TimeSpan FrameInterval => TimeSpan.FromSeconds(
        1 / Math.Min(_state.FrameRate(), _size <= 28 ? 30 : 60));

    internal bool MotionAllowed => IsLoaded && _inViewport && Visibility == Visibility.Visible
        && !MainWindow.MotionSuspended && Moving();

    private bool Moving()
    {
        try
        {
            return (_settings ??= new Windows.UI.ViewManagement.UISettings()).AnimationsEnabled;
        }
        catch (Exception)
        {
            return true;
        }
    }
}
