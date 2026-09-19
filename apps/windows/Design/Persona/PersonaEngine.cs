// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

namespace Tokenstat.Design.Persona;

/// <summary>
/// One character's living state: its body, its face, its clock. Time is
/// accumulated and spent in fixed steps. A frame that arrives late spends more
/// steps, up to a cap. A frame that arrives after the app was in the
/// background spends none, because a spring integrated across a two second gap
/// is a spring that leaves the frame.
/// </summary>
internal sealed class PersonaEngine
{
    /// <summary>
    /// The simulation's own step. Springs this stiff are stable well past it,
    /// and it divides evenly into both 60 and 120.
    /// </summary>
    private const double FixedStep = 1.0 / 120;

    /// <summary>
    /// The most real time one frame may spend. Beyond this the clock is simply
    /// skipped: catching up is never worth a visible lurch.
    /// </summary>
    private const double MaxFrame = 1.0 / 12;

    /// <summary>
    /// How long one mood takes to become another. Long enough that a newspaper
    /// has time to be put down and a game picked up, short enough that nobody
    /// waits through it. Both moods run for the whole of it.
    /// </summary>
    private const double ShiftDuration = 0.55;

    public PersonaSoftBody Body { get; private set; }

    public PersonaFacePose Face { get; private set; }

    public List<PersonaMote> Motes { get; } = new();

    public PersonaMood Mood { get; private set; }

    public PersonaTraits Traits { get; private set; }

    public ulong Seed { get; private set; }

    /// <summary>
    /// Seconds since this mood began. Every mood function reads this, so a
    /// mood always starts at its own beginning however long the app has run.
    /// </summary>
    public double Clock { get; private set; }

    /// <summary>
    /// The mood being left behind, still running on its own clock, and how
    /// much of it is left. One means the change just happened.
    /// </summary>
    private (PersonaMood Mood, double Clock)? _leaving;

    private double _shift;

    /// <summary>
    /// How soft a recent landing has left the body, one to zero. It decays on
    /// its own, so no mood has to remember to put the stiffness back.
    /// </summary>
    private double _softening;

    /// <summary>The ring-out after an impact, and the clock it runs on.</summary>
    private double _jiggle;

    private double _jiggleClock;

    /// <summary>
    /// Dust from recent landings. A fixed four, oldest overwritten, because a
    /// growing array in a per-frame path is a leak with a nice name.
    /// </summary>
    private readonly (double X, double Age, double Weight)[] _dust = new (double, double, double)[4];

    private int _dustCursor;

    private double? _lastTime;
    private double _pending;
    private double _blinkCountdown = 2.5;
    private double _blinkHold;
    private int _beatIndex;
    private int _launches;
    private ulong _random;
    private bool _started;

    public PersonaEngine(ulong seed, PersonaMood mood = PersonaMood.Idle)
    {
        Seed = seed;
        Mood = mood;
        Traits = new PersonaTraits(seed);
        Body = new PersonaSoftBody(lumps: Traits.Lumps);
        _random = seed == 0 ? 0x9E3779B97F4A7C15ul : seed;
        Face = mood.Face(0, Traits);
        _blinkCountdown = 1.4 + NextUnit() * 3.0;
        for (int i = 0; i < _dust.Length; i++)
        {
            _dust[i] = (PersonaStage.CentreX, 10, 0);
        }
    }

    /// <summary>Kinetic energy, for anything that wants to know whether this character has finished reacting.</summary>
    public double Energy => Body.Energy;

    /// <summary>
    /// Become a different character in the same seat. Changing the seed of a
    /// view that is already on screen must not throw away the motion the
    /// person is watching.
    /// </summary>
    public void Reseed(ulong seed)
    {
        if (seed == Seed)
        {
            return;
        }
        Seed = seed;
        Traits = new PersonaTraits(seed);
        _random = seed == 0 ? 0x9E3779B97F4A7C15ul : seed;
        Body = new PersonaSoftBody(lumps: Traits.Lumps);
        Settle();
        // A new face announces itself rather than appearing mid-breath.
        Body.Impulse(new PVector(0, -0.75));
        Body.Pulse(0.10);
    }

