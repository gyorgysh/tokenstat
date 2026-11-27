// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Tokenstat.Design.Persona;

internal static class PersonaRenderer
{
    public static void Draw(PersonaEngine engine, PersonaScene canvas, double width, double height)
    {
        canvas.Begin();
        try { DrawFrame(engine, canvas, width, height); }
        finally { canvas.End(); }
    }

    private static void DrawFrame(PersonaEngine engine, PersonaScene canvas, double width, double height)
    {
        double unit = Math.Min(width, height);
        if (unit <= 1)
        {
            return;
        }

        var traits = engine.Traits;
        var body = engine.Body;
        var bounds = body.Bounds;
        var hue = traits.Hue;
        var ink = hue.MixedWith(Color.FromArgb(255, 0, 0, 0), 0.78);
        var outline = OutlineGeometry(body, width, height);

        DrawShadow(canvas, bounds, width, height, unit, hue);

        if (traits.HasAntenna && unit >= 18)
        {
            DrawAntenna(canvas, body, width, height, unit, hue);
        }

        canvas.Paint(
            outline,
            PersonaDraw.Linear(
                PersonaDraw.Pt(0.5, 0), PersonaDraw.Pt(0.5, 1),
                (hue.MixedWith(PersonaDraw.White, 0.34), 0), (hue, 1)));
        canvas.Paint(
            outline, null, PersonaDraw.Solid(hue, 0.65), Math.Max(0.5, unit * 0.012));
        var tint = engine.Mood.Tint();
        if (tint is { } stain)
        {
            canvas.Paint(
                outline, null, PersonaDraw.Solid(stain), Math.Max(1, unit * 0.020));
        }

        DrawHighlight(canvas, bounds, width, height, outline);
        int firstFaceElement = canvas.Count;
        DrawFace(engine, canvas, width, height, unit, ink, outline);
        if (Math.Abs(engine.Roll) > 1e-4)
        {
            var origin = body.Centroid;
            var transform = new RotateTransform
            {
                CenterX = origin.X * width, CenterY = origin.Y * height,
                Angle = engine.Roll * 180 / Math.PI,
            };
            for (int i = firstFaceElement; i < canvas.Count; i++)
            {
                canvas.TransformFace(i, transform);
            }
        }
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
        PersonaScene canvas, PRect bounds, double width, double height, double unit, Color hue)
    {
        double air = Math.Max(0, PersonaStage.Floor - bounds.MaxY);
        double closeness = Math.Max(0.30, 1 - air * 2.6);
        double w = bounds.Width * width * 0.80 * closeness;
        double h = unit * 0.052 * closeness;
        double y = PersonaStage.Floor * height - h * 0.35;
        var geometry = new PathGeometry();
        PersonaDraw.Ellipse(geometry, bounds.MidX * width, y + h / 2, w / 2, h / 2);
        canvas.Paint(geometry, PersonaDraw.Solid(hue, 0.20 * closeness));
    }

    private static void DrawHighlight(PersonaScene canvas, PRect bounds, double width, double height, Geometry clip)
    {
        double w = bounds.Width * width * 0.155;
        double h = bounds.Height * height * 0.085;
        double cx = bounds.MidX * width - w * 1.55 + w / 2;
        double cy = (bounds.MinY + bounds.Height * 0.17) * height + h / 2;
        var geometry = new PathGeometry();
        PersonaDraw.EllipseRotated(geometry, cx, cy, w / 2, h / 2, -0.5);
        canvas.Paint(
            geometry,
            PersonaDraw.Radial(
                PersonaDraw.Pt(0.5, 0.5), 0.62,
                (PersonaDraw.White.WithOpacity(0.26), 0), (PersonaDraw.White.WithOpacity(0), 1)),
            clip: clip);
    }

