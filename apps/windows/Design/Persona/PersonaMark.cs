// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Tokenstat.Design.Persona;

/// <summary>
/// The face of a conversation. Drawn, not drawn-by-someone: every persona gets
/// a character built from one number, so a new persona has a face the moment it
/// is named and there is no asset to ship, scale, or theme. It is one creature
/// in different moods rather than a set of icons: underneath is a soft body,
/// and moods push it rather than pose it. Motion stays inside a fixed frame,
/// so a transcript can pin to this seat while the character bounces inside it
/// without the row changing height.
/// </summary>
internal sealed class PersonaMark : Canvas
{
    private readonly PersonaEngine _engine;
    private readonly DispatcherTimer _timer = new();
    private readonly Stopwatch _clock = Stopwatch.StartNew();

    private ulong _seed;
    private double _size;
    private PersonaMood _state;

    public PersonaMark(ulong seed = 0, double size = 28, PersonaMood state = PersonaMood.Idle, bool pokeable = false)
    {
        _seed = seed;
        _size = size;
        _state = state;
        Pokeable = pokeable;
        _engine = new PersonaEngine(seed, state);
        Width = size;
        Height = size;
        AutomationProperties.SetAccessibilityView(this, AccessibilityView.Raw);
        _timer.Tick += (_, _) => Tick();
        Loaded += (_, _) => Start();
        Unloaded += (_, _) => Stop();
    }

    /// <summary>Stable per persona. Zero falls back to one settled look rather than an empty frame.</summary>
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
        }
    }

    public double Size
    {
        get => _size;
        set
        {
            _size = value;
            Width = value;
            Height = value;
        }
    }

    public PersonaMood State
    {
        get => _state;
        set
        {
            _state = value;
            _timer.Interval = TimeSpan.FromSeconds(1 / value.FrameRate());
        }
    }

    /// <summary>Whether a click shoves it. Off by default: a face beside a message is not a control.</summary>
    public bool Pokeable { get; set; }

    protected override void OnPointerPressed(PointerRoutedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (!Pokeable || _size <= 0)
        {
            return;
        }
        var at = e.GetCurrentPoint(this).Position;
        _engine.Poke(new PPoint(at.X / _size, at.Y / _size));
    }

    private void Start()
    {
        _timer.Interval = TimeSpan.FromSeconds(1 / _state.FrameRate());
        _timer.Start();
        Tick();
    }

    private void Stop() => _timer.Stop();

    private void Tick()
    {
        _engine.AdvanceTo(_clock.Elapsed.TotalSeconds, _state, Moving());
        PersonaRenderer.Draw(_engine, this, _size, _size);
    }

    /// <summary>
    /// Motion is off when the person asked for it to be. Then the engine
    /// presents the mood's resting pose rather than freezing mid-bounce.
    /// </summary>
    private static bool Moving()
    {
        try
        {
            return new Windows.UI.ViewManagement.UISettings().AnimationsEnabled;
        }
        catch (Exception)
        {
            return true;
        }
    }
}
