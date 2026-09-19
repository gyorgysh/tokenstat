// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

namespace Tokenstat.Design.Persona;

/// <summary>
/// Everything that is not the creature: a thought, a ball, sparks, notes,
/// z's, a drip. Written into a buffer the engine owns, so a frame of motion
/// allocates nothing.
/// </summary>
internal static class PersonaMoodMotes
{
    public static void Motes(
        this PersonaMood mood,
        double clock,
        PersonaTraits traits,
        PersonaAnchors anchors,
        List<PersonaMote> motes)
    {
        var crown = anchors.Crown;
        switch (mood)
        {
            case PersonaMood.Idle:
            {
                double yawn = PersonaMoodTiming.Beat(PersonaMoodTiming.Phase(clock, 11.5), 0.62, 0.76);
                if (yawn <= 0.35)
                {
                    break;
                }
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Puff,
                    new PPoint(anchors.Mouth.X + 0.10, anchors.Mouth.Y - (yawn - 0.35) * 0.10),
                    0.34 + (1 - yawn) * 0.30,
                    (yawn - 0.35) * 0.34));
                break;
            }

            case PersonaMood.Thinking:
            {
                double idea = PersonaMoodTiming.ThinkingIdea(clock);
                double orbit = clock * 2 * Math.PI / 2.4;
                var centre = new PPoint(crown.X + 0.17, crown.Y - 0.10);
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Dot,
                    new PPoint(centre.X + Math.Cos(orbit) * 0.075, centre.Y + Math.Sin(orbit) * 0.045),
                    0.9,
                    0.85 * (1 - idea)));
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Dot,
                    new PPoint(centre.X + Math.Cos(orbit + 2.2) * 0.052, centre.Y + Math.Sin(orbit + 2.2) * 0.031),
                    0.55,
                    0.5 * (1 - idea)));
                if (idea <= 0.55)
                {
                    break;
                }
                // The thought arriving, drawn as the two dots it was already
                // circling flying apart.
                for (int i = 0; i < 4; i++)
                {
                    double angle = i * (Math.PI / 2) - Math.PI / 4;
                    double burst = (idea - 0.55) / 0.45;
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Dot,
                        new PPoint(
                            centre.X + Math.Cos(angle) * (0.03 + burst * 0.075),
                            Math.Max(0.06, centre.Y) + Math.Sin(angle) * (0.02 + burst * 0.055)),
                        0.55 * (1 - burst * 0.5),
                        (1 - burst) * 0.8));
                }
                break;
            }

            case PersonaMood.Juggling:
            {
                var ball = PersonaMoodTiming.RallyBall(clock);
                motes.Add(new PersonaMote(PersonaMote.Kind.Ball, ball.Point));
                if (ball.Panic <= 0.3)
                {
                    break;
                }
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Sweat,
                    new PPoint(crown.X - 0.12, crown.Y + 0.02 - ball.Panic * 0.05),
                    0.9,
                    ball.Panic,
                    -0.5));
                break;
            }

            case PersonaMood.Working:
            {
                var job = PersonaMoodTiming.Hammering(clock);
                var nail = new PPoint(0.77, PersonaStage.Floor);
                double showing = Math.Max(1 - job.Sunk * 0.78, 0.12);
                var head = new PPoint(nail.X, PersonaStage.Floor - 0.10 * showing);
                motes.Add(new PersonaMote(PersonaMote.Kind.Nail, nail, showing));
                // The swing is aimed rather than posed: the angle is worked
                // out from where the hammer is held to where the nail head
                // currently is, so the blow lands on it, and keeps landing on
                // it as the nail goes in.
                var grip = new PPoint(anchors.Hands.X + 0.01, anchors.Hands.Y - 0.02);
                double aim = Math.Atan2(head.Y - grip.Y, Math.Max(head.X - grip.X, 0.01));
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Hammer,
                    grip,
                    1,
                    1 - job.Admire * 0.7,
                    aim - job.Lift * 1.30));
                if (job.Strike > 0.25)
                {
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Puff,
                        new PPoint(nail.X - 0.03, PersonaStage.Floor - 0.02),
                        0.30 + job.Strike * 0.30,
                        job.Strike * 0.45));
                }
                if (job.Admire <= 0.35)
                {
                    break;
                }
                for (int i = 0; i < 3; i++)
                {
                    double angle = -Math.PI / 2 + (i - 1) * 0.6;
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Spark,
                        new PPoint(
                            nail.X + Math.Cos(angle) * 0.08,
                            PersonaStage.Floor - 0.05 + Math.Sin(angle) * 0.05),
                        (job.Admire - 0.35) * 0.9,
                        (job.Admire - 0.35) * 1.5,
                        angle));
                }
                break;
            }

            case PersonaMood.Ok:
            {
                for (int i = 0; i < 7; i++)
                {
                    double angle = i * (2 * Math.PI / 7) - Math.PI / 2;
                    double life = Math.Clamp(clock / 0.85, 0, 1);
                    if (life >= 1)
                    {
                        break;
                    }
                    double reach = 0.06 + life * 0.20;
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Spark,
                        new PPoint(
                            crown.X + Math.Cos(angle) * reach,
                            crown.Y - 0.02 + Math.Sin(angle) * reach * 0.85),
                        1 - life * 0.5,
                        (1 - life) * (1 - life),
                        angle));
                }
                // Confetti outlives the sparks by a couple of seconds, so the
                // celebration has a tail on it rather than stopping dead.
                for (int i = 0; i < 9; i++)
                {
                    double seed = i;
                    double life = Math.Clamp((clock - seed * 0.045) / 2.4, 0, 1);
                    if (life <= 0 || life >= 1)
                    {
                        continue;
                    }
                    double drift = Math.Sin(seed * 2.4);
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Confetti,
                        new PPoint(
                            Math.Clamp(crown.X + drift * (0.10 + life * 0.24), 0.06, 0.94),
                            crown.Y - 0.16 + life * life * 0.72 + Math.Sin(seed) * 0.05),
                        0.85 + Math.Sin(seed * 5.1) * 0.25,
                        1 - life * life,
                        seed * 1.7 + clock * (3.0 + drift * 2)));
                }
                break;
            }

            case PersonaMood.Dancing:
            {
                double period = PersonaMoodTiming.BeatPeriod * 2;
                for (int step = 0; step < 2; step++)
                {
                    double age = clock % period + step * period;
                    if (age >= 1.6)
                    {
                        continue;
                    }
                    double life = age / 1.6;
                    double side = step == 0 ? 1 : -1;
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Note,
                        new PPoint(
                            Math.Clamp(crown.X + side * (0.13 + Math.Sin(life * Math.PI * 1.5) * 0.04), 0.14, 0.86),
                            // The note itself has a tall stem. Leave it room
                            // at the top, rather than merely keeping its
                            // centre in.
                            Math.Max(0.16, crown.Y - 0.01 - life * 0.18)),
                        0.8 + life * 0.3,
                        (1 - life) * 0.9,
                        side * 0.25));
                }
                break;
            }

            case PersonaMood.Sleeping:
            {
                const double period = 1.7;
                for (int step = 0; step < 3; step++)
                {
                    double age = clock % period + step * period;
                    if (age >= 3.4)
                    {
                        continue;
                    }
                    double life = age / 3.4;
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Zed,
                        new PPoint(
                            crown.X + 0.12 + Math.Sin(life * Math.PI * 2) * 0.035 + life * 0.06,
                            crown.Y - 0.02 - life * 0.34),
                        0.55 + life * 0.75,
                        Math.Min(life * 4, 1) * (1 - life)));
                }
                var snore = PersonaMoodTiming.Snore(clock);
                if (snore.Breath < -0.4)
                {
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Puff,
                        new PPoint(anchors.Mouth.X + 0.11, anchors.Mouth.Y),
                        0.30 + (-snore.Breath - 0.4) * 0.9,
                        (-snore.Breath - 0.4) * 0.42));
                }
                if (snore.Dream <= 0.05)
                {
                    break;
                }
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Heart,
                    new PPoint(crown.X - 0.14, crown.Y - 0.04 - snore.Dream * 0.16),
                    0.75,
                    snore.Dream * 0.85,
                    -0.25));
                break;
            }

            case PersonaMood.Failed:
            {
                double retry = PersonaMoodTiming.FailedRetry(clock);
                if (retry > 0.25)
                {
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Sweat,
                        new PPoint(crown.X + 0.15, crown.Y - 0.03 - retry * 0.05),
                        0.9,
                        (retry - 0.25) * 1.6,
                        0.5));
                }
                const double period = 2.6;
                double age = clock % period;
                if (clock <= 1.0 || age >= 1.2)
                {
                    break;
                }
                double life = age / 1.2;
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Drop,
                    new PPoint(
                        crown.X + 0.17,
                        PersonaStage.Floor - 0.075 + life * life * 0.085),
                    1 - life * 0.35,
                    Math.Min(life * 5, 1) * (1 - life * life)));
                break;
            }

            case PersonaMood.Reading:
            {
                // One sheet, held, drifting. The interesting part of somebody
                // reading is that they are absorbed and barely moving. What is
                // on the page is the event.
                var gag = PersonaMoodTiming.ReadingGag(clock);
                double sway = Math.Sin(clock * 2 * Math.PI / 5.3);
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Paper,
                    new PPoint(
                        anchors.Raised.X + sway * 0.014 + gag.Shock * Math.Sin(clock * 44) * 0.012,
                        anchors.Raised.Y + Math.Sin(clock * 2 * Math.PI / 3.7) * 0.006 - gag.Shock * 0.02),
                    anchors.Bounds.Width / (PersonaStage.RestRadius * 2),
                    1,
                    sway * 0.055 + gag.Laugh * Math.Sin(clock * 26) * 0.05));
                if (gag.Shock <= 0.25)
                {
                    break;
                }
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Mark,
                    new PPoint(crown.X + 0.17, crown.Y - 0.06 - gag.Shock * 0.05),
                    0.8 + gag.Shock * 0.5,
                    Math.Min(1, (gag.Shock - 0.25) * 2.6)));
                break;
            }

            case PersonaMood.Gaming:
            {
                var round = PersonaMoodTiming.GamingRound(clock);
                // The screen faces him, so what reaches us is the light off
                // it. Drawn under the face rather than over the body, which is
                // what makes it read as a screen rather than a lamp.
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Glow,
                    new PPoint(anchors.Hands.X, anchors.Hands.Y - 0.03),
                    1 + round.Win * 0.7,
                    0.55 + round.Win * 0.45 - round.Loss * 0.30));
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Console,
                    anchors.Hands,
                    1,
                    1,
                    // Three rates: a rock, a lean, and the small fast jitter
                    // of somebody actually working the buttons.
                    Math.Sin(clock * 2 * Math.PI * 1.15) * 0.15
                        + Math.Sin(clock * 2 * Math.PI * 0.43) * 0.10
                        + Math.Sin(clock * 2 * Math.PI * 6.3) * 0.028
                        + round.Loss * 0.5));
                if (round.Loss > 0.2)
                {
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Mark,
                        new PPoint(crown.X + 0.16, crown.Y - 0.05),
                        0.75,
                        Math.Min(1, (round.Loss - 0.2) * 2.4),
                        1));
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Sweat,
                        new PPoint(crown.X - 0.13, crown.Y + 0.01),
                        0.8,
                        Math.Min(1, (round.Loss - 0.2) * 2.0),
                        -0.6));
                }
                if (round.Win <= 0.1)
                {
                    break;
                }
                for (int i = 0; i < 4; i++)
                {
                    double angle = -Math.PI / 2 + (i - 1.5) * 0.42;
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Spark,
                        new PPoint(
                            anchors.Hands.X + Math.Cos(angle) * (0.06 + (1 - round.Win) * 0.10),
                            anchors.Hands.Y - 0.04 + Math.Sin(angle) * (0.05 + (1 - round.Win) * 0.08)),
                        round.Win,
                        round.Win,
                        angle));
                }
                for (int i = 0; i < 6; i++)
                {
                    double seed = i;
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Confetti,
                        new PPoint(
                            Math.Clamp(crown.X + Math.Sin(seed * 2.1) * 0.22, 0.06, 0.94),
                            Math.Max(0.06, crown.Y - 0.10 + (1 - round.Win) * 0.30 + Math.Sin(seed) * 0.04)),
                        0.8,
                        round.Win,
                        seed * 1.9 + clock * 4));
                }
                break;
            }

            case PersonaMood.Pacing:
            {
                double idea = PersonaMoodTiming.PacingIdea(clock);
                double orbit = clock * 2 * Math.PI / 2.9;
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Dot,
                    new PPoint(
                        crown.X + 0.15 + Math.Cos(orbit) * 0.045,
                        crown.Y - 0.10 + Math.Sin(orbit) * 0.030),
                    0.75,
                    0.7 * (1 - idea)));
                if (idea <= 0.5)
                {
                    break;
                }
                // The thought it has been walking round with, arriving.
                double burst = (idea - 0.5) / 0.5;
                for (int i = 0; i < 3; i++)
                {
                    double angle = -Math.PI / 2 + (i - 1) * 0.8;
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Dot,
                        new PPoint(
                            crown.X + 0.15 + Math.Cos(angle) * (0.02 + burst * 0.065),
                            Math.Max(0.07, crown.Y - 0.10) + Math.Sin(angle) * (0.02 + burst * 0.05)),
                        0.5 * (1 - burst * 0.4),
                        (1 - burst) * 0.75));
                }
                break;
            }

            case PersonaMood.Typing:
            {
                var keys = PersonaMoodTiming.Typing(clock);
                // On the floor, in front of it, which is where a keyboard goes.
                var keyboard = new PPoint(0.66, PersonaStage.Floor);
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Keyboard,
                    keyboard,
                    1,
                    1,
                    keys.Lit));
                if (keys.Pause > 0.25)
                {
                    // Stopped mid-word with nothing to say next, which is the
                    // most honest thing this whole cast does.
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Mark,
                        new PPoint(crown.X + 0.16, Math.Max(0.12, crown.Y - 0.07)),
                        0.8,
                        Math.Min(1, (keys.Pause - 0.25) * 2.4),
                        1));
                }
                if (keys.Tap <= 0.55)
                {
                    break;
                }
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Spark,
                    new PPoint(keyboard.X + keys.Lit * 0.14 - 0.07, keyboard.Y - 0.085),
                    0.30,
                    (keys.Tap - 0.55) * 1.5,
                    Math.PI / 4));
                break;
            }

            case PersonaMood.Sipping:
            {
                var tea = PersonaMoodTiming.Tea(clock);
                // From the hands to the mouth, and no further.
                var mouth = anchors.Mouth;
                var rest = anchors.Hands;
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Mug,
                    new PPoint(
                        // Held out to the side, and brought in towards the
                        // face to drink.
                        rest.X + 0.080 - tea.Lift * 0.062,
                        rest.Y + (mouth.Y + 0.020 - rest.Y) * tea.Lift),
                    1,
                    1,
                    // Negative, so the rim tips towards the mouth rather than
                    // away from it.
                    -tea.Lift * 0.80));
                for (int step = 0; step < 2; step++)
                {
                    double life = (clock + step * 1.1) % 2.2 / 2.2;
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Puff,
                        new PPoint(
                            rest.X + 0.09 + Math.Sin(life * Math.PI * 2) * 0.018,
                            rest.Y - 0.16 - life * 0.14 - tea.Lift * 0.10),
                        0.34 + life * 0.28,
                        (1 - life) * 0.30 * (1 - tea.Lift)));
                }
                if (tea.Warm <= 0.4)
                {
                    break;
                }
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Heart,
                    new PPoint(crown.X + 0.15, crown.Y - 0.03 - tea.Warm * 0.12),
                    0.65,
                    (tea.Warm - 0.4) * 1.3,
                    0.2));
                break;
            }

            case PersonaMood.Sketching:
            {
                var work = PersonaMoodTiming.Sketch(clock);
                var sheet = new PPoint(0.66, PersonaStage.Floor);
                motes.Add(new PersonaMote(PersonaMote.Kind.Sheet, sheet));
                // The wet end of the brush and the mark it is making, and that
                // is all.
                var tip = new PPoint(sheet.X + work.Sweep * 0.10, sheet.Y - 0.055);
                for (int step = 0; step < 3; step++)
                {
                    double age = step * 0.13;
                    double trail = PersonaMoodTiming.SketchSweep(work.Clock - age);
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Stroke,
                        new PPoint(sheet.X + trail * 0.10, sheet.Y - 0.052),
                        0.5,
                        (1 - step / 3.0) * 0.5 * (1 - work.Look)));
                }
                if (work.Look >= 0.5)
                {
                    break;
                }
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Brush,
                    // Bristles down on the paper, handle up and back towards
                    // the character, which is the only way anybody holds one.
                    new PPoint(tip.X, tip.Y - 0.085),
                    1,
                    1 - work.Look * 2,
                    1.15 - work.Sweep * 0.30));
                break;
            }

            case PersonaMood.Speaking:
                break;

            case PersonaMood.Stargazing:
            {
                var sky = PersonaMoodTiming.Sky(clock);
                double orbit = clock * 2 * Math.PI / 5.2;
                for (int i = 0; i < 3; i++)
                {
                    double angle = orbit + i * 2.1;
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Spark,
                        new PPoint(
                            crown.X + Math.Cos(angle) * (0.12 + i * 0.035),
                            crown.Y - 0.18 + Math.Sin(angle) * 0.055),
                        0.35 + i * 0.12,
                        0.50 + i * 0.12,
                        angle));
                }
                if (sky.Crossing > 0)
                {
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.ShootingStar,
                        new PPoint(sky.StarX + PersonaStage.CentreX, 0.10 + sky.Crossing * 0.06),
                        1,
                        Math.Min(1, Math.Min(sky.Crossing, 1 - sky.Crossing) * 5),
                        0.32));
                }
                if (sky.Wish <= 0.2)
                {
                    break;
                }
                foreach (double side in new double[] { -1, 1 })
                {
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Heart,
                        new PPoint(crown.X + side * 0.16, crown.Y - 0.02 - sky.Wish * 0.13),
                        0.7,
                        (sky.Wish - 0.2) * 1.2,
                        side * 0.25));
                }
                break;
            }

            case PersonaMood.Gardening:
            {
                var plot = PersonaMoodTiming.Garden(clock);
                // Planted in the floor, in its own patch of soil, off to one
                // side.
                var root = new PPoint(0.72, PersonaStage.Floor);
                if (plot.Bloom < 0.5)
                {
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Sprout,
                        root,
                        0.45 + plot.Growth * 0.85 + Math.Sin(clock * 2 * Math.PI / 3.4) * 0.05,
                        1 - plot.Bloom * 2));
                }
                if (plot.Bloom > 0.02)
                {
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Flower,
                        new PPoint(root.X, root.Y - 0.03 - 0.14 * plot.Bloom),
                        plot.Bloom * 1.05,
                        Math.Min(1, plot.Bloom * 2)));
                }
                if (plot.Joy > 0.2)
                {
                    for (int i = 0; i < 3; i++)
                    {
                        double angle = -Math.PI / 2 + (i - 1) * 0.72;
                        motes.Add(new PersonaMote(
                            PersonaMote.Kind.Spark,
                            new PPoint(
                                root.X + Math.Cos(angle) * (0.08 + plot.Joy * 0.05),
                                root.Y - 0.19 + Math.Sin(angle) * (0.06 + plot.Joy * 0.04)),
                            plot.Joy * 0.45,
                            plot.Joy * 0.8,
                            angle));
                    }
                }
                double pat = Math.Max(0, Math.Sin(clock * 2 * Math.PI / 1.15));
                if (pat <= 0.72 || plot.Joy >= 0.2)
                {
                    break;
                }
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Puff,
                    new PPoint(root.X - 0.05, PersonaStage.Floor - 0.012),
                    0.38,
                    (pat - 0.72) / 0.28 * 0.35));
                break;
            }

            case PersonaMood.Bubbling:
            {
                var bubble = PersonaMoodTiming.Bubble(clock);
                if (bubble.Size > 0.02)
                {
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Bubble,
                        new PPoint(
                            anchors.Mouth.X + 0.10 + bubble.Size * 0.10,
                            anchors.Mouth.Y - bubble.Size * 0.02),
                        0.28 + bubble.Size * 1.15,
                        1));
                }
                if (bubble.Pop <= 0.02)
                {
                    break;
                }
                // The bubble is not there any more, only the argument about
                // where it went.
                for (int i = 0; i < 6; i++)
                {
                    double angle = i * (2 * Math.PI / 6);
                    double reach = 0.04 + (1 - bubble.Pop) * 0.16;
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Puff,
                        new PPoint(
                            anchors.Mouth.X + 0.16 + Math.Cos(angle) * reach,
                            anchors.Mouth.Y - 0.02 + Math.Sin(angle) * reach),
                        0.28 + (1 - bubble.Pop) * 0.34,
                        bubble.Pop * 0.55));
                }
                break;
            }

            case PersonaMood.Snacking:
            {
                var snack = PersonaMoodTiming.Snack(clock);
                if (snack.Left > 0.02)
                {
                    motes.Add(new PersonaMote(
                        PersonaMote.Kind.Cookie,
                        new PPoint(
                            anchors.Hands.X + 0.10 - snack.Bite * 0.045,
                            anchors.Hands.Y - 0.02 - snack.Bite * 0.02),
                        1,
                        snack.Left,
                        snack.Bites));
                }
                if (snack.Bite > 0.4)
                {
                    // Crumbs. Nobody eats a biscuit tidily and neither does this.
                    for (int i = 0; i < 3; i++)
                    {
                        double seed = i;
                        motes.Add(new PersonaMote(
                            PersonaMote.Kind.Dot,
                            new PPoint(
                                anchors.Mouth.X + 0.06 + Math.Sin(seed * 3.1) * 0.05,
                                anchors.Mouth.Y + 0.02 + (snack.Bite - 0.4) * (0.10 + seed * 0.04)),
                            0.24 + seed * 0.05,
                            (snack.Bite - 0.4) * 1.2));
                    }
                }
                if (snack.Happy <= 0.25)
                {
                    break;
                }
                motes.Add(new PersonaMote(
                    PersonaMote.Kind.Heart,
                    new PPoint(crown.X + 0.14, crown.Y - 0.03 - snack.Happy * 0.12),
                    0.7,
                    (snack.Happy - 0.25) * 1.4,
                    0.2));
                break;
            }

            case PersonaMood.Bouncing:
            case PersonaMood.Waiting:
                break;
        }
    }
}
