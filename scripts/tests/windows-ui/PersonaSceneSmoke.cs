// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Composition;
using Microsoft.Graphics.Canvas.Geometry;
using System.Numerics;
using Tokenstat.Design.Persona;

namespace NativeUiTests;

internal static class PersonaSceneSmoke
{
    public static void Run()
    {
        var canvas = new Canvas();
        var scene = new PersonaScene(canvas);
        scene.Begin();
        var first = scene.Paint(new PathGeometry(), new SolidColorBrush(Microsoft.UI.Colors.White),
            clip: new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, 20, 20) });
        first.RenderTransform = new RotateTransform { Angle = 40 };
        first.Opacity = 0.2;
        scene.Paint(new PathGeometry());
        scene.End();
        if (ElementCompositionPreview.GetElementVisual(first).Clip is not CompositionGeometricClip)
            throw new Exception("Persona did not install a native geometric clip");
        for (int frame = 0; frame < 100; frame++)
        {
            scene.Begin();
            var path = scene.Paint(new PathGeometry());
            if (!ReferenceEquals(first, path))
                throw new Exception("Native persona slot replaced its visual");
            if (path.Fill is not null)
                throw new Exception("Native persona slot leaked its fill");
            if (path.Clip is not null)
                throw new Exception("Native persona slot leaked its clip");
            // The public getter allocates an identity matrix when the property is unset.
            var localTransform = path.ReadLocalValue(UIElement.RenderTransformProperty);
            if (localTransform is Microsoft.UI.Xaml.Media.Transform)
                throw new Exception("Native persona slot leaked its transform");
            if (path.Opacity != 1)
                throw new Exception("Native persona slot leaked its opacity");
            scene.End();
            if (ElementCompositionPreview.GetElementVisual(first).Clip is not null)
                throw new Exception("Persona slot retained its previous composition clip");
        }
        if (canvas.Children.Count != 2 || canvas.Children[1].Visibility != Visibility.Collapsed)
            throw new Exception("Native persona kept allocating visuals or showing an old prop");
        scene.Begin(); scene.End();
        if (first.Visibility != Visibility.Collapsed || first.Data is not null)
            throw new Exception("Native persona empty frame retained a visible pose");
        Program.Log("PASS: native persona reuses visual slots and clears old paint, clips, transforms and props");

        var circle = new PathGeometry();
        var ring = new PathFigure { StartPoint = new Windows.Foundation.Point(0, 10), IsClosed = true };
        ring.Segments.Add(new ArcSegment { Point = new Windows.Foundation.Point(20, 10), Size = new Windows.Foundation.Size(10, 10), SweepDirection = SweepDirection.Clockwise });
        ring.Segments.Add(new ArcSegment { Point = new Windows.Foundation.Point(0, 10), Size = new Windows.Foundation.Size(10, 10), SweepDirection = SweepDirection.Clockwise });
        circle.Figures.Add(ring);
        using (var curve = PersonaClipGeometry.Create(circle))
        {
            if (!curve.FillContainsPoint(new Vector2(10, 10)) || curve.FillContainsPoint(new Vector2(1, 1)))
                throw new Exception("Persona curved clip degraded to its bounding rectangle");
        }
        circle.Transform = new TranslateTransform { X = 30 };
        // The renderer paints one body geometry as a fill, outline and clip.
        // WinUI rejects attaching that same native geometry to a second Path.
        for (int frame = 0; frame < 100; frame++)
        {
            scene.Begin();
            var body = scene.Paint(circle, new SolidColorBrush(Microsoft.UI.Colors.White));
            var outline = scene.Paint(circle, stroke: new SolidColorBrush(Microsoft.UI.Colors.Black), clip: circle);
            scene.End();
            if (ReferenceEquals(body.Data, outline.Data) || ReferenceEquals(body.Data, circle))
                throw new Exception("Persona body and outline share their native geometry");
            var bodyData = (PathGeometry)body.Data;
            var outlineData = (PathGeometry)outline.Data;
            if (ReferenceEquals(bodyData.Figures[0], outlineData.Figures[0])
                || ReferenceEquals(bodyData.Figures[0].Segments[0], ring.Segments[0]))
                throw new Exception("Persona copied geometry without separating native figures and segments");
            using var bodyCurve = PersonaClipGeometry.Create(bodyData);
            using var outlineCurve = PersonaClipGeometry.Create(outlineData);
            if (!bodyCurve.FillContainsPoint(new Vector2(40, 10))
                || !outlineCurve.FillContainsPoint(new Vector2(40, 10)))
                throw new Exception("Persona geometry copy lost its curved shape or transform");
            ((ArcSegment)bodyData.Figures[0].Segments[0]).Point = new Windows.Foundation.Point(100, 100);
            if (((ArcSegment)ring.Segments[0]).Point.X != 20
                || ((ArcSegment)outlineData.Figures[0].Segments[0]).Point.X != 20)
                throw new Exception("Painting a persona changed another visual or its clip source");
            var faceTransform = new TransformGroup();
            faceTransform.Children.Add(new ScaleTransform { ScaleX = 0.5, CenterX = 10 });
            faceTransform.Children.Add(new TranslateTransform { X = 7 });
            bodyData.Transform = PersonaScene.CopyTransform(faceTransform);
            outlineData.Transform = PersonaScene.CopyTransform(faceTransform);
            var facePoint = outlineData.Transform.TransformPoint(new Windows.Foundation.Point(20, 10));
            if (facePoint.X != 22 || facePoint.Y != 10
                || ReferenceEquals(bodyData.Transform, outlineData.Transform))
                throw new Exception("Persona face transforms lost their composition or share native ownership");
            ((MatrixTransform)bodyData.Transform).Matrix = Matrix.Identity;
            if (outlineData.Transform.TransformPoint(new Windows.Foundation.Point(20, 10)).X != 22)
                throw new Exception("Changing a persona face transform affected another visual");
        }
        if (canvas.Children.Count != 2)
            throw new Exception("Copying persona geometry allocated additional visual slots");
        Program.Log("PASS: shared persona body, outline, curved clips and face transforms have independent native owners");
        var mask = new RectangleGeometry { Rect = new Windows.Foundation.Rect(30, 0, 10, 20) };
        scene.Begin(); scene.Paint(new PathGeometry(), clip: circle, mask: mask); scene.End();
        var compositionClip = (CompositionGeometricClip)ElementCompositionPreview.GetElementVisual(first).Clip;
        if (compositionClip.Geometry is not CompositionPathGeometry)
            throw new Exception("Persona intersection was not supplied as a curved composition path");
        using var transformedBody = PersonaClipGeometry.Create(circle);
        using var mouth = PersonaClipGeometry.Create(mask);
        using var intersection = PersonaClipGeometry.Intersect(transformedBody, mouth);
        if (!intersection.FillContainsPoint(new Vector2(35, 10))
            || intersection.FillContainsPoint(new Vector2(45, 10))
            || intersection.FillContainsPoint(new Vector2(31, 1)))
            throw new Exception("Persona mouth mask did not intersect the transformed curved body");
        scene.ReleaseClips();
        if (ElementCompositionPreview.GetElementVisual(first).Clip is not null)
            throw new Exception("Unloading a persona retained its composition clip");
        Program.Log("PASS: native curved clip, transformed mouth intersection and resource cleanup");
    }
}
