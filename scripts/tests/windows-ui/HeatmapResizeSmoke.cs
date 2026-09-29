// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Tokenstat.Design;

namespace NativeUiTests;

internal static class HeatmapResizeSmoke
{
    internal static async Task Run(StackPanel host)
    {
        var rows = new JsonArray();
        for (int r = 0; r < 7; r++)
        {
            var days = new JsonArray();
            for (int c = 0; c < 53; c++)
                days.Add(new JsonObject {
                    ["date"] = new DateTime(2025, 1, 1).AddDays(c * 7 + r).ToString("yyyy-MM-dd"),
                    ["value"] = 1000, ["level"] = c % 5 });
            rows.Add(days);
        }
        var view = Heatmap.View(new JsonObject { ["rows"] = rows, ["weeks"] = 53 }, "2025-01-01");
        view.Width = 600;
        host.Children.Add(view);
        try
        {
            host.UpdateLayout();
            await Task.Delay(50);
            var canvas = Descendants(view).OfType<Canvas>().Single(c => c.Children.OfType<Button>().Any());
            var cells = canvas.Children.OfType<Rectangle>().ToArray();
            var input = canvas.Children.OfType<Button>().Single();
            var originalWidth = cells[0].Width;
            input.Focus(FocusState.Keyboard);
            foreach (double width in new double[] { 320, 800, 440 })
            {
                view.Width = width;
                host.UpdateLayout();
                await Task.Delay(50);
                var current = Descendants(view).OfType<Canvas>().Single(c => c.Children.OfType<Button>().Any());
                if (!ReferenceEquals(canvas, current) || !cells.SequenceEqual(current.Children.OfType<Rectangle>()))
                    throw new Exception("Resizing recreated calendar visuals");
                if (!ReferenceEquals(input, current.Children.OfType<Button>().Single()) || input.FocusState == FocusState.Unfocused)
                    throw new Exception("Resizing lost the calendar keyboard control or focus");
                if (Math.Abs(input.Width - canvas.Width) > 0.01 || Math.Abs(input.Height - canvas.Height) > 0.01)
                    throw new Exception("Calendar hit area did not follow its cells");
            }
            if (Math.Abs(originalWidth - cells[0].Width) < 0.01 || view.SelectedDate != "2025-01-01")
                throw new Exception("Calendar geometry or selection did not survive resizing");
            Program.Log("PASS: calendar resize retains cell/control identity, keyboard focus and selection");
        }
        finally { host.Children.Remove(view); }
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
