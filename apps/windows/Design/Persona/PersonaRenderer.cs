// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Tokenstat.Design.Persona;

/// <summary>
/// Everything a persona looks like, drawn in one pass. Nothing in here decides
/// anything. It reads the engine and paints it, which is why a new mood needs
/// no drawing code: it moves the body, and the body is what this file draws.
/// Without Win2D there is no immediate-mode canvas, so each frame rebuilds a
/// set of Path elements on a WinUI Canvas: shadow, body, clipped face, motes.
/// </summary>
internal static class PersonaRenderer
{
    public static void Draw(PersonaEngine engine, Canvas canvas, double width, double height)
    {
        canvas.Children.Clear();
        double unit = Math.Min(width, height);
        if (unit <= 1)
        {
            return;
        }

        var traits = engine.Traits;
        var body = engine.Body;
        var bounds = body.Bounds;
        var hue = traits.Hue;
        var ink = engine.Mood.Tint() ?? hue;
        var outline = OutlineGeometry(body, width, height);

        DrawShadow(canvas, bounds, width, height, unit, hue);

        if (traits.HasAntenna && unit >= 18)
        {
            DrawAntenna(canvas, body, width, height, unit, hue);
        }

        canvas.Children.Add(PersonaDraw.Shape(
            outline,
            PersonaDraw.Linear(
                PersonaDraw.Pt(0.5, 0), PersonaDraw.Pt(0.5, 1),
                (hue.WithOpacity(0.20), 0), (hue.WithOpacity(0.38), 1))));
        canvas.Children.Add(PersonaDraw.Shape(
            outline, null, PersonaDraw.Solid(hue, 0.92), Math.Max(1, unit * 0.036)));
        var tint = engine.Mood.Tint();
        if (tint is { } stain)
        {
            canvas.Children.Add(PersonaDraw.Shape(
                outline, null, PersonaDraw.Solid(stain), Math.Max(1.5, unit * 0.055)));
        }

        // Face, highlight and screen light are clipped to the body, so a heavy
        // squash pushes them around inside the creature rather than letting an
        // eye escape it.
        DrawHighlight(canvas, bounds, width, height, outline);
        DrawFace(engine, canvas, width, height, unit, ink, outline);
        foreach (var mote in engine.Motes)
        {
            if (mote.MoteKind == PersonaMote.Kind.Glow)
            {
                PersonaRendererProps.DrawGlow(canvas, mote, width, height, unit, outline);
            }
        }

        if (unit >= 20)
        {
            DrawMotes(engine, canvas, width, height, unit, hue, ink);
        }
    }

    /// <summary>
    /// The silhouette, as one closed path of cubic segments. Catmull-Rom
    /// through the smoothed ring, converted to Beziers, which is what keeps a
    /// heavy squash from creasing.
    /// </summary>
    public static PathGeometry OutlineGeometry(PersonaSoftBody body, double width, double height)
    {
        var points = body.Outline(width, height);
        var geometry = new PathGeometry();
        int n = points.Length;
        if (n <= 3)
        {
            return geometry;
        }
        var figure = PersonaDraw.Figure(points[0]);
        for (int i = 0; i < n; i++)
        {
            var p0 = points[(i + n - 1) % n];
            var p1 = points[i];
            var p2 = points[(i + 1) % n];
            var p3 = points[(i + 2) % n];
            PersonaDraw.Bezier(
                figure, p2,
                new PPoint(p1.X + (p2.X - p0.X) / 6, p1.Y + (p2.Y - p0.Y) / 6),
                new PPoint(p2.X - (p3.X - p1.X) / 6, p2.Y - (p3.Y - p1.Y) / 6));
        }
        geometry.Figures.Add(figure);
        return geometry;
    }

