// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
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
        // A slot can hold an eye in one frame and a prop in the next. Reset all
        // per-mark state, including transforms and fading applied after Paint.
        path.Visibility = Visibility.Visible;
        path.Data = data;
        path.Fill = fill;
        path.Stroke = stroke;
        path.StrokeThickness = thickness;
        path.StrokeStartLineCap = cap;
        path.StrokeEndLineCap = cap;
        path.StrokeLineJoin = join;
        path.RenderTransform = null;
        path.Opacity = 1;
        path.Clip = null;
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
            path.Data = null;
            path.Fill = null;
            path.Stroke = null;
            path.Clip = null;
            path.RenderTransform = null;
        }
    }

    public void ReleaseClips() => _clipper.Clear();
}
