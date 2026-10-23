// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Navigation;

namespace Tokenstat.Design;

/// <summary>Shared sidebar and rail metrics, independent of native template defaults.</summary>
internal static class SidebarChrome
{
    private sealed class ProjectAlignment { internal bool Pending; }
    private static readonly ConditionalWeakTable<NavigationViewItem, ProjectAlignment> ProjectAlignments = new();
    private sealed class ProjectBinding { internal FontIcon? Chevron; }
    private static readonly ConditionalWeakTable<NavigationViewItem, ProjectBinding> ProjectBindings = new();
    private sealed class ActionBinding { internal Control[] Actions = []; internal bool Pointer; internal bool Focused; }
    private static readonly ConditionalWeakTable<Control, ActionBinding> ActionBindings = new();

    static SidebarChrome()
    {
        NavigationRows.Retiring += row =>
        {
            if (ProjectBindings.TryGetValue(row, out var project)) project.Chevron = null;
            if (ActionBindings.TryGetValue(row, out var actions)) { actions.Actions = []; actions.Pointer = false; actions.Focused = false; }
        };
        NavigationRows.Reconciled += (fresh, retained) =>
        {
            if (ProjectBindings.TryGetValue(fresh, out var project)) BindProject(retained, project.Chevron);
            if (ActionBindings.TryGetValue(fresh, out var actions)) RevealActions(retained, actions.Actions);
        };
    }

    private static void BindProject(NavigationViewItem row, FontIcon? chevron)
    {
        var state = ProjectBindings.GetValue(row, owner =>
        {
            var binding = new ProjectBinding();
            void Paint()
            {
                if (binding.Chevron is not { } mark) return;
                mark.Glyph = owner.IsExpanded ? "\uE70D" : "\uE76C";
                AlignProject(owner);
            }
            owner.RegisterPropertyChangedCallback(NavigationViewItem.IsExpandedProperty, (_, _) => Paint());
            owner.Loaded += (_, _) => Paint();
            return binding;
        });
        state.Chevron = chevron;
        if (chevron is not null) chevron.Glyph = row.IsExpanded ? "\uE70D" : "\uE76C";
        AlignProject(row);
    }

    // The app supplies the sink so shared control fixtures need no app entry point.
    internal static Action<string>? ThresholdFailure { get; set; }