    private static void DrawShadow(
        Canvas canvas, PRect bounds, double width, double height, double unit, Color hue)
    {
        // Contact shadow: it shrinks and fades as the body leaves the ground,
        // which is most of what sells a jump as a jump.
        double air = Math.Max(0, PersonaStage.Floor - bounds.MaxY);
        double closeness = Math.Max(0.30, 1 - air * 2.6);
        double w = bounds.Width * width * 0.80 * closeness;
        double h = unit * 0.052 * closeness;
        double y = PersonaStage.Floor * height - h * 0.35;
        var geometry = new PathGeometry();
        PersonaDraw.Ellipse(geometry, width / 2, y + h / 2, w / 2, h / 2);
        canvas.Children.Add(PersonaDraw.Shape(geometry, PersonaDraw.Solid(hue, 0.20 * closeness)));
    }

    private static void DrawHighlight(Canvas canvas, PRect bounds, double width, double height, Geometry clip)
    {
        // Placed off the middle rather than off the bounding box, so a squash
        // slides it across the body instead of pinning it to a corner.
        double w = bounds.Width * width * 0.155;
        double h = bounds.Height * height * 0.085;
        double cx = bounds.MidX * width - w * 1.55 + w / 2;
        double cy = (bounds.MinY + bounds.Height * 0.17) * height + h / 2;
        var geometry = new PathGeometry();
        PersonaDraw.EllipseRotated(geometry, cx, cy, w / 2, h / 2, -0.5);
        // A soft gradient rather than a flat ellipse: at low opacity a hard
        // edge reads as a scuff on the surface instead of light on it.
        canvas.Children.Add(PersonaDraw.Shape(
            geometry,
            PersonaDraw.Radial(
                PersonaDraw.Pt(0.5, 0.5), 0.62,
                (PersonaDraw.White.WithOpacity(0.26), 0), (PersonaDraw.White.WithOpacity(0), 1)),
            clip: clip));
    }

