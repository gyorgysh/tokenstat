// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

namespace Tokenstat.Design.Persona;

/// <summary>
/// How a mood shapes its cycle. Every activity is a story, not a loop: an
/// idea arrives, the tea is too hot, the bubble pops. Beat and ramp are how
/// those are written, and StalledClock is how a character stops doing one
/// thing long enough to react to another.
/// </summary>
internal static class PersonaMoodTiming
{
    /// <summary>Where we are in a repeating cycle, zero to one.</summary>
    public static double Phase(double clock, double period) => (clock % period) / period;

    /// <summary>
    /// A single rise and fall inside a window of a cycle: zero outside it, one
    /// at the middle of it. Every gag is one of these.
    /// </summary>
    public static double Beat(double phase, double from, double to)
    {
        if (phase <= from || phase >= to)
        {
            return 0;
        }
        return Math.Sin((phase - from) / (to - from) * Math.PI);
    }

    /// <summary>
    /// Zero before a window and one after it, eased across. For anything that
    /// happens once and stays happened, like a sprout growing.
    /// </summary>
    public static double Ramp(double phase, double from, double to)
    {
        double t = Math.Clamp((phase - from) / Math.Max(to - from, 1e-4), 0, 1);
        return t * t * (3 - 2 * t);
    }

    /// <summary>
    /// A clock that stops inside a window of its own cycle and carries on
    /// afterwards from where it stopped. This is what lets a character stop
    /// walking to have a thought without drifting backwards or cutting to a
    /// held pose.
    /// </summary>
    public static double StalledClock(double clock, double period, double from, double to)
    {
        double cycles = Math.Floor(clock / period);
        double inside = clock - cycles * period;
        double start = from * period;
        double stop = to * period;
        double held = stop - start;
        return cycles * (period - held) + Math.Min(inside, start) + Math.Max(0, inside - stop);
    }

    /// <summary>One hit to the next, in the rally.</summary>
    public const double RallyPeriod = 0.78;

    /// <summary>125bpm. Fast enough to read as a beat at small sizes, slow enough not to buzz.</summary>
    public const double BeatPeriod = 0.48;

    /// <summary>One length of the floor, there or back.</summary>
    public const double StridePeriod = 2.6;

    /// <summary>
    /// Where a pacing character is and which way it is going. A cosine rather
    /// than a triangle wave, so it slows into each turn and speeds up across
    /// the middle.
    /// </summary>
    public static (double X, double Direction) PacingWalk(double clock)
    {
        double turn = clock * Math.PI / StridePeriod;
        return (PersonaStage.CentreX - Math.Cos(turn) * 0.175, Math.Sin(turn) > 0 ? 1 : -1);
    }

    /// <summary>The pacing cycle: it walks, and once every nine seconds it stops dead because it has worked something out.</summary>
    public const double PaceThinkPeriod = 9.1;

    public static double PacingClock(double clock) =>
        StalledClock(clock, PaceThinkPeriod, 0.72, 0.88);

    public static double PacingIdea(double clock) =>
        Beat(Phase(clock, PaceThinkPeriod), 0.72, 0.90);

    /// <summary>
    /// One nail, in four blows, and then a moment of being pleased about it.
    /// Lift is how far back the hammer is drawn, strike is the blow landing,
    /// sunk is how much of the nail is left showing. The swing has to be slow
    /// going up and fast coming down or it reads as a vibration.
    /// </summary>
    public const double NailPeriod = 4.2;

    public const double BlowPeriod = 0.66;

    public static (double Lift, double Strike, double Sunk, double Admire) Hammering(double clock)
    {
        double cycle = Phase(clock, NailPeriod);
        double admire = Beat(cycle, 0.66, 0.94);
        if (admire >= 0.02)
        {
            return (0, 0, 1, admire);
        }
        double blows = Math.Floor(cycle * NailPeriod / BlowPeriod);
        double swing = Phase(clock, BlowPeriod);
        // Three quarters of the beat drawing back, a quarter coming down.
        double lift = swing < 0.74 ? Ramp(swing, 0, 0.74) : 1 - Ramp(swing, 0.74, 1);
        return (lift, Beat(swing, 0.86, 1.0), Math.Min(1, blows / 4), 0);
    }

