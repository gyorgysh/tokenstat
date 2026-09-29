// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design.Persona;

internal static class SceneTests
{
    public static void Run()
    {
        static void Check(bool value, string message) { if (!value) throw new Exception(message); }
        var canvas = new Canvas();
        var scene = new PersonaScene(canvas);
        scene.Begin();
        var first = scene.Paint(new PathGeometry(), new Brush(), new Brush(), 4,
            PenLineCap.Round, PenLineJoin.Round, new PathGeometry());
        first.RenderTransform = new object();
        first.Opacity = 0.1;
        var second = scene.Paint(new PathGeometry());
        scene.End();
        scene.Begin();
        var replacement = new PathGeometry();
        Check(ReferenceEquals(first, scene.Paint(replacement)), "A repaint replaced its visual slot");
        Check(first.Data == replacement && first.Fill is null && first.Stroke is null
            && first.Clip is null && first.RenderTransform is null && first.Opacity == 1
            && first.StrokeThickness == 1 && first.StrokeStartLineCap == PenLineCap.Flat
            && first.StrokeEndLineCap == PenLineCap.Flat && first.StrokeLineJoin == PenLineJoin.Miter,
            "A reused mark retained the previous face/prop style");
        scene.End();
        Check(second.Visibility == Visibility.Collapsed && second.Data is null,
            "A disappearing mote remained visible or retained its geometry");
        for (int frame = 0; frame < 1000; frame++)
        {
            scene.Begin();
            int count = frame % 17;
            for (int i = 0; i < count; i++) scene.Paint(new PathGeometry());
            scene.End();
            Check(scene.Count == count && canvas.Children.Count(p => p.Visibility == Visibility.Visible) == count,
                "Changing moods left stale visual slots visible");
        }
        Check(canvas.Children.Count == 16 && ReferenceEquals(canvas.Children[0], first)
            && ReferenceEquals(canvas.Children[1], second), "Steady animation kept allocating visual elements");
        scene.Begin(); scene.End();
        Check(canvas.Children.All(p => p.Visibility == Visibility.Collapsed && p.Data is null),
            "An empty frame did not hide the previous pose");
        Console.WriteLine("Persona scene: stable visuals, state reset, shrinking/empty frames passed");
    }
}
