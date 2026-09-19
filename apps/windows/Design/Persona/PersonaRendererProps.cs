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
/// The held things: newspaper, console, keyboard, mug, tools, and the small
/// props. Props are drawn from the character's side of the picture, not ours:
/// the newspaper is a blank back with the eyes over the top edge, and the game
/// is a plain shell with the screen's light on the face.
/// </summary>
internal static class PersonaRendererProps
{
    /// <summary>
    /// The newspaper, from our side of it. We are looking at the back: a wide
    /// blank sheet held up, a fold down the middle, and two eyes over the top
    /// edge. Column rules on our side would mean he was reading it backwards.
    /// </summary>
    public static void DrawPaper(
        Canvas canvas, double px, double py, double unit, double tilt, double scale, Color hue)
    {
        double w = unit * 0.58 * scale;
        double h = unit * 0.32 * scale;
        double minX = px - w / 2;
        double minY = py - h / 2;
        double maxX = px + w / 2;
        double maxY = py + h / 2;
        double midX = px;
        double midY = py;
        PPoint T(double x, double y) => PersonaDraw.Rot(x, y, midX, midY, tilt);

        // The top edge dips at the fold and lifts at the corners, because a
        // sheet held at two points hangs, and a straight edge reads as card.
        var sheet = new PathGeometry();
        var outline = PersonaDraw.Figure(T(minX, minY + h * 0.06));
        PersonaDraw.Quad(outline, T(midX, minY + h * 0.16), T(minX + w * 0.26, minY));
        PersonaDraw.Quad(outline, T(maxX, minY + h * 0.06), T(maxX - w * 0.26, minY));
        PersonaDraw.Line(outline, T(maxX - w * 0.03, maxY));
        PersonaDraw.Quad(outline, T(midX, maxY - h * 0.05), T(midX + w * 0.24, maxY + h * 0.03));
        PersonaDraw.Quad(outline, T(minX + w * 0.03, maxY), T(midX - w * 0.24, maxY + h * 0.03));
        sheet.Figures.Add(outline);
        canvas.Children.Add(PersonaDraw.Shape(sheet, PersonaDraw.Solid(PersonaDraw.White, 0.90)));

        // The fold: what turns two flat halves into one sheet with a crease.
        var fold = new PathGeometry();
        var crease = PersonaDraw.Figure(T(midX, minY + h * 0.16), false);
        PersonaDraw.Quad(crease, T(midX, maxY - h * 0.05), T(midX - w * 0.02, (minY + maxY) / 2));
        fold.Figures.Add(crease);
        canvas.Children.Add(PersonaDraw.Shape(
            fold, null, PersonaDraw.Solid(hue, 0.35), Math.Max(1, unit * 0.016),
            PenLineCap.Round, PenLineJoin.Round, sheet));

        if (unit >= 44)
        {
            // The print, showing faintly through the paper. Enough to say
            // there is something on the other side, not enough to read.
            var bleed = new PathGeometry();
            for (int line = 0; line < 4; line++)
            {
                double y = minY + h * (0.34 + line * 0.16);
                var row = PersonaDraw.Figure(T(minX + w * 0.09, y), false);
                PersonaDraw.Line(row, T(midX - w * 0.06, y));
                bleed.Figures.Add(row);
                var row2 = PersonaDraw.Figure(T(midX + w * 0.06, y), false);
                PersonaDraw.Line(row2, T(maxX - w * 0.09, y));
                bleed.Figures.Add(row2);
            }
            canvas.Children.Add(PersonaDraw.Shape(
                bleed, null, PersonaDraw.Solid(hue, 0.13), Math.Max(0.5, unit * 0.011),
                PenLineCap.Round, PenLineJoin.Round, sheet));
        }

        // The outline last, so nothing drawn on the sheet can sit on top of
        // its own edge.
        canvas.Children.Add(PersonaDraw.Shape(
            sheet, null, PersonaDraw.Solid(hue, 0.95), Math.Max(1, unit * 0.024)));
    }

