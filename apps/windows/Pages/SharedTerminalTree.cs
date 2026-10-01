// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Tokenstat.Pages;

/// <summary>Move one native terminal tree between viewers without duplicate parents.</summary>
internal sealed class SharedTerminalTree
{
    private readonly UIElement _content;
    internal Page? Owner { get; private set; }
    internal SharedTerminalTree(UIElement content) => _content = content;
    internal void Attach(Page owner)
    {
        if (ReferenceEquals(Owner, owner)) return;
        if (Owner is not null) Owner.Content = null;
        Owner = owner;
        owner.Content = _content;
    }
    internal void Detach(Page owner)
    {
        if (!ReferenceEquals(Owner, owner)) return;
        owner.Content = null;
        Owner = null;
    }
}
