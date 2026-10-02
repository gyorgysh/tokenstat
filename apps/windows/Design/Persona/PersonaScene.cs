// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using ShapesPath = Microsoft.UI.Xaml.Shapes.Path;

namespace Tokenstat.Design.Persona;

/// <summary>
/// A persona owns its visual slots for its lifetime. Repainting updates those
/// slots instead of detaching and allocating every Path on every timer tick.
/// Surplus slots collapse when a mood uses fewer marks, and are reused later.
/// </summary>
internal sealed class PersonaScene(Canvas canvas)
{
    private readonly List<ShapesPath> _paths = new();
    private readonly List<PersonaClip?> _clips = new();
    private readonly PersonaClipper _clipper = new();
    public int Count { get; private set; }
    public ShapesPath this[int index] => _paths[index];

    public void Begin() => Count = 0;

    public ShapesPath Paint(PathGeometry data, Brush? fill = null, Brush? stroke = null,
        double thickness = 1, PenLineCap cap = PenLineCap.Flat,
        PenLineJoin join = PenLineJoin.Miter, Geometry? clip = null, Geometry? mask = null)
    {
        if (Count == _paths.Count)
        {
            var added = new ShapesPath { IsHitTestVisible = false };
            _paths.Add(added);
            _clips.Add(null);
            canvas.Children.Add(added);
        }
        var path = _paths[Count++];
        _clips[Count - 1] = clip is null ? null : new PersonaClip(clip, mask);
        path.Visibility = Visibility.Visible;
        ClearLocalValues(path);
        // WinUI gives geometry (including its figures and segments) one native
        // owner. The body is painted as both a fill and an outline, so each
        // visual needs its own copy, while the source remains usable as a clip.
        path.Data = CopyGeometry(data);
        if (fill is not null) path.Fill = fill;
        if (stroke is not null) path.Stroke = stroke;
        path.StrokeThickness = thickness;
        path.StrokeStartLineCap = cap;
        path.StrokeEndLineCap = cap;
        path.StrokeLineJoin = join;
        path.Opacity = 1;
        return path;
    }

    public void End()
    {
        _clipper.Update(_paths, _clips, Count);
        for (int i = Count; i < _paths.Count; i++)
        {
            _clips[i] = null;
            var path = _paths[i];
            if (path.Visibility == Visibility.Collapsed) continue;
            path.Visibility = Visibility.Collapsed;
            ClearLocalValues(path);
        }
    }

    public void ReleaseClips() => _clipper.Clear();

    private static PathGeometry CopyGeometry(PathGeometry source)
    {
        var copy = new PathGeometry { FillRule = source.FillRule };
        if (source.Transform is { } transform) copy.Transform = CopyTransform(transform);
        foreach (var figure in source.Figures)
        {
            var added = new PathFigure
            {
                StartPoint = figure.StartPoint,
                IsClosed = figure.IsClosed,
                IsFilled = figure.IsFilled,
            };
            foreach (var segment in figure.Segments) added.Segments.Add(CopySegment(segment));
            copy.Figures.Add(added);
        }
        return copy;
    }

    private static PathSegment CopySegment(PathSegment source) => source switch
    {
        LineSegment line => new LineSegment { Point = line.Point },
        BezierSegment curve => new BezierSegment { Point1 = curve.Point1, Point2 = curve.Point2, Point3 = curve.Point3 },
        QuadraticBezierSegment curve => new QuadraticBezierSegment { Point1 = curve.Point1, Point2 = curve.Point2 },
        ArcSegment arc => new ArcSegment
        {
            Point = arc.Point, Size = arc.Size, RotationAngle = arc.RotationAngle,
            IsLargeArc = arc.IsLargeArc, SweepDirection = arc.SweepDirection,
        },
        PolyLineSegment lines => CopyLines(lines),
        _ => throw new NotSupportedException(L10n.Text("windows.personaclipgeometry.unsupported_persona_clip_segment_0.4e368260", $"{source.GetType().Name}")),
    };

    private static PolyLineSegment CopyLines(PolyLineSegment source)
    {
        var copy = new PolyLineSegment();
        foreach (var point in source.Points) copy.Points.Add(point);
        return copy;
    }

    // A TransformGroup is also a native object with one owner. Sampling its
    // affine basis preserves yaw, roll and translation without sharing it.
    public static MatrixTransform CopyTransform(Transform source)
    {
        var zero = source.TransformPoint(new Point(0, 0));
        var x = source.TransformPoint(new Point(1, 0));
        var y = source.TransformPoint(new Point(0, 1));
        return new MatrixTransform
        {
            Matrix = new Matrix(x.X - zero.X, x.Y - zero.Y,
                y.X - zero.X, y.Y - zero.Y, zero.X, zero.Y),
        };
    }

    // A slot can hold an eye in one frame and a prop in the next. ClearValue
    // drops the fill, stroke, and clip. The same call leaves RenderTransform
    // set, so the turn is written back to null on UIElement.
    private static void ClearLocalValues(ShapesPath path)
    {
        path.ClearValue(ShapesPath.DataProperty);
        path.ClearValue(ShapesPath.FillProperty);
        path.ClearValue(ShapesPath.StrokeProperty);
        path.ClearValue(ShapesPath.ClipProperty);
        path.RenderTransform = null;
        path.SetValue(UIElement.RenderTransformProperty, null);
    }
}
