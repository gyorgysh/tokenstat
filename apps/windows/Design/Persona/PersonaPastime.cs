// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Tokenstat.Design.Persona;

/// <summary>
/// A character left to get on with something. Two places do not know what mood
/// to be in and must not hold a pose: an empty chat, where nobody has asked
/// for anything yet, and a long wait, where one loop starts to read as a hang.
/// So this picks. It holds a quiet mood for a while, does something for a
/// while, and goes back to quiet, with the length of each drawn fresh every
/// time. Nothing repeats the same activity twice in a row.
/// </summary>
internal sealed class PersonaPastime : Grid
{
    /// <summary>What a character has to choose from.</summary>
    internal enum Repertoire
    {
        /// <summary>
        /// Nobody has asked for anything. It reads, it plays, it bounces off
        /// the walls, and every so often it gives up and has a nap.
        /// </summary>
        Leisure,

        /// <summary>
        /// It is working on an answer. Turning it over on the spot, or walking
        /// the floor, which is the same thought in a different shape.
        /// </summary>
        Thought,
    }

    private readonly PersonaMark _mark = new(pokeable: true);
    private readonly Random _random = new();
    private CancellationTokenSource? _loop;

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
            _doing = value;
            _mark.State = Quiet(value);
        }
    }

    private void Start()
    {
        Stop();
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
        // An empty screen should be interesting the moment it appears, so
        // leisure opens on something. A wait must not: thought starts as
        // thinking because that is what is actually true, and anything else
        // would be the picture lying about the state of the turn.
        bool first = doing == Repertoire.Leisure;
        while (!token.IsCancellationRequested)
        {
            try
            {
                if (first)
                {
                    // A short beat, so the character is seen arriving rather
                    // than already mid-activity when the screen fades in.
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

                PersonaMood next;
                if (doing == Repertoire.Leisure && _random.NextDouble() < 0.12)
                {
                    next = PersonaMood.Sleeping;
                }
                else
                {
                    // Never the same thing twice running. One repeat is a
                    // coincidence to a person watching, two is a loop.
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
                _mark.State = Quiet(doing);
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

    /// <summary>How long it stays quiet before finding something to do.</summary>
    private static (double Lo, double Hi) QuietFor(Repertoire doing) =>
        doing == Repertoire.Leisure ? (2.6, 5.4) : (4.0, 7.5);

    /// <summary>
    /// How many tellings of an activity to sit through. Counted in the
    /// activity's own cycles rather than in seconds, so a five second story is
    /// not shown five times over and an eleven second one is not cut off
    /// before its point.
    /// </summary>
    private static (int Lo, int Hi) Tellings(Repertoire doing) =>
        doing == Repertoire.Leisure ? (1, 2) : (1, 1);

    /// <summary>
    /// The bounds a telling is clamped to, for a mood with no story of its own
    /// and for the very short ones.
    /// </summary>
    private static (double Lo, double Hi) BusyFor(Repertoire doing) =>
        doing == Repertoire.Leisure ? (5.5, 20.0) : (5.0, 11.0);

    /// <summary>
    /// How long to hold one activity: a whole number of its own tellings, kept
    /// inside the busy bounds so a three second story is not shown once and
    /// gone, and an eleven second one does not outstay itself.
    /// </summary>
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
            // No whole telling can fit the category's bounds. Keep the story
            // intact in preference to cutting its ending off.
            return story;
        }
        return story * _random.Next(least, most + 1);
    }

    private double RandomIn((double Lo, double Hi) range) =>
        range.Lo + _random.NextDouble() * (range.Hi - range.Lo);
}
