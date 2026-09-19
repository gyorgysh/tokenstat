// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Tokenstat.Design;

internal static class NativeContentLayout
{
    // NavigationView does not bind content alignment into its presenter.
    // Match the content identity so nested controls retain their own layout.
    internal static void Stretch(Control owner, object content)
    {
        owner.ApplyTemplate();
        void Visit(DependencyObject node)
        {
            if (node is ContentPresenter presenter && ReferenceEquals(presenter.Content, content))
            {
                presenter.HorizontalContentAlignment = HorizontalAlignment.Stretch;
                presenter.VerticalContentAlignment = VerticalAlignment.Stretch;
                return;
            }
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
                Visit(VisualTreeHelper.GetChild(node, i));
        }
        Visit(owner);
    }
}
