// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Tokenstat.Design;

internal sealed class ResizeHandle : UserControl
{
    private readonly Thumb _thumb = new() { IsTabStop = false, Background = Theme.ClearBrush };
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
    public ResizeHandle(bool vertical = false)
    {
        if (vertical) Height = 6; else Width = 6;
        Content = _thumb;
        IsTabStop = true;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(this, vertical ? L10n.Text("windows.resizehandle.drag_or_use_up_and_down") : L10n.Text("windows.resizehandle.drag_or_use_left_and_right_arrows_to_resiz.7cd7cd98"));
        ToolTipService.SetToolTip(this, L10n.Text("windows.resizehandle.drag_to_resize_double_click_to_reset.0feeacb9"));
        Background = Theme.ClearBrush;
        ProtectedCursor = InputSystemCursor.Create(vertical ? InputSystemCursorShape.SizeNorthSouth : InputSystemCursorShape.SizeWestEast);
        PointerEntered += (_, _) => Background = Theme.AccentSoftBrush;
        PointerExited += (_, _) => Background = Theme.ClearBrush;
        _thumb.DragStarted += (_, _) => ColumnResize.InProgress = true;
        _thumb.DragCompleted += (_, _) => ColumnResize.InProgress = false;
        Unloaded += (_, _) => ColumnResize.InProgress = false;
    }
}

internal static class ColumnResize
{
    internal static bool InProgress { get; set; }
}
