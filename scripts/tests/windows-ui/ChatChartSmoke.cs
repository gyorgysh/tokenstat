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
    }
}

// The fixture owns this window; production App is deliberately not loaded.
namespace Tokenstat
{
    internal static class App { internal static Window? CurrentWindow { get; set; } }
}