    /// <summary>
    /// The light a screen throws back at whoever is looking into it. This is
    /// how the game is shown: the screen faces the character, so the only
    /// honest way to put it on our side is the glow on his face.
    /// </summary>
    public static void DrawGlow(Canvas canvas, PersonaMote mote, double width, double height, double unit, Geometry clip)
    {
        double cx = mote.Position.X * width;
        double cy = mote.Position.Y * height;
        double reach = unit * 0.42 * mote.Scale;
        var geometry = new PathGeometry();
        PersonaDraw.Ellipse(geometry, cx, cy, reach, reach);
        canvas.Children.Add(PersonaDraw.Shape(
            geometry,
            PersonaDraw.Radial(
                PersonaDraw.Pt(0.5, 0.5), 0.5,
                (PersonaDraw.White.WithOpacity(0.42 * mote.Opacity), 0),
                (PersonaDraw.White.WithOpacity(0), 1)),
            clip: clip));
    }

    /// <summary>
    /// The back of something handheld. No screen and no buttons on this side:
    /// they face the character. What we get is the shape, the tilt, and the
    /// fact that it never stops moving.
    /// </summary>
    public static void DrawConsole(Canvas canvas, double px, double py, double unit, double tilt, Color hue)
    {
        double w = unit * 0.34;
        double h = unit * 0.20;
        double minX = px - w / 2;
        double minY = py - h / 2;
        var shell = new PathGeometry();
        PersonaDraw.RoundedRect(shell, minX, minY, w, h, h * 0.36);
        var shape = PersonaDraw.Shape(
            shell,
            PersonaDraw.Linear(
                PersonaDraw.Pt(0.5, 0), PersonaDraw.Pt(0.5, 1),
                (hue.WithOpacity(0.95), 0), (hue.WithOpacity(0.72), 1)),
            PersonaDraw.Solid(PersonaDraw.White, 0.30), Math.Max(1, unit * 0.014));
        PersonaDraw.Spin(shape, tilt, px, py);
        canvas.Children.Add(shape);

        if (unit < 44)
        {
            return;
        }
        // One moulding line across the back. It is what stops a rounded
        // rectangle reading as a card.
        var seam = new PathGeometry();
        var line = PersonaDraw.Figure(new PPoint(minX + w * 0.16, py + h * 0.16), false);
        PersonaDraw.Line(line, minX + w - w * 0.16, py + h * 0.16);
        seam.Figures.Add(line);
        var seamShape = PersonaDraw.Shape(
            seam, null, PersonaDraw.Solid(PersonaDraw.White, 0.22), Math.Max(0.5, unit * 0.012),
            PenLineCap.Round, PenLineJoin.Round);
        PersonaDraw.Spin(seamShape, tilt, px, py);
        canvas.Children.Add(seamShape);
    }

    /// <summary>
    /// A keyboard lying on the floor, seen from slightly above and in front.
    /// Point is the middle of its front edge, and that edge sits exactly on
    /// the floor line. A near edge, a narrower far edge and a front lip.
    /// </summary>
    public static void DrawKeyboard(Canvas canvas, double px, double py, double unit, Color hue, double opacity)
    {
        double front = unit * 0.46;
        double back = unit * 0.37;
        double depth = unit * 0.085;
        double thickness = unit * 0.030;
        double topY = py - thickness;
        double backY = topY - depth;

        // The lip. It is the only part with any height, and it is what says
        // the thing is resting on something rather than floating over it.
        var lip = new PathGeometry();
        var lipFigure = PersonaDraw.Figure(new PPoint(px - front / 2, topY));
        PersonaDraw.Line(lipFigure, px + front / 2, topY);
        PersonaDraw.Line(lipFigure, px + front / 2 - unit * 0.008, py);
        PersonaDraw.Line(lipFigure, px - front / 2 + unit * 0.008, py);
        lip.Figures.Add(lipFigure);
        canvas.Children.Add(PersonaDraw.Shape(
            lip, PersonaDraw.Solid(hue, 0.34 * opacity),
            PersonaDraw.Solid(hue, 0.85 * opacity), Math.Max(1, unit * 0.016)));

        var top = new PathGeometry();
        var topFigure = PersonaDraw.Figure(new PPoint(px - front / 2, topY));
        PersonaDraw.Line(topFigure, px - back / 2, backY);
        PersonaDraw.Line(topFigure, px + back / 2, backY);
        PersonaDraw.Line(topFigure, px + front / 2, topY);
        top.Figures.Add(topFigure);
        canvas.Children.Add(PersonaDraw.Shape(
            top, PersonaDraw.Solid(hue, 0.18 * opacity),
            PersonaDraw.Solid(hue, 0.85 * opacity), Math.Max(1, unit * 0.016)));

        if (unit < 32)
        {
            return;
        }
        // Three rows, each narrower and shorter than the one in front of it,
        // because that is what rows going away from you do.
        for (int row = 0; row < 3; row++)
        {
            double along = row / 3.0;
            double rowWidth = front + (back - front) * along;
            double rowY = topY + (backY - topY) * (along + 0.14);
            double keyWidth = rowWidth * 0.115;
            double keyHeight = depth * (0.22 - along * 0.04);
            for (int column = 0; column < 6; column++)
            {
                double x = px - rowWidth / 2 + rowWidth * 0.075
                    + column * rowWidth * 0.17
                    + (row == 1 ? rowWidth * 0.03 : 0);
                var key = new PathGeometry();
                PersonaDraw.RoundedRect(key, x, rowY, keyWidth, keyHeight, keyHeight * 0.34);
                double lit = (column + row * 2) % 5 == 0 ? 0.62 : 0.30;
                canvas.Children.Add(PersonaDraw.Shape(key, PersonaDraw.Solid(hue, lit * opacity)));
            }
        }
    }