    private static void DrawAntenna(
        Canvas canvas, PersonaSoftBody body, double width, double height, double unit, Color tint)
    {
        // Rooted in the crown node, so it whips with the squash instead of
        // floating over a rectangle the body no longer fills.
        var crown = body.Crown;
        double rootX = crown.X * width;
        double rootY = crown.Y * height;
        double lean = (crown.X - body.Centroid.X) * width;
        double tipX = rootX + unit * 0.06 + lean * 1.6;
        double tipY = rootY - unit * 0.15;
        var stalk = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(rootX, rootY + unit * 0.02), false);
        PersonaDraw.Quad(figure, new PPoint(tipX, tipY), new PPoint(rootX + unit * 0.09 + lean, rootY - unit * 0.05));
        stalk.Figures.Add(figure);
        canvas.Children.Add(PersonaDraw.Shape(
            stalk, null, PersonaDraw.Solid(tint, 0.75), Math.Max(1, unit * 0.032),
            PenLineCap.Round, PenLineJoin.Round));
        var tip = new PathGeometry();
        PersonaDraw.Ellipse(tip, tipX, tipY, unit * 0.045, unit * 0.045);
        canvas.Children.Add(PersonaDraw.Shape(tip, PersonaDraw.Solid(tint)));
    }

    private static void DrawFace(
        PersonaEngine engine, Canvas canvas, double width, double height,
        double unit, Color ink, Geometry clip)
    {
        var traits = engine.Traits;
        var face = engine.Face;
        var body = engine.Body;
        var bounds = body.Bounds;
        var centroid = body.Centroid;
        var crown = body.Crown;

        // The face borrows the body's own squash rather than being animated
        // separately. Wide and flat means narrow eyes further apart, tall and
        // thin means round eyes closer together.
        double aspect = Math.Clamp(bounds.Height / Math.Max(bounds.Width, 1e-4), 0.45, 1.7);

        // Lean, taken from where the crown sits relative to the middle. The
        // face tilts with the body for free, in every mood.
        double tilt = Math.Atan2(crown.X - centroid.X, Math.Max(centroid.Y - crown.Y, 1e-4)) * 0.75;

        double heightPoints = bounds.Height * height;
        double anchorHeight = heightPoints * (0.10 + face.Lift);
        double originX = centroid.X * width;
        double originY = centroid.Y * height;
        PPoint Place(double dx, double dy) => new(
            originX + dx * Math.Cos(tilt) - dy * Math.Sin(tilt),
            originY + dx * Math.Sin(tilt) + dy * Math.Cos(tilt));

        int count = traits.EyeCount;
        // Small marks need proportionally bigger features or the face turns
        // into two specks. Three fixed steps, not a curve.
        double lod = unit < 24 ? 1.35 : unit < 34 ? 1.15 : 1.0;
        double radius = unit * (count == 1 ? 0.115 : count == 2 ? 0.082 : 0.065)
            * lod * Math.Clamp(face.EyeScale, 0.4, 2.2);
        double spread = radius * (count == 2 ? 2.9 : 2.6) * face.Spread / Math.Max(Math.Sqrt(aspect), 0.6);
        double openness = Math.Max(0.02, face.Openness * (1 - engine.Blink * 0.96) * aspect);

        for (int i = 0; i < count; i++)
        {
            double offset = i - (count - 1) / 2.0;
            var centre = Place(
                offset * spread + face.Gaze.X * radius * 0.34,
                -anchorHeight + face.Gaze.Y * radius * 0.30);
            // The lower lid takes a bite out of the bottom of the eye.
            // Concentration reads as a lid: shrinking the whole eye instead
            // just makes the creature look further away.
            double lid = radius * 2 * openness * Math.Clamp(face.Squint, 0, 0.8);
            double ex = centre.X - radius;
            double ey = centre.Y - radius * openness;
            double ew = radius * 2;
            double eh = Math.Max(radius * 0.10, radius * 2 * openness - lid);
            switch (face.EyeStyle)
            {
                case PersonaFacePose.Eyes.HappyArc:
                    DrawArcEye(canvas, ex, ey, ew, eh, unit, ink, false, clip);
                    break;
                case PersonaFacePose.Eyes.ContentArc:
                    DrawArcEye(canvas, ex, ey, ew, eh, unit, ink, true, clip);
                    break;
                default:
                    var eye = new PathGeometry();
                    switch (traits.Eye)
                    {
                        case PersonaTraits.EyeShape.Pixel:
                            PersonaDraw.RoundedRect(eye, ex, ey, ew, eh, radius * 0.32);
                            break;
                        case PersonaTraits.EyeShape.Oval:
                            PersonaDraw.Ellipse(eye, ex + ew / 2, ey + eh / 2, ew / 2 - radius * 0.22, eh / 2);
                            break;
                        default:
                            PersonaDraw.Ellipse(eye, ex + ew / 2, ey + eh / 2, ew / 2, eh / 2);
                            break;
                    }
                    canvas.Children.Add(PersonaDraw.Shape(eye, PersonaDraw.Solid(ink), clip: clip));
                    break;
            }

            if (unit >= 30 && Math.Abs(face.Brow) > 0.06)
            {
                DrawBrow(canvas, centre, radius, unit, ink, face.Brow, offset, clip);
            }
        }

        if (face.Blush > 0.02 && unit >= 26)
        {
            DrawBlush(canvas, Place, anchorHeight, radius, spread, unit, face.Blush, clip);
        }

        if (unit < 21)
        {
            return;
        }
        DrawMouth(canvas, Place, anchorHeight, radius, unit, ink, face, traits, clip);
    }

    private static void DrawArcEye(
        Canvas canvas, double x, double y, double w, double h,
        double unit, Color ink, bool flipped, Geometry clip)
    {
        double midY = y + h / 2;
        double lift = w * 0.55;
        var geometry = new PathGeometry();
        var arc = PersonaDraw.Figure(new PPoint(0, 0), false);
        if (flipped)
        {
            arc.StartPoint = PersonaDraw.Pt(x, midY - lift * 0.3);
            PersonaDraw.Quad(arc, new PPoint(x + w, midY - lift * 0.3), new PPoint(x + w / 2, midY + lift * 0.9));
        }
        else
        {
            arc.StartPoint = PersonaDraw.Pt(x, midY + lift * 0.3);
            PersonaDraw.Quad(arc, new PPoint(x + w, midY + lift * 0.3), new PPoint(x + w / 2, midY - lift * 1.5));
        }
        geometry.Figures.Add(arc);
        canvas.Children.Add(PersonaDraw.Shape(
            geometry, null, PersonaDraw.Solid(ink), Math.Max(1, unit * 0.05),
            PenLineCap.Round, PenLineJoin.Round, clip));
    }

    /// <summary>Two soft patches on the cheeks, drawn under the eyes and outside them.</summary>
    private static void DrawBlush(
        Canvas canvas, Func<double, double, PPoint> place, double anchorHeight,
        double radius, double spread, double unit, double amount, Geometry clip)
    {
        double strength = Math.Clamp(amount, 0, 1);
        foreach (double side in new double[] { -1, 1 })
        {
            var centre = place(side * (spread * 0.62 + radius * 0.9), -anchorHeight + radius * 1.25);
            double w = radius * 1.5;
            double h = radius * 0.78;
            var geometry = new PathGeometry();
            PersonaDraw.Ellipse(geometry, centre.X, centre.Y, w / 2, h / 2);
            canvas.Children.Add(PersonaDraw.Shape(
                geometry,
                PersonaDraw.Radial(
                    PersonaDraw.Pt(0.5, 0.5), 0.62,
                    (Theme.Danger.WithOpacity(0.42 * strength), 0), (Theme.Danger.WithOpacity(0), 1)),
                clip: clip));
        }
    }

    private static void DrawBrow(
        Canvas canvas, PPoint centre, double radius, double unit, Color ink,
        double amount, double side, Geometry clip)
    {
        // The inner end drops for strain and rises for surprise. Which end is
        // inner depends on which eye this is, so one number does both brows.
        double inner = side <= 0 ? 1 : -1;
        double w = radius * 1.5;
        double lift = radius * (1.55 + Math.Max(0, -amount) * 0.5);
        double drop = radius * amount * 0.55;
        var a = new PPoint(centre.X - w / 2 * inner, centre.Y - lift + drop);
        var b = new PPoint(centre.X + w / 2 * inner, centre.Y - lift - drop * 0.4);
        var geometry = new PathGeometry();
        var path = PersonaDraw.Figure(a, false);
        PersonaDraw.Quad(path, b, new PPoint((a.X + b.X) / 2, (a.Y + b.Y) / 2 - radius * 0.18));
        geometry.Figures.Add(path);
        canvas.Children.Add(PersonaDraw.Shape(
            geometry, null, PersonaDraw.Solid(ink, 0.72), Math.Max(1, unit * 0.036),
            PenLineCap.Round, PenLineJoin.Round, clip));
    }

    private static void DrawMouth(
        Canvas canvas, Func<double, double, PPoint> place, double anchorHeight,
        double radius, double unit, Color ink, PersonaFacePose face,
        PersonaTraits traits, Geometry clip)
    {
        // A mouth is one closed path with two curved edges: the top edge
        // carries the smile, the gap between the edges carries the speech.
        // The persona's own mouth is a bias on the mood's, not a replacement.
        double resting = traits.Mouth switch
        {
            PersonaTraits.MouthShape.Smile => 0.34,
            PersonaTraits.MouthShape.Frown => -0.34,
            PersonaTraits.MouthShape.Flat => -0.10,
            _ => 0,
        };
        double curve = Math.Clamp(face.MouthCurve + resting, -1.1, 1.1);
        // An open mouth widens as it opens. Without it a loud syllable is a
        // tall narrow wedge rather than a vowel.
        double half = unit * 0.078 * face.MouthWidth * traits.MouthWidth
            * (1 + Math.Clamp(face.MouthOpen, 0, 1.2) * 0.22);
        double open = Math.Max(0, face.MouthOpen) * unit * 0.140;
        double baseY = -anchorHeight + radius * 2.15;

        var left = place(-half, baseY);
        var right = place(half, baseY);
        // A quadratic reaches half its control offset, so the gap between the
        // two edges is half of open. Doubled here rather than in the moods.
        var bow = place(0, baseY + curve * unit * 0.142);
        var sag = place(0, baseY + curve * unit * 0.142 + open * 2);

        if (open < unit * 0.006)
        {
            var line = new PathGeometry();
            var stroke = PersonaDraw.Figure(left, false);
            PersonaDraw.Quad(stroke, right, bow);
            line.Figures.Add(stroke);
            canvas.Children.Add(PersonaDraw.Shape(
                line, null, PersonaDraw.Solid(ink, 0.78), Math.Max(1, unit * 0.038),
                PenLineCap.Round, PenLineJoin.Round, clip));
            return;
        }

        var geometry = new PathGeometry();
        var path = PersonaDraw.Figure(left);
        PersonaDraw.Quad(path, right, bow);
        PersonaDraw.Quad(path, left, sag);
        geometry.Figures.Add(path);
        canvas.Children.Add(PersonaDraw.Shape(geometry, PersonaDraw.Solid(ink, 0.72), clip: clip));

        if (face.Tongue <= 0.02)
        {
            return;
        }
        // Clipped to the mouth, so a tongue never escapes the face however
        // wide the mood asked for it.
        double reach = Math.Clamp(face.Tongue, 0, 1);
        var tip = place(0, baseY + curve * unit * 0.142 + open * 2 * (1 - reach * 0.55));
        double tw = half * 0.86;
        var tongue = new PathGeometry();
        var both = new CombinedGeometry(GeometryCombineMode.Intersect, clip, geometry);
        PersonaDraw.Ellipse(tongue, tip.X, tip.Y + open * 0.15 + unit * 0.01, tw / 2, open * 0.75 + unit * 0.01);
        canvas.Children.Add(PersonaDraw.Shape(
            tongue, PersonaDraw.Solid(Theme.Danger, 0.62), clip: both));
    }

    private static void DrawMotes(
        PersonaEngine engine, Canvas canvas, double width, double height,
        double unit, Color hue, Color ink)
    {
        foreach (var mote in engine.Motes)
        {
            if (mote.MoteKind == PersonaMote.Kind.Glow)
            {
                continue;
            }
            double px = mote.Position.X * width;
            double py = mote.Position.Y * height;
            switch (mote.MoteKind)
            {
                case PersonaMote.Kind.Dot:
                {
                    double size = unit * 0.052 * mote.Scale;
                    var geometry = new PathGeometry();
                    PersonaDraw.Ellipse(geometry, px, py, size, size);
                    canvas.Children.Add(PersonaDraw.Shape(
                        geometry, PersonaDraw.Solid(hue, mote.Opacity * 0.85)));
                    break;
                }

                case PersonaMote.Kind.Ball:
                {
                    double size = unit * 0.062;
                    var geometry = new PathGeometry();
                    PersonaDraw.Ellipse(geometry, px, py, size, size);
                    canvas.Children.Add(PersonaDraw.Shape(
                        geometry, PersonaDraw.Solid(Theme.Secondary, mote.Opacity)));
                    var shine = new PathGeometry();
                    PersonaDraw.Ellipse(shine, px - size * 0.30, py - size * 0.40, size * 0.35, size * 0.30);
                    canvas.Children.Add(PersonaDraw.Shape(
                        shine, PersonaDraw.Solid(PersonaDraw.White, 0.5 * mote.Opacity)));
                    break;
                }

                case PersonaMote.Kind.Spark:
                {
                    double reach = unit * 0.062 * mote.Scale;
                    var geometry = new PathGeometry();
                    for (int step = 0; step < 2; step++)
                    {
                        double angle = mote.Angle + step * Math.PI / 2;
                        var stroke = PersonaDraw.Figure(
                            new PPoint(px - Math.Cos(angle) * reach, py - Math.Sin(angle) * reach), false);
                        PersonaDraw.Line(stroke, px + Math.Cos(angle) * reach, py + Math.Sin(angle) * reach);
                        geometry.Figures.Add(stroke);
                    }
                    canvas.Children.Add(PersonaDraw.Shape(
                        geometry, null, PersonaDraw.Solid(hue, mote.Opacity), Math.Max(1, unit * 0.032),
                        PenLineCap.Round, PenLineJoin.Round));
                    break;
                }

                case PersonaMote.Kind.Note:
                {
                    double size = unit * 0.055 * mote.Scale;
                    var head = new PathGeometry();
                    PersonaDraw.Ellipse(head, px - size * 0.15, py, size * 0.85, size * 0.65);
                    canvas.Children.Add(PersonaDraw.Shape(head, PersonaDraw.Solid(hue, mote.Opacity)));
                    double stemX = px - size * 0.15 + size * 0.85 - size * 0.12;
                    var stem = new PathGeometry();
                    var line = PersonaDraw.Figure(new PPoint(stemX, py), false);
                    PersonaDraw.Line(line, stemX, py - size * 0.65 - size * 1.5);
                    PersonaDraw.Quad(
                        line,
                        new PPoint(stemX + size * 0.12 + size * 0.75, py - size * 0.65 - size * 0.55),
                        new PPoint(stemX + size * 0.12 + size * 0.85, py - size * 0.65 - size * 1.5));
                    stem.Figures.Add(line);
                    canvas.Children.Add(PersonaDraw.Shape(
                        stem, null, PersonaDraw.Solid(hue, mote.Opacity), Math.Max(1, unit * 0.030),
                        PenLineCap.Round, PenLineJoin.Round));
                    break;
                }

                case PersonaMote.Kind.Zed:
                {
                    double size = unit * 0.062 * mote.Scale;
                    var geometry = new PathGeometry();
                    var zed = PersonaDraw.Figure(new PPoint(px - size * 0.5, py - size * 0.5), false);
                    PersonaDraw.Line(zed, px + size * 0.5, py - size * 0.5);
                    PersonaDraw.Line(zed, px - size * 0.5, py + size * 0.5);
                    PersonaDraw.Line(zed, px + size * 0.5, py + size * 0.5);
                    geometry.Figures.Add(zed);
                    canvas.Children.Add(PersonaDraw.Shape(
                        geometry, null, PersonaDraw.Solid(hue, mote.Opacity * 0.9),
                        Math.Max(1, unit * 0.030), PenLineCap.Round, PenLineJoin.Round));
                    break;
                }

                case PersonaMote.Kind.Drop:
                {
                    double size = unit * 0.045 * mote.Scale;
                    var geometry = new PathGeometry();
                    var drop = PersonaDraw.Figure(new PPoint(px, py - size * 1.6));
                    PersonaDraw.Quad(
                        drop, new PPoint(px + size, py + size * 0.2),
                        new PPoint(px + size * 0.75, py - size * 0.6));
                    PersonaDraw.Arc(
                        drop, new PPoint(px - size, py + size * 0.2), size, size,
                        false, SweepDirection.Clockwise);
                    PersonaDraw.Quad(
                        drop, new PPoint(px, py - size * 1.6),
                        new PPoint(px - size * 0.75, py - size * 0.6));
                    geometry.Figures.Add(drop);
                    canvas.Children.Add(PersonaDraw.Shape(
                        geometry, PersonaDraw.Solid(ink, mote.Opacity * 0.85)));
                    break;
                }

                case PersonaMote.Kind.Puff:
                {
                    double size = unit * 0.055 * mote.Scale;
                    var geometry = new PathGeometry();
                    PersonaDraw.Ellipse(geometry, px, py, size, size * 0.55);
                    canvas.Children.Add(PersonaDraw.Shape(
                        geometry, PersonaDraw.Solid(hue, mote.Opacity)));
                    break;
                }

                case PersonaMote.Kind.Paper:
                    PersonaRendererProps.DrawPaper(canvas, px, py, unit, mote.Angle, mote.Scale, hue);
                    break;

                case PersonaMote.Kind.Console:
                    PersonaRendererProps.DrawConsole(canvas, px, py, unit, mote.Angle, hue);
                    break;

                case PersonaMote.Kind.Keyboard:
                    PersonaRendererProps.DrawKeyboard(canvas, px, py, unit, hue, mote.Opacity);
                    break;

                case PersonaMote.Kind.Sheet:
                    PersonaRendererProps.DrawSheet(canvas, px, py, unit, mote.Scale, hue, mote.Opacity);
                    break;

                case PersonaMote.Kind.Mug:
                    PersonaRendererProps.DrawMug(canvas, px, py, unit, mote.Angle, hue, mote.Opacity);
                    break;

                case PersonaMote.Kind.Sprout:
                    PersonaRendererProps.DrawSprout(canvas, px, py, unit, mote.Scale, hue, mote.Opacity);
                    break;

                case PersonaMote.Kind.Hammer:
                    PersonaRendererProps.DrawHammer(canvas, px, py, unit, mote.Angle, hue, mote.Opacity);
                    break;

                case PersonaMote.Kind.Nail:
                    PersonaRendererProps.DrawNail(canvas, px, py, unit, mote.Scale, hue, mote.Opacity);
                    break;

                case PersonaMote.Kind.Brush:
                    PersonaRendererProps.DrawPaintBrush(canvas, px, py, unit, mote.Angle, hue, mote.Opacity);
                    break;

                case PersonaMote.Kind.Flower:
                    PersonaRendererProps.DrawFlower(canvas, px, py, unit, mote.Scale, hue, mote.Opacity);
                    break;

                case PersonaMote.Kind.Mark:
                    PersonaRendererProps.DrawMark(
                        canvas, px, py, unit, mote.Scale, mote.Angle != 0, ink, mote.Opacity);
                    break;

                case PersonaMote.Kind.Sweat:
                    PersonaRendererProps.DrawSweat(canvas, px, py, unit, mote.Scale, mote.Angle, mote.Opacity);
                    break;

                case PersonaMote.Kind.Heart:
                    PersonaRendererProps.DrawHeart(canvas, px, py, unit, mote.Scale, mote.Angle, mote.Opacity);
                    break;

                case PersonaMote.Kind.ShootingStar:
                    PersonaRendererProps.DrawShootingStar(
                        canvas, px, py, unit, mote.Scale, mote.Angle, mote.Opacity);
                    break;

                case PersonaMote.Kind.Confetti:
                    PersonaRendererProps.DrawConfetti(
                        canvas, px, py, unit, mote.Scale, mote.Angle, hue, mote.Opacity);
                    break;

                case PersonaMote.Kind.Stroke:
                    PersonaRendererProps.DrawStroke(
                        canvas, px, py, unit, mote.Scale, mote.Angle, hue, mote.Opacity);
                    break;

                case PersonaMote.Kind.Bubble:
                    PersonaRendererProps.DrawBubble(canvas, px, py, unit, mote.Scale, hue, mote.Opacity);
                    break;

                case PersonaMote.Kind.Cookie:
                    PersonaRendererProps.DrawCookie(
                        canvas, px, py, unit, mote.Scale, mote.Angle, hue, mote.Opacity);
                    break;

                case PersonaMote.Kind.Glow:
                    break;
            }
        }
    }
}
