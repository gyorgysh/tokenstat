// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

namespace Tokenstat.Design.Persona;

/// <summary>
/// Where the face is and what it is doing, independent of where the body is.
/// Every field is a number rather than a case, so the engine can ease one pose
/// into the next and a mood change reads as an expression changing rather than
/// a mask being swapped.
/// </summary>
internal sealed class PersonaFacePose
{
    /// <summary>What the eyes are, when they are not eyes.</summary>
    internal enum Eyes
    {
        /// <summary>This creature's own eyes, from its traits.</summary>
        Normal,

        /// <summary>Two upward arcs. Pleased.</summary>
        HappyArc,

        /// <summary>Two downward arcs. Asleep, or content with its own company.</summary>
        ContentArc,
    }

    public Eyes EyeStyle { get; set; }

    /// <summary>Eyelid. Zero is shut, one is normal, above one is wide.</summary>
    public double Openness { get; set; } = 1;

    /// <summary>Lower lid. Concentration, not sleep.</summary>
    public double Squint { get; set; }

    /// <summary>Where it is looking, in eye-radii.</summary>
    public PPoint Gaze { get; set; }

    /// <summary>Eyes higher or lower on the body than usual.</summary>
    public double Lift { get; set; }

    /// <summary>Eye separation multiplier.</summary>
    public double Spread { get; set; } = 1;

    /// <summary>Negative raises the brows, positive lowers the inner ends.</summary>
    public double Brow { get; set; }

    /// <summary>Minus one is a frown, plus one a smile.</summary>
    public double MouthCurve { get; set; }

    public double MouthOpen { get; set; }

    public double MouthWidth { get; set; } = 1;

    public bool Blinks { get; set; } = true;

    /// <summary>
    /// Both eyes, bigger or smaller. Saucer eyes are half of surprise and the
    /// eyelid is only the other half.
    /// </summary>
    public double EyeScale { get; set; } = 1;

    /// <summary>Two warm patches under the eyes. Pleased with itself, or caught out.</summary>
    public double Blush { get; set; }

    /// <summary>
    /// How far the tongue is out of an open mouth. Effort, delight, or a
    /// deliberate raspberry, depending on the rest of the face.
    /// </summary>
    public double Tongue { get; set; }

    /// <summary>
    /// One expression part way into another. Used while a mood is changing, so
    /// the face is crossfading at the same time as the body rather than
    /// chasing a target that has already jumped.
    /// </summary>
    public static PersonaFacePose Blend(PersonaFacePose from, PersonaFacePose to, double amount)
    {
        double t = Math.Clamp(amount, 0, 1);
        double k = t * t * (3 - 2 * t);
        double Mix(double a, double b) => a + (b - a) * k;
        return new PersonaFacePose
        {
            Openness = Mix(from.Openness, to.Openness),
            Squint = Mix(from.Squint, to.Squint),
            Gaze = new PPoint(Mix(from.Gaze.X, to.Gaze.X), Mix(from.Gaze.Y, to.Gaze.Y)),
            Lift = Mix(from.Lift, to.Lift),
            Spread = Mix(from.Spread, to.Spread),
            Brow = Mix(from.Brow, to.Brow),
            MouthCurve = Mix(from.MouthCurve, to.MouthCurve),
            MouthOpen = Mix(from.MouthOpen, to.MouthOpen),
            MouthWidth = Mix(from.MouthWidth, to.MouthWidth),
            EyeScale = Mix(from.EyeScale, to.EyeScale),
            Blush = Mix(from.Blush, to.Blush),
            Tongue = Mix(from.Tongue, to.Tongue),
            Blinks = to.Blinks,
            // Eye shape is a decision, not a quantity. Half a star is not an
            // expression, so it changes at the midpoint, under the blink.
            EyeStyle = k < 0.5 ? from.EyeStyle : to.EyeStyle,
        };
    }

    /// <summary>
    /// Component-wise ease toward a target. Runs every step with a time
    /// constant, so a face never snaps and never lags noticeably either.
    /// </summary>
    public void EaseTowards(PersonaFacePose target, double rate)
    {
        double k = Math.Min(rate, 1);
        Openness += (target.Openness - Openness) * k;
        Squint += (target.Squint - Squint) * k;
        Gaze = new PPoint(Gaze.X + (target.Gaze.X - Gaze.X) * k, Gaze.Y + (target.Gaze.Y - Gaze.Y) * k);
        Lift += (target.Lift - Lift) * k;
        Spread += (target.Spread - Spread) * k;
        Brow += (target.Brow - Brow) * k;
        MouthCurve += (target.MouthCurve - MouthCurve) * k;
        MouthOpen += (target.MouthOpen - MouthOpen) * k;
        MouthWidth += (target.MouthWidth - MouthWidth) * k;
        EyeScale += (target.EyeScale - EyeScale) * k;
        Blush += (target.Blush - Blush) * k;
        Tongue += (target.Tongue - Tongue) * k;
        Blinks = target.Blinks;
        EyeStyle = target.EyeStyle;
    }
}

/// <summary>
/// One thing in the air. Positions are in the same unit space as the body.
/// </summary>
internal sealed class PersonaMote
{
    internal enum Kind
    {
        Dot,
        Ball,
        Spark,
        Note,
        Zed,
        Drop,
        Puff,

        /// <summary>An open newspaper, held.</summary>
        Paper,

        /// <summary>The back of something handheld. The screen faces the character, not us.</summary>
        Console,

        /// <summary>The light that screen throws back onto its face.</summary>
        Glow,

        /// <summary>A keyboard lying on the floor, near edge on the floor line.</summary>
        Keyboard,

        /// <summary>A sheet of paper on the floor, in the same shallow perspective.</summary>
        Sheet,

        /// <summary>A warm mug held at chest height.</summary>
        Mug,

        /// <summary>A tiny plant which makes an excellent desk companion.</summary>
        Sprout,

        /// <summary>What the sprout becomes if somebody keeps watering it.</summary>
        Flower,

        /// <summary>A punctuation mark in the air. Angle picks it: zero is an exclamation, anything else a question.</summary>
        Mark,

        /// <summary>The bead of sweat every cartoon has used for a hundred years, because it works.</summary>
        Sweat,
        Heart,

        /// <summary>A star with a tail, crossing the top of the frame.</summary>
        ShootingStar,

        /// <summary>One scrap of paper, tumbling. Angle is its spin.</summary>
        Confetti,

        /// <summary>A wet stroke of paint left on the floor.</summary>
        Stroke,

        /// <summary>Blown, growing, and about to be a mistake.</summary>
        Bubble,

        /// <summary>A round biscuit, with as many bites out of it as the angle allows.</summary>
        Cookie,

        /// <summary>A hammer, swung. Angle is where it is in the swing.</summary>
        Hammer,

        /// <summary>A nail in the floor. Scale is how much of it is still showing.</summary>
        Nail,

        /// <summary>A comically large paint brush dragged along the floor.</summary>
        Brush,
    }

    public PersonaMote(Kind kind, PPoint position, double scale = 1, double opacity = 1, double angle = 0)
    {
        MoteKind = kind;
        Position = position;
        Scale = scale;
        Opacity = opacity;
        Angle = angle;
    }

    public Kind MoteKind { get; }

    public PPoint Position { get; }

    public double Scale { get; set; }

    public double Opacity { get; set; }

    public double Angle { get; }
}
