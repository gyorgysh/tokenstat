// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Tokenstat.Design.Persona;

internal sealed class PersonaPastime : Grid
{
    internal enum Repertoire
    {
        Leisure,

        Thought,
    }

    private readonly PersonaMark _mark = new(pokeable: true);
    private readonly Random _random = new();
    private CancellationTokenSource? _loop;
    private bool _inViewport = true;

    private ulong _seed;
    private double _size = 40;
    private Repertoire _doing = Repertoire.Leisure;

    public PersonaPastime(ulong seed = 0, double size = 40, Repertoire doing = Repertoire.Leisure)
    {
        _seed = seed;
        _size = size;
        _doing = doing;
        _mark.Seed = seed;
        _mark.Size = size;
        _mark.State = Quiet(doing);
        Children.Add(_mark);
        Loaded += (_, _) => Start();
        Unloaded += (_, _) => Stop();
        EffectiveViewportChanged += (_, args) =>
        {
            var viewport = args.EffectiveViewport;
            bool visible = viewport.Width > 0 && viewport.Height > 0
                && viewport.Right > 0 && viewport.Bottom > 0
                && viewport.Left < ActualWidth && viewport.Top < ActualHeight;
            if (_inViewport == visible) return;
            _inViewport = visible;
            if (visible && IsLoaded) Start();
            else Stop();
        };
    }

    public ulong Seed
    {
        get => _seed;
        set
        {
            _seed = value;
            _mark.Seed = value;
        }
    }

    public double Size
    {
        get => _size;
        set
        {
            _size = value;
            _mark.Size = value;
        }
    }

    public Repertoire Doing
    {
        get => _doing;
        set
        {
            if (_doing == value) return;
            _doing = value;
            _mark.State = Quiet(value);
            if (IsLoaded) Start();
        }
    }

    private void Start()
    {
        Stop();
        if (!_inViewport) return;
        _loop = new CancellationTokenSource();
        _ = LiveAsync(_loop.Token);
    }

    private void Stop()
    {
        _loop?.Cancel();
        _loop?.Dispose();
        _loop = null;
    }

    private async Task LiveAsync(CancellationToken token)
    {
        var doing = _doing;
        _mark.State = Quiet(doing);
        PersonaMood? last = null;
        bool first = doing == Repertoire.Leisure;
        while (!token.IsCancellationRequested)
        {
            try
            {
                if (first)
                {
                    first = false;
                    await Task.Delay(TimeSpan.FromMilliseconds(700), token);
                }
                else
                {
                    await Task.Delay(TimeSpan.FromSeconds(RandomIn(QuietFor(doing))), token);
                }
                if (token.IsCancellationRequested)
                {
                    return;
                }

                if (!_mark.MotionAllowed) continue;

                PersonaMood next;
                if (doing == Repertoire.Leisure && _random.NextDouble() < 0.12)
                {
                    next = PersonaMood.Sleeping;
                }
                else
                {
                    var choices = Activities(doing).Where(m => m != last).ToList();
                    next = choices.Count > 0 ? choices[_random.Next(choices.Count)] : Quiet(doing);
                }
                last = next;
                _mark.State = next;

                double span = next == PersonaMood.Sleeping
                    ? 7 + _random.NextDouble() * 7
                    : Span(doing, next);
                await Task.Delay(TimeSpan.FromSeconds(span), token);
                if (token.IsCancellationRequested)
                {
                    return;
                }
                if (_mark.MotionAllowed) _mark.State = Quiet(doing);
            }
            catch (TaskCanceledException)
            {
                return;
            }
        }
    }

    private static PersonaMood Quiet(Repertoire doing) =>
        doing == Repertoire.Leisure ? PersonaMood.Idle : PersonaMood.Thinking;

    private static PersonaMood[] Activities(Repertoire doing) =>
        doing == Repertoire.Leisure
            ? [
                PersonaMood.Bouncing, PersonaMood.Reading, PersonaMood.Gaming,
                PersonaMood.Dancing, PersonaMood.Juggling, PersonaMood.Pacing,
                PersonaMood.Typing, PersonaMood.Sipping, PersonaMood.Sketching,
                PersonaMood.Stargazing, PersonaMood.Gardening, PersonaMood.Bubbling,
                PersonaMood.Snacking,
            ]
            : [PersonaMood.Pacing, PersonaMood.Thinking];

    private static (double Lo, double Hi) QuietFor(Repertoire doing) =>
        doing == Repertoire.Leisure ? (2.6, 5.4) : (1.2, 2.4);

    private static (int Lo, int Hi) Tellings(Repertoire doing) =>
        doing == Repertoire.Leisure ? (1, 2) : (1, 1);

    private static (double Lo, double Hi) BusyFor(Repertoire doing) =>
        doing == Repertoire.Leisure ? (5.5, 20.0) : (5.0, 11.0);

    private double Span(Repertoire doing, PersonaMood mood)
    {
        double story = mood.StoryLength();
        var busy = BusyFor(doing);
        if (story <= 0)
        {
            return RandomIn(busy);
        }
        var tellings = Tellings(doing);
        int least = Math.Max(tellings.Lo, (int)Math.Ceiling(busy.Lo / story));
        int most = Math.Min(tellings.Hi, (int)Math.Floor(busy.Hi / story));
        if (least > most)
        {
            return story;
        }
        return story * _random.Next(least, most + 1);
    }

    private double RandomIn((double Lo, double Hi) range) =>
        range.Lo + _random.NextDouble() * (range.Hi - range.Lo);
}
