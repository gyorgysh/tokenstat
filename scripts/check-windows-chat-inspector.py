#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise actual inspector builders with counting, non-native controls.

The optional benchmark measures managed builder work and constructed controls,
not WinUI layout/rendering or FPS. No application, host, or network is used.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-root', type=Path, default=root)
parser.add_argument('--benchmark', type=Path, nargs='*', help='private inspection JSON snapshots')
args = parser.parse_args()
source_root = args.source_root.resolve()

def methods(source, signature):
    result, offset = [], 0
    while (start := source.find(signature, offset)) >= 0:
        brace = source.index('{', start)
        end, depth = brace + 1, 1
        while depth:
            depth += (source[end] == '{') - (source[end] == '}')
            end += 1
        if source[end:end + 1] == ';':
            end += 1
        result.append(source[start:end])
        offset = end
    if not result:
        raise ValueError(signature)
    return '\n'.join(result)

stats = (source_root / 'apps/windows/Pages/ChatPage.Stats.cs').read_text()
activity = (source_root / 'apps/windows/Pages/ChatPage.Activity.cs').read_text()
builders = '\n'.join(methods(stats, signature) for signature in [
    '    private void AddStats(', '    private static Grid ContextUsageBar(',
    '    private static Grid StatsMetric(', '    private Border CollapsibleStatsCard(',
    '    private void AppendUsage(', '    private Expander StatsDisclosure(',
    '    private UIElement ToolBrowser(', '    private UIElement ServerRow(',
])
builders += '\n' + stats[stats.index('    private static string ServerStatus('):stats.rindex('\n}')]
builders += '\n' + '\n'.join(methods(activity, signature) for signature in [
    '    private static string ActivityText(', '    private static string ActivityStatus(',
    '    private static string ActivitySummary(', '    private static FrameworkElement ActivityPlanChecklist(', '    private UIElement ActivityCard(',
    '    private UIElement ActivityDisclosure(', '    private static void AddActivitySource(',
    '    private static void AddActivityMetric(', '    private static ProgressBar ActivityProgress(',
])

