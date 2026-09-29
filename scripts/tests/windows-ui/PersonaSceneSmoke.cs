// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
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
        for (int frame = 0; frame < 100; frame++)
        {
            scene.Begin();
            var path = scene.Paint(new PathGeometry());
            if (!ReferenceEquals(first, path) || path.Fill is not null || path.Clip is not null
                || path.RenderTransform is not null || path.Opacity != 1)
                throw new Exception("Native persona slot leaked prior appearance or replaced its visual");
            scene.End();
        }
        if (canvas.Children.Count != 2 || canvas.Children[1].Visibility != Visibility.Collapsed)
            throw new Exception("Native persona kept allocating visuals or showing an old prop");
        scene.Begin(); scene.End();
        if (first.Visibility != Visibility.Collapsed || first.Data is not null)
            throw new Exception("Native persona empty frame retained a visible pose");
        Program.Log("PASS: native persona reuses visual slots and clears old paint, clips, transforms and props");
    }
}
