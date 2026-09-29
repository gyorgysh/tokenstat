// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using ShapesPath = Microsoft.UI.Xaml.Shapes.Path;

namespace Tokenstat.Design.Persona;

internal readonly record struct PersonaClip(Geometry Body, Geometry? Mask = null);

/// <summary>
/// One body clip is shared by all facial marks in a frame. Build after the
/// face transform is applied, so a tongue's mouth mask follows yaw and roll.
/// Keep native geometry alive until every visual has moved to the next frame.
/// </summary>
internal sealed class PersonaClipper
{
    private Frame? _frame;
    private readonly Dictionary<ShapesPath, Visual> _visuals = new();
    private readonly HashSet<ShapesPath> _active = new();

    public void Update(IReadOnlyList<ShapesPath> paths, IReadOnlyList<PersonaClip?> clips, int count)
    {
        var next = new Frame();
        try
        {
            for (int i = 0; i < paths.Count; i++)
            {
                var path = paths[i];
                if (i < count && clips[i] is { } clip)
                {
                    if (!_visuals.TryGetValue(path, out var visual))
                        _visuals.Add(path, visual = ElementCompositionPreview.GetElementVisual(path));
                    visual.Clip = next.Get(visual.Compositor, clip);
                    _active.Add(path);
                }
                else if (_active.Remove(path)) _visuals[path].Clip = null;
            }
        }
        catch
        {
            Clear();
            next.Dispose();
            throw;
        }
        var previous = _frame;
        _frame = next;
        previous?.Dispose();
    }

    public void Clear()
    {
        foreach (var path in _active) _visuals[path].Clip = null;
        _active.Clear(); _visuals.Clear();
        _frame?.Dispose();
        _frame = null;
    }

    private sealed class Frame : IDisposable
    {
        private readonly Dictionary<Geometry, CanvasGeometry> _sources = new();
        private readonly Dictionary<PersonaClip, CompositionGeometricClip> _clips = new();
        private readonly List<IDisposable> _resources = new();

        private CanvasGeometry Source(Geometry shape)
        {
            if (_sources.TryGetValue(shape, out var existing)) return existing;
            var source = PersonaClipGeometry.Create(shape);
            _sources.Add(shape, source); _resources.Add(source);
            return source;
        }

        public CompositionGeometricClip Get(Compositor compositor, PersonaClip clip)
        {
            if (_clips.TryGetValue(clip, out var existing)) return existing;
            var geometry = Source(clip.Body);
            if (clip.Mask is { } mask)
            {
                geometry = PersonaClipGeometry.Intersect(geometry, Source(mask));
                _resources.Add(geometry);
            }
            var path = compositor.CreatePathGeometry(new CompositionPath(geometry));
            _resources.Add(path);
            var result = compositor.CreateGeometricClip(path);
            _resources.Add(result);
            _clips.Add(clip, result);
            return result;
        }

        public void Dispose()
        {
            for (int i = _resources.Count - 1; i >= 0; i--) _resources[i].Dispose();
            _resources.Clear(); _clips.Clear(); _sources.Clear();
        }
    }
}