    /// <summary>
    /// A sheet of paper lying on the floor, in the same shallow perspective as
    /// the keyboard: near edge wide and on the floor line, far edge narrower.
    /// </summary>
    public static void DrawSheet(
        Canvas canvas, double px, double py, double unit, double scale, Color hue, double opacity)
    {
        double front = unit * 0.44 * scale;
        double back = unit * 0.34 * scale;
        double depth = unit * 0.11 * scale;
        var sheet = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px - front / 2, py));
        PersonaDraw.Line(figure, px - back / 2, py - depth);
        PersonaDraw.Line(figure, px + back / 2, py - depth);
        PersonaDraw.Line(figure, px + front / 2, py);
        sheet.Figures.Add(figure);
        canvas.Children.Add(PersonaDraw.Shape(
            sheet, PersonaDraw.Solid(PersonaDraw.White, 0.82 * opacity),
            PersonaDraw.Solid(hue, 0.55 * opacity), Math.Max(1, unit * 0.014)));
    }

    public static void DrawMug(
        Canvas canvas, double px, double py, double unit, double tilt, Color hue, double opacity)
    {
        double w = unit * 0.20;
        double h = unit * 0.23;
        double minX = px - w / 2;
        double minY = py - h / 2;
        var cup = new PathGeometry();
        PersonaDraw.RoundedRect(cup, minX, minY, w, h, w * 0.22);
        var shape = PersonaDraw.Shape(
            cup, PersonaDraw.Solid(hue, 0.82 * opacity),
            PersonaDraw.Solid(PersonaDraw.White, 0.38 * opacity), Math.Max(1, unit * 0.016));
        PersonaDraw.Spin(shape, tilt, px, py);
        canvas.Children.Add(shape);

        var handle = new PathGeometry();
        PersonaDraw.Ellipse(handle, minX + w - w * 0.05 + w * 0.55 / 2, minY + h * 0.25 + h * 0.46 / 2, w * 0.55 / 2, h * 0.46 / 2);
        var handleShape = PersonaDraw.Shape(
            handle, null, PersonaDraw.Solid(hue, opacity), Math.Max(1, unit * 0.036));
        PersonaDraw.Spin(handleShape, tilt, px, py);
        canvas.Children.Add(handleShape);
    }

    public static void DrawSprout(
        Canvas canvas, double px, double py, double unit, double scale, Color hue, double opacity)
    {
        double reach = unit * 0.13 * scale;
        // A little mound of soil first. Without it a stem meeting the floor
        // line reads as stuck onto the picture rather than growing out of it.
        DrawSoil(canvas, px, py, unit, reach * 1.5, opacity);
        var stem = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px, py), false);
        PersonaDraw.Quad(
            figure, new PPoint(px + reach * 0.08, py - reach * 1.45),
            new PPoint(px - reach * 0.12, py - reach * 0.72));
        stem.Figures.Add(figure);
        canvas.Children.Add(PersonaDraw.Shape(
            stem, null, PersonaDraw.Solid(hue, opacity), Math.Max(1, unit * 0.022),
            PenLineCap.Round, PenLineJoin.Round));
        foreach (double side in new double[] { -1, 1 })
        {
            var leaf = new PathGeometry();
            double lx = px + side * reach * 0.34;
            double ly = py - reach * (side < 0 ? 1.42 : 1.72) + reach * 0.24;
            PersonaDraw.Ellipse(leaf, lx, ly, reach * 0.44, reach * 0.24);
            canvas.Children.Add(PersonaDraw.Shape(leaf, PersonaDraw.Solid(hue, 0.72 * opacity)));
        }
    }

    /// <summary>
    /// A brush, held handle-up with the bristles down on the paper. Drawn
    /// along +x, so the caller's angle points the working end. The bristles
    /// are a splayed bundle of separate tapered hairs rather than one rounded
    /// blob.
    /// </summary>
    public static void DrawPaintBrush(
        Canvas canvas, double px, double py, double unit, double tilt, Color hue, double opacity)
    {
        double handle = unit * 0.30;
        double w = unit * 0.044;

        // A tapered handle: thick where it is held, thinner at the ferrule.
        var shaft = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px - handle * 0.58, py - w * 0.42));
        PersonaDraw.Line(figure, px + handle * 0.24, py - w * 0.26);
        PersonaDraw.Line(figure, px + handle * 0.24, py + w * 0.26);
        PersonaDraw.Line(figure, px - handle * 0.58, py + w * 0.42);
        shaft.Figures.Add(figure);
        var shaftShape = PersonaDraw.Shape(shaft, PersonaDraw.Solid(hue, 0.95 * opacity));
        PersonaDraw.Spin(shaftShape, tilt, px, py);
        canvas.Children.Add(shaftShape);

        var ferrule = new PathGeometry();
        PersonaDraw.RoundedRect(
            ferrule, px + handle * 0.22, py - w * 0.42, handle * 0.14, w * 0.84, w * 0.16);
        var ferruleShape = PersonaDraw.Shape(ferrule, PersonaDraw.Solid(PersonaDraw.White, 0.62 * opacity));
        PersonaDraw.Spin(ferruleShape, tilt, px, py);
        canvas.Children.Add(ferruleShape);

        // Five hairs, splayed and bent. They fan wider than the ferrule and
        // each comes to a point.
        double root = handle * 0.34;
        double tip = handle * 0.62;
        for (int i = 0; i < 5; i++)
        {
            double spread = (i - 2) / 2.0;
            double start = spread * w * 0.30;
            double end = spread * w * 1.10;
            var hair = new PathGeometry();
            var strand = PersonaDraw.Figure(new PPoint(px + root, py + start - w * 0.12));
            PersonaDraw.Quad(
                strand, new PPoint(px + tip, py + end),
                new PPoint(px + (root + tip) * 0.5, py + start + (end - start) * 0.2));
            PersonaDraw.Quad(
                strand, new PPoint(px + root, py + start + w * 0.12),
                new PPoint(px + (root + tip) * 0.5, py + start + (end - start) * 0.8));
            hair.Figures.Add(strand);
            var hairShape = PersonaDraw.Shape(
                hair, PersonaDraw.Solid(Theme.Secondary, (0.92 - Math.Abs(spread) * 0.18) * opacity));
            PersonaDraw.Spin(hairShape, tilt, px, py);
            canvas.Children.Add(hairShape);
        }
    }

    /// <summary>
    /// What the sprout becomes. Five petals and a middle, because four reads
    /// as a propeller and six reads as a snowflake.
    /// </summary>
    public static void DrawFlower(
        Canvas canvas, double px, double py, double unit, double scale, Color hue, double opacity)
    {
        double reach = unit * 0.105 * scale;
        // The same patch of soil the sprout came out of, and the stalk it kept.
        double rootX = px;
        double rootY = py + reach * 1.9;
        DrawSoil(canvas, rootX, rootY, unit, reach * 1.5, opacity);
        var stalk = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(rootX, rootY), false);
        PersonaDraw.Quad(figure, new PPoint(px, py), new PPoint(px - reach * 0.30, py + reach));
        stalk.Figures.Add(figure);
        canvas.Children.Add(PersonaDraw.Shape(
            stalk, null, PersonaDraw.Solid(hue, 0.85 * opacity), Math.Max(1, unit * 0.022),
            PenLineCap.Round, PenLineJoin.Round));
        for (int step = 0; step < 5; step++)
        {
            double angle = -Math.PI / 2 + step * 2 * Math.PI / 5;
            double cx = px + Math.Cos(angle) * reach * 0.72;
            double cy = py + Math.Sin(angle) * reach * 0.72;
            var petal = new PathGeometry();
            PersonaDraw.Ellipse(petal, cx, cy, reach * 0.52, reach * 0.52);
            canvas.Children.Add(PersonaDraw.Shape(
                petal, PersonaDraw.Solid(Theme.Secondary, 0.88 * opacity)));
        }
        var middle = new PathGeometry();
        PersonaDraw.Ellipse(middle, px, py, reach * 0.34, reach * 0.34);
        canvas.Children.Add(PersonaDraw.Shape(middle, PersonaDraw.Solid(Theme.Warning, opacity)));
    }

    /// <summary>One piece of punctuation, floating. The only text this cast is allowed.</summary>
    public static void DrawMark(
        Canvas canvas, double px, double py, double unit, double scale,
        bool question, Color ink, double opacity)
    {
        double h = unit * 0.20 * scale;
        double w = Math.Max(1.5, unit * 0.045 * scale);
        if (question)
        {
            var hook = new PathGeometry();
            var figure = PersonaDraw.Figure(new PPoint(px - h * 0.24, py - h * 0.40), false);
            PersonaDraw.Quad(
                figure, new PPoint(px, py + h * 0.10),
                new PPoint(px + h * 0.42, py - h * 0.46));
            hook.Figures.Add(figure);
            canvas.Children.Add(PersonaDraw.Shape(
                hook, null, PersonaDraw.Solid(ink, opacity), w,
                PenLineCap.Round, PenLineJoin.Round));
        }
        else
        {
            var stem = new PathGeometry();
            var figure = PersonaDraw.Figure(new PPoint(px, py - h * 0.50), false);
            PersonaDraw.Line(figure, px, py + h * 0.10);
            stem.Figures.Add(figure);
            canvas.Children.Add(PersonaDraw.Shape(
                stem, null, PersonaDraw.Solid(ink, opacity), w,
                PenLineCap.Round, PenLineJoin.Round));
        }
        var dot = new PathGeometry();
        PersonaDraw.Ellipse(dot, px, py + h * 0.28 + w * 0.6, w * 0.6, w * 0.6);
        canvas.Children.Add(PersonaDraw.Shape(dot, PersonaDraw.Solid(ink, opacity)));
    }

    /// <summary>
    /// The bead of sweat. It flies off the head rather than running down it,
    /// which is the cartoon version and the one that reads at this size.
    /// </summary>
    public static void DrawSweat(
        Canvas canvas, double px, double py, double unit, double scale, double tilt, double opacity)
    {
        double s = unit * 0.048 * scale;
        var drop = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px, py - s * 1.5));
        PersonaDraw.Quad(figure, new PPoint(px + s, py + s * 0.2), new PPoint(px + s * 0.8, py - s * 0.5));
        PersonaDraw.Arc(figure, new PPoint(px - s, py + s * 0.2), s, s, false, SweepDirection.Clockwise);
        PersonaDraw.Quad(figure, new PPoint(px, py - s * 1.5), new PPoint(px - s * 0.8, py - s * 0.5));
        drop.Figures.Add(figure);
        var shape = PersonaDraw.Shape(drop, PersonaDraw.Solid(Theme.Secondary, 0.80 * opacity));
        PersonaDraw.Spin(shape, tilt, px, py);
        canvas.Children.Add(shape);

        var shine = new PathGeometry();
        PersonaDraw.Ellipse(shine, px - s * 0.55 + s * 0.45 / 2, py - s * 0.30 + s * 0.55 / 2, s * 0.45 / 2, s * 0.55 / 2);
        var shineShape = PersonaDraw.Shape(shine, PersonaDraw.Solid(PersonaDraw.White, 0.55 * opacity));
        PersonaDraw.Spin(shineShape, tilt, px, py);
        canvas.Children.Add(shineShape);
    }

    public static void DrawHeart(
        Canvas canvas, double px, double py, double unit, double scale, double tilt, double opacity)
    {
        double s = unit * 0.060 * scale;
        var heart = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px, py + s * 0.95));
        PersonaDraw.Bezier(
            figure, new PPoint(px - s, py - s * 0.30),
            new PPoint(px - s * 0.62, py + s * 0.42), new PPoint(px - s, py + s * 0.16));
        PersonaDraw.Arc(figure, new PPoint(px + s * 0.02, py - s * 0.34), s * 0.52, s * 0.52, false, SweepDirection.Counterclockwise);
        PersonaDraw.Arc(figure, new PPoint(px + s * 1.02, py - s * 0.34), s * 0.52, s * 0.52, false, SweepDirection.Counterclockwise);
        PersonaDraw.Bezier(
            figure, new PPoint(px, py + s * 0.95),
            new PPoint(px + s, py + s * 0.16), new PPoint(px + s * 0.62, py + s * 0.42));
        heart.Figures.Add(figure);
        var shape = PersonaDraw.Shape(heart, PersonaDraw.Solid(Theme.Danger, 0.80 * opacity));
        PersonaDraw.Spin(shape, tilt, px, py);
        canvas.Children.Add(shape);
    }

    /// <summary>
    /// A star with a tail behind it. Tilt is the direction it is travelling,
    /// so the tail always trails rather than pointing wherever it was drawn.
    /// </summary>
    public static void DrawShootingStar(
        Canvas canvas, double px, double py, double unit, double scale, double tilt, double opacity)
    {
        double reach = unit * 0.040 * scale;
        double tailX = px - Math.Cos(tilt) * reach * 7;
        double tailY = py - Math.Sin(tilt) * reach * 7;
        var tail = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px, py), false);
        PersonaDraw.Line(figure, tailX, tailY);
        tail.Figures.Add(figure);
        // Relative gradient along the stroke, head bright to tail gone.
        double minX = Math.Min(px, tailX);
        double minY = Math.Min(py, tailY);
        double w = Math.Max(Math.Abs(px - tailX), 1e-6);
        double h = Math.Max(Math.Abs(py - tailY), 1e-6);
        canvas.Children.Add(PersonaDraw.Shape(
            tail, null,
            PersonaDraw.Linear(
                PersonaDraw.Pt((px - minX) / w, (py - minY) / h),
                PersonaDraw.Pt((tailX - minX) / w, (tailY - minY) / h),
                (Theme.Warning.WithOpacity(0.85 * opacity), 0), (Theme.Warning.WithOpacity(0), 1)),
            Math.Max(1, reach * 0.75), PenLineCap.Round, PenLineJoin.Round));

        var star = new PathGeometry();
        PathFigure? points = null;
        for (int step = 0; step < 8; step++)
        {
            double angle = step * Math.PI / 4;
            double outer = step % 2 == 0 ? reach * 1.5 : reach * 0.5;
            var corner = new PPoint(px + Math.Cos(angle) * outer, py + Math.Sin(angle) * outer);
            if (points is null)
            {
                points = PersonaDraw.Figure(corner);
            }
            else
            {
                PersonaDraw.Line(points, corner);
            }
        }
        if (points is not null)
        {
            star.Figures.Add(points);
        }
        canvas.Children.Add(PersonaDraw.Shape(star, PersonaDraw.Solid(Theme.Warning, opacity)));
    }

    /// <summary>
    /// One scrap, tumbling. Colour comes off the brand arc rather than the
    /// party shop, so a celebration still looks like this app celebrating.
    /// </summary>
    public static void DrawConfetti(
        Canvas canvas, double px, double py, double unit, double scale,
        double tilt, Color hue, double opacity)
    {
        double size = unit * 0.042 * scale;
        Color[] palette = [Theme.Accent, Theme.Secondary, Theme.Warning, hue];
        var colour = palette[Math.Abs((int)(tilt * 7)) % palette.Length];
        var geometry = new PathGeometry();
        PersonaDraw.RoundedRect(geometry, px - size * 0.5, py - size * 0.85, size, size * 1.7, size * 0.22);
        var shape = PersonaDraw.Shape(geometry, PersonaDraw.Solid(colour, opacity));
        // Squashed by its own spin, so a flat scrap turns edge-on to us
        // halfway round instead of sliding sideways.
        var group = new TransformGroup();
        group.Children.Add(new RotateTransform { Angle = tilt * 180 / Math.PI, CenterX = px, CenterY = py });
        group.Children.Add(new ScaleTransform
        {
            ScaleX = 1,
            ScaleY = Math.Max(0.15, Math.Abs(Math.Cos(tilt * 1.7))),
            CenterX = px,
            CenterY = py,
        });
        shape.RenderTransform = group;
        canvas.Children.Add(shape);
    }

    /// <summary>
    /// A wet stroke of paint. Fat in the middle and tapered at both ends,
    /// because that is what a brush pressed and lifted leaves behind.
    /// </summary>
    public static void DrawStroke(
        Canvas canvas, double px, double py, double unit, double scale,
        double tilt, Color hue, double opacity)
    {
        double length = unit * 0.13 * scale;
        double w = unit * 0.040 * scale;
        var geometry = new PathGeometry();
        var mark = PersonaDraw.Figure(new PPoint(px - length, py));
        PersonaDraw.Quad(mark, new PPoint(px + length, py), new PPoint(px, py - w * 1.5));
        PersonaDraw.Quad(mark, new PPoint(px - length, py), new PPoint(px, py + w * 1.5));
        geometry.Figures.Add(mark);
        var shape = PersonaDraw.Shape(geometry, PersonaDraw.Solid(Theme.Secondary, 0.85 * opacity));
        PersonaDraw.Spin(shape, tilt, px, py);
        canvas.Children.Add(shape);
        _ = hue;
    }

    /// <summary>
    /// A soap bubble: mostly nothing, with a rim and one highlight. It has to
    /// be see-through or it is a ball, and a ball is a different mood entirely.
    /// </summary>
    public static void DrawBubble(
        Canvas canvas, double px, double py, double unit, double scale, Color hue, double opacity)
    {
        double reach = unit * 0.10 * scale;
        var geometry = new PathGeometry();
        PersonaDraw.Ellipse(geometry, px, py, reach, reach);
        canvas.Children.Add(PersonaDraw.Shape(
            geometry,
            PersonaDraw.Radial(
                PersonaDraw.Pt(0.5, 0.5), 0.5,
                (PersonaDraw.White.WithOpacity(0.02 * opacity), 0),
                (PersonaDraw.White.WithOpacity(0.02 * opacity), 0.2),
                (Theme.Secondary.WithOpacity(0.26 * opacity), 1))));
        canvas.Children.Add(PersonaDraw.Shape(
            geometry, null, PersonaDraw.Solid(PersonaDraw.White, 0.62 * opacity),
            Math.Max(1, unit * 0.014)));
        var shine = new PathGeometry();
        PersonaDraw.Ellipse(
            shine, px - reach + reach * 0.34 + reach * 0.22, py - reach + reach * 0.28 + reach * 0.16,
            reach * 0.22, reach * 0.16);
        canvas.Children.Add(PersonaDraw.Shape(shine, PersonaDraw.Solid(PersonaDraw.White, 0.72 * opacity)));
        _ = hue;
    }

    /// <summary>
    /// A biscuit, with bites taken out of it. Angle counts the bites, so the
    /// same prop covers the whole snack from whole to nearly gone.
    /// </summary>
    public static void DrawCookie(
        Canvas canvas, double px, double py, double unit, double scale,
        double tilt, Color hue, double opacity)
    {
        double reach = unit * 0.105 * scale;
        int bites = Math.Clamp((int)tilt, 0, 3);
        // No boolean geometry in WinUI: an even-odd path with the bites as
        // subpaths reads the same, stroke included.
        var biscuit = new PathGeometry { FillRule = FillRule.EvenOdd };
        PersonaDraw.Ellipse(biscuit, px, py, reach, reach);
        for (int bite = 0; bite < bites; bite++)
        {
            double angle = -Math.PI * 0.75 + bite * 0.62;
            double cx = px + Math.Cos(angle) * reach * 0.92;
            double cy = py + Math.Sin(angle) * reach * 0.92;
            PersonaDraw.Ellipse(biscuit, cx, cy, reach * 0.46, reach * 0.46);
        }
        // The persona's own colour, like every other prop it holds.
        canvas.Children.Add(PersonaDraw.Shape(
            biscuit, PersonaDraw.Solid(hue, 0.62 * opacity),
            PersonaDraw.Solid(hue, 0.95 * opacity), Math.Max(1, unit * 0.014)));
        // The chips. Fixed offsets rather than random ones, so a biscuit does
        // not reshuffle itself every frame.
        foreach (var offset in new PPoint[] { new(-0.34, 0.18), new(0.22, 0.36), new(0.05, -0.30) })
        {
            var chip = new PathGeometry();
            PersonaDraw.Ellipse(
                chip, px + offset.X * reach, py + offset.Y * reach, reach * 0.15, reach * 0.15);
            canvas.Children.Add(PersonaDraw.Shape(chip, PersonaDraw.Solid(hue, 0.95 * opacity)));
        }
    }

    /// <summary>
    /// The patch of ground a plant is in. Small, dark, and flat on the floor
    /// line, which is all it takes for a stem to read as rooted.
    /// </summary>
    public static void DrawSoil(Canvas canvas, double px, double py, double unit, double w, double opacity)
    {
        var mound = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px - w, py));
        PersonaDraw.Quad(figure, new PPoint(px + w, py), new PPoint(px, py - w * 0.62));
        mound.Figures.Add(figure);
        canvas.Children.Add(PersonaDraw.Shape(mound, PersonaDraw.Solid(PersonaDraw.Black, 0.30 * opacity)));
        _ = unit;
    }

    /// <summary>
    /// The hammer, pivoting where the character holds it. Tilt is the swing,
    /// so the head is drawn at the far end of a handle that rotates around the
    /// grip. The head is deliberately heavy.
    /// </summary>
    public static void DrawHammer(
        Canvas canvas, double px, double py, double unit, double tilt, Color hue, double opacity)
    {
        double handle = unit * 0.30;
        var shaft = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px, py), false);
        PersonaDraw.Line(figure, px + handle, py);
        shaft.Figures.Add(figure);
        var shaftShape = PersonaDraw.Shape(
            shaft, null, PersonaDraw.Solid(hue, 0.95 * opacity), Math.Max(2, unit * 0.042),
            PenLineCap.Round, PenLineJoin.Round);
        PersonaDraw.Spin(shaftShape, tilt, px, py);
        canvas.Children.Add(shaftShape);

        var head = new PathGeometry();
        PersonaDraw.RoundedRect(
            head, px + handle - unit * 0.030, py - unit * 0.075,
            unit * 0.105, unit * 0.15, unit * 0.022);
        var headShape = PersonaDraw.Shape(head, PersonaDraw.Solid(Theme.Secondary, 0.95 * opacity));
        PersonaDraw.Spin(headShape, tilt, px, py);
        canvas.Children.Add(headShape);

        var claw = new PathGeometry();
        PersonaDraw.RoundedRect(
            claw, px + handle - unit * 0.030 - unit * 0.045, py - unit * 0.030,
            unit * 0.055, unit * 0.060, unit * 0.014);
        var clawShape = PersonaDraw.Shape(claw, PersonaDraw.Solid(Theme.Secondary, 0.72 * opacity));
        PersonaDraw.Spin(clawShape, tilt, px, py);
        canvas.Children.Add(clawShape);
    }

    /// <summary>
    /// A nail in the floor, most of the way in by the end of a cycle. Showing
    /// is how much of the shank is still above the boards.
    /// </summary>
    public static void DrawNail(
        Canvas canvas, double px, double py, double unit, double showing, Color hue, double opacity)
    {
        double length = unit * 0.11 * Math.Max(showing, 0.10);
        var shank = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px, py), false);
        PersonaDraw.Line(figure, px, py - length);
        shank.Figures.Add(figure);
        canvas.Children.Add(PersonaDraw.Shape(
            shank, null, PersonaDraw.Solid(Theme.Secondary, 0.90 * opacity),
            Math.Max(1.5, unit * 0.026), PenLineCap.Flat, PenLineJoin.Miter));
        var head = new PathGeometry();
        PersonaDraw.Ellipse(head, px, py - length - unit * 0.016 + unit * 0.014, unit * 0.032, unit * 0.014);
        canvas.Children.Add(PersonaDraw.Shape(head, PersonaDraw.Solid(Theme.Secondary, opacity)));
        _ = hue;
    }
}