    /// <summary>Update app-owned pane content after the native transition returns.</summary>
    public static void FollowPaneState(NavigationView view, Action update)
    {
        var pending = false;
        view.RegisterPropertyChangedCallback(NavigationView.IsPaneOpenProperty, (_, _) =>
        {
            if (pending) return;
            pending = true;
            // Header/footer replacement and hierarchy expansion can rebuild the
            // pane. They must not reenter SplitView's property transition.
            if (!view.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                pending = false;
                update();
            })) pending = false;
        });
    }

    /// <summary>Keep adaptive navigation between expanded and minimal modes.</summary>
    public static void SetAdaptiveThreshold(NavigationView view, double width)
    {
        // The shell has no icon-only pane. Updating Expanded first while
        // growing briefly enters Compact before the second setter runs.
        // Overlap the thresholds during the update, then leave them equal.
        var expanded = double.NaN;
        var compact = double.NaN;
        var stage = "read thresholds";
        try
        {
            expanded = view.ExpandedModeThresholdWidth;
            compact = view.CompactModeThresholdWidth;
            if (width > expanded)
            {
                stage = "grow compact";
                if (compact != width) view.CompactModeThresholdWidth = width;
                stage = "grow expanded";
                if (expanded != width) view.ExpandedModeThresholdWidth = width;
            }
            else
            {
                stage = "shrink expanded";
                if (expanded != width) view.ExpandedModeThresholdWidth = width;
                stage = "shrink compact";
                if (compact != width) view.CompactModeThresholdWidth = width;
            }
        }
        catch (Exception error)
        {
            if (Environment.GetEnvironmentVariable("CI") == "true" && Environment.GetEnvironmentVariable("TOKENSTAT_UI_STARTUP_TRACE") == "1")
            {
                var loaded = false;
                var actual = double.NaN;
                try { loaded = view.IsLoaded; actual = view.ActualWidth; } catch { }
                try { ThresholdFailure?.Invoke($"Sidebar threshold failure: stage={stage}; loaded={loaded}; actual={actual}; expanded={expanded}; compact={compact}; next={width}; HRESULT=0x{error.HResult:x8}"); } catch { }
            }
            throw;
        }
    }

    public static void ExpandNewHistory(NavigationViewItem row, bool hadChildren, bool paneOpen)
    {
        if (hadChildren || row.MenuItems.Count == 0 || !paneOpen) return;
        // WinUI creates its child repeater lazily. Setting an already-true
        // IsExpanded leaves that newly created repeater collapsed, so refresh
        // the state after the first history rows exist.
        row.IsExpanded = false;
        row.IsExpanded = true;
    }

    public static Grid ProjectContent(NavigationViewItem row, UIElement label, bool remote, params Control[] actions)
        => ProjectContent(row, label, remote, false, actions);
    public static Grid ProjectContent(NavigationViewItem row, UIElement label, bool remote, bool shared, params Control[] actions)
    {
        var grid = new Grid { ColumnSpacing = 6, MinHeight = 28 };
        foreach (var width in new[] { new GridLength(16), new GridLength(18), new GridLength(1, GridUnitType.Star) })
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        var chevron = new FontIcon { FontSize = 8 };
        var expand = new Button
        {
            Content = chevron, Width = 16, Height = 24, MinWidth = 0, MinHeight = 0,
            Padding = new Thickness(0), BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };
        AutomationProperties.SetName(expand, L10n.Text("windows.mainwindow_xaml.expand_collapse"));
        // Content can move to a reused native container. Resolve its current
        // owner rather than capturing the discarded, unmounted candidate.
        expand.Click += (_, _) =>
        {
            for (DependencyObject? owner = grid; owner is not null; owner = VisualTreeHelper.GetParent(owner))
                if (owner is NavigationViewItem current) { current.IsExpanded = !current.IsExpanded; break; }
        };
        BindProject(row, chevron);
        grid.Children.Add(expand);
        var folderMark = new Grid(); folderMark.Children.Add(new SymbolIcon { Symbol = remote ? Symbol.Globe : Symbol.Folder });
        if (shared) folderMark.Children.Add(new Viewbox { Width = 10, Height = 10, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Child = new SymbolIcon { Symbol = Symbol.Contact } });
        var folder = new Viewbox { Width = 16, Height = 16, Child = folderMark };
        Grid.SetColumn(folder, 1);
        grid.Children.Add(folder);
        Grid.SetColumn((FrameworkElement)label, 2);
        grid.Children.Add(label);
        foreach (var action in actions)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(action, grid.ColumnDefinitions.Count - 1);
            grid.Children.Add(action);
        }
        return grid;
    }

    // CompactPaneLength is zero because the shell owns its rail. That also
    // makes the native icon seat zero-width. Project icons and the leading
    // disclosure are therefore part of our row, while native selection,
    // hierarchy and keyboard navigation remain owned by NavigationView.
    public static void AlignProject(NavigationViewItem row)
    {
        if (!row.IsLoaded) return;
        var alignment = ProjectAlignments.GetValue(row, static _ => new ProjectAlignment());
        if (alignment.Pending) return;
        alignment.Pending = true;
        // Native item state changes can replace the presenter style. Do not
        // force its template, or edit its parts, inside that transition.
        if (!row.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            alignment.Pending = false;
            if (row.IsLoaded) Visit(row);
        })) alignment.Pending = false;
        static void Visit(DependencyObject parent)
        {
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
            {
                var child = VisualTreeHelper.GetChild(parent, i);
                if (child is FrameworkElement { Name: "ExpandCollapseChevron" } chevron)
                {
                    chevron.Width = 0;
                    chevron.Visibility = Visibility.Collapsed;
                }
                if (child is NavigationViewItem) continue;
                Visit(child);
            }
        }
    }

    public static NavigationViewItem ChatFooter(string tag, string label, Action toggle, Action? all)
    {
        var grid = new Grid { ColumnSpacing = 8, Tag = label + ":" + (all is not null) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Button Link(string text) => new()
        {
            Content = text, FontSize = 11, Opacity = 0.7, MinWidth = 0, MinHeight = 0,
            Padding = new Thickness(0, 4, 0, 4), BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        var more = Link(label);
        more.Click += (_, _) => toggle();
        AutomationProperties.SetAutomationId(more, "sidebar.chatMore");
        grid.Children.Add(more);
        if (all is not null)
        {
            var archive = Link(L10n.Text("windows.mainwindow_xaml.see_all_chats.e705024a"));
            archive.Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4,
                Children = { new Viewbox { Width = 11, Height = 11, Child = ActionIcon.Search.Icon() },
                    new TextBlock { Text = L10n.Text("windows.mainwindow_xaml.see_all_chats.e705024a"), FontSize = 11 } } };
            archive.Click += (_, _) => all();
            AutomationProperties.SetAutomationId(archive, "sidebar.chatAll");
            AutomationProperties.SetName(archive, L10n.Text("windows.mainwindow_xaml.see_all_chats.e705024a"));
            Grid.SetColumn(archive, 1);
            grid.Children.Add(archive);
        }
        return new NavigationViewItem { Tag = tag, Content = grid, SelectsOnInvoked = false,
            HorizontalContentAlignment = HorizontalAlignment.Stretch };
    }

    /// <summary>Keep row actions visible while the pointer or keyboard focus is inside.</summary>
    public static void RevealActions(Control row, params Control[] actions)
    {
        var state = ActionBindings.GetValue(row, owner =>
        {
            var binding = new ActionBinding();
            void Paint()
            {
                foreach (var action in binding.Actions) action.Opacity = binding.Pointer || binding.Focused ? 1 : 0;
            }
            void RefreshFocus()
            {
                binding.Focused = false;
                if (owner.XamlRoot is not null)
                    for (var current = FocusManager.GetFocusedElement(owner.XamlRoot) as DependencyObject;
                        current is not null; current = VisualTreeHelper.GetParent(current))
                        if (ReferenceEquals(current, owner)) { binding.Focused = true; break; }
                Paint();
            }
            owner.PointerEntered += (_, _) => { binding.Pointer = true; Paint(); };
            owner.PointerExited += (_, _) => { binding.Pointer = false; RefreshFocus(); };
            owner.GotFocus += (_, _) => { binding.Focused = true; Paint(); };
            owner.LostFocus += (_, _) => owner.DispatcherQueue.TryEnqueue(RefreshFocus);
            return binding;
        });
        state.Actions = actions;
        foreach (var action in state.Actions) action.Opacity = state.Pointer || state.Focused ? 1 : 0;
    }

    public static Button RailButton(IconElement icon, string label, RoutedEventHandler click)
    {
        var button = new Button
        {
            Width = 40, Height = 36, MinWidth = 0, MinHeight = 0,
            Padding = new Thickness(0), CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Center,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
            Content = new Viewbox { Width = 16, Height = 16, Child = icon },
        };
        button.Click += click;
        AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, label);
        Select(button, false);
        return button;
    }

    public static void Select(Button button, bool selected)
    {
        button.Background = selected ? Theme.Brush(static () => Theme.RowSelected)
            : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        button.Foreground = selected ? Theme.AccentBrush : Theme.Brush(static () => Theme.ControlGlyph);
        button.Resources["ButtonBackgroundPointerOver"] = Theme.Brush(static () => Theme.RowHighlight);
        button.Resources["ButtonBackgroundPressed"] = Theme.Brush(static () => Theme.RowSelected);
        button.Resources["ButtonForegroundPointerOver"] = selected ? Theme.AccentBrush
            : Theme.Brush(static () => Theme.ControlGlyphHover);
        AutomationProperties.SetItemStatus(button, selected
            ? L10n.Text("windows.segmentedcapsule.selected.57fd7a0c")
            : L10n.Text("windows.segmentedcapsule.not_selected.df12aeba"));
    }

    public static Button Row(string label, ActionIcon icon, RoutedEventHandler click, string? shortcut = null)
    {
        var content = new Grid { ColumnSpacing = 10 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.Children.Add(icon.Mark(14));
        var text = new TextBlock { Text = label, FontSize = 13, VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis };
        Grid.SetColumn(text, 1);
        content.Children.Add(text);
        if (shortcut is not null)
        {
            var hint = new TextBlock { Text = shortcut, FontSize = 10, Opacity = 0.5,
                VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(hint, 2);
            content.Children.Add(hint);
        }
        var button = new Button
        {
            Content = content, Height = 32, MinHeight = 0, MinWidth = 0,
            Padding = new Thickness(10, 0, 10, 0), Margin = new Thickness(4, 0, 4, 0),
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(8),
        };
        button.Click += click;
        AutomationProperties.SetName(button, label);
        return button;
    }
}
