// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

namespace Tokenstat.Design.Persona;

/// <summary>Where the face is, before the body's own motion pushes it around.</summary>
internal static class PersonaMoodFace
{
    public static PersonaFacePose Face(this PersonaMood mood, double clock, PersonaTraits traits)
    {
        var face = new PersonaFacePose();
        switch (mood)
        {
            case PersonaMood.Idle:
            {
                double yawn = PersonaMoodTiming.Beat(PersonaMoodTiming.Phase(clock, 11.5), 0.62, 0.76);
                face.Gaze = new PPoint(
                    Math.Sin(clock * 2 * Math.PI / 7.3) * 0.22,
                    Math.Sin(clock * 2 * Math.PI / 9.1) * 0.10);
                face.MouthCurve = traits.Mouth == PersonaTraits.MouthShape.Frown ? -0.30 : 0.45;
                if (yawn > 0.08)
                {
                    face.EyeStyle = PersonaFacePose.Eyes.ContentArc;
                    face.Brow = -0.30 * yawn;
                    face.MouthCurve = 0.10;
                    face.MouthOpen = yawn * 1.15;
                    face.MouthWidth = 0.72;
                    face.Tongue = yawn * 0.35;
                    face.Blinks = false;
                }
                break;
            }

            case PersonaMood.Bouncing:
                face.Openness = 1.10;
                face.EyeScale = 1.14;
                face.MouthCurve = 0.55;
                face.MouthOpen = 0.55;
                face.MouthWidth = 0.80;
                face.Tongue = 0.40;
                face.Gaze = new PPoint(0, -0.12);
                face.Blinks = false;
                break;

            case PersonaMood.Thinking:
            {
                double idea = PersonaMoodTiming.ThinkingIdea(clock);
                double orbit = clock * 2 * Math.PI / 2.4;
                face.Lift = 0.10;
                face.Gaze = new PPoint(0.42 + Math.Cos(orbit) * 0.22, -0.55 + Math.Sin(orbit) * 0.16);
                face.Openness = 0.86;
                face.Squint = 0.24 * (1 - idea);
                face.Brow = 0.30 - idea * 0.75;
                face.MouthCurve = -0.05 + idea * 1.0;
                face.MouthWidth = 0.70 + idea * 0.35;
                face.MouthOpen = idea * 0.55;
                if (idea > 0.45)
                {
                    // The moment it lands, and the only moment. Held any
                    // longer and having an idea stops being an event.
                    face.Openness = 1.15;
                    face.Squint = 0;
                    face.EyeScale = 1.10;
                }
                break;
            }

            case PersonaMood.Working:
            {
                var job = PersonaMoodTiming.Hammering(clock);
                face.Openness = 0.62 + job.Admire * 0.30;
                face.Squint = 0.32 * (1 - job.Admire);
                face.Brow = 0.40 - job.Admire * 0.55;
                // Eyes on the nail, all the way down. It is what makes the
                // swing land somewhere rather than merely happen.
                face.Gaze = new PPoint(0.45 - job.Admire * 0.20, 0.60 - job.Admire * 0.85);
                face.Lift = -0.02;
                face.MouthCurve = -0.1 + job.Admire * 1.0 + job.Strike * 0.2;
                face.MouthWidth = 0.75;
                face.MouthOpen = job.Strike * 0.30;
                face.Blinks = false;
                if (job.Admire > 0.55)
                {
                    face.EyeStyle = PersonaFacePose.Eyes.HappyArc;
                }
                break;
            }

            case PersonaMood.Speaking:
            {
                double syllable = PersonaMoodTiming.SpeechEnvelope(clock);
                face.Openness = 1.0 + syllable * 0.16;
                // Brows up, never down, and the mouth kept to a talking size.
                face.Brow = -0.16 - syllable * 0.10;
                face.MouthOpen = 0.24 + syllable * 0.62;
                face.MouthCurve = 0.38;
                face.MouthWidth = 1.05 + syllable * 0.30;
                face.Gaze = new PPoint(Math.Sin(clock * 2 * Math.PI / 3.7) * 0.25, -0.10);
                break;
            }

            case PersonaMood.Juggling:
            {
                var ball = PersonaMoodTiming.RallyBall(clock);
                face.Gaze = new PPoint(
                    (ball.Point.X - PersonaStage.CentreX) * 3.4,
                    (ball.Point.Y - 0.42) * 2.6);
                face.Openness = 1.12;
                face.MouthCurve = 0.45 - ball.Panic * 0.9;
                face.MouthOpen = 0.22 + ball.Panic * 0.7;
                face.Blinks = false;
                if (ball.Panic > 0.35)
                {
                    // It is going to be fine. It does not know that.
                    face.Openness = 1.12 + ball.Panic * 0.45;
                    face.EyeScale = 1 + ball.Panic * 0.40;
                    face.Brow = -0.4;
                }
                break;
            }

            case PersonaMood.Dancing:
            {
                double beat = clock / PersonaMoodTiming.BeatPeriod;
                face.Openness = 0.10;
                face.Squint = 0;
                face.EyeStyle = PersonaFacePose.Eyes.HappyArc;
                face.MouthCurve = 0.85;
                face.MouthOpen = 0.20 + Math.Max(0, Math.Sin(beat * 2 * Math.PI)) * 0.22;
                face.Blush = 0.22;
                face.Gaze = new PPoint(Math.Sin(beat * Math.PI) * 0.3, 0);
                face.Blinks = false;
                break;
            }

            case PersonaMood.Waiting:
            {
                // Big round eyes, but relaxed brows and a tiny smile: eager is
                // friendlier than an unblinking, alarmed stare.
                double sigh = PersonaMoodTiming.WaitingSigh(clock);
                face.Openness = 1.12;
                face.EyeScale = 1.06;
                face.Brow = -0.08 + sigh * 0.40;
                face.Lift = 0.02;
                face.Spread = 0.86;
                face.Gaze = new PPoint(Math.Sin(clock * 2 * Math.PI / 3.1) * 0.10, 0.04 + sigh * 0.25);
                face.MouthCurve = 0.34 - sigh * 0.70;
                face.MouthOpen = 0.10 + sigh * 0.30;
                face.MouthWidth = 0.58;
                if (sigh > 0.55)
                {
                    face.EyeStyle = PersonaFacePose.Eyes.ContentArc;
                }
                break;
            }

            case PersonaMood.Ok:
                face.EyeStyle = PersonaFacePose.Eyes.HappyArc;
                face.Openness = 0.24;
                face.MouthCurve = 1;
                face.MouthOpen = 0.55;
                face.MouthWidth = 1.10;
                face.Blush = 0.35;
                face.Blinks = false;
                break;

            case PersonaMood.Failed:
            {
                double melt = Math.Clamp((clock - 0.34) / 0.85, 0, 1);
                double retry = PersonaMoodTiming.FailedRetry(clock);
                face.Openness = 1 - melt * 0.66;
                face.Brow = 0.35 + melt * 0.35;
                face.Gaze = new PPoint(0, 0.30 + melt * 0.25);
                face.Lift = -melt * 0.05;
                face.MouthCurve = -0.8;
                face.MouthWidth = 0.9;
                face.MouthOpen = retry * 0.35;
                face.Blinks = false;
                break;
            }

            case PersonaMood.Reading:
            {
                // A saccade, not a sweep: eyes jump along a line, drop to the
                // next one, and jump back. Reading is what that looks like.
                var gag = PersonaMoodTiming.ReadingGag(clock);
                double line = clock / 2.1;
                double across = line - Math.Floor(line);
                face.Gaze = new PPoint(
                    -0.55 + Math.Floor(across * 5) / 4 * 1.10,
                    0.30 + ((int)Math.Floor(line) % 3 == 2 ? 0.10 : 0));
                face.Openness = 0.86;
                face.Squint = 0.22;
                face.Brow = 0.16;
                // Eyes up on the body, so they clear the top edge of the paper.
                face.Lift = 0.07;
                face.MouthCurve = 0.10;
                face.MouthWidth = 0.7;
                if (gag.Shock > 0.25)
                {
                    face.Openness = 0.86 + gag.Shock * 0.60;
                    face.EyeScale = 1 + gag.Shock * 0.35;
                    face.Squint = 0;
                    face.Gaze = new PPoint(0, 0.20);
                    face.Brow = -0.5;
                    face.MouthOpen = gag.Shock * 0.55;
                    face.MouthCurve = -0.3;
                }
                else if (gag.Laugh > 0.25)
                {
                    face.EyeStyle = PersonaFacePose.Eyes.HappyArc;
                    face.MouthCurve = 0.9;
                    face.MouthOpen = gag.Laugh * 0.75;
                    face.MouthWidth = 1.0;
                    face.Tongue = gag.Laugh * 0.30;
                    face.Blush = gag.Laugh * 0.35;
                }
                break;
            }

            case PersonaMood.Gaming:
            {
                var round = PersonaMoodTiming.GamingRound(clock);
                face.Openness = 1.06 - round.Win * 0.9;
                face.Squint = 0.14;
                face.Brow = 0.34 - round.Win * 0.8 + round.Loss * 0.5;
                face.Gaze = new PPoint(0, 0.58);
                face.Lift = -0.02;
                face.MouthCurve = -0.05 + round.Win * 1.1 - round.Loss * 1.0;
                face.MouthOpen = 0.20 + round.Win * 0.55 + round.Loss * 0.25;
                face.MouthWidth = 0.68 + round.Win * 0.45;
                face.Tongue = round.Win * 0.40;
                face.Blush = round.Win * 0.35;
                if (round.Win > 0.45)
                {
                    face.EyeStyle = PersonaFacePose.Eyes.HappyArc;
                }
                else if (round.Loss > 0.3)
                {
                    // Sad, not dead. Half-shut eyes under a heavy brow.
                    face.Openness = 0.55;
                    face.Squint = 0.45;
                }
                break;
            }

            case PersonaMood.Pacing:
            {
                var walk = PersonaMoodTiming.PacingWalk(PersonaMoodTiming.PacingClock(clock));
                double idea = PersonaMoodTiming.PacingIdea(clock);
                face.Gaze = new PPoint(walk.Direction * 0.55 * (1 - idea), -0.10 - idea * 0.55);
                face.Openness = 0.92;
                face.Squint = 0.18 * (1 - idea);
                face.Brow = 0.28 - idea * 0.70;
                face.MouthCurve = -0.08 + idea * 1.0;
                face.MouthWidth = 0.72;
                face.MouthOpen = idea * 0.45;
                if (idea > 0.45)
                {
                    face.Openness = 1.10;
                    face.Squint = 0;
                    face.Brow = -0.45;
                }
                break;
            }

            case PersonaMood.Typing:
            {
                var keys = PersonaMoodTiming.Typing(clock);
                face.Openness = 0.90 + keys.Pause * 0.10;
                face.Squint = 0.22 * (1 - keys.Pause);
                face.Brow = 0.18 - keys.Pause * 0.45;
                face.Gaze = new PPoint(0.40 * (1 - keys.Pause), 0.62 - keys.Pause * 1.30);
                face.Lift = -0.03;
                face.MouthCurve = 0.10 - keys.Pause * 0.28 + keys.Nod * 0.80;
                face.MouthWidth = 0.66;
                face.Blinks = false;
                if (keys.Nod > 0.5)
                {
                    face.EyeStyle = PersonaFacePose.Eyes.HappyArc;
                }
                break;
            }

            case PersonaMood.Sipping:
            {
                var tea = PersonaMoodTiming.Tea(clock);
                face.Openness = 0.72 - tea.Lift * 0.28;
                face.Squint = 0.20 + tea.Lift * 0.25;
                face.Gaze = new PPoint(0.12 * tea.Lift, 0.40 - tea.Lift * 0.10);
                face.Lift = -0.02;
                face.MouthCurve = 0.30 + tea.Warm * 0.45;
                face.MouthOpen = tea.Lift * 0.10;
                face.MouthWidth = 0.60;
                face.Blush = tea.Warm * 0.30;
                if (tea.Warm > 0.45)
                {
                    face.EyeStyle = PersonaFacePose.Eyes.ContentArc;
                }
                break;
            }

            case PersonaMood.Sketching:
            {
                var work = PersonaMoodTiming.Sketch(clock);
                face.Openness = 0.70;
                face.Squint = 0.30 * (1 - work.Look);
                face.Brow = 0.24 - work.Look * 0.45;
                face.Gaze = new PPoint(0.30 + work.Sweep * 0.22, 0.62 - work.Look * 0.34);
                face.Lift = -0.04;
                face.MouthCurve = 0.08 + work.Look * 0.60;
                face.MouthWidth = 0.66;
                face.Blinks = false;
                if (work.Look > 0.5)
                {
                    face.EyeStyle = PersonaFacePose.Eyes.HappyArc;
                    face.Blush = 0.25;
                }
                break;
            }

            case PersonaMood.Stargazing:
            {
                var sky = PersonaMoodTiming.Sky(clock);
                double orbit = clock * 2 * Math.PI / 5.2;
                face.Openness = 1.05;
                face.Squint = 0.08;
                face.Brow = -0.12;
                face.Gaze = new PPoint(Math.Cos(orbit) * 0.40, -0.68 + Math.Sin(orbit) * 0.10);
                face.Lift = 0.12;
                face.MouthCurve = 0.45;
                face.MouthWidth = 0.68;
                if (sky.Gasp > 0.2)
                {
                    face.EyeScale = 1 + sky.Gasp * 0.35;
                    face.Gaze = new PPoint(sky.StarX * 2.2, -0.85);
                    face.MouthOpen = sky.Gasp * 0.60;
                    face.MouthWidth = 0.55;
                    face.Brow = -0.45;
                }
                else if (sky.Wish > 0.2)
                {
                    face.EyeStyle = PersonaFacePose.Eyes.ContentArc;
                    face.MouthCurve = 0.85;
                    face.Blush = sky.Wish * 0.45;
                }
                break;
            }

            case PersonaMood.Gardening:
            {
                var plot = PersonaMoodTiming.Garden(clock);
                face.Openness = 0.68;
                face.Squint = 0.22 * (1 - plot.Joy);
                face.Brow = 0.18 - plot.Joy * 0.55;
                face.Gaze = new PPoint(0.34, 0.56 - plot.Joy * 0.40);
                face.Lift = -0.04;
                face.MouthCurve = 0.30 + plot.Joy * 0.75;
                face.MouthWidth = 0.66 + plot.Joy * 0.30;
                face.MouthOpen = plot.Joy * 0.40;
                face.Blinks = false;
                if (plot.Joy > 0.4)
                {
                    face.EyeStyle = PersonaFacePose.Eyes.HappyArc;
                    face.Blush = 0.45;
                }
                break;
            }

            case PersonaMood.Bubbling:
            {
                var bubble = PersonaMoodTiming.Bubble(clock);
                face.Openness = 0.80;
                face.Squint = 0.30 * bubble.Blow;
                face.Brow = 0.20 * bubble.Blow;
                face.Gaze = new PPoint(0, 0.45 + bubble.Blow * 0.10);
                face.MouthCurve = 0.10;
                face.MouthOpen = 0.22 + bubble.Blow * 0.12;
                face.MouthWidth = 0.42;
                face.Blush = bubble.Blow * 0.25 + bubble.Sheepish * 0.60;
                if (bubble.Pop > 0.15)
                {
                    face.Openness = 0.80 + bubble.Pop * 0.70;
                    face.EyeScale = 1 + bubble.Pop * 0.45;
                    face.Squint = 0;
                    face.Brow = -0.6;
                    face.MouthOpen = 0.55;
                    face.MouthWidth = 0.80;
                    face.Blinks = false;
                }
                else if (bubble.Sheepish > 0.3)
                {
                    face.EyeStyle = PersonaFacePose.Eyes.HappyArc;
                    face.MouthCurve = 0.55;
                }
                break;
            }

            case PersonaMood.Snacking:
            {
                var snack = PersonaMoodTiming.Snack(clock);
                face.Openness = 0.80;
                face.Squint = 0.20 + snack.Chew * 0.35;
                face.Gaze = new PPoint(-0.10, 0.42 - snack.Bite * 0.20);
                face.MouthCurve = 0.35 + snack.Happy * 0.60;
                face.MouthWidth = 0.60 + snack.Bite * 0.35;
                face.MouthOpen = snack.Bite * 1.10 + snack.Chew * 0.16;
                face.Tongue = snack.Bite * 0.35;
                face.Blush = snack.Happy * 0.55;
                if (snack.Chew > 0.4 || snack.Happy > 0.4)
                {
                    face.EyeStyle = PersonaFacePose.Eyes.ContentArc;
                }
                break;
            }

            case PersonaMood.Sleeping:
            {
                var snore = PersonaMoodTiming.Snore(clock);
                face.EyeStyle = PersonaFacePose.Eyes.ContentArc;
                face.Openness = 0.05;
                face.Lift = -0.02;
                face.MouthCurve = 0.15 + snore.Dream * 0.5;
                face.MouthOpen = 0.18 + Math.Max(0, snore.Breath) * 0.34;
                face.MouthWidth = 0.5;
                face.Blush = snore.Dream * 0.40;
                face.Blinks = false;
                break;
            }
        }
        return face;
    }
}
