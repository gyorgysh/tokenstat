// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

namespace Tokenstat.Design.Persona;

/// <summary>The forces for an instant of a mood. Clock is seconds since the mood began.</summary>
internal static class PersonaMoodDrive
{
    public static PersonaDrive Drive(this PersonaMood mood, double clock, PersonaTraits traits)
    {
        var drive = new PersonaDrive
        {
            Damping = 3.4 * traits.Firmness,
            RingStiffness = 210 * traits.Firmness,
            ShapeStiffness = 150 * traits.Firmness,
            Pressure = 44 * traits.Firmness,
        };

        switch (mood)
        {
            case PersonaMood.Idle:
            {
                double breathe = Math.Sin(clock * 2 * Math.PI / 2.8);
                double drift = Math.Sin(clock * 2 * Math.PI / 6.7);
                double yawn = PersonaMoodTiming.Beat(PersonaMoodTiming.Phase(clock, 11.5), 0.62, 0.76);
                drive.Stretch = new PSize(
                    1 + breathe * 0.032 - yawn * 0.13,
                    1 - breathe * 0.030 + yawn * 0.22);
                drive.AnchorX = PersonaStage.CentreX + drift * 0.014;
                drive.Lean = drift * 0.05 - yawn * 0.05;
                drive.Wobble = 0.05;
                drive.WobblePhase = clock * 0.36;
                drive.Gravity = 0.9 - yawn * 0.35;
                break;
            }

            case PersonaMood.Bouncing:
                drive.Gravity = 3.1;
                drive.Restitution = 0.62;
                drive.Friction = 0.94;
                // Loose and underdamped on purpose. A bouncing ball that holds
                // its shape is a bouncing ball, and this one should be a
                // bouncing water balloon.
                drive.Damping = 1.25 * traits.Firmness;
                drive.Pressure = 58 * traits.Firmness;
                drive.ShapeStiffness = 118 * traits.Firmness;
                drive.AnchorPull = 2.4;
                // A little smaller in the air, which buys the headroom the hop
                // needs without the resting character being smaller than it was.
                drive.Radius = PersonaStage.RestRadius * 0.90;
                drive.Stretch = new PSize(1, 1);
                break;

            case PersonaMood.Thinking:
            {
                double idea = PersonaMoodTiming.ThinkingIdea(clock);
                drive.Gravity = 0.85 - idea * 0.55;
                drive.Damping = (4.0 - idea * 1.4) * traits.Firmness;
                drive.Swirl = 0.16 * Math.Sin(clock * 2 * Math.PI / 1.7) * (1 - idea);
                drive.Wobble = 0.24 * (1 - idea * 0.6);
                drive.WobblePhase = clock * 0.62;
                drive.Lean = (-0.07 + Math.Sin(clock * 2 * Math.PI / 2.3) * 0.05) * (1 - idea);
                double breathe = Math.Sin(clock * 2 * Math.PI / 1.9);
                drive.Stretch = new PSize(
                    1 - breathe * 0.018 - idea * 0.13,
                    1 + breathe * 0.022 + idea * 0.20);
                break;
            }

            case PersonaMood.Working:
            {
                var job = PersonaMoodTiming.Hammering(clock);
                drive.Gravity = 2.0;
                drive.Restitution = 0.10;
                drive.Damping = 4.4 * traits.Firmness;
                drive.Pressure = 50 * traits.Firmness;
                drive.Radius = PersonaStage.RestRadius * 0.96;
                // It stands over the job rather than pacing past it. The swing
                // is the motion, and a character walking while it hammers is a
                // character doing two things badly.
                drive.AnchorX = PersonaStage.CentreX - 0.06;
                drive.AnchorPull = 12;
                drive.Lean = 0.10 + job.Strike * 0.30 - job.Lift * 0.16 - job.Admire * 0.34;
                drive.Stretch = new PSize(
                    1 + job.Strike * 0.10 - job.Admire * 0.05,
                    1 - job.Strike * 0.09 + job.Admire * 0.08);
                drive.Wobble = 0.06;
                drive.WobblePhase = clock * 1.2;
                break;
            }

            case PersonaMood.Speaking:
            {
                double syllable = PersonaMoodTiming.SpeechEnvelope(clock);
                drive.Gravity = 0.95;
                drive.Damping = 3.1 * traits.Firmness;
                drive.Stretch = new PSize(1 - syllable * 0.085, 1 + syllable * 0.120);
                drive.Lean = Math.Sin(clock * 2 * Math.PI / 1.4) * (0.10 + syllable * 0.08);
                drive.Wobble = 0.10 + syllable * 0.24;
                drive.WobblePhase = clock * 1.9;
                break;
            }

            case PersonaMood.Juggling:
            {
                var ball = PersonaMoodTiming.RallyBall(clock);
                double swing = ball.Point.X - PersonaStage.CentreX;
                drive.Gravity = 1.0;
                drive.Damping = (3.0 - ball.Panic * 0.9) * traits.Firmness;
                // The body chases the ball rather than swinging on a fixed
                // sine, so the fourth throw going wide drags the whole
                // creature after it.
                drive.AnchorX = PersonaStage.CentreX + swing * (0.55 + ball.Panic * 0.55);
                drive.Lean = swing * (1.5 + ball.Panic * 1.4);
                drive.AnchorPull = 9 + ball.Panic * 7;
                drive.Stretch = new PSize(1 - ball.Panic * 0.06, 1 + ball.Panic * 0.09);
                break;
            }

            case PersonaMood.Dancing:
            {
                double beat = clock / PersonaMoodTiming.BeatPeriod;
                double pump = Math.Sin(beat * 2 * Math.PI);
                double sway = Math.Sin(beat * Math.PI);
                drive.Gravity = 1.35;
                drive.Restitution = 0.30;
                drive.Damping = 3.0 * traits.Firmness;
                // Small. This is somebody enjoying a song where they are
                // standing, not a routine: a light bob, a shift of weight left
                // and right, and that is the whole dance.
                drive.Stretch = new PSize(1 + pump * 0.045, 1 - pump * 0.042);
                drive.AnchorX = PersonaStage.CentreX + sway * 0.075;
                drive.Radius = PersonaStage.RestRadius * 0.95;
                drive.Lean = sway * 0.22;
                drive.AnchorPull = 9;
                break;
            }

            case PersonaMood.Waiting:
            {
                double tap = Math.Max(0, Math.Sin(clock * 2 * Math.PI / 1.2));
                double sigh = PersonaMoodTiming.WaitingSigh(clock);
                drive.Gravity = 1.0;
                drive.Damping = 3.6 * traits.Firmness;
                drive.Lean = 0.15 + Math.Sin(clock * 2 * Math.PI / 3.1) * 0.07;
                drive.Stretch = new PSize(
                    1 + tap * 0.030 + sigh * 0.10,
                    1 - tap * 0.028 - sigh * 0.13);
                drive.AnchorX = PersonaStage.CentreX + 0.012;
                break;
            }

            case PersonaMood.Ok:
            {
                drive.Gravity = 2.7;
                drive.Restitution = 0.42;
                drive.Damping = 2.1 * traits.Firmness;
                drive.ShapeStiffness = 124 * traits.Firmness;
                drive.Radius = PersonaStage.RestRadius * 0.92;
                double rise = Math.Max(0, 1 - clock / 0.45);
                drive.Stretch = new PSize(1 - rise * 0.20, 1 + rise * 0.28);
                break;
            }

            case PersonaMood.Failed:
            {
                // Three phases in one expression: a shake it cannot absorb, a
                // collapse, then a puddle that has not entirely given up.
                double melt = Math.Clamp((clock - 0.34) / 0.85, 0, 1);
                double eased = melt * melt * (3 - 2 * melt);
                double retry = PersonaMoodTiming.FailedRetry(clock);
                drive.Gravity = 1.1 + eased * 1.5;
                drive.Restitution = 0.30 * (1 - eased);
                drive.Damping = (3.0 + eased * 1.4) * traits.Firmness;
                drive.Pressure = (44 - eased * 18) * traits.Firmness;
                drive.ShapeStiffness = (150 - eased * 88) * traits.Firmness;
                // A puddle is allowed to feel its own weight. That is the point.
                drive.Support = 1 - eased * 0.7;
                drive.Stretch = new PSize(
                    1 + eased * 0.34 - retry * 0.22,
                    1 - eased * 0.42 + retry * 0.30 + Math.Sin(clock * 2 * Math.PI / 3.4) * 0.012);
                drive.Lean = Math.Sin(clock * 2 * Math.PI / 4.1) * 0.03 * eased;
                break;
            }

            case PersonaMood.Reading:
            {
                double sway = Math.Sin(clock * 2 * Math.PI / 5.3);
                var gag = PersonaMoodTiming.ReadingGag(clock);
                drive.Gravity = 0.9;
                drive.Damping = (3.9 - gag.Laugh * 1.6) * traits.Firmness;
                drive.Lean = 0.07 + sway * 0.035 - gag.Shock * 0.20;
                drive.AnchorX = PersonaStage.CentreX - 0.012 + sway * 0.008;
                // The laugh is a fast wobble on top of the read, which is what
                // somebody trying not to laugh at a newspaper actually does.
                double chuckle = gag.Laugh * Math.Sin(clock * 2 * Math.PI * 7.5);
                drive.Stretch = new PSize(
                    1 + sway * 0.016 - gag.Shock * 0.08 - chuckle * 0.05,
                    1 - sway * 0.014 + gag.Shock * 0.13 + chuckle * 0.06);
                break;
            }

            case PersonaMood.Gaming:
            {
                // Rocking, not swaying: two rates beating against each other,
                // so the lean never settles into a metronome.
                double rock = Math.Sin(clock * 2 * Math.PI * 1.15) * 0.65
                    + Math.Sin(clock * 2 * Math.PI * 0.43) * 0.35;
                var round = PersonaMoodTiming.GamingRound(clock);
                drive.Gravity = 1.15;
                drive.Damping = 3.2 * traits.Firmness;
                drive.Lean = rock * 0.26 * (1 - round.Loss) + round.Loss * 0.14;
                drive.AnchorX = PersonaStage.CentreX + rock * 0.030;
                drive.AnchorPull = 9;
                // Losing is played entirely in the body: it deflates, and the
                // ground stops holding it up.
                drive.Support = 1 - round.Loss * 0.35;
                drive.Stretch = new PSize(
                    1 + round.Loss * 0.16 - round.Win * 0.10,
                    1 - round.Loss * 0.20 + round.Win * 0.15);
                break;
            }

            case PersonaMood.Pacing:
            {
                var walk = PersonaMoodTiming.PacingWalk(PersonaMoodTiming.PacingClock(clock));
                double idea = PersonaMoodTiming.PacingIdea(clock);
                drive.Gravity = 1.5;
                drive.Restitution = 0.14;
                drive.Damping = 3.4 * traits.Firmness;
                drive.AnchorX = walk.X;
                drive.Radius = PersonaStage.RestRadius * 0.88;
                // Leaning into the direction of travel, and standing up
                // straight at the turns, which is where the lean crosses zero.
                drive.Lean = walk.Direction * 0.20 * (1 - idea) - idea * 0.10;
                drive.AnchorPull = 13;
                drive.Stretch = new PSize(1 - idea * 0.12, 1 + idea * 0.18);
                break;
            }

            case PersonaMood.Typing:
            {
                var keys = PersonaMoodTiming.Typing(clock);
                drive.Gravity = 1.35;
                drive.Damping = 3.4 * traits.Firmness;
                drive.Pressure = 42 * traits.Firmness;
                // Leaning over a keyboard that is on the floor, which is where
                // a keyboard is.
                drive.AnchorX = PersonaStage.CentreX - 0.055;
                drive.AnchorPull = 12;
                drive.Lean = 0.24 * (1 - keys.Pause) - keys.Pause * 0.12 + keys.Nod * 0.10;
                drive.Stretch = new PSize(
                    1 + keys.Tap * 0.035 - keys.Pause * 0.04,
                    1 - keys.Tap * 0.040 + keys.Pause * 0.06 + keys.Nod * 0.05);
                drive.Wobble = keys.Pause * 0.14;
                drive.WobblePhase = clock * 0.8;
                break;
            }

            case PersonaMood.Sipping:
            {
                var tea = PersonaMoodTiming.Tea(clock);
                drive.Gravity = 0.95;
                drive.Damping = 4.2 * traits.Firmness;
                // The still one. A long slow breathe, a sip now and then, and
                // nothing else asking for attention. The body tips back a
                // little into the sip, which is the only way a ball can drink.
                double breathe = Math.Sin(clock * 2 * Math.PI / 5.2);
                drive.Lean = breathe * 0.020 - tea.Lift * 0.16;
                drive.AnchorX = PersonaStage.CentreX - 0.020 * tea.Lift;
                drive.Stretch = new PSize(
                    1 + breathe * 0.014 - tea.Lift * 0.020,
                    1 - breathe * 0.013 + tea.Lift * 0.026);
                break;
            }

            case PersonaMood.Sketching:
            {
                var work = PersonaMoodTiming.Sketch(clock);
                drive.Gravity = 1.55;
                drive.Damping = 3.6 * traits.Firmness;
                // Leaning down and across at the sheet on the floor, and
                // following its own hand from one side of it to the other.
                drive.Lean = 0.20 + work.Sweep * 0.12 - work.Look * 0.30;
                drive.AnchorX = PersonaStage.CentreX - 0.09 + work.Sweep * 0.030 - work.Look * 0.045;
                drive.AnchorPull = 11;
                drive.Stretch = new PSize(
                    1 + Math.Abs(work.Sweep) * 0.030 - work.Look * 0.04,
                    1 - Math.Abs(work.Sweep) * 0.026 + work.Look * 0.06);
                break;
            }

            case PersonaMood.Stargazing:
            {
                var sky = PersonaMoodTiming.Sky(clock);
                drive.Gravity = 0.82 - sky.Gasp * 0.30;
                drive.Damping = 4.0 * traits.Firmness;
                drive.Lean = Math.Sin(clock * 2 * Math.PI / 4.8) * 0.05 - sky.Gasp * 0.10;
                drive.Stretch = new PSize(
                    0.99 - sky.Gasp * 0.07 - sky.Wish * 0.03,
                    1.01 + sky.Gasp * 0.11 + sky.Wish * 0.04);
                break;
            }

            case PersonaMood.Gardening:
            {
                var plot = PersonaMoodTiming.Garden(clock);
                double pat = Math.Max(0, Math.Sin(clock * 2 * Math.PI / 1.15)) * (1 - plot.Joy);
                drive.Gravity = 1.35;
                drive.Damping = 3.8 * traits.Firmness;
                // Leaning towards its own patch, which is on the floor to its
                // right, so the patting lands on the soil.
                drive.Lean = (0.16 + pat * 0.08) * (1 - plot.Joy) - plot.Joy * 0.10;
                drive.Stretch = new PSize(
                    1 + pat * 0.025 - plot.Joy * 0.10,
                    1 - pat * 0.020 + plot.Joy * 0.16);
                drive.AnchorX = PersonaStage.CentreX - 0.055;
                break;
            }

            case PersonaMood.Bubbling:
            {
                var bubble = PersonaMoodTiming.Bubble(clock);
                drive.Gravity = 1.0;
                drive.Damping = (3.4 - bubble.Blow * 0.8) * traits.Firmness;
                // Cheeks first, then the flinch. The body inflates while it
                // blows and loses all of it in three frames when the thing pops.
                drive.Pressure = (44 + bubble.Blow * 16 - bubble.Pop * 22) * traits.Firmness;
                drive.ShapeStiffness = (150 - bubble.Pop * 70) * traits.Firmness;
                drive.Stretch = new PSize(
                    1 + bubble.Blow * 0.10 - bubble.Pop * 0.04,
                    1 + bubble.Blow * 0.04 - bubble.Pop * 0.10);
                drive.Lean = 0.06 + bubble.Blow * 0.08 - bubble.Pop * 0.22;
                drive.Wobble = bubble.Pop * 0.40;
                drive.WobblePhase = clock * 4.2;
                break;
            }

            case PersonaMood.Snacking:
            {
                var snack = PersonaMoodTiming.Snack(clock);
                drive.Gravity = 1.2;
                drive.Damping = 3.5 * traits.Firmness;
                drive.Lean = -0.10 - snack.Bite * 0.30 + snack.Chew * 0.05;
                drive.AnchorX = PersonaStage.CentreX - 0.02;
                // Chewing is a fast small squash, which is the whole
                // difference between eating and holding food.
                double jaw = snack.Chew * Math.Sin(clock * 2 * Math.PI * 4.6);
                drive.Stretch = new PSize(
                    1 + snack.Bite * 0.09 + jaw * 0.045 + snack.Happy * 0.06,
                    1 - snack.Bite * 0.07 - jaw * 0.050 - snack.Happy * 0.04);
                drive.Wobble = snack.Happy * 0.22;
                drive.WobblePhase = clock * 2.6;
                break;
            }

            case PersonaMood.Sleeping:
            {
                var snore = PersonaMoodTiming.Snore(clock);
                drive.Gravity = 1.0;
                drive.Damping = 4.6 * traits.Firmness;
                drive.Pressure = (34 + snore.Breath * 8) * traits.Firmness;
                drive.Stretch = new PSize(
                    1.17 + snore.Breath * 0.055,
                    0.74 - snore.Breath * 0.058 + snore.Dream * 0.05);
                drive.Wobble = 0.03;
                drive.WobblePhase = clock * 0.12;
                break;
            }
        }
        return drive;
    }
}
