// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Pages;

namespace NativeUiTests
{
    /// <summary>Mount the production WebView2 container, then exercise its real offline page.</summary>
    internal static class ChatChartSmoke
    {
        internal static async Task Run(StackPanel body)
        {
            using var examples = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "chart-examples.json")));
            var source = examples.RootElement[0].GetRawText();
            CheckPreservation(source);
            var chart = new ChatChartView(source) { Width = 640 };
            var scroll = new ScrollViewer { Content = chart, Height = 700 };
            body.Children.Insert(0, scroll);
            body.UpdateLayout();
            async Task<WebView2> Ready()
            {
                var deadline = DateTime.UtcNow.AddSeconds(30);
                while (DateTime.UtcNow < deadline)
                {
                    if (chart.Children.FirstOrDefault() is WebView2 web && web.CoreWebView2 is not null)
                    {
                        try { if (await web.ExecuteScriptAsync("!!window.TokenstatChart?.inspect().valid") == "true") return web; }
                        catch { /* Initialization can overlap the first poll. */ }
                    }
                    await Task.Delay(50);
                }
                throw new Exception("Native chart did not load the bundled offline renderer");
            }
            var web = await Ready();
            foreach (var example in examples.RootElement.EnumerateArray())
            {
                await web.ExecuteScriptAsync($"window.TokenstatChart.render({example.GetRawText()},{{dark:true,reducedMotion:true}})");
                if (await web.ExecuteScriptAsync("window.TokenstatChart.inspect().valid && document.querySelectorAll('#plot svg path').length>0") != "true")
                    throw new Exception("Native chart failed: " + example.GetProperty("type"));
            }
            await web.ExecuteScriptAsync($"window.TokenstatChart.render({source},{{reducedMotion:true}});document.getElementById('plot').dispatchEvent(new KeyboardEvent('keydown',{{key:'ArrowRight'}}));document.getElementById('table-toggle').click()");
            if (await web.ExecuteScriptAsync("!!window.TokenstatChart.inspect().selected && !document.getElementById('data-panel').hidden && document.querySelectorAll('#rows tr').length===8") != "true")
                throw new Exception("Native chart inspection/table did not preserve exact observations");
            await Task.Delay(200);
            if (chart.Height < 500 || chart.Height > 2200) throw new Exception("Chart height bridge did not size the native container");
            web.CoreWebView2.Navigate("https://invalid.example/blocked");
            await Task.Delay(150);
            if (web.CoreWebView2.Source != "https://charts.tokenstat.invalid/index.html") throw new Exception("Chart navigation escaped its bundled page");
            scroll.Content = null;
            await Task.Delay(100);
            scroll.Content = chart;
            body.UpdateLayout();
            await Ready();
            body.Children.Remove(scroll);
            await CheckViewportAsync(body, source);
            Program.Log("PASS: offline native charts render all families, inspect values, open data, resize, block navigation and remount cleanly");
        }

        private static void CheckPreservation(string source)
        {
            var fence = "```tokenstat-chart\n" + source + "\n```";
            static int Charts(UIElement element) => element switch {
                ChatChartView => 1,
                Panel panel => panel.Children.Sum(Charts),
                Border { Child: { } child } => Charts(child),
                _ => 0,
            };
            var fallback = new List<string>();
            UIElement Code(string text) { fallback.Add(text); return new TextBlock { Text = text }; }
            var many = string.Join("\n\n", Enumerable.Repeat(fence, 200));
            if (Charts(ChatMarkdown.Create(many, Code)) != 200 || fallback.Count != 0)
                throw new Exception("Markdown changed later chart fences into raw JSON");
            fallback.Clear();
            var quoted = string.Join("\n", fence.Split('\n').Select(line => "> " + line));
            if (Charts(ChatMarkdown.Create(string.Join("\n\n", Enumerable.Repeat(quoted, 200)), Code)) != 200 || fallback.Count != 0)
                throw new Exception("Nested Markdown changed later chart fences into raw JSON");
            Program.Log("PASS: all 200 chart fences, including nested Markdown, remain charts");
        }

        private static async Task CheckViewportAsync(StackPanel body, string source)
        {
            var charts = Enumerable.Range(0, 12).Select(_ => new ChatChartView(source)).ToArray();
            var stack = new StackPanel { Spacing = 8 };
            foreach (var chart in charts) stack.Children.Add(chart);
            var scroll = new ScrollViewer { Content = stack, Width = 640, Height = 480 };
            async Task Until(Func<bool> condition)
            {
                for (var attempt = 0; attempt < 400; attempt++)
                {
                    body.UpdateLayout();
                    if (condition()) return;
                    await Task.Delay(50);
                }
                throw new Exception("Chart viewport did not settle");
            }
            static WebView2? Browser(ChatChartView chart) => chart.Children.OfType<WebView2>().FirstOrDefault();
            async Task Ready(ChatChartView chart)
            {
                for (var attempt = 0; attempt < 400; attempt++)
                {
                    if (Browser(chart) is { CoreWebView2: not null } web)
                    {
                        try { if (await web.ExecuteScriptAsync("!!window.TokenstatChart?.inspect().valid") == "true") return; }
                        catch { }
                    }
                    await Task.Delay(50);
                }
                throw new Exception("Visible chart failed to render after viewport mounting");
            }
            try
            {
                body.Children.Insert(0, scroll);
                await Until(() => Browser(charts[0])?.CoreWebView2 is not null);
                await Ready(charts[0]);
                var original = Browser(charts[0]);
                if (charts.Count(chart => Browser(chart) is not null) > 3 || Browser(charts[^1]) is not null)
                    throw new Exception("Offscreen charts eagerly created native browsers");
                var height = JsonSerializer.Deserialize<double>(await original!.ExecuteScriptAsync(
                    "Math.min(2200,Math.max(180,Math.ceil(document.getElementById('root').getBoundingClientRect().height)))"));
                await Until(() => charts[0].Height == height);
                scroll.ChangeView(null, scroll.ExtentHeight - scroll.ViewportHeight, null, true);
                await Until(() => Browser(charts[0]) is null && Browser(charts[^1])?.CoreWebView2 is not null);
                await Ready(charts[^1]);
                if (charts[0].Height != height || charts.Count(chart => Browser(chart) is not null) > 3)
                    throw new Exception("Offscreen charts lost their measured space or retained their browsers");
                scroll.ChangeView(null, 0, null, true);
                await Until(() => Browser(charts[^1]) is null && Browser(charts[0])?.CoreWebView2 is not null);
                await Ready(charts[0]);
                if (ReferenceEquals(original, Browser(charts[0]))) throw new Exception("A released chart reused its closed browser");
                // Rapid moves can overlap environment creation and native
                // initialization. Only the final viewport may retain browsers.
                for (var index = 0; index < 4; index++)
                {
                    scroll.ChangeView(null, scroll.ExtentHeight - scroll.ViewportHeight, null, true);
                    body.UpdateLayout();
                    scroll.ChangeView(null, 0, null, true);
                    body.UpdateLayout();
                }
                await Until(() => Browser(charts[0])?.CoreWebView2 is not null && Browser(charts[^1]) is null);
                stack.Visibility = Visibility.Collapsed;
                await Until(() => charts.All(chart => Browser(chart) is null));
                stack.Visibility = Visibility.Visible;
                await Until(() => Browser(charts[0])?.CoreWebView2 is not null);
                await Ready(charts[0]);
                Program.Log("PASS: scrolling mounts later charts, releases offscreen browsers, preserves height and remounts safely");
            }
            finally { body.Children.Remove(scroll); }
        }
    }
}

// The fixture owns this window; production App is deliberately not loaded.
namespace Tokenstat
{
    internal static class App { internal static Window? CurrentWindow { get; set; } }
}
