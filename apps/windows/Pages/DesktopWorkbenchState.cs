// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

internal enum DesktopWorkbenchTool { Changes, Browser, Terminal, Inspector }

/// <summary>Workspace tool selection is independent of the active conversation.</summary>
internal sealed class DesktopWorkbenchState
{
    private readonly List<DesktopWorkbenchTool> _tabs = new();
    public IReadOnlyList<DesktopWorkbenchTool> Tabs => _tabs;
    public DesktopWorkbenchTool? Selected { get; private set; }
    public bool IsPresented { get; private set; }
    public void Open(DesktopWorkbenchTool tool)
    {
        if (!_tabs.Contains(tool)) _tabs.Add(tool);
        Selected = tool;
        IsPresented = true;
    }
    public void Close(DesktopWorkbenchTool tool)
    {
        var index = _tabs.IndexOf(tool);
        if (index < 0) return;
        _tabs.RemoveAt(index);
        if (Selected == tool) Selected = _tabs.Count == 0 ? null : _tabs[Math.Max(0, index - 1)];
        if (_tabs.Count == 0) IsPresented = false;
    }
    public void Hide() => IsPresented = false;
}