    /// <summary>Down tools, look at the work.</summary>
    public static double WorkAdmire(double clock) => Hammering(clock).Admire;

    /// <summary>The thought lands. Rare enough to be worth waiting for, short enough to be over before it can become a pose.</summary>
    public static double ThinkingIdea(double clock) => Beat(Phase(clock, 7.2), 0.80, 0.97);

    /// <summary>The long slow breath out of somebody who has been waiting a while.</summary>
    public static double WaitingSigh(double clock) => Beat(Phase(clock, 5.6), 0.70, 0.92);

    /// <summary>A puddle that keeps trying to stand back up, every four and a bit seconds, and cannot.</summary>
    public static double FailedRetry(double clock)
    {
        if (clock <= 1.5)
        {
            return 0;
        }
        return Beat(Phase(clock - 1.5, 4.4), 0.55, 0.80);
    }

    /// <summary>Typing: bursts of keys, a pause where it reconsiders, and a small nod at whatever it decided.</summary>
    public const double TypePeriod = 6.4;

    public static (double Tap, double Lit, double Pause, double Nod) Typing(double clock)
    {
        double cycle = Phase(clock, TypePeriod);
        double pause = Ramp(cycle, 0.62, 0.70) * (1 - Ramp(cycle, 0.84, 0.90));
        double nod = Beat(cycle, 0.88, 0.99);
        // Two rates against each other, so the patter is uneven the way real
        // typing is rather than a drum roll.
        double patter = Math.Max(0, Math.Sin(clock * 2 * Math.PI * 6.4))
            * (0.7 + 0.3 * Math.Sin(clock * 2 * Math.PI * 1.7));
        return (patter * (1 - pause) * (1 - nod), Phase(clock, 0.37), pause, nod);
    }

    /// <summary>A cup of tea, drunk properly: lift, small sip, down, and a while of being warm about it. Twice a cycle.</summary>
    public const double TeaPeriod = 7.4;

    public static (double Lift, double Warm) Tea(double clock)
    {
        double phase = Phase(clock, TeaPeriod);
        return (
            Math.Max(Beat(phase, 0.10, 0.30), Beat(phase, 0.40, 0.60)),
            Beat(phase, 0.62, 0.98));
    }

    /// <summary>
    /// A round of the game, won or lost, alternating. Losing needs to be in
    /// here as much as winning: a character that only ever wins is a trophy.
    /// </summary>
    public const double GamePeriod = 10.4;

    public static (double Win, double Loss) GamingRound(double clock)
    {
        double period = GamePeriod / 2;
        int round = (int)Math.Floor((clock + 2.6) / period);
        double evt = Beat(Phase(clock + 2.6, period), 0.55, 0.76);
        return round % 2 == 0 ? (evt, 0) : (0, evt);
    }

    /// <summary>
    /// The brush going back and forth across the sheet, and now and then a
    /// pause to look at what it has done. Sweep is minus one to one across the
    /// paper, a cosine so the brush slows at each end and lifts.
    /// </summary>
    public const double SketchPeriod = 8.6;

    public static double SketchSweep(double clock) => -Math.Cos(clock * 2 * Math.PI / 1.45);

    public static (double Clock, double Sweep, double Look) Sketch(double clock)
    {
        double cycle = Phase(clock, SketchPeriod);
        double held = StalledClock(clock, SketchPeriod, 0.74, 0.94);
        return (held, SketchSweep(held), Beat(cycle, 0.74, 0.96));
    }

    /// <summary>Something crosses the sky, it gasps, and then it makes a wish, which is the correct order of operations.</summary>
    public static (double Crossing, double StarX, double Gasp, double Wish) Sky(double clock)
    {
        const double period = 9.4;
        double phase = Phase(clock, period);
        double crossing = phase > 0.30 && phase < 0.52 ? (phase - 0.30) / 0.22 : 0;
        return (crossing, -0.34 + crossing * 0.68, Beat(phase, 0.34, 0.56), Beat(phase, 0.62, 0.94));
    }