    /// <summary>
    /// Advance to a wall-clock instant in seconds and refresh everything the
    /// renderer reads. Safe to call with the same instant twice.
    /// </summary>
    public void AdvanceTo(double time, PersonaMood requested, bool moving)
    {
        if (requested != Mood)
        {
            Enter(requested);
        }

        if (!moving)
        {
            // Motion is off, or nobody is looking. Present the mood's resting
            // pose rather than freezing mid-bounce, which reads as a glitch.
            Settle();
            _lastTime = null;
            Refresh();
            return;
        }

        try
        {
            if (_lastTime is not double last)
            {
                if (!_started)
                {
                    _started = true;
                    Settle();
                    EnterImpulse(Mood);
                }
                Refresh();
                return;
            }

            double elapsed = time - last;
            if (elapsed <= 0)
            {
                Refresh();
                return;
            }
            _pending += Math.Min(elapsed, MaxFrame);

            while (_pending >= FixedStep)
            {
                _pending -= FixedStep;
                double previous = Clock;
                Clock += FixedStep;
                Step(previous, Clock);
            }
            Refresh();
        }
        finally
        {
            _lastTime = time;
        }
    }

    private void Step(double previous, double now)
    {
        FireEvents(previous, now);

        if (_shift > 0)
        {
            _shift = Math.Max(0, _shift - FixedStep / ShiftDuration);
            if (_leaving is { } leaving)
            {
                _leaving = (leaving.Mood, leaving.Clock + FixedStep);
            }
            if (_shift == 0)
            {
                _leaving = null;
            }
        }

        // While a mood is changing, both are asked what they want and the
        // answers are mixed. The body is never handed a new set of forces in
        // one frame, so it never has a moment where it visibly changes its
        // mind.
        var arriving = Mood.Drive(now, Traits);
        var arrivingFace = Mood.Face(now, Traits);
        PersonaDrive drive;
        PersonaFacePose target;
        if (_leaving is { } gone && _shift > 0)
        {
            double done = 1 - _shift;
            drive = PersonaDrive.Blend(gone.Mood.Drive(gone.Clock, Traits), arriving, done);
            target = PersonaFacePose.Blend(gone.Mood.Face(gone.Clock, Traits), arrivingFace, done);
        }
        else
        {
            drive = arriving;
            target = arrivingFace;
        }

        // What a landing left behind. Both decay on their own clock, so the
        // squash always comes back and no mood can leave the body permanently
        // slack by forgetting to tidy up after itself.
        if (_softening > 0 || _jiggle > 0)
        {
            _softening = Math.Max(0, _softening - FixedStep / 0.24);
            _jiggle = Math.Max(0, _jiggle - FixedStep / 0.55);
            _jiggleClock += FixedStep;
            double eased = _softening * _softening;
            drive.ShapeStiffness *= 1 - 0.38 * eased;
            drive.Pressure *= 1 - 0.20 * eased;
            drive.Damping *= 1 - 0.22 * eased;
            drive.Jiggle += _jiggle * _jiggle * 0.55;
            drive.JigglePhase = _jiggleClock * 5.2;
        }

        Body.Step(FixedStep, drive);
        AbsorbLanding();
        // The face eases toward the mood's pose rather than being set to it,
        // which is what makes a change of mood read as an expression moving.
        Face.EaseTowards(target, FixedStep * 11);
        AdvanceBlink(FixedStep);
    }

