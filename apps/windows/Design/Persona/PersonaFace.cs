// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

namespace Tokenstat.Design.Persona;

internal sealed class PersonaFacePose
{
    internal enum Eyes
    {
        Normal,

        HappyArc,

        ContentArc,
    }

    public Eyes EyeStyle { get; set; }

    public double Openness { get; set; } = 1;

    public double Squint { get; set; }

    public PPoint Gaze { get; set; }

    public double Lift { get; set; }

    public double Spread { get; set; } = 1;

    public double Brow { get; set; }

    public double MouthCurve { get; set; }

    public double MouthOpen { get; set; }

    public double MouthWidth { get; set; } = 1;

    public bool Blinks { get; set; } = true;

    public double EyeScale { get; set; } = 1;

    public double Blush { get; set; }

    public double Tongue { get; set; }

    public double Cheer { get; set; }

    public double Droop { get; set; }

    public PersonaFacePose Expressed()
    {
        var output = Copy();
        switch (EyeStyle)
        {
            case Eyes.HappyArc:
                output.Cheer = 1;
                output.Squint = 0;
                output.Openness = 1;
                break;
            case Eyes.ContentArc:
                output.Openness = 0;
                output.Cheer = 0;
                output.Blinks = false;
                break;
        }
        output.EyeStyle = Eyes.Normal;
        return output;
    }

    private PersonaFacePose Copy() => new()
    {
        EyeStyle = EyeStyle, Openness = Openness, Squint = Squint, Gaze = Gaze, Lift = Lift,
        Spread = Spread, Brow = Brow, MouthCurve = MouthCurve, MouthOpen = MouthOpen,
        MouthWidth = MouthWidth, Blinks = Blinks, EyeScale = EyeScale, Blush = Blush,
        Tongue = Tongue, Cheer = Cheer, Droop = Droop,
    };

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
            Cheer = Mix(from.Cheer, to.Cheer),
            Droop = Mix(from.Droop, to.Droop),
            Blinks = to.Blinks,
            EyeStyle = k < 0.5 ? from.EyeStyle : to.EyeStyle,
        };
    }

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
        Cheer += (target.Cheer - Cheer) * k;
        Droop += (target.Droop - Droop) * k;
        Blinks = target.Blinks;
        EyeStyle = target.EyeStyle;
    }
}

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

        Paper,

        Console,

        Glow,

        Keyboard,

        Sheet,

        Mug,

        Sprout,

        Flower,

        Mark,

        Sweat,
        Heart,

        ShootingStar,

        Confetti,

        Stroke,

        Bubble,

        Cookie,

        Hammer,

        Nail,

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
