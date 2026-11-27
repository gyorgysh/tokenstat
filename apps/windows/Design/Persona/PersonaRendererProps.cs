// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Tokenstat.Design.Persona;

internal static class PersonaRendererProps
{
    public static void DrawPaper(
        PersonaScene canvas, double px, double py, double unit, double tilt, double scale, Color hue)
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

        var sheet = new PathGeometry();
        var outline = PersonaDraw.Figure(T(minX, minY + h * 0.06));
        PersonaDraw.Quad(outline, T(midX, minY + h * 0.16), T(minX + w * 0.26, minY));
        PersonaDraw.Quad(outline, T(maxX, minY + h * 0.06), T(maxX - w * 0.26, minY));
        PersonaDraw.Line(outline, T(maxX - w * 0.03, maxY));
        PersonaDraw.Quad(outline, T(midX, maxY - h * 0.05), T(midX + w * 0.24, maxY + h * 0.03));
        PersonaDraw.Quad(outline, T(minX + w * 0.03, maxY), T(midX - w * 0.24, maxY + h * 0.03));
        sheet.Figures.Add(outline);
        canvas.Paint(sheet, PersonaDraw.Solid(PersonaDraw.White, 0.90));

        var fold = new PathGeometry();
        var crease = PersonaDraw.Figure(T(midX, minY + h * 0.16), false);
        PersonaDraw.Quad(crease, T(midX, maxY - h * 0.05), T(midX - w * 0.02, (minY + maxY) / 2));
        fold.Figures.Add(crease);
        canvas.Paint(
            fold, null, PersonaDraw.Solid(hue, 0.35), Math.Max(1, unit * 0.016),
            PenLineCap.Round, PenLineJoin.Round, sheet);

        if (unit >= 44)
        {
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
            canvas.Paint(
                bleed, null, PersonaDraw.Solid(hue, 0.13), Math.Max(0.5, unit * 0.011),
                PenLineCap.Round, PenLineJoin.Round, sheet);
        }