    /// <summary>
    /// Turn a landing into a splat. The floor reports how hard the body
    /// arrived. Everything a landing looks like is bought here, once, for
    /// every mood: the body goes briefly slack so the squash lingers past the
    /// bounce, a wave rings round the rim, and the ground puffs.
    /// </summary>
    private void AbsorbLanding()
    {
        for (int i = 0; i < _dust.Length; i++)
        {
            _dust[i] = (_dust[i].X, _dust[i].Age + FixedStep, _dust[i].Weight);
        }
        var hit = Body.TakeImpact();
        if (hit is not { } landed || landed.Speed <= 0.32)
        {
            return;
        }
        double force = Math.Min(1, (landed.Speed - 0.32) / 1.5);
        // The hardest recent landing, not the sum of them. Adding meant a
        // dancing character saturated inside two bars and stayed a slack bag
        // for the rest of the song.
        _softening = Math.Max(_softening, force);
        _jiggle = Math.Max(_jiggle, force);
        _jiggleClock = 0;
        if (force <= 0.18)
        {
            return;
        }
        _dust[_dustCursor] = (landed.X, 0, force);
        _dustCursor = (_dustCursor + 1) % _dust.Length;
    }

    /// <summary>
    /// Everything the renderer reads that is not integrated: the motes and the
    /// dust. Mid-change, both moods put their things in the air at once. The
    /// old ones shrink away and the new ones grow in.
    /// </summary>
    private void Refresh()
    {
        Motes.Clear();
        var anchors = Body.Anchors;
        if (_leaving is { } gone && _shift > 0)
        {
            int start = Motes.Count;
            gone.Mood.Motes(gone.Clock, Traits, anchors, Motes);
            Fade(start, Eased(Ramp((_shift - 0.35) / 0.65)));
        }
        int fresh = Motes.Count;
        Mood.Motes(Clock, Traits, anchors, Motes);
        if (_shift > 0)
        {
            Fade(fresh, Eased(Ramp((0.65 - _shift) / 0.65)));
        }
        AddDust();
    }

    /// <summary>
    /// The ground answering back. Two puffs per landing, thrown outwards from
    /// where the body actually hit rather than from the middle of the frame.
    /// </summary>
    private void AddDust()
    {
        foreach (var grain in _dust)
        {
            if (grain.Age >= 0.46)
            {
                continue;
            }
            double life = grain.Age / 0.46;
            foreach (double side in new double[] { -1, 1 })
            {
                Motes.Add(new PersonaMote(
                    PersonaMote.Kind.Puff,
                    new PPoint(
                        grain.X + side * (0.03 + life * 0.11) * grain.Weight,
                        PersonaStage.Floor - 0.012 - life * life * 0.045),
                    (0.34 + life * 0.62) * grain.Weight,
                    (1 - life) * (1 - life) * 0.42 * grain.Weight));
            }
        }
    }

    /// <summary>
    /// Zero to one, clamped. The two props overlap only in the middle third of
    /// a shift: the old one is most of the way gone before the new one is
    /// really there.
    /// </summary>
    private static double Ramp(double value) => Math.Clamp(value, 0, 1);

    /// <summary>
    /// Take a prop down to nothing, or bring it up from nothing. It shrinks as
    /// well as fades, because something set down moves away from the hands.
    /// </summary>
    private void Fade(int start, double amount)
    {
        for (int i = start; i < Motes.Count; i++)
        {
            Motes[i].Opacity *= amount;
            Motes[i].Scale *= 0.62 + 0.38 * amount;
        }
    }

    /// <summary>Smoothstep. A linear crossfade has a corner at each end and the eye finds both of them.</summary>
    private static double Eased(double value)
    {
        double t = Math.Clamp(value, 0, 1);
        return t * t * (3 - 2 * t);
    }

    private void Enter(PersonaMood next)
    {
        // Keep the old mood alive for half a second while the new one takes
        // over, and blink on the way through. A blink over a change is the
        // oldest trick in animation: the eye forgives almost anything that
        // happens behind one.
        _leaving = (Mood, Clock);
        _shift = 1;
        _blinkHold = 0.13;
        // A gather. The body dips and springs back, which is the beat that
        // makes the change look like a decision rather than an edit.
        Body.Pulse(-0.13);

        Mood = next;
        Clock = 0;
        _beatIndex = 0;
        _launches = 0;
        EnterImpulse(next);
    }

