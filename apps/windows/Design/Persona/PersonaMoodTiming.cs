// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

namespace Tokenstat.Design.Persona;

internal static class PersonaMoodTiming
{
    public static double Phase(double clock, double period) => (clock % period) / period;

    public static double Beat(double phase, double from, double to)
    {
        if (phase <= from || phase >= to)
        {
            return 0;
        }
        return Math.Sin((phase - from) / (to - from) * Math.PI);
    }

    public static double Ramp(double phase, double from, double to)
    {
        double t = Math.Clamp((phase - from) / Math.Max(to - from, 1e-4), 0, 1);
        return t * t * (3 - 2 * t);
    }

    public static double StalledClock(double clock, double period, double from, double to)
    {
        double cycles = Math.Floor(clock / period);
        double inside = clock - cycles * period;
        double start = from * period;
        double stop = to * period;
        double held = stop - start;
        return cycles * (period - held) + Math.Min(inside, start) + Math.Max(0, inside - stop);
    }

    public const double RallyPeriod = 0.78;

    public const double BeatPeriod = 0.48;

    public const double StridePeriod = 2.6;

    public static (double X, double Direction) PacingWalk(double clock)
    {
        double turn = clock * Math.PI / StridePeriod;
        return (PersonaStage.CentreX - Math.Cos(turn) * 0.175, Math.Sin(turn) > 0 ? 1 : -1);
    }

    public const double PaceThinkPeriod = 9.1;

    public static double PacingClock(double clock) =>
        StalledClock(clock, PaceThinkPeriod, 0.72, 0.88);

    public static double PacingIdea(double clock) =>
        Beat(Phase(clock, PaceThinkPeriod), 0.72, 0.90);

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
        double lift = swing < 0.74 ? Ramp(swing, 0, 0.74) : 1 - Ramp(swing, 0.74, 1);
        return (lift, Beat(swing, 0.86, 1.0), Math.Min(1, blows / 4), 0);
    }

    public static double WorkAdmire(double clock) => Hammering(clock).Admire;

    public static double ThinkingIdea(double clock) => Beat(Phase(clock, 7.2), 0.80, 0.97);

    public static double WaitingSigh(double clock) => Beat(Phase(clock, 5.6), 0.70, 0.92);

    public static double FailedRetry(double clock)
    {
        if (clock <= 1.5)
        {
            return 0;
        }
        return Beat(Phase(clock - 1.5, 4.4), 0.55, 0.80);
    }

    public const double TypePeriod = 6.4;

    public static (double Tap, double Lit, double Pause, double Nod) Typing(double clock)
    {
        double cycle = Phase(clock, TypePeriod);
        double pause = Ramp(cycle, 0.62, 0.70) * (1 - Ramp(cycle, 0.84, 0.90));
        double nod = Beat(cycle, 0.88, 0.99);
        double patter = Math.Max(0, Math.Sin(clock * 2 * Math.PI * 6.4))
            * (0.7 + 0.3 * Math.Sin(clock * 2 * Math.PI * 1.7));
        return (patter * (1 - pause) * (1 - nod), Phase(clock, 0.37), pause, nod);
    }

    public const double TeaPeriod = 7.4;

    public static (double Lift, double Warm) Tea(double clock)
    {
        double phase = Phase(clock, TeaPeriod);
        return (
            Math.Max(Beat(phase, 0.10, 0.30), Beat(phase, 0.40, 0.60)),
            Beat(phase, 0.62, 0.98));
    }

    public const double GamePeriod = 10.4;

    public static (double Win, double Loss) GamingRound(double clock)
    {
        double period = GamePeriod / 2;
        int round = (int)Math.Floor((clock + 2.6) / period);
        double evt = Beat(Phase(clock + 2.6, period), 0.55, 0.76);
        return round % 2 == 0 ? (evt, 0) : (0, evt);
    }

    public const double SketchPeriod = 8.6;

    public static double SketchSweep(double clock) => -Math.Cos(clock * 2 * Math.PI / 1.45);

    public static (double Clock, double Sweep, double Look) Sketch(double clock)
    {
        double cycle = Phase(clock, SketchPeriod);
        double held = StalledClock(clock, SketchPeriod, 0.74, 0.94);
        return (held, SketchSweep(held), Beat(cycle, 0.74, 0.96));
    }

    public static (double Crossing, double StarX, double Gasp, double Wish) Sky(double clock)
    {
        const double period = 9.4;
        double phase = Phase(clock, period);
        double crossing = phase > 0.30 && phase < 0.52 ? (phase - 0.30) / 0.22 : 0;
        return (crossing, -0.34 + crossing * 0.68, Beat(phase, 0.34, 0.56), Beat(phase, 0.62, 0.94));
    }

    public static (double Growth, double Bloom, double Joy) Garden(double clock)
    {
        const double period = 11.2;
        double phase = Phase(clock, period);
        return (
            Ramp(phase, 0.04, 0.62),
            Ramp(phase, 0.64, 0.74) * (1 - Ramp(phase, 0.94, 0.99)),
            Beat(phase, 0.66, 0.92));
    }

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

    public static (double Shock, double Laugh) ReadingGag(double clock)
    {
        const double period = 8.4;
        int round = (int)Math.Floor(clock / period);
        double evt = Beat(Phase(clock, period), 0.62, 0.84);
        return round % 2 == 0 ? (evt, 0) : (0, evt);
    }

    public static (double Breath, double Dream) Snore(double clock) =>
        (Math.Sin(clock * 2 * Math.PI / 4.6), Beat(Phase(clock, 13.0), 0.55, 0.80));

    public static double SpeechEnvelope(double clock)
    {
        double syllable = Math.Sin(clock * 2 * Math.PI * 5.1);
        double phrase = 0.55 + 0.45 * Math.Sin(clock * 2 * Math.PI * 0.41);
        return Math.Max(0, syllable) * phrase;
    }

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
        double top = wild ? 0.03 : 0.06;
        const double launch = 0.22;
        double y = launch - 4 * (launch - top) * t * (1 - t);
        return (new PPoint(x, y), wild ? Math.Sin(t * Math.PI) : 0);
    }
}
