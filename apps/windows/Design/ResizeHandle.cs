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
    public ResizeHandle()
    {
        Width = 6;
        Content = _thumb;
        IsTabStop = true;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(this, "Drag or use Left and Right arrows to resize. Double-click to reset.");
        ToolTipService.SetToolTip(this, "Drag to resize · Double-click to reset");
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        PointerEntered += (_, _) => Background = Theme.AccentSoftBrush;
        PointerExited += (_, _) => Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _thumb.DragStarted += (_, _) => MainWindow.ColumnsResizing = true;
        _thumb.DragCompleted += (_, _) => MainWindow.ColumnsResizing = false;
        Unloaded += (_, _) => MainWindow.ColumnsResizing = false;
    }
}