    /// <summary>
    /// The kick a mood arrives with. Without one, a change of mood is a change
    /// of forces, and forces take time to show. With one, the character reacts
    /// on the frame the news arrives.
    /// </summary>
    private void EnterImpulse(PersonaMood mood)
    {
        switch (mood)
        {
            case PersonaMood.Idle:
                break;
            case PersonaMood.Bouncing:
                Body.Impulse(new PVector(0, -1.15));
                break;
            case PersonaMood.Thinking:
                Body.Pulse(-0.09);
                break;
            case PersonaMood.Working:
                Body.Impulse(new PVector(0, -0.42));
                break;
            case PersonaMood.Speaking:
                Body.Pulse(0.06);
                break;
            case PersonaMood.Juggling:
                Body.Impulse(new PVector(0, -0.20));
                break;
            case PersonaMood.Dancing:
                Body.Impulse(new PVector(0, -0.45));
                break;
            case PersonaMood.Waiting:
                Body.Impulse(new PVector(0, -0.28));
                Body.Pulse(0.05);
                break;
            case PersonaMood.Ok:
                Body.Impulse(new PVector(0, -1.30));
                Body.Pulse(0.24);
                break;
            case PersonaMood.Failed:
                Body.Impulse(new PVector(0.55, 0));
                break;
            case PersonaMood.Sleeping:
                Body.Slump(0.55);
                break;
            case PersonaMood.Reading:
                Body.Pulse(-0.05);
                break;
            case PersonaMood.Gaming:
                Body.Impulse(new PVector(0, -0.22));
                break;
            case PersonaMood.Pacing:
                Body.Impulse(new PVector(-0.18, -0.30));
                break;
            case PersonaMood.Typing:
                Body.Impulse(new PVector(0, -0.16));
                break;
            case PersonaMood.Sipping:
                Body.Pulse(-0.04);
                break;
            case PersonaMood.Sketching:
                Body.Pulse(-0.04);
                break;
            case PersonaMood.Stargazing:
                Body.Pulse(0.04);
                break;
            case PersonaMood.Gardening:
                Body.Impulse(new PVector(-0.10, -0.14));
                break;
            case PersonaMood.Bubbling:
                Body.Pulse(0.05);
                break;
            case PersonaMood.Snacking:
                Body.Pulse(-0.05);
                break;
        }
    }

