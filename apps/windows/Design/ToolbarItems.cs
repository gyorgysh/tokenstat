// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;

namespace Tokenstat.Design;

internal interface IToolbarItems
{
    UIElement? ToolbarScope { get; }

    IList<UIElement> ToolbarActions();

    event Action? ToolbarChanged;
}