code = r'''
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Tokenstat.Pages;
using AutomationProperties = Microsoft.UI.Xaml.Automation.AutomationProperties;

enum Visibility { Visible, Collapsed }
enum HorizontalAlignment { Stretch, Left }
enum VerticalAlignment { Center }
enum TextWrapping { Wrap }
enum TextTrimming { CharacterEllipsis }
enum GridUnitType { Star }
readonly record struct GridLength(double Value, GridUnitType Unit = GridUnitType.Star) { public static GridLength Auto => new(0); }
readonly record struct Thickness { public Thickness(double all) {} public Thickness(double l, double t, double r, double b) {} }
readonly record struct CornerRadius(double Value);
readonly record struct Point(double X, double Y);
sealed class PointCollection : List<Point> {}
sealed class Brush {}
static class FontWeights { public static readonly object SemiBold = new(); }
class UIElement { public static long Constructed; public UIElement() { Constructed++; } public Visibility Visibility { get; set; } }
class FrameworkElement : UIElement {
    public object? Tag { get; set; }
    public HorizontalAlignment HorizontalAlignment { get; set; }
    public HorizontalAlignment HorizontalContentAlignment { get; set; }
    public VerticalAlignment VerticalAlignment { get; set; }
    public Thickness Padding { get; set; }
    public Thickness Margin { get; set; }
    public double Width { get; set; }
    public double Height { get; set; }
    public double ActualWidth { get; set; } = 320;
    public double MaxHeight { get; set; }
    public double MinHeight { get; set; }
    public bool IsHitTestVisible { get; set; }
    public Dictionary<string, object> Resources { get; } = new();
}
class Panel : FrameworkElement { public List<UIElement> Children { get; } = new(); }
class StackPanel : Panel { public double Spacing { get; set; } }
class ColumnDefinition { public GridLength Width { get; set; } }
class Grid : Panel {
    public double ColumnSpacing { get; set; }
    public Brush? Background { get; set; }
    public List<ColumnDefinition> ColumnDefinitions { get; } = new();
    public static void SetColumn(UIElement item, int column) {}
}
class TextBlock : FrameworkElement {
    public string Text { get; set; } = "";
    public double FontSize { get; set; }
    public double Opacity { get; set; }
    public Brush? Foreground { get; set; }
    public object? FontWeight { get; set; }
    public TextTrimming TextTrimming { get; set; }
    public TextWrapping TextWrapping { get; set; }
    public bool IsTextSelectionEnabled { get; set; }
}
class TextBox : FrameworkElement {
    string _text = "";
    public string Text { get => _text; set { if (_text == value) return; _text = value; TextChanged?.Invoke(this, EventArgs.Empty); } }
    public string PlaceholderText { get; set; } = "";
    public event EventHandler? TextChanged;
}
class Border : FrameworkElement {
    public UIElement? Child { get; set; }
    public Brush? Background { get; set; }
    public Brush? BorderBrush { get; set; }
    public Thickness BorderThickness { get; set; }
    public CornerRadius CornerRadius { get; set; }
}
class Button : FrameworkElement {
    public object? Content { get; set; }
    public Brush? Background { get; set; }
    public Thickness BorderThickness { get; set; }
    public event EventHandler? Click;
    public void Invoke() => Click?.Invoke(this, EventArgs.Empty);
}
class ScrollViewer : FrameworkElement { public object? Content { get; set; } }
class Expander : FrameworkElement {
    public object? Header { get; set; }
    public object? Content { get; set; }
    public bool IsExpanded { get; set; }
    public event EventHandler? Expanding, Collapsed;
    public void SetExpanded(bool value) { if (value == IsExpanded) return; IsExpanded = value; if (value) Expanding?.Invoke(this, EventArgs.Empty); else Collapsed?.Invoke(this, EventArgs.Empty); }
}
class Canvas : Panel { public event EventHandler? SizeChanged; }
class Polyline : FrameworkElement {
    public Brush? Stroke { get; set; }
    public double StrokeThickness { get; set; }
    public PointCollection Points { get; set; } = new();
}
class ProgressBar : FrameworkElement { public double Minimum { get; set; } public double Maximum { get; set; } public double Value { get; set; } }
static class ToolTipService { public static void SetToolTip(UIElement item, object text) {} }
static class Fonts { public static TextBlock Tabular(TextBlock text) => text; }
static class L10n { public static string Text(string key, params string[] args) => args.Length == 0 ? key : key + ":" + string.Join(",", args); }
static class Theme {
    public static Brush AccentBrush = new(), AccentSoftBrush = new(), PanelBrush = new(), BorderBrush = new();
    public static object Secondary = new(), Warning = new(), DefaultText = new();
    public const int SpaceS = 4, SpaceM = 8, CardRadius = 12;
    public static Brush Brush(Func<object> color) => new();
}
enum ActionIcon { Done, Run, Scheduled }
static class ActionIconGlyph { public static TextBlock Icon(this ActionIcon icon) => new() { Text = icon.ToString() }; }
namespace Microsoft.UI.Xaml.Automation { static class AutomationProperties { public static void SetHelpText(UIElement item, string text) {} public static void SetName(UIElement item, string text) {} } }
namespace Tokenstat.Pages {
internal sealed partial class ChatPage {
    private readonly Dictionary<string, bool> _statsExpanded = new();
    private readonly Dictionary<string, string> _statsQueries = new();
    private readonly List<TextBox> _statsFilters = new();
    private JsonNode? _inspection;
    private JsonNode? CurrentInspection => _inspection;
    private JsonObject? _aggregateUsage;
    private JsonNode _openChat = new JsonObject { ["model"] = "fixture-model", ["running"] = false };
    private static JsonArray AsArray(JsonNode? node, string key) => node?[key] as JsonArray ?? new();
    private static TextBlock Muted(string text) => new() { Text = text, Opacity = .7 };
    public ChatPage(JsonNode? inspection, params string[] open) { _inspection = inspection; foreach (var key in open) _statsExpanded[key] = true; }
    public StackPanel Build() { _statsFilters.Clear(); var root = new StackPanel(); AddStats(root); return root; }
''' + builders + r'''
    static IEnumerable<UIElement> Walk(object? value) {
        if (value is not UIElement item) yield break;
        yield return item;
        object? content = item switch { Border border => border.Child, Button button => button.Content, ScrollViewer scroll => scroll.Content, Expander expander => expander.Content, _ => null };
        foreach (var child in Walk(content)) yield return child;
        if (item is Expander header) foreach (var child in Walk(header.Header)) yield return child;
        if (item is Panel panel) foreach (var nested in panel.Children) foreach (var child in Walk(nested)) yield return child;
    }
    static Button Toggle(UIElement root, string title) => Walk(root).OfType<Button>().First(button => Walk(button.Content).OfType<TextBlock>().Any(text => text.Text == title));
    static bool HasText(UIElement root, string text) => Walk(root).OfType<TextBlock>().Any(block => block.Text == text);
    static void Check(bool pass, string message) { if (!pass) throw new Exception(message); }
    public static void Checks() {
        var data = Fixture(); var page = new ChatPage(data); var root = page.Build();
        Check(!HasText(root, "goal-objective") && !HasText(root, "1. plan-step") && !HasText(root, "agent-task"), "Collapsed activity built its goal/plan/agent details");
        Toggle(root, "common.chat.activity.title").Invoke();
        Check(HasText(root, "goal-objective") && HasText(root, "1. plan-step"), "Reported goal and plan did not open automatically");
        Check(!HasText(root, "agent-task"), "Collapsed agent card built its task");
        Toggle(root, "agent-name").Invoke(); Check(HasText(root, "agent-task"), "Opening an agent lost its task");
        var activityCount = UIElement.Constructed;
        Toggle(root, "common.chat.activity.title").Invoke(); Toggle(root, "common.chat.activity.title").Invoke();
        Check(activityCount == UIElement.Constructed, "Reopening activity rebuilt its details");
        Toggle(root, "common.chat.activity.plan").Invoke();
        var refreshed = page.Build();
        Check(!HasText(refreshed, "1. plan-step"), "Automatic expansion overrode a manual collapse on refresh");
        var checklist = ActivityPlanChecklist(ChatActivityData.Read(data, page._openChat)!);
        Check(HasText(checklist, "plan-step") && HasText(checklist, "Scheduled"), "Transcript checklist lost its reported step or status");
        var planDialog = new ChatPage(data).ActivityCard(data, expanded: true, section: "plan");
        Check(HasText(planDialog, "1. plan-step") && !HasText(planDialog, "goal-objective") && !HasText(planDialog, "agent-task"), "The plan command expanded unrelated sections or hid the requested plan");
        var goalDialog = new ChatPage(data).ActivityCard(data, expanded: true, section: "goal");
        Check(HasText(goalDialog, "goal-objective") && !HasText(goalDialog, "1. plan-step"), "The goal command lost its explicit expansion");
        Check(!HasText(root, "server-0"), "Collapsed MCP card built its server inventory");
        Check(!Walk(root).OfType<TextBox>().Any(), "Collapsed context built a tool filter");
        Toggle(root, "common.chat.stats.mcp_servers").Invoke();
        Check(HasText(root, "server-0"), "Opening MCP did not build server rows");
        Check(!HasText(root, "tool-0"), "Collapsed server tool list was materialized");
        var server = Walk(root).OfType<Expander>().First(expander => expander.Header is Grid);
        server.SetExpanded(true); Check(HasText(root, "tool-0"), "Opening server tools lost their names");
        var count = UIElement.Constructed;
        server.SetExpanded(false); server.SetExpanded(true);
        Check(UIElement.Constructed == count, "Reopening server tools rebuilt their native owners");
        Toggle(root, "common.chat.stats").Invoke();
        Check(!Walk(root).OfType<TextBox>().Any(), "Collapsed tool browser built its search/group UI");
        var available = Walk(root).OfType<Expander>().First(expander => expander.Header is string label && label.StartsWith("common.chat.stats.available_tools:"));
        available.SetExpanded(true);
        var filter = Walk(root).OfType<TextBox>().Single(); filter.Text = "mcp__one";
        var group = Walk(root).OfType<Expander>().First(expander => expander.Header is string label && label.StartsWith("one ·"));
        group.SetExpanded(true); Check(HasText(root, "mcp__one__read"), "Lazy tool group lost matching names");
        count = UIElement.Constructed; group.SetExpanded(false); group.SetExpanded(true);
        Check(count == UIElement.Constructed, "Reopening a group allocated duplicate names");
        root = page.Build(); Check(Walk(root).OfType<TextBox>().Single().Text == "mcp__one", "Inspection refresh lost filter/state");
        var oldHost = new ChatPage(null); oldHost._aggregateUsage = new JsonObject { ["input"] = 3, ["output"] = 4 };
        root = oldHost.Build(); Toggle(root, "common.chat.stats").Invoke();
        Check(Walk(root).OfType<Expander>().Any(expander => Equals(expander.Header, "common.chat.stats.conversation")), "Missing inspection hid cached whole-archive usage");
        Console.WriteLine("PASS: actual inspector builders defer collapsed inventories, preserve expansion/filter ownership, and retain old-host usage");
    }
    static JsonObject Fixture() => new() {
        ["model"] = "fixture", ["contextUsed"] = 20, ["contextWindow"] = 100,
        ["tools"] = new JsonArray("mcp__one__read", "mcp__one__write", "mcp__two__read"),
        ["mcpServers"] = new JsonArray(new JsonObject { ["name"] = "server-0", ["source"] = "agent", ["status"] = "connected", ["tools"] = new JsonArray("tool-0", "tool-1") }),
        ["activity"] = new JsonObject { ["goalReported"] = true, ["planReported"] = true, ["agentsReported"] = true,
            ["goal"] = new JsonObject { ["objective"] = "goal-objective", ["status"] = "active" },
            ["plan"] = new JsonArray(new JsonObject { ["text"] = "plan-step", ["status"] = "pending" }),
            ["agents"] = new JsonArray(new JsonObject { ["id"] = "agent-id", ["name"] = "agent-name", ["task"] = "agent-task", ["status"] = "running" }) } };
    public static void Benchmark(string[] paths) {
        foreach (var path in paths) {
            var data = JsonNode.Parse(File.ReadAllText(path));
            foreach (var (label, open) in new[] { ("collapsed", Array.Empty<string>()), ("context", new[] { "context" }), ("servers", new[] { "servers" }), ("tools", new[] { "context", "available" }) }) {
                const int iterations = 300;
                for (var i = 0; i < 30; i++) new ChatPage(data, open).Build();
                GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
                var controls = UIElement.Constructed; var allocated = GC.GetAllocatedBytesForCurrentThread(); var watch = Stopwatch.StartNew();
                for (var i = 0; i < iterations; i++) new ChatPage(data, open).Build();
                watch.Stop();
                Console.WriteLine(JsonSerializer.Serialize(new { file = Path.GetFileName(Path.GetDirectoryName(path)), state = label, iterations, microseconds = watch.Elapsed.TotalMicroseconds / iterations, bytes = (GC.GetAllocatedBytesForCurrentThread() - allocated) / iterations, controls = (UIElement.Constructed - controls) / iterations }));
            }
        }
    }
}
}
class Entry { static void Main(string[] args) { if (args.Length == 0) ChatPage.Checks(); else ChatPage.Benchmark(args); } }
'''

with tempfile.TemporaryDirectory(prefix='tokenstat-windows-inspector-') as temp:
    folder = Path(temp)
    (folder / 'Program.cs').write_text(code)
    for name in ['Format', 'ChatActivityData']:
        (folder / (name + '.cs')).write_text((source_root / f'apps/windows/Pages/{name}.cs').read_text())
    (folder / 'Inspector.csproj').write_text('''<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable><NoWarn>CS0067;CS0649</NoWarn></PropertyGroup></Project>''')
    subprocess.run(['dotnet', 'build', str(folder / 'Inspector.csproj'), '-c', 'Release', '--nologo', '-v:q'], check=True)
    subprocess.run(['dotnet', str(folder / 'bin/Release/net8.0/Inspector.dll'), *[str(path.resolve()) for path in args.benchmark or []]], check=True,
                   env=os.environ | {'DOTNET_TieredCompilation': '0'})