    /// <summary>
    /// Discrete beats. Everything continuous is a force in the mood; this is
    /// only what has to happen at an instant, which is what a hop, a beat and
    /// a bounce are. Anticipation lives here too: a jump with a crouch an
    /// eighth of a second earlier reads as a decision, and the crouch is one
    /// extra call.
    /// </summary>
    private void FireEvents(double previous, double now)
    {
        switch (Mood)
        {
            case PersonaMood.Bouncing:
                // Re-kick once it has run out of bounce, rather than on a
                // timer, so the rhythm comes from the physics. Down, and no
                // longer going anywhere. Measured on the body's travel rather
                // than its total energy, because a slack blob quivering on the
                // floor has plenty of the second kind and would never be
                // kicked again.
                bool low = Body.Centroid.Y > PersonaStage.Floor - PersonaStage.RestRadius * 1.12;
                if (low && Math.Abs(Body.Momentum.Y) < 0.14)
                {
                    _launches += 1;
                    double side = _launches % 2 == 0 ? 1 : -1;
                    Body.Impulse(new PVector(side * 0.34, -1.45));
                    Body.Pulse(-0.10);
                }
                break;

            case PersonaMood.Working:
                if (PersonaMoodTiming.WorkAdmire(now) >= 0.02)
                {
                    break;
                }
                // The blow, and the body arriving behind it. A hammer that
                // lands without the shoulder following through is being waved.
                if (Crossed(PersonaMoodTiming.BlowPeriod, previous + 0.07, now + 0.07))
                {
                    Body.Pulse(-0.06);
                }
                if (Struck(PersonaMoodTiming.BlowPeriod, 0.93, previous, now))
                {
                    Body.Impulse(new PVector(0.10, 0.34));
                    Body.Poke(Body.Anchors.Hands, -0.42, 0.30);
                }
                break;

            case PersonaMood.Dancing:
                if (Crossed(PersonaMoodTiming.BeatPeriod, previous + 0.10, now + 0.10))
                {
                    Body.Pulse(-0.06);
                }
                if (Crossed(PersonaMoodTiming.BeatPeriod, previous, now))
                {
                    _beatIndex += 1;
                    bool accent = _beatIndex % 4 == 0;
                    Body.Impulse(new PVector(0, accent ? -0.34 : -0.15));
                    Body.Pulse(accent ? 0.07 : -0.04);
                }
                break;

            case PersonaMood.Juggling:
                if (Crossed(PersonaMoodTiming.RallyPeriod, previous, now))
                {
                    // The ball lands on the crown at the seam between two
                    // arcs, and the wild one lands harder because it fell
                    // further.
                    bool wild = (int)Math.Floor(now / PersonaMoodTiming.RallyPeriod) % 4 == 0;
                    Body.Poke(Body.Crown, wild ? -1.25 : -0.85, 0.26);
                    Body.Impulse(new PVector(0, wild ? 0.34 : 0.22));
                }
                break;

            case PersonaMood.Waiting:
                if (Crossed(1.2, previous, now))
                {
                    Body.Impulse(new PVector(0, 0.46));
                }
                if (Struck(5.6, 0.70, previous, now))
                {
                    Body.Pulse(-0.11);
                }
                break;

            case PersonaMood.Failed:
                // A shake it cannot absorb, then it stops fighting.
                if (now < 0.34 && Crossed(0.085, previous, now))
                {
                    double side = (int)(previous / 0.085) % 2 == 0 ? -1 : 1;
                    Body.Impulse(new PVector(side * 1.05, 0));
                }
                if (Crossed(0.34, previous, now))
                {
                    Body.Slump(0.85);
                }
                // It has another go every few seconds, gets a third of the way
                // up, and gives that up as well.
                if (now > 1.5 && Struck(4.4, 0.55, previous - 1.5, now - 1.5))
                {
                    Body.Impulse(new PVector(0, -0.62));
                }
                if (now > 1.5 && Struck(4.4, 0.80, previous - 1.5, now - 1.5))
                {
                    Body.Slump(0.45);
                }
                break;

            case PersonaMood.Idle:
                // A shift of weight, so a resting character is not a loop.
                if (Crossed(5.4, previous, now))
                {
                    double side = NextUnit() > 0.5 ? 1 : -1;
                    Body.Impulse(new PVector(side * 0.12, -0.10));
                }
                if (Struck(11.5, 0.62, previous, now))
                {
                    Body.Impulse(new PVector(0, -0.30));
                }
                break;

            case PersonaMood.Thinking:
                // The idea arrives as a jolt. It is the one moment in this
                // mood that is not churn, so it has to land like one.
                if (Struck(7.2, 0.84, previous, now))
                {
                    Body.Impulse(new PVector(0, -0.80));
                    Body.Pulse(0.18);
                }
                break;

            case PersonaMood.Gaming:
            {
                var round = PersonaMoodTiming.GamingRound(now);
                if (round.Win > 0.6 && Struck(PersonaMoodTiming.GamePeriod, 0.078, previous, now))
                {
                    Body.Impulse(new PVector(0, -0.95));
                    Body.Pulse(0.13);
                }
                else if (round.Loss > 0.6 && Struck(PersonaMoodTiming.GamePeriod, 0.578, previous, now))
                {
                    Body.Slump(0.55);
                }
                else if (Crossed(0.26, previous, now))
                {
                    Body.Poke(Body.Anchors.Hands, -0.13, 0.20);
                }
                break;
            }

            case PersonaMood.Pacing:
                if (PersonaMoodTiming.PacingIdea(now) < 0.25)
                {
                    // A footfall, and a heavier one at each turn where it
                    // plants and pushes off the other way.
                    if (Crossed(0.42, previous, now))
                    {
                        Body.Impulse(new PVector(0, -0.32));
                    }
                    if (Crossed(PersonaMoodTiming.StridePeriod, previous, now))
                    {
                        Body.Impulse(new PVector(0, -0.44));
                        Body.Pulse(-0.07);
                    }
                }
                if (Struck(PersonaMoodTiming.PaceThinkPeriod, 0.78, previous, now))
                {
                    Body.Impulse(new PVector(0, -0.50));
                    Body.Pulse(0.14);
                }
                break;

            case PersonaMood.Typing:
            {
                // Keystrokes, not hops. A small local knock at the hands for
                // each one, fast and uneven.
                var keys = PersonaMoodTiming.Typing(now);
                if (keys.Tap > 0.5 && Crossed(0.078, previous, now))
                {
                    Body.Poke(Body.Anchors.Hands, -0.20, 0.22);
                    Body.Impulse(new PVector(0, -0.05));
                }
                if (Struck(PersonaMoodTiming.TypePeriod, 0.90, previous, now))
                {
                    Body.Impulse(new PVector(0, -0.34));
                    Body.Pulse(0.08);
                }
                break;
            }

            case PersonaMood.Gardening:
                if (PersonaMoodTiming.Garden(now).Joy < 0.3 && Crossed(1.15, previous, now))
                {
                    Body.Impulse(new PVector(-0.04, -0.16));
                    Body.Poke(Body.Anchors.Hands, -0.12, 0.20);
                }
                if (Struck(11.2, 0.70, previous, now))
                {
                    Body.Impulse(new PVector(0, -0.85));
                    Body.Pulse(0.14);
                }
                break;

            case PersonaMood.Reading:
                // Something on the page. The body has to move for it, or the
                // face is reacting to nothing.
                if (Struck(8.4, 0.66, previous, now))
                {
                    if (PersonaMoodTiming.ReadingGag(now).Shock > 0)
                    {
                        Body.Impulse(new PVector(0, -0.70));
                        Body.Pulse(0.16);
                    }
                    else
                    {
                        Body.Pulse(-0.12);
                    }
                }
                break;

            case PersonaMood.Sipping:
                // Hot. The whole body finds out at once.
                if (Struck(PersonaMoodTiming.TeaPeriod, 0.30, previous, now))
                {
                    Body.Impulse(new PVector(0, -0.55));
                    Body.Poke(Body.Anchors.Mouth, -0.55, 0.28);
                }
                break;

            case PersonaMood.Sketching:
                // A small knock at each end of the sweep, where the hand
                // changes direction. That is the only impulse a brush stroke
                // has in it.
                if (PersonaMoodTiming.Sketch(now).Look < 0.25 && Crossed(0.725, previous, now))
                {
                    Body.Poke(Body.Anchors.Hands, -0.16, 0.24);
                }
                break;

            case PersonaMood.Stargazing:
                if (Struck(9.4, 0.40, previous, now))
                {
                    Body.Impulse(new PVector(0, -0.34));
                    Body.Pulse(0.09);
                }
                break;

            case PersonaMood.Sleeping:
                // A twitch, in the middle of a good dream.
                if (Struck(13.0, 0.62, previous, now))
                {
                    Body.Poke(Body.Crown, -0.22, 0.28);
                }
                break;

            case PersonaMood.Ok:
                // Once is a result. Twice is a celebration.
                if (now < 0.7 && Crossed(0.62, previous, now))
                {
                    Body.Impulse(new PVector(0, -0.72));
                    Body.Pulse(0.10);
                }
                break;

            case PersonaMood.Bubbling:
                if (Struck(5.4, 0.60, previous, now))
                {
                    // It knew. It has always known. It is surprised anyway.
                    Body.Poke(Body.Anchors.Mouth, -0.95, 0.34);
                    Body.Impulse(new PVector(-0.30, -0.18));
                    _blinkHold = 0.12;
                }
                break;

            case PersonaMood.Snacking:
                foreach (double start in new double[] { 0.10, 0.32, 0.54 })
                {
                    if (Struck(7.6, start, previous, now))
                    {
                        Body.Impulse(new PVector(-0.22, -0.20));
                        Body.Poke(Body.Anchors.Mouth, -0.30, 0.26);
                    }
                }
                if (Struck(7.6, 0.80, previous, now))
                {
                    Body.Impulse(new PVector(0, -0.40));
                    Body.Pulse(0.10);
                }
                break;

            case PersonaMood.Speaking:
                break;
        }
    }