    /// <summary>
    /// One sprout, grown and then flowered. The whole cycle is the point: a
    /// plant that is always the same size is a decoration.
    /// </summary>
    public static (double Growth, double Bloom, double Joy) Garden(double clock)
    {
        const double period = 11.2;
        double phase = Phase(clock, period);
        return (
            Ramp(phase, 0.04, 0.62),
            Ramp(phase, 0.64, 0.74) * (1 - Ramp(phase, 0.94, 0.99)),
            Beat(phase, 0.66, 0.92));
    }

    /// <summary>Blow, blow, blow, pop, be surprised, pretend that was the plan.</summary>
    public static (double Size, double Blow, double Pop, double Sheepish) Bubble(double clock)
    {
        const double period = 5.4;
        double phase = Phase(clock, period);
        double growing = Ramp(phase, 0.12, 0.60);
        return (
            growing * (1 - Ramp(phase, 0.60, 0.615)),
            Beat(phase, 0.08, 0.62),
            Beat(phase, 0.60, 0.78),
            Beat(phase, 0.76, 0.99));
    }

    /// <summary>A biscuit in three bites, with chewing in between and no dignity at any point.</summary>
    public static (double Bite, double Chew, double Happy, double Left, double Bites) Snack(double clock)
    {
        const double period = 7.6;
        double phase = Phase(clock, period);
        double[] starts = [0.10, 0.32, 0.54];
        double bite = 0;
        double taken = 0;
        foreach (double start in starts)
        {
            bite = Math.Max(bite, Beat(phase, start, start + 0.09));
            taken += Ramp(phase, start + 0.04, start + 0.09);
        }
        double chew = Math.Max(
            Math.Max(Beat(phase, 0.19, 0.30), Beat(phase, 0.41, 0.52)),
            Beat(phase, 0.63, 0.74));
        return (
            bite,
            chew,
            Beat(phase, 0.74, 0.96),
            1 - Ramp(phase, 0.58, 0.64) + Ramp(phase, 0.96, 0.99),
            Math.Floor(taken));
    }

    /// <summary>
    /// The two things that happen to somebody reading: something appalling,
    /// and something very funny. They alternate, so neither becomes the joke.
    /// </summary>
    public static (double Shock, double Laugh) ReadingGag(double clock)
    {
        const double period = 8.4;
        int round = (int)Math.Floor(clock / period);
        double evt = Beat(Phase(clock, period), 0.62, 0.84);
        return round % 2 == 0 ? (evt, 0) : (0, evt);
    }

    /// <summary>Breathing, asleep, and the occasional good dream.</summary>
    public static (double Breath, double Dream) Snore(double clock) =>
        (Math.Sin(clock * 2 * Math.PI / 4.6), Beat(Phase(clock, 13.0), 0.55, 0.80));

    /// <summary>
    /// Speech as an envelope rather than a metronome: a fast syllable rate
    /// under a slow phrase rate, so it pauses for breath on its own.
    /// </summary>
    public static double SpeechEnvelope(double clock)
    {
        double syllable = Math.Sin(clock * 2 * Math.PI * 5.1);
        double phrase = 0.55 + 0.45 * Math.Sin(clock * 2 * Math.PI * 0.41);
        return Math.Max(0, syllable) * phrase;
    }

    /// <summary>
    /// The ball's parabola. Launched off the crown, apex alternating sides, so
    /// the body has a reason to lean one way and then the other. Every fourth
    /// throw goes wrong: higher, wider, and very nearly not caught.
    /// </summary>
    public static (PPoint Point, double Panic) RallyBall(double clock)
    {
        double period = RallyPeriod;
        double index = Math.Floor(clock / period);
        double t = clock / period - index;
        double side = index % 2 == 0 ? 1 : -1;
        bool wild = index % 4 == 3;
        double reach = wild ? 0.30 : 0.17;
        double from = PersonaStage.CentreX - side * (wild ? 0.17 : reach);
        double to = PersonaStage.CentreX + side * reach;
        double x = from + (to - from) * t;
        // A parabola between the two crowns, apex near the top of the frame.
        double top = wild ? 0.03 : 0.06;
        const double launch = 0.22;
        double y = launch - 4 * (launch - top) * t * (1 - t);
        return (new PPoint(x, y), wild ? Math.Sin(t * Math.PI) : 0);
    }
}
