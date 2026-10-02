// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Minimal property model for the production scene's reuse contract. Native
// rendering still requires the Windows UI executable on a Windows runtime.
namespace Microsoft.UI.Xaml
{
    public enum Visibility { Visible, Collapsed }

    public sealed class DependencyProperty
    {
        internal DependencyProperty() {}
    }

    // RenderTransform is declared on UIElement. The scene writes that
    // property back to null. ClearValue leaves the slot's turn in place.
    public class UIElement
    {
        public static DependencyProperty RenderTransformProperty { get; } = new();
    }
}
namespace Microsoft.UI.Xaml.Controls
{
    public sealed class Canvas
    {
        public List<Shapes.Path> Children { get; } = new();
    }
}
namespace Microsoft.UI.Xaml.Media
{
    public class Brush;
    public class Geometry
    {
        public object Bounds { get; set; } = new();
        public Transform? Transform { get; set; }
    }
    public enum FillRule { EvenOdd, Nonzero }
    public sealed class PathGeometry : Geometry
    {
        public FillRule FillRule { get; set; }
        public List<PathFigure> Figures { get; } = new();
    }
    public sealed class PathFigure
    {
        public Windows.Foundation.Point StartPoint { get; set; }
        public bool IsClosed { get; set; }
        public bool IsFilled { get; set; }
        public List<PathSegment> Segments { get; } = new();
    }
    public abstract class PathSegment;
    public sealed class LineSegment : PathSegment { public Windows.Foundation.Point Point { get; set; } }
    public sealed class BezierSegment : PathSegment
    {
        public Windows.Foundation.Point Point1 { get; set; }
        public Windows.Foundation.Point Point2 { get; set; }
        public Windows.Foundation.Point Point3 { get; set; }
    }
    public sealed class QuadraticBezierSegment : PathSegment
    {
        public Windows.Foundation.Point Point1 { get; set; }
        public Windows.Foundation.Point Point2 { get; set; }
    }
    public enum SweepDirection { Counterclockwise, Clockwise }
    public sealed class ArcSegment : PathSegment
    {
        public Windows.Foundation.Point Point { get; set; }
        public Windows.Foundation.Size Size { get; set; }
        public double RotationAngle { get; set; }
        public bool IsLargeArc { get; set; }
        public SweepDirection SweepDirection { get; set; }
    }
    public sealed class PolyLineSegment : PathSegment { public List<Windows.Foundation.Point> Points { get; } = new(); }
    public abstract class Transform { public abstract Windows.Foundation.Point TransformPoint(Windows.Foundation.Point point); }
    public readonly record struct Matrix(double M11, double M12, double M21, double M22, double OffsetX, double OffsetY);
    public sealed class MatrixTransform : Transform
    {
        public Matrix Matrix { get; set; }
        public override Windows.Foundation.Point TransformPoint(Windows.Foundation.Point point) =>
            new(point.X * Matrix.M11 + point.Y * Matrix.M21 + Matrix.OffsetX,
                point.X * Matrix.M12 + point.Y * Matrix.M22 + Matrix.OffsetY);
    }
    public sealed class RectangleGeometry : Geometry { public object? Rect { get; set; } }
    public enum PenLineCap { Flat, Round }
    public enum PenLineJoin { Miter, Round }
}
namespace Windows.Foundation
{
    public readonly record struct Point(double X, double Y);
    public readonly record struct Size(double Width, double Height);
}
namespace Tokenstat.Design
{
    internal static class L10n { public static string Text(string key, params string[] args) => key; }
}
namespace Microsoft.UI.Xaml.Shapes
{
    public sealed class Path
    {
        public static DependencyProperty DataProperty { get; } = new();
        public static DependencyProperty FillProperty { get; } = new();
        public static DependencyProperty StrokeProperty { get; } = new();
        public static DependencyProperty ClipProperty { get; } = new();
        public static DependencyProperty RenderTransformProperty { get; } = new();

        public bool IsHitTestVisible { get; set; }
        public Visibility Visibility { get; set; }
        public Media.PathGeometry? Data { get; set; }
        public Media.Brush? Fill { get; set; }
        public Media.Brush? Stroke { get; set; }
        public double StrokeThickness { get; set; }
        public Media.PenLineCap StrokeStartLineCap { get; set; }
        public Media.PenLineCap StrokeEndLineCap { get; set; }
        public Media.PenLineJoin StrokeLineJoin { get; set; }
        public object? RenderTransform { get; set; }
        public double Opacity { get; set; }
        public Media.RectangleGeometry? Clip { get; set; }

        // The scene drops fill, stroke, clip, and data through ClearValue.
        // The turn is stored as null through SetValue on UIElement.
        public void ClearValue(DependencyProperty property)
        {
            if (ReferenceEquals(property, DataProperty)) Data = null;
            else if (ReferenceEquals(property, FillProperty)) Fill = null;
            else if (ReferenceEquals(property, StrokeProperty)) Stroke = null;
            else if (ReferenceEquals(property, ClipProperty)) Clip = null;
            else if (ReferenceEquals(property, RenderTransformProperty)
                || ReferenceEquals(property, UIElement.RenderTransformProperty))
                RenderTransform = null;
        }

        public void SetValue(DependencyProperty property, object? value)
        {
            if (ReferenceEquals(property, RenderTransformProperty)
                || ReferenceEquals(property, UIElement.RenderTransformProperty))
                RenderTransform = value;
        }
    }
}

// The portable executable checks visual-slot ownership, not Direct2D. Native
// clipping and activation are exercised by PersonaSceneSmoke on Windows.
namespace Tokenstat.Design.Persona
{
    internal readonly record struct PersonaClip(Microsoft.UI.Xaml.Media.Geometry Body,
        Microsoft.UI.Xaml.Media.Geometry? Mask = null);
    internal sealed class PersonaClipper
    {
        public void Update(IReadOnlyList<Microsoft.UI.Xaml.Shapes.Path> paths, IReadOnlyList<PersonaClip?> clips, int count) { }
        public void Clear() { }
    }
}
