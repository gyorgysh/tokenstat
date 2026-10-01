// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Tokenstat.Design;

/// <summary>A native draggable divider, also reachable with the keyboard.</summary>
internal sealed class ResizeHandle : UserControl
{
    private readonly Thumb _thumb = new() { IsTabStop = false, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
    public event DragDeltaEventHandler DragDelta
    {
        add => _thumb.DragDelta += value;
        remove => _thumb.DragDelta -= value;
    }
    public event DragCompletedEventHandler DragCompleted
    {
        add => _thumb.DragCompleted += value;
        remove => _thumb.DragCompleted -= value;
    }
    public ResizeHandle()
    {
        Width = 6;
        Content = _thumb;
        IsTabStop = true;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(this, L10n.Text("windows.resizehandle.drag_or_use_left_and_right_arrows_to_resiz.7cd7cd98"));
        ToolTipService.SetToolTip(this, L10n.Text("windows.resizehandle.drag_to_resize_double_click_to_reset.0feeacb9"));
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        PointerEntered += (_, _) => Background = Theme.AccentSoftBrush;
        PointerExited += (_, _) => Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _thumb.DragStarted += (_, _) => ColumnResize.InProgress = true;
        _thumb.DragCompleted += (_, _) => ColumnResize.InProgress = false;
        Unloaded += (_, _) => ColumnResize.InProgress = false;
    }
}

/// <summary>
/// Whether a column divider is being dragged, so motion can pause meanwhile.
/// Kept beside the handle rather than on the window, so the handle builds on
/// its own, as the native smoke tests compile it.
/// </summary>
internal static class ColumnResize
{
    internal static bool InProgress { get; set; }
}