    /// <summary>
    /// Poke the character. A real, local hit at a point in unit space, so a
    /// click on its left side pushes its left side.
    /// </summary>
    public void Poke(PPoint point)
    {
        Body.Poke(point, 0.85, 0.30);
        _blinkCountdown = Math.Min(_blinkCountdown, 0.12);
    }

    private void AdvanceBlink(double dt)
    {
        if (_blinkHold > 0)
        {
            _blinkHold -= dt;
            if (_blinkHold <= 0)
            {
                _blinkCountdown = 2.2 + NextUnit() * 3.4;
            }
            return;
        }
        if (!Face.Blinks)
        {
            return;
        }
        _blinkCountdown -= dt;
        if (_blinkCountdown <= 0)
        {
            _blinkHold = 0.10;
        }
    }

    /// <summary>How shut the eyes are from blinking alone, zero to one.</summary>
    public double Blink
    {
        get
        {
            if (_blinkHold <= 0)
            {
                return 0;
            }
            // Fast down, slower up: a real blink is not symmetric. The hold
            // may be longer than the down phase, so the progress clamps to the
            // start of the cycle.
            double progress = Math.Clamp(1 - _blinkHold / 0.10, 0, 1);
            return progress < 0.35 ? progress / 0.35 : Math.Max(0, 1 - (progress - 0.35) / 0.65);
        }
    }

