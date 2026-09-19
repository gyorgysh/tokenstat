// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;
// The WinUI shape element collides with System.IO.Path under implicit usings.
using ShapesPath = Microsoft.UI.Xaml.Shapes.Path;

namespace Tokenstat.Design.Persona;

/// <summary>
/// The small geometry vocabulary the persona renderer draws with. WinUI has no
/// immediate-mode canvas without Win2D, so every mark is a Path element with
/// baked coordinates: rotations are applied to the points, not to the element,
/// which keeps clips and gradients in the same space as the paint.
/// </summary>
internal static class PersonaDraw
{
    public static Point Pt(PPoint p) => new(p.X, p.Y);

    public static Point Pt(double x, double y) => new(x, y);

    public static SolidColorBrush Solid(Color color, double opacity = 1) =>
        new(color.WithOpacity(opacity));

    public static LinearGradientBrush Linear(Point start, Point end, params (Color Color, double Offset)[] stops)
    {
        var brush = new LinearGradientBrush { StartPoint = start, EndPoint = end };
        foreach (var stop in stops)
        {
            brush.GradientStops.Add(new GradientStop { Color = stop.Color, Offset = stop.Offset });
        }
        return brush;
    }

    public static RadialGradientBrush Radial(Point center, double radius, params (Color Color, double Offset)[] stops)
    {
        var brush = new RadialGradientBrush
        {
            Center = center,
            GradientOrigin = center,
            RadiusX = radius,
            RadiusY = radius,
        };
        foreach (var stop in stops)
        {
            brush.GradientStops.Add(new GradientStop { Color = stop.Color, Offset = stop.Offset });
        }
        return brush;
    }

    public static PathFigure Figure(PPoint start, bool closed = true) =>
        new() { StartPoint = Pt(start), IsClosed = closed, IsFilled = true };

    public static void Line(PathFigure f, PPoint p) =>
        f.Segments.Add(new LineSegment { Point = Pt(p) });

    public static void Line(PathFigure f, double x, double y) =>
        f.Segments.Add(new LineSegment { Point = Pt(x, y) });

    public static void Quad(PathFigure f, PPoint to, PPoint control) =>
        f.Segments.Add(new QuadraticBezierSegment { Point1 = Pt(control), Point2 = Pt(to) });

    public static void Bezier(PathFigure f, PPoint to, PPoint c1, PPoint c2) =>
        f.Segments.Add(new BezierSegment { Point1 = Pt(c1), Point2 = Pt(c2), Point3 = Pt(to) });

    public static void Arc(PathFigure f, PPoint to, double rx, double ry, bool largeArc, SweepDirection sweep) =>
        f.Segments.Add(new ArcSegment
        {
            Point = Pt(to),
            Size = new Size(Math.Max(rx, 0.01), Math.Max(ry, 0.01)),
            RotationAngle = 0,
            IsLargeArc = largeArc,
            SweepDirection = sweep,
        });

    /// <summary>A closed axis-aligned ellipse, as two arcs.</summary>
    public static void Ellipse(PathGeometry g, double cx, double cy, double rx, double ry)
    {
        if (rx <= 0 || ry <= 0)
        {
            return;
        }
        var f = Figure(new PPoint(cx - rx, cy));
        Arc(f, new PPoint(cx + rx, cy), rx, ry, false, SweepDirection.Clockwise);
        Arc(f, new PPoint(cx - rx, cy), rx, ry, false, SweepDirection.Clockwise);
        g.Figures.Add(f);
    }

    /// <summary>
    /// A closed ellipse rotated by an angle in radians, as four Beziers.
    /// Arcs cannot carry a rotation here, so the highlight and other tilted
    /// ellipses go through this.
    /// </summary>
    public static void EllipseRotated(PathGeometry g, double cx, double cy, double rx, double ry, double angle)
    {
        const double k = 0.5522847498;
        (double X, double Y)[] pts =
        [
            (1, 0), (1, k), (k, 1), (0, 1),
            (-k, 1), (-1, k), (-1, 0),
            (-1, -k), (-k, -1), (0, -1),
            (k, -1), (1, -k), (1, 0),
        ];
        PPoint Map((double X, double Y) p)
        {
            double ex = p.X * rx;
            double ey = p.Y * ry;
            double c = Math.Cos(angle);
            double s = Math.Sin(angle);
            return new PPoint(cx + ex * c - ey * s, cy + ex * s + ey * c);
        }
        var f = Figure(Map(pts[0]));
        for (int s = 0; s < 4; s++)
        {
            Bezier(f, Map(pts[s * 3 + 3]), Map(pts[s * 3 + 1]), Map(pts[s * 3 + 2]));
        }
        g.Figures.Add(f);
    }

    /// <summary>A closed axis-aligned rounded rectangle.</summary>
    public static void RoundedRect(PathGeometry g, double x, double y, double w, double h, double r)
    {
        r = Math.Min(r, Math.Min(w, h) / 2);
        if (r <= 0)
        {
            var box = Figure(new PPoint(x, y));
            Line(box, x + w, y);
            Line(box, x + w, y + h);
            Line(box, x, y + h);
            g.Figures.Add(box);
            return;
        }
        var f = Figure(new PPoint(x + r, y));
        Line(f, x + w - r, y);
        Arc(f, new PPoint(x + w, y + r), r, r, false, SweepDirection.Clockwise);
        Line(f, x + w, y + h - r);
        Arc(f, new PPoint(x + w - r, y + h), r, r, false, SweepDirection.Clockwise);
        Line(f, x + r, y + h);
        Arc(f, new PPoint(x, y + h - r), r, r, false, SweepDirection.Clockwise);
        Line(f, x, y + r);
        Arc(f, new PPoint(x + r, y), r, r, false, SweepDirection.Clockwise);
        g.Figures.Add(f);
    }

    /// <summary>Rotate a point about a pivot, in radians, y down.</summary>
    public static PPoint Rot(double x, double y, double cx, double cy, double angle)
    {
        double dx = x - cx;
        double dy = y - cy;
        double c = Math.Cos(angle);
        double s = Math.Sin(angle);
        return new PPoint(cx + dx * c - dy * s, cy + dx * s + dy * c);
    }

    /// <summary>
    /// One paintable element. Coordinates are absolute in the mark's frame:
    /// the path sits at the canvas origin, so clips share the space.
    /// </summary>
    public static ShapesPath Shape(
        PathGeometry data,
        Brush? fill = null,
        Brush? stroke = null,
        double thickness = 1,
        PenLineCap cap = PenLineCap.Flat,
        PenLineJoin join = PenLineJoin.Miter,
        Geometry? clip = null)
    {
        var path = new ShapesPath { Data = data };
        if (fill is not null)
        {
            path.Fill = fill;
        }
        if (stroke is not null)
        {
            path.Stroke = stroke;
            path.StrokeThickness = thickness;
            path.StrokeStartLineCap = cap;
            path.StrokeEndLineCap = cap;
            path.StrokeLineJoin = join;
        }
        if (clip is not null)
        {
            path.Clip = (RectangleGeometry)clip;
        }
        return path;
    }

    /// <summary>
    /// Spin an element about a point in the mark's frame. Used for props drawn
    /// in their own straight frame: console, mug, brush, hammer, sweat, heart.
    /// Anything with a clip bakes the rotation into its points instead.
    /// </summary>
    public static void Spin(ShapesPath path, double radians, double cx, double cy)
    {
        path.RenderTransform = new RotateTransform
        {
            Angle = radians * 180 / Math.PI,
            CenterX = cx,
            CenterY = cy,
        };
    }

    public static Color White => Colors.White;

    public static Color Black => Colors.Black;
}
