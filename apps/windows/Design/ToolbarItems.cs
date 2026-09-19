// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;

namespace Tokenstat.Design;

/// <summary>
/// A page's share of the one top bar. Mirrors the Mac DetailChromeBar, which
/// carries the screen's own scope, accessory and actions beside the shared
/// search and inspector toggles: the shell renders ToolbarScope on the left
/// and ToolbarActions on the right, before its own search icon, so every
/// screen has one bar rather than a global strip over a per-page strip.
/// </summary>
internal interface IToolbarItems
{
    /// <summary>
    /// Which folder is on screen, when this screen is showing one. Null for
    /// global screens, like the Mac scope chip.
    /// </summary>
    UIElement? ToolbarScope { get; }

    /// <summary>
    /// This screen's actions, in order: refresh, new, save, scan, fetch, add.
    /// Built fresh per call unless an element holds state the page itself
    /// owns, such as a filter holding its selection.
    /// </summary>
    IList<UIElement> ToolbarActions();

    /// <summary>
    /// Raised when the scope or the actions changed and the shell should
    /// rebuild the bar. The shell subscribes on navigation and drops the page
    /// when it navigates away, so a late load cannot repaint another screen.
    /// </summary>
    event Action? ToolbarChanged;
}