    /// <summary>
    /// Put the body at the mood's resting shape with no motion in it. Used on
    /// the first frame, and whenever motion is off.
    /// </summary>
    private void Settle()
    {
        _leaving = null;
        _shift = 0;
        var drive = Mood.Drive(0, Traits);
        var centre = new PPoint(
            drive.AnchorX,
            PersonaStage.Floor - drive.Radius * drive.Stretch.Height);
        Body.Reset(centre, drive.Stretch, drive.Radius);
        Face = Mood.Face(0, Traits);
        _blinkHold = 0;
        _pending = 0;
        _softening = 0;
        _jiggle = 0;
        for (int i = 0; i < _dust.Length; i++)
        {
            _dust[i] = (_dust[i].X, 10, _dust[i].Weight);
        }
    }

    private static bool Crossed(double period, double previous, double now) =>
        Math.Floor(previous / period) != Math.Floor(now / period);

    /// <summary>
    /// Once per cycle, at a given phase of it. The same shift a mood applies
    /// when it works out where in its own story it is, so an impulse lands on
    /// the frame the face is already reacting.
    /// </summary>
    private static bool Struck(double period, double at, double previous, double now) =>
        Crossed(period, previous - at * period, now - at * period);

    /// <summary>
    /// xorshift, so a blink pattern is this persona's own and the same on
    /// every machine. Not security, just variety.
    /// </summary>
    private double NextUnit()
    {
        _random ^= _random << 13;
        _random ^= _random >> 7;
        _random ^= _random << 17;
        return (_random % 10_000) / 10_000.0;
    }
}
