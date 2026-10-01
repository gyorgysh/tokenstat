// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Numerics;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Tokenstat.Design.Persona;

/// <summary>Preserve the actual curved silhouette when passing it to Direct2D.</summary>
internal static class PersonaClipGeometry
{
    private static Vector2 Point(Point p) => new((float)p.X, (float)p.Y);

    public static CanvasGeometry Intersect(CanvasGeometry body, CanvasGeometry mask) =>
        body.CombineWith(mask, Matrix3x2.Identity, CanvasGeometryCombine.Intersect);

    public static CanvasGeometry Create(Geometry source)
    {
        CanvasGeometry result;
        if (source is RectangleGeometry rectangle)
        {
            result = CanvasGeometry.CreateRectangle(null, rectangle.Rect);
        }
        else if (source is PathGeometry path)
        {
            using var builder = new CanvasPathBuilder(null);
            builder.SetFilledRegionDetermination(path.FillRule == FillRule.EvenOdd
                ? CanvasFilledRegionDetermination.Alternate : CanvasFilledRegionDetermination.Winding);
            foreach (var figure in path.Figures)
            {
                builder.BeginFigure(Point(figure.StartPoint), figure.IsFilled ? CanvasFigureFill.Default : CanvasFigureFill.DoesNotAffectFills);
                foreach (var segment in figure.Segments)
                {
                    switch (segment)
                    {
                        case LineSegment line: builder.AddLine(Point(line.Point)); break;
                        case BezierSegment curve: builder.AddCubicBezier(Point(curve.Point1), Point(curve.Point2), Point(curve.Point3)); break;
                        case QuadraticBezierSegment curve: builder.AddQuadraticBezier(Point(curve.Point1), Point(curve.Point2)); break;
                        case ArcSegment arc:
                            builder.AddArc(Point(arc.Point), (float)arc.Size.Width, (float)arc.Size.Height,
                                (float)(arc.RotationAngle * Math.PI / 180),
                                arc.SweepDirection == SweepDirection.Clockwise ? CanvasSweepDirection.Clockwise : CanvasSweepDirection.CounterClockwise,
                                arc.IsLargeArc ? CanvasArcSize.Large : CanvasArcSize.Small);
                            break;
                        case PolyLineSegment lines:
                            foreach (var p in lines.Points) builder.AddLine(Point(p));
                            break;
                        default: throw new NotSupportedException(L10n.Text("windows.personaclipgeometry.unsupported_persona_clip_segment_0.4e368260", $"{segment.GetType().Name}"));
                    }
                }
                builder.EndFigure(figure.IsClosed ? CanvasFigureLoop.Closed : CanvasFigureLoop.Open);
            }
            result = CanvasGeometry.CreatePath(builder);
        }
        else throw new NotSupportedException(L10n.Text("windows.personaclipgeometry.unsupported_persona_clip_0.07a77db1", $"{source.GetType().Name}"));

        if (source.Transform is null) return result;
        // TransformGroup can combine translation, yaw compression and roll.
        // Read its affine basis instead of assuming any one transform type.
        var zero = source.Transform.TransformPoint(new Point(0, 0));
        var x = source.Transform.TransformPoint(new Point(1, 0));
        var y = source.Transform.TransformPoint(new Point(0, 1));
        var matrix = new Matrix3x2((float)(x.X - zero.X), (float)(x.Y - zero.Y),
            (float)(y.X - zero.X), (float)(y.Y - zero.Y), (float)zero.X, (float)zero.Y);
        using (result) return result.Transform(matrix);
    }
}
