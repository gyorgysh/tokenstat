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
            CheckBudgets(source);
            var chart = new ChatChartView(source) { Width = 640 };
            body.Children.Insert(0, chart);
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
            body.Children.Remove(chart);
            await Task.Delay(100);
            body.Children.Insert(0, chart);
            body.UpdateLayout();
            await Ready();
            body.Children.Remove(chart);
            Program.Log("PASS: offline native charts render all families, inspect values, open data, resize, block navigation and remount cleanly");
        }

        private static void CheckBudgets(string source)
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
            if (Charts(ChatMarkdown.Create(many, Code)) != 4 || fallback.Count != 196 || fallback.Any(text => text != source))
                throw new Exception("Markdown failed to bound chart browsers while preserving the full JSON");
            fallback.Clear();
            var quoted = string.Join("\n", fence.Split('\n').Select(line => "> " + line));
            if (Charts(ChatMarkdown.Create(string.Join("\n\n", Enumerable.Repeat(quoted, 200)), Code)) != 4 || fallback.Count != 196)
                throw new Exception("Nested Markdown bypassed the reply's chart browser limit");
            var transcript = new ChartRenderBudget(ChartRenderBudget.PerTranscript);
            var count = Enumerable.Range(0, 100).Sum(_ => Charts(ChatMarkdown.Create(fence, Code, chartBudget: transcript)));
            if (count != 8) throw new Exception("Shared history exceeded its aggregate chart browser limit");
            Program.Log("PASS: chart browsers are bounded per message and transcript, including nested Markdown, without losing JSON");
        }
    }
}

// The fixture owns this window; production App is deliberately not loaded.
namespace Tokenstat
{
    internal static class App { internal static Window? CurrentWindow { get; set; } }
}