    private static void DrawAntenna(
        PersonaScene canvas, PersonaSoftBody body, double width, double height, double unit, Color tint)
    {
        var crown = body.Crown;
        double rootX = crown.X * width;
        double rootY = crown.Y * height;
        double lean = (crown.X - body.Centroid.X) * width;
        double tipX = rootX + unit * 0.06 + lean * 1.6;
        double tipY = rootY - unit * 0.15;
        var stalk = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(rootX, rootY + unit * 0.02), false);
        PersonaDraw.Quad(figure, new PPoint(tipX, tipY), new PPoint(rootX + unit * 0.09 + lean, rootY - unit * 0.023));
        stalk.Figures.Add(figure);
        canvas.Paint(
            stalk, null, PersonaDraw.Solid(tint, 0.75), Math.Max(1, unit * 0.032),
            PenLineCap.Round, PenLineJoin.Round);
        var tip = new PathGeometry();
        PersonaDraw.Ellipse(tip, tipX, tipY, unit * 0.045, unit * 0.045);
        canvas.Paint(tip, PersonaDraw.Solid(tint));
    }

    private static void DrawFace(
        PersonaEngine engine, PersonaScene canvas, double width, double height,
        double unit, Color ink, Geometry clip)
    {
        var traits = engine.Traits;
        var face = engine.Face;
        var body = engine.Body;
        var bounds = body.Bounds;
        var centroid = body.Centroid;
        var crown = body.Crown;

        double aspect = Math.Clamp(bounds.Height / Math.Max(bounds.Width, 1e-4), 0.45, 1.7);

        double lean = Math.Clamp(Math.Atan2(crown.X - centroid.X, Math.Max(centroid.Y - crown.Y, 1e-4)) * 0.25, -0.12, 0.12);
        double tilt = lean + engine.HeadTilt;

        double heightPoints = bounds.Height * height;
        double anchorHeight = heightPoints * (0.05 + face.Lift);
        double originX = centroid.X * width;
        double originY = centroid.Y * height;

        double sphereX = Math.Max(1, bounds.Width * width * 0.5);
        double sphereY = Math.Max(1, heightPoints * 0.5);
        double gazeX = Math.Clamp(face.Gaze.X + engine.Look.X, -1.3, 1.3);
        double gazeY = Math.Clamp(face.Gaze.Y + engine.Look.Y, -1.3, 1.3);
        double turn = engine.Yaw + gazeX * 0.30;
        double nod = gazeY * 0.20;
        (PPoint Point, double Width, double Height, double Facing) Project(double dx, double dy)
        {
            double theta = Math.Asin(Math.Clamp(dx / sphereX, -0.98, 0.98)) + turn;
            double phi = Math.Asin(Math.Clamp(dy / sphereY, -0.98, 0.98)) + nod;
            return (new PPoint(sphereX * Math.Sin(theta), sphereY * Math.Sin(phi)),
                Math.Max(0, Math.Cos(theta)), Math.Max(0.2, Math.Cos(phi)), Math.Cos(theta));
        }
        PPoint Place(PPoint offset) => new(
            originX + offset.X * Math.Cos(tilt) - offset.Y * Math.Sin(tilt),
            originY + offset.X * Math.Sin(tilt) + offset.Y * Math.Cos(tilt));
        PPoint OnFace(double dx, double dy) => Place(Project(dx, dy).Point);

        int count = traits.EyeCount;
        double lod = unit < 24 ? 1.28 : unit < 34 ? 1.12 : 1.0;
        double radius = unit * 0.060 * lod * Math.Clamp(face.EyeScale, 0.8, 1.25);
        double spread = unit * 0.25 * Math.Clamp(face.Spread, 0.85, 1.15) / Math.Max(Math.Sqrt(aspect), 0.6);
        double tall = Math.Clamp(Math.Sqrt(aspect), 0.75, 1.3);

        for (int i = 0; i < count; i++)
        {
            double offset = i - (count - 1) / 2.0;
            double side = offset < 0 ? -1 : 1;
            var spot = Project(offset * spread, -anchorHeight);
            if (spot.Facing <= 0.02)
            {
                continue;
            }
            var centre = Place(spot.Point);
            double winked = engine.WinkSide == side ? engine.Wink : 0;
            DrawEye(
                canvas, centre, radius, spot.Width, spot.Height * tall, side, face,
                winked > 0 ? Math.Max(winked, engine.Blink) : engine.Blink,
                Math.Max(face.Cheer, winked), tilt, unit, ink, traits.Eye,
                Math.Min(1, spot.Facing * 4), clip);

            if (unit >= 40 && Math.Abs(face.Brow) > 0.45)
            {
                DrawBrow(canvas, centre, radius, unit, ink, face.Brow * 0.45, offset, clip);
            }
        }

        double facing = Math.Min(1, Math.Max(0, Math.Cos(turn)) * 4);
        if (facing <= 0.01)
        {
            return;
        }
        int first = canvas.Count;
        if (unit >= 22)
        {
            DrawBlush(canvas, OnFace, anchorHeight, radius, spread, unit, Math.Max(0.32, face.Blush), clip);
        }
        if (unit >= 21)
        {
            DrawMouth(canvas, OnFace, anchorHeight, radius, unit, ink, face, traits, clip);
        }
        for (int k = first; k < canvas.Count; k++)
        {
            canvas[k].Opacity *= facing;
        }
    }

    private static void DrawEye(
        PersonaScene canvas, PPoint centre, double radius, double widthScale, double heightScale,
        double side, PersonaFacePose face, double blink, double cheer, double tilt, double unit,
        Color ink, PersonaTraits.EyeShape shape, double opacity, Geometry clip)
    {
        double wide = Math.Clamp(face.Openness, 0, 1.3);
        double closing = Math.Clamp(blink, 0, 1);
        double w = radius * 2 * (shape == PersonaTraits.EyeShape.Oval ? 0.86 : 1) * widthScale * (1 + closing * 0.10);
        double h = radius * 2 * (shape == PersonaTraits.EyeShape.Oval ? 1.14 : 1)
            * Math.Min(1.4, heightScale * Math.Max(1, wide)) * (1 - Math.Min(0, blink) * 0.9);
        double open = Math.Clamp(Math.Min(wide, 1) * (1 - closing), 0, 1);
        double squint = Math.Clamp(face.Squint, 0, 0.8);
        double smile = Math.Clamp(Math.Max(cheer, squint * 0.45), 0, 1);
        double droop = Math.Clamp(face.Droop, 0, 1);
        double focus = Math.Clamp((face.Brow - 0.15) / 0.85, 0, 1) * (1 - droop) * 0.55;

        PPoint Local(double x, double y) => PersonaDraw.Rot(centre.X + x, centre.Y + y, centre.X, centre.Y, tilt);
        double minX = -w / 2, maxX = w / 2, minY = -h / 2, maxY = h / 2;
        double meet = minY + h * 0.68;
        double shut = 1 - open;
        double upper = minY + (meet - minY) * shut;
        double innerX = side < 0 ? maxX : minX;
        double outerX = side < 0 ? minX : maxX;
        double innerY = upper + h * 0.30 * focus;
        double outerY = upper + h * 0.40 * droop;
        double LidY(double x) => innerY + (outerY - innerY) * (x - innerX) / (outerX - innerX);
        double left = minX - w;
        double right = maxX + w;
        double arch = LidY(0) - h * (1.6 * shut * (1 - shut) + 0.26 * Math.Min(1, focus + droop));
        double lowerBase = maxY - (maxY - meet) * shut - h * 0.30 * squint;
        double lowerEdge = Math.Max(lowerBase - h * 0.10 * smile, Math.Max(LidY(left), LidY(right)));
        double lowerPeak = Math.Max(lowerBase - h * 1.35 * smile, arch);

        var gap = new PathGeometry();
        var figure = PersonaDraw.Figure(Local(left, LidY(left)));
        PersonaDraw.Quad(figure, Local(right, LidY(right)), Local(0, arch));
        PersonaDraw.Line(figure, Local(right, lowerEdge));
        PersonaDraw.Quad(figure, Local(left, lowerEdge), Local(0, lowerPeak));
        gap.Figures.Add(figure);

        if (open > 0.04)
        {
            var eye = new PathGeometry();
            PersonaDraw.EllipseRotated(eye, centre.X, centre.Y, w / 2, h / 2, tilt);
            canvas.Paint(eye, PersonaDraw.Solid(ink), clip: clip, mask: gap).Opacity = opacity;

            if (unit >= 22 && open > 0.3)
            {
                double size = Math.Min(w, h);
                var big = Local(-w * 0.22, minY + h * 0.30);
                var glint = new PathGeometry();
                PersonaDraw.Ellipse(glint, big.X, big.Y, size * 0.15, size * 0.15);
                canvas.Paint(glint, PersonaDraw.Solid(PersonaDraw.White, 0.92), clip: clip, mask: gap).Opacity = opacity;
                var small = Local(w * 0.16, minY + h * 0.64);
                var spark = new PathGeometry();
                PersonaDraw.Ellipse(spark, small.X, small.Y, size * 0.065, size * 0.065);
                canvas.Paint(spark, PersonaDraw.Solid(PersonaDraw.White, 0.62), clip: clip, mask: gap).Opacity = opacity;
            }
        }

        double line = Math.Clamp((0.24 - open) / 0.18, 0, 1);
        if (line > 0)
        {
            double sag = h * 0.22 * (smile > 0.5 ? -1 : 1) - h * 0.10 * droop;
            var arc = new PathGeometry();
            var curve = PersonaDraw.Figure(Local(minX, meet - sag * 0.25), false);
            PersonaDraw.Quad(curve, Local(maxX, meet - sag * 0.25), Local(0, meet + sag));
            arc.Figures.Add(curve);
            canvas.Paint(
                arc, null, PersonaDraw.Solid(ink, line), Math.Max(1, unit * 0.024),
                PenLineCap.Round, PenLineJoin.Round, clip).Opacity = opacity;
        }
    }

    private static void DrawBlush(
        PersonaScene canvas, Func<double, double, PPoint> place, double anchorHeight,
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
            canvas.Paint(
                geometry,
                PersonaDraw.Radial(
                    PersonaDraw.Pt(0.5, 0.5), 0.62,
                    (Theme.Danger.WithOpacity(0.42 * strength), 0), (Theme.Danger.WithOpacity(0), 1)),
                clip: clip);
        }
    }

    private static void DrawBrow(
        PersonaScene canvas, PPoint centre, double radius, double unit, Color ink,
        double amount, double side, Geometry clip)
    {
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
        canvas.Paint(
            geometry, null, PersonaDraw.Solid(ink, 0.72), Math.Max(1, unit * 0.018),
            PenLineCap.Round, PenLineJoin.Round, clip);
    }

    private static void DrawMouth(
        PersonaScene canvas, Func<double, double, PPoint> place, double anchorHeight,
        double radius, double unit, Color ink, PersonaFacePose face,
        PersonaTraits traits, Geometry clip)
    {
        double resting = traits.Mouth switch
        {
            PersonaTraits.MouthShape.Smile => 0.34,
            PersonaTraits.MouthShape.Frown => -0.34,
            PersonaTraits.MouthShape.Flat => -0.10,
            _ => 0,
        };
        double curve = Math.Clamp(face.MouthCurve + resting, -1.1, 1.1);
        double half = unit * 0.052 * Math.Min(face.MouthWidth, 1.2) * traits.MouthWidth
            * (1 + Math.Clamp(face.MouthOpen, 0, 1.2) * 0.22);
        double open = Math.Clamp(face.MouthOpen, 0, 0.8) * unit * 0.065;
        double baseY = -anchorHeight + unit * 0.12;

        var left = place(-half, baseY);
        var right = place(half, baseY);
        var bow = place(0, baseY + curve * unit * 0.080);
        var sag = place(0, baseY + curve * unit * 0.080 + open * 2);

        if (open < unit * 0.006)
        {
            var line = new PathGeometry();
            var stroke = PersonaDraw.Figure(left, false);
            PersonaDraw.Quad(stroke, right, bow);
            line.Figures.Add(stroke);
            canvas.Paint(
                line, null, PersonaDraw.Solid(ink, 0.78), Math.Max(1, unit * 0.020),
                PenLineCap.Round, PenLineJoin.Round, clip);
            return;
        }

        var geometry = new PathGeometry();
        var path = PersonaDraw.Figure(left);
        PersonaDraw.Quad(path, right, bow);
        PersonaDraw.Quad(path, left, sag);
        geometry.Figures.Add(path);
        canvas.Paint(geometry, PersonaDraw.Solid(ink, 0.72), clip: clip);

        if (face.Tongue <= 0.02)
        {
            return;
        }
        double reach = Math.Clamp(face.Tongue, 0, 1);
        var tip = place(0, baseY + curve * unit * 0.080 + open * 2 * (1 - reach * 0.55));
        double tw = half * 0.86;
        var tongue = new PathGeometry();
        PersonaDraw.Ellipse(tongue, tip.X, tip.Y + open * 0.15 + unit * 0.01, tw / 2, open * 0.75 + unit * 0.01);
        canvas.Paint(
            tongue, PersonaDraw.Solid(Theme.Danger, 0.62), clip: clip, mask: geometry);
    }

    private static void DrawMotes(
        PersonaEngine engine, PersonaScene canvas, double width, double height,
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
                    canvas.Paint(
                        geometry, PersonaDraw.Solid(hue, mote.Opacity * 0.85));
                    break;
                }

                case PersonaMote.Kind.Ball:
                {
                    double size = unit * 0.062;
                    var geometry = new PathGeometry();
                    PersonaDraw.Ellipse(geometry, px, py, size, size);
                    canvas.Paint(
                        geometry, PersonaDraw.Solid(Theme.Secondary, mote.Opacity));
                    var shine = new PathGeometry();
                    PersonaDraw.Ellipse(shine, px - size * 0.30, py - size * 0.40, size * 0.35, size * 0.30);
                    canvas.Paint(
                        shine, PersonaDraw.Solid(PersonaDraw.White, 0.5 * mote.Opacity));
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
                    canvas.Paint(
                        geometry, null, PersonaDraw.Solid(hue, mote.Opacity), Math.Max(1, unit * 0.032),
                        PenLineCap.Round, PenLineJoin.Round);
                    break;
                }

                case PersonaMote.Kind.Note:
                {
                    double size = unit * 0.055 * mote.Scale;
                    var head = new PathGeometry();
                    PersonaDraw.Ellipse(head, px - size * 0.15, py, size * 0.85, size * 0.65);
                    canvas.Paint(head, PersonaDraw.Solid(hue, mote.Opacity));
                    double stemX = px - size * 0.15 + size * 0.85 - size * 0.12;
                    var stem = new PathGeometry();
                    var line = PersonaDraw.Figure(new PPoint(stemX, py), false);
                    PersonaDraw.Line(line, stemX, py - size * 0.65 - size * 1.5);
                    PersonaDraw.Quad(
                        line,
                        new PPoint(stemX + size * 0.12 + size * 0.75, py - size * 0.65 - size * 0.55),
                        new PPoint(stemX + size * 0.12 + size * 0.85, py - size * 0.65 - size * 1.5));
                    stem.Figures.Add(line);
                    canvas.Paint(
                        stem, null, PersonaDraw.Solid(hue, mote.Opacity), Math.Max(1, unit * 0.030),
                        PenLineCap.Round, PenLineJoin.Round);
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
                    canvas.Paint(
                        geometry, null, PersonaDraw.Solid(hue, mote.Opacity * 0.9),
                        Math.Max(1, unit * 0.030), PenLineCap.Round, PenLineJoin.Round);
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
                    canvas.Paint(
                        geometry, PersonaDraw.Solid(ink, mote.Opacity * 0.85));
                    break;
                }

                case PersonaMote.Kind.Puff:
                {
                    double size = unit * 0.055 * mote.Scale;
                    var geometry = new PathGeometry();
                    PersonaDraw.Ellipse(geometry, px, py, size, size * 0.55);
                    canvas.Paint(
                        geometry, PersonaDraw.Solid(hue, mote.Opacity));
                    break;
                }

                case PersonaMote.Kind.Paper:
                {
                    var first = canvas.Count;
                    PersonaRendererProps.DrawPaper(canvas, px, py, unit, mote.Angle, mote.Scale, hue);
                    for (var i = first; i < canvas.Count; i++) canvas[i].Opacity *= mote.Opacity;
                    break;
                }

                case PersonaMote.Kind.Console:
                {
                    var first = canvas.Count;
                    PersonaRendererProps.DrawConsole(canvas, px, py, unit * mote.Scale, mote.Angle, hue);
                    for (var i = first; i < canvas.Count; i++) canvas[i].Opacity *= mote.Opacity;
                    break;
                }

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
