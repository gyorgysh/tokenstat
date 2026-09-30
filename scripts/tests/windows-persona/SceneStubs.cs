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
    public class Geometry { public object Bounds { get; set; } = new(); }
    public sealed class PathGeometry : Geometry;
    public sealed class RectangleGeometry : Geometry { public object? Rect { get; set; } }
    public enum PenLineCap { Flat, Round }
    public enum PenLineJoin { Miter, Round }
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