        canvas.Paint(
            sheet, null, PersonaDraw.Solid(hue, 0.95), Math.Max(1, unit * 0.024));
    }

    public static void DrawGlow(PersonaScene canvas, PersonaMote mote, double width, double height, double unit, Geometry clip)
    {
        double cx = mote.Position.X * width;
        double cy = mote.Position.Y * height;
        double reach = unit * 0.42 * mote.Scale;
        var geometry = new PathGeometry();
        PersonaDraw.Ellipse(geometry, cx, cy, reach, reach);
        canvas.Paint(
            geometry,
            PersonaDraw.Radial(
                PersonaDraw.Pt(0.5, 0.5), 0.5,
                (PersonaDraw.White.WithOpacity(0.42 * mote.Opacity), 0),
                (PersonaDraw.White.WithOpacity(0), 1)),
            clip: clip);
    }

    public static void DrawConsole(PersonaScene canvas, double px, double py, double unit, double tilt, Color hue)
    {
        double w = unit * 0.34;
        double h = unit * 0.20;
        double minX = px - w / 2;
        double minY = py - h / 2;
        var shell = new PathGeometry();
        PersonaDraw.RoundedRect(shell, minX, minY, w, h, h * 0.36);
        var shape = canvas.Paint(
            shell,
            PersonaDraw.Linear(
                PersonaDraw.Pt(0.5, 0), PersonaDraw.Pt(0.5, 1),
                (hue.WithOpacity(0.95), 0), (hue.WithOpacity(0.72), 1)),
            PersonaDraw.Solid(PersonaDraw.White, 0.30), Math.Max(1, unit * 0.014));
        PersonaDraw.Spin(shape, tilt, px, py);

        if (unit < 44)
        {
            return;
        }
        var seam = new PathGeometry();
        var line = PersonaDraw.Figure(new PPoint(minX + w * 0.16, py + h * 0.16), false);
        PersonaDraw.Line(line, minX + w - w * 0.16, py + h * 0.16);
        seam.Figures.Add(line);
        var seamShape = canvas.Paint(
            seam, null, PersonaDraw.Solid(PersonaDraw.White, 0.22), Math.Max(0.5, unit * 0.012),
            PenLineCap.Round, PenLineJoin.Round);
        PersonaDraw.Spin(seamShape, tilt, px, py);
    }

    public static void DrawKeyboard(PersonaScene canvas, double px, double py, double unit, Color hue, double opacity)
    {
        double front = unit * 0.46;
        double back = unit * 0.37;
        double depth = unit * 0.085;
        double thickness = unit * 0.030;
        double topY = py - thickness;
        double backY = topY - depth;

        var lip = new PathGeometry();
        var lipFigure = PersonaDraw.Figure(new PPoint(px - front / 2, topY));
        PersonaDraw.Line(lipFigure, px + front / 2, topY);
        PersonaDraw.Line(lipFigure, px + front / 2 - unit * 0.008, py);
        PersonaDraw.Line(lipFigure, px - front / 2 + unit * 0.008, py);
        lip.Figures.Add(lipFigure);
        canvas.Paint(
            lip, PersonaDraw.Solid(hue, 0.34 * opacity),
            PersonaDraw.Solid(hue, 0.85 * opacity), Math.Max(1, unit * 0.016));

        var top = new PathGeometry();
        var topFigure = PersonaDraw.Figure(new PPoint(px - front / 2, topY));
        PersonaDraw.Line(topFigure, px - back / 2, backY);
        PersonaDraw.Line(topFigure, px + back / 2, backY);
        PersonaDraw.Line(topFigure, px + front / 2, topY);
        top.Figures.Add(topFigure);
        canvas.Paint(
            top, PersonaDraw.Solid(hue, 0.18 * opacity),
            PersonaDraw.Solid(hue, 0.85 * opacity), Math.Max(1, unit * 0.016));

        if (unit < 32)
        {
            return;
        }
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
                canvas.Paint(key, PersonaDraw.Solid(hue, lit * opacity));
            }
        }
    }

    public static void DrawSheet(
        PersonaScene canvas, double px, double py, double unit, double scale, Color hue, double opacity)
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
        canvas.Paint(
            sheet, PersonaDraw.Solid(PersonaDraw.White, 0.82 * opacity),
            PersonaDraw.Solid(hue, 0.55 * opacity), Math.Max(1, unit * 0.014));
    }

    public static void DrawMug(
        PersonaScene canvas, double px, double py, double unit, double tilt, Color hue, double opacity)
    {
        double w = unit * 0.20;
        double h = unit * 0.23;
        double minX = px - w / 2;
        double minY = py - h / 2;
        var cup = new PathGeometry();
        PersonaDraw.RoundedRect(cup, minX, minY, w, h, w * 0.22);
        var shape = canvas.Paint(
            cup, PersonaDraw.Solid(hue, 0.82 * opacity),
            PersonaDraw.Solid(PersonaDraw.White, 0.38 * opacity), Math.Max(1, unit * 0.016));
        PersonaDraw.Spin(shape, tilt, px, py);

        var handle = new PathGeometry();
        PersonaDraw.Ellipse(handle, minX + w - w * 0.05 + w * 0.55 / 2, minY + h * 0.25 + h * 0.46 / 2, w * 0.55 / 2, h * 0.46 / 2);
        var handleShape = canvas.Paint(
            handle, null, PersonaDraw.Solid(hue, opacity), Math.Max(1, unit * 0.036));
        PersonaDraw.Spin(handleShape, tilt, px, py);
    }

    public static void DrawSprout(
        PersonaScene canvas, double px, double py, double unit, double scale, Color hue, double opacity)
    {
        double reach = unit * 0.13 * scale;
        DrawSoil(canvas, px, py, unit, reach * 1.5, opacity);
        var stem = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px, py), false);
        PersonaDraw.Quad(
            figure, new PPoint(px + reach * 0.08, py - reach * 1.45),
            new PPoint(px - reach * 0.12, py - reach * 0.72));
        stem.Figures.Add(figure);
        canvas.Paint(
            stem, null, PersonaDraw.Solid(hue, opacity), Math.Max(1, unit * 0.022),
            PenLineCap.Round, PenLineJoin.Round);
        foreach (double side in new double[] { -1, 1 })
        {
            var leaf = new PathGeometry();
            double lx = px + side * reach * 0.34;
            double ly = py - reach * (side < 0 ? 1.42 : 1.72) + reach * 0.24;
            PersonaDraw.Ellipse(leaf, lx, ly, reach * 0.44, reach * 0.24);
            canvas.Paint(leaf, PersonaDraw.Solid(hue, 0.72 * opacity));
        }
    }

    public static void DrawPaintBrush(
        PersonaScene canvas, double px, double py, double unit, double tilt, Color hue, double opacity)
    {
        double handle = unit * 0.30;
        double w = unit * 0.044;

        var shaft = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px - handle * 0.58, py - w * 0.42));
        PersonaDraw.Line(figure, px + handle * 0.24, py - w * 0.26);
        PersonaDraw.Line(figure, px + handle * 0.24, py + w * 0.26);
        PersonaDraw.Line(figure, px - handle * 0.58, py + w * 0.42);
        shaft.Figures.Add(figure);
        var shaftShape = canvas.Paint(shaft, PersonaDraw.Solid(hue, 0.95 * opacity));
        PersonaDraw.Spin(shaftShape, tilt, px, py);

        var ferrule = new PathGeometry();
        PersonaDraw.RoundedRect(
            ferrule, px + handle * 0.22, py - w * 0.42, handle * 0.14, w * 0.84, w * 0.16);
        var ferruleShape = canvas.Paint(ferrule, PersonaDraw.Solid(PersonaDraw.White, 0.62 * opacity));
        PersonaDraw.Spin(ferruleShape, tilt, px, py);

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
            var hairShape = canvas.Paint(
                hair, PersonaDraw.Solid(Theme.Secondary, (0.92 - Math.Abs(spread) * 0.18) * opacity));
            PersonaDraw.Spin(hairShape, tilt, px, py);

        }
    }

    public static void DrawFlower(
        PersonaScene canvas, double px, double py, double unit, double scale, Color hue, double opacity)
    {
        double reach = unit * 0.105 * scale;
        double rootX = px;
        double rootY = py + reach * 1.9;
        DrawSoil(canvas, rootX, rootY, unit, reach * 1.5, opacity);
        var stalk = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(rootX, rootY), false);
        PersonaDraw.Quad(figure, new PPoint(px, py), new PPoint(px - reach * 0.30, py + reach));
        stalk.Figures.Add(figure);
        canvas.Paint(
            stalk, null, PersonaDraw.Solid(hue, 0.85 * opacity), Math.Max(1, unit * 0.022),
            PenLineCap.Round, PenLineJoin.Round);
        for (int step = 0; step < 5; step++)
        {
            double angle = -Math.PI / 2 + step * 2 * Math.PI / 5;
            double cx = px + Math.Cos(angle) * reach * 0.72;
            double cy = py + Math.Sin(angle) * reach * 0.72;
            var petal = new PathGeometry();
            PersonaDraw.Ellipse(petal, cx, cy, reach * 0.52, reach * 0.52);
            canvas.Paint(
                petal, PersonaDraw.Solid(Theme.Secondary, 0.88 * opacity));
        }
        var middle = new PathGeometry();
        PersonaDraw.Ellipse(middle, px, py, reach * 0.34, reach * 0.34);
        canvas.Paint(middle, PersonaDraw.Solid(Theme.Warning, opacity));
    }

    public static void DrawMark(
        PersonaScene canvas, double px, double py, double unit, double scale,
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
            canvas.Paint(
                hook, null, PersonaDraw.Solid(ink, opacity), w,
                PenLineCap.Round, PenLineJoin.Round);
        }
        else
        {
            var stem = new PathGeometry();
            var figure = PersonaDraw.Figure(new PPoint(px, py - h * 0.50), false);
            PersonaDraw.Line(figure, px, py + h * 0.10);
            stem.Figures.Add(figure);
            canvas.Paint(
                stem, null, PersonaDraw.Solid(ink, opacity), w,
                PenLineCap.Round, PenLineJoin.Round);
        }
        var dot = new PathGeometry();
        PersonaDraw.Ellipse(dot, px, py + h * 0.28 + w * 0.6, w * 0.6, w * 0.6);
        canvas.Paint(dot, PersonaDraw.Solid(ink, opacity));
    }

    public static void DrawSweat(
        PersonaScene canvas, double px, double py, double unit, double scale, double tilt, double opacity)
    {
        double s = unit * 0.048 * scale;
        var drop = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px, py - s * 1.5));
        PersonaDraw.Quad(figure, new PPoint(px + s, py + s * 0.2), new PPoint(px + s * 0.8, py - s * 0.5));
        PersonaDraw.Arc(figure, new PPoint(px - s, py + s * 0.2), s, s, false, SweepDirection.Clockwise);
        PersonaDraw.Quad(figure, new PPoint(px, py - s * 1.5), new PPoint(px - s * 0.8, py - s * 0.5));
        drop.Figures.Add(figure);
        var shape = canvas.Paint(drop, PersonaDraw.Solid(Theme.Secondary, 0.80 * opacity));
        PersonaDraw.Spin(shape, tilt, px, py);

        var shine = new PathGeometry();
        PersonaDraw.Ellipse(shine, px - s * 0.55 + s * 0.45 / 2, py - s * 0.30 + s * 0.55 / 2, s * 0.45 / 2, s * 0.55 / 2);
        var shineShape = canvas.Paint(shine, PersonaDraw.Solid(PersonaDraw.White, 0.55 * opacity));
        PersonaDraw.Spin(shineShape, tilt, px, py);
    }

    public static void DrawHeart(
        PersonaScene canvas, double px, double py, double unit, double scale, double tilt, double opacity)
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
        var shape = canvas.Paint(heart, PersonaDraw.Solid(Theme.Danger, 0.80 * opacity));
        PersonaDraw.Spin(shape, tilt, px, py);
    }

    public static void DrawShootingStar(
        PersonaScene canvas, double px, double py, double unit, double scale, double tilt, double opacity)
    {
        double reach = unit * 0.040 * scale;
        double tailX = px - Math.Cos(tilt) * reach * 7;
        double tailY = py - Math.Sin(tilt) * reach * 7;
        var tail = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px, py), false);
        PersonaDraw.Line(figure, tailX, tailY);
        tail.Figures.Add(figure);
        double minX = Math.Min(px, tailX);
        double minY = Math.Min(py, tailY);
        double w = Math.Max(Math.Abs(px - tailX), 1e-6);
        double h = Math.Max(Math.Abs(py - tailY), 1e-6);
        canvas.Paint(
            tail, null,
            PersonaDraw.Linear(
                PersonaDraw.Pt((px - minX) / w, (py - minY) / h),
                PersonaDraw.Pt((tailX - minX) / w, (tailY - minY) / h),
                (Theme.Warning.WithOpacity(0.85 * opacity), 0), (Theme.Warning.WithOpacity(0), 1)),
            Math.Max(1, reach * 0.75), PenLineCap.Round, PenLineJoin.Round);

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
        canvas.Paint(star, PersonaDraw.Solid(Theme.Warning, opacity));
    }

    public static void DrawConfetti(
        PersonaScene canvas, double px, double py, double unit, double scale,
        double tilt, Color hue, double opacity)
    {
        double size = unit * 0.042 * scale;
        Color[] palette = [Theme.Accent, Theme.Secondary, Theme.Warning, hue];
        var colour = palette[Math.Abs((int)(tilt * 7)) % palette.Length];
        var geometry = new PathGeometry();
        PersonaDraw.RoundedRect(geometry, px - size * 0.5, py - size * 0.85, size, size * 1.7, size * 0.22);
        var shape = canvas.Paint(geometry, PersonaDraw.Solid(colour, opacity));
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
    }

    public static void DrawStroke(
        PersonaScene canvas, double px, double py, double unit, double scale,
        double tilt, Color hue, double opacity)
    {
        double length = unit * 0.13 * scale;
        double w = unit * 0.040 * scale;
        var geometry = new PathGeometry();
        var mark = PersonaDraw.Figure(new PPoint(px - length, py));
        PersonaDraw.Quad(mark, new PPoint(px + length, py), new PPoint(px, py - w * 1.5));
        PersonaDraw.Quad(mark, new PPoint(px - length, py), new PPoint(px, py + w * 1.5));
        geometry.Figures.Add(mark);
        var shape = canvas.Paint(geometry, PersonaDraw.Solid(Theme.Secondary, 0.85 * opacity));
        PersonaDraw.Spin(shape, tilt, px, py);

        _ = hue;
    }

    public static void DrawBubble(
        PersonaScene canvas, double px, double py, double unit, double scale, Color hue, double opacity)
    {
        double reach = unit * 0.10 * scale;
        var geometry = new PathGeometry();
        PersonaDraw.Ellipse(geometry, px, py, reach, reach);
        canvas.Paint(
            geometry,
            PersonaDraw.Radial(
                PersonaDraw.Pt(0.5, 0.5), 0.5,
                (PersonaDraw.White.WithOpacity(0.02 * opacity), 0),
                (PersonaDraw.White.WithOpacity(0.02 * opacity), 0.2),
                (Theme.Secondary.WithOpacity(0.26 * opacity), 1)));
        canvas.Paint(
            geometry, null, PersonaDraw.Solid(PersonaDraw.White, 0.62 * opacity),
            Math.Max(1, unit * 0.014));
        var shine = new PathGeometry();
        PersonaDraw.Ellipse(
            shine, px - reach + reach * 0.34 + reach * 0.22, py - reach + reach * 0.28 + reach * 0.16,
            reach * 0.22, reach * 0.16);
        canvas.Paint(shine, PersonaDraw.Solid(PersonaDraw.White, 0.72 * opacity));
        _ = hue;
    }

    public static void DrawCookie(
        PersonaScene canvas, double px, double py, double unit, double scale,
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
        canvas.Paint(
            biscuit, PersonaDraw.Solid(hue, 0.62 * opacity),
            PersonaDraw.Solid(hue, 0.95 * opacity), Math.Max(1, unit * 0.014));
        foreach (var offset in new PPoint[] { new(-0.34, 0.18), new(0.22, 0.36), new(0.05, -0.30) })
        {
            var chip = new PathGeometry();
            PersonaDraw.Ellipse(
                chip, px + offset.X * reach, py + offset.Y * reach, reach * 0.15, reach * 0.15);
            canvas.Paint(chip, PersonaDraw.Solid(hue, 0.95 * opacity));
        }
    }

    public static void DrawSoil(PersonaScene canvas, double px, double py, double unit, double w, double opacity)
    {
        var mound = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px - w, py));
        PersonaDraw.Quad(figure, new PPoint(px + w, py), new PPoint(px, py - w * 0.62));
        mound.Figures.Add(figure);
        canvas.Paint(mound, PersonaDraw.Solid(PersonaDraw.Black, 0.30 * opacity));
        _ = unit;
    }

    public static void DrawHammer(
        PersonaScene canvas, double px, double py, double unit, double tilt, Color hue, double opacity)
    {
        double handle = unit * 0.30;
        var shaft = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px, py), false);
        PersonaDraw.Line(figure, px + handle, py);
        shaft.Figures.Add(figure);
        var shaftShape = canvas.Paint(
            shaft, null, PersonaDraw.Solid(hue, 0.95 * opacity), Math.Max(2, unit * 0.042),
            PenLineCap.Round, PenLineJoin.Round);
        PersonaDraw.Spin(shaftShape, tilt, px, py);

        var head = new PathGeometry();
        PersonaDraw.RoundedRect(
            head, px + handle - unit * 0.030, py - unit * 0.075,
            unit * 0.105, unit * 0.15, unit * 0.022);
        var headShape = canvas.Paint(head, PersonaDraw.Solid(Theme.Secondary, 0.95 * opacity));
        PersonaDraw.Spin(headShape, tilt, px, py);

        var claw = new PathGeometry();
        PersonaDraw.RoundedRect(
            claw, px + handle - unit * 0.030 - unit * 0.045, py - unit * 0.030,
            unit * 0.055, unit * 0.060, unit * 0.014);
        var clawShape = canvas.Paint(claw, PersonaDraw.Solid(Theme.Secondary, 0.72 * opacity));
        PersonaDraw.Spin(clawShape, tilt, px, py);
    }

    public static void DrawNail(
        PersonaScene canvas, double px, double py, double unit, double showing, Color hue, double opacity)
    {
        double length = unit * 0.11 * Math.Max(showing, 0.10);
        var shank = new PathGeometry();
        var figure = PersonaDraw.Figure(new PPoint(px, py), false);
        PersonaDraw.Line(figure, px, py - length);
        shank.Figures.Add(figure);
        canvas.Paint(
            shank, null, PersonaDraw.Solid(Theme.Secondary, 0.90 * opacity),
            Math.Max(1.5, unit * 0.026), PenLineCap.Flat, PenLineJoin.Miter);
        var head = new PathGeometry();
        PersonaDraw.Ellipse(head, px, py - length - unit * 0.016 + unit * 0.014, unit * 0.032, unit * 0.014);
        canvas.Paint(head, PersonaDraw.Solid(Theme.Secondary, opacity));
        _ = hue;
    }
}
