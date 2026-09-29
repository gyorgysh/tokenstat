// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Minimal property model for the production scene's reuse contract. Native
// rendering still requires the Windows UI executable on a Windows runtime.
namespace Microsoft.UI.Xaml
{
    public enum Visibility { Visible, Collapsed }
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
