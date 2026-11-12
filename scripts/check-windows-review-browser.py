#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compile the shipping review browser with minimal UI stubs and exercise navigation."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
STUBS = r'''
namespace Microsoft.UI.Xaml {
    public enum Visibility { Visible, Collapsed }
    public enum HorizontalAlignment { Left, Stretch, Center }
    public enum GridUnitType { Star }
    public enum TextTrimming { CharacterEllipsis }
    public enum VerticalAlignment { Center }
    public struct GridLength { public double Value; public GridLength(double n) { Value = n; } public GridLength(double n, GridUnitType type) { Value = n; } public static GridLength Auto => new(0); }
    public class UIElement { public Visibility Visibility { get; set; }
        public event EventHandler<Microsoft.UI.Xaml.Input.PointerRoutedEventArgs>? PointerPressed, PointerMoved, PointerReleased, PointerCaptureLost;
        public bool CapturePointer(Microsoft.UI.Xaml.Input.Pointer p) => true; public void ReleasePointerCapture(Microsoft.UI.Xaml.Input.Pointer p) {}
        public void Drag(double from, double to) {
            PointerPressed?.Invoke(this, new(from)); PointerMoved?.Invoke(this, new(to)); PointerReleased?.Invoke(this, new(to)); } }
    public class FrameworkElement : UIElement { public HorizontalAlignment HorizontalAlignment { get; set; } public VerticalAlignment VerticalAlignment { get; set; } }
    public class Size { public double Width; }
    public class SizeChangedEventArgs : EventArgs { public Size NewSize = new(); }
}
namespace Microsoft.UI.Xaml.Input {
    public class Pointer {}
    public class PointerPoint { public Windows.Foundation.Point Position; }
    public class PointerRoutedEventArgs : EventArgs { private readonly double _x; public PointerRoutedEventArgs(double x) { _x = x; }
        public Pointer Pointer = new(); public PointerPoint GetCurrentPoint(object? relative) => new() { Position = new() { X = _x } }; }
}
namespace Windows.Foundation { public struct Point { public double X, Y; } }
namespace Microsoft.UI.Xaml.Media { public class Brush {} }
namespace Microsoft.UI.Xaml.Controls {
    using Microsoft.UI.Xaml;
    public class RowDefinition { public GridLength Height { get; set; } }
    public class ColumnDefinition { public GridLength Width { get; set; } }
    public class Grid : FrameworkElement {
        public List<RowDefinition> RowDefinitions = new(); public List<ColumnDefinition> ColumnDefinitions = new(); public List<UIElement> Children = new();
        public event EventHandler<SizeChangedEventArgs>? SizeChanged;
        public static void SetRow(UIElement e, int n) {} public static void SetColumn(UIElement e, int n) {} public static void SetColumnSpan(UIElement e, int n) {}
        public void Resize(double width) => SizeChanged?.Invoke(this, new SizeChangedEventArgs { NewSize = new Size { Width = width } });
    }
    public enum ScrollBarVisibility { Auto }
    public class ScrollViewer : FrameworkElement { public object? Content; public ScrollBarVisibility HorizontalScrollBarVisibility, VerticalScrollBarVisibility; public double VerticalOffset = 50; public void UpdateLayout() {} public void ChangeView(double? x, double? y, object? z, bool noAnimation) { VerticalOffset = y ?? VerticalOffset; } }
    public enum ListViewSelectionMode { Single }
    public class Selector : FrameworkElement {
        public List<object> Items = new(); private int _selectedIndex = -1;
        public event EventHandler? SelectionChanged;
        public int SelectedIndex { get => _selectedIndex; set { if (_selectedIndex != value) { _selectedIndex = value; SelectionChanged?.Invoke(this, EventArgs.Empty); } } }
    }
    public class ListView : Selector { public ListViewSelectionMode SelectionMode; public object? Header; }
    public class ComboBox : Selector { }
    public class ListViewItem : FrameworkElement { public object? Content, Tag; public HorizontalAlignment HorizontalContentAlignment; }
    public class ComboBoxItem : FrameworkElement { public object? Content, Tag; }
    public enum Orientation { Horizontal }
    public class StackPanel : FrameworkElement { public double Spacing; public Orientation Orientation; public List<UIElement> Children = new(); }
    public class CheckBox : FrameworkElement { public object? Content; public bool IsThreeState; public bool? IsChecked; public double MinWidth; public bool IsEnabled; public event EventHandler? Click; public void Tap() { IsChecked = !(IsChecked ?? false); Click?.Invoke(this, EventArgs.Empty); } }
    public class Border : FrameworkElement { public double Width; public Microsoft.UI.Xaml.Media.Brush? Background; public UIElement? Child; }
    public class TextBlock : FrameworkElement { public string? Text; public double FontSize, Opacity; public TextTrimming TextTrimming; }
    public static class ToolTipService { public static void SetToolTip(UIElement target, object value) {} }
}
namespace Microsoft.UI.Xaml.Automation { public static class AutomationProperties { public static void SetName(Microsoft.UI.Xaml.UIElement target, string name) {} } }
namespace Tokenstat.Design { public static class Theme { public static Microsoft.UI.Xaml.Media.Brush ClearBrush => new(); public static Microsoft.UI.Xaml.Media.Brush BorderBrush => new(); } }
namespace Tokenstat.Navigation { public static class L10n { public static string Text(string key) => key; } }
'''
TEST = r'''
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Pages;
var paths = Enumerable.Range(0, 35).Select(i => $"folder{i}/file.txt").ToArray();
var selected = new List<string>();
var browser = new WorkspaceReviewBrowser(paths, paths[0], new TextBlock(), selected.Add);
var list = browser.Children.OfType<ListView>().Single();
var picker = browser.Children.OfType<ComboBox>().Single();
if (list.Items.Count != 35 || picker.Items.Count != 35) throw new Exception("All files must be available");
browser.Resize(800);
if (list.Visibility != Visibility.Visible || picker.Visibility != Visibility.Collapsed) throw new Exception("Wide layout");
var splitter = browser.Children.OfType<Border>().Single();
splitter.Drag(210, 300);
if (browser.ColumnDefinitions[0].Width.Value != 300) throw new Exception("Dragging the rule resizes the list");
splitter.Drag(300, 2000);
if (browser.ColumnDefinitions[0].Width.Value != 400) throw new Exception("The list stops at half the pane");
list.SelectedIndex = 34;
if (selected.Count != 1 || selected[0] != paths[34] || picker.SelectedIndex != 34) throw new Exception("List selection");
browser.Resize(400);
if (picker.Visibility != Visibility.Visible || list.Visibility != Visibility.Collapsed) throw new Exception("Compact layout");
picker.SelectedIndex = 1;
if (selected.Count != 2 || selected[1] != paths[1] || list.SelectedIndex != 1) throw new Exception("Picker selection");
if (browser.VerticalOffset != 0) throw new Exception("A different file starts at the top");
Console.WriteLine("PASS: Windows review browser keeps every path, resizes, switches layout and selects one file once");
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-review-browser-') as temp:
    folder = Path(temp)
    (folder / 'Stubs.cs').write_text(STUBS)
    (folder / 'Program.cs').write_text(TEST)
    (folder / 'WorkspaceReviewBrowser.cs').write_text((ROOT / 'apps/windows/Pages/WorkspaceReviewBrowser.cs').read_text())
    (folder / 'Check.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup></Project>')
    subprocess.run(['dotnet', 'run', '--project', str(folder / 'Check.csproj'), '-c', 'Release'], check=True)
