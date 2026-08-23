// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Tokenstat.Design;
using Tokenstat.Install;

namespace Tokenstat.Pages;

internal sealed class AboutPage : Page
{
    public AboutPage()
    {
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "tokenstat.png");
        UIElement mark;
        if (File.Exists(iconPath))
        {
            mark = new Image
            {
                Source = new BitmapImage(new Uri(iconPath)),
                Width = 72,
                Height = 72,
                HorizontalAlignment = HorizontalAlignment.Left,
            };
        }
        else
        {
            mark = new SymbolIcon { Symbol = Symbol.FourBars, Width = 48, Height = 48, Foreground = Theme.AccentBrush };
        }

        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(mark);
        body.Children.Add(new TextBlock
        {
            Text = "tokenstat",
            FontSize = 22,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        body.Children.Add(new TextBlock { Text = "Version " + AppInfo.Version, Opacity = 0.8 });
        body.Children.Add(new TextBlock { Text = AppInfo.Copyright });
        body.Children.Add(new TextBlock { Text = AppInfo.Company, Opacity = 0.8 });
        body.Children.Add(new TextBlock
        {
            Text = "Token usage from every AI coding agent on this PC, read locally.",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.8,
            MaxWidth = 480,
        });
        body.Children.Add(new TextBlock
        {
            Text = $"{AppInfo.Author.Name} · {AppInfo.Author.Role}",
            Opacity = 0.8,
        });
        body.Children.Add(Link("Contact", AppInfo.Author.Email));
        body.Children.Add(Link(AppInfo.WebsiteLabel, AppInfo.Website));
        body.Children.Add(Link(AppInfo.Author.SiteLabel, AppInfo.Author.Site));
        body.Children.Add(Link("Source", AppInfo.Repository));
        body.Children.Add(new TextBlock
        {
            Text = "Everything happens on your machine. tokenstat reads your local logs, extracts counters, and discards the rest. Only aggregate numbers are eligible for sync.",
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 480,
            Opacity = 0.8,
        });
        if (SelfInstall.IsRunningFromInstall)
        {
            body.Children.Add(new TextBlock
            {
                Text = "Installed at " + SelfInstall.InstallDirectory,
                Opacity = 0.6,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        else if (SelfInstall.IsDevBuild)
        {
            body.Children.Add(new TextBlock
            {
                Text = "Development build. It will not copy itself into Programs.",
                Opacity = 0.6,
            });
        }

        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL),
            Content = Chrome.Card("About", body),
        };
    }

    private static HyperlinkButton Link(string label, string url)
    {
        var link = new HyperlinkButton { Content = label, NavigateUri = new Uri(url) };
        link.Click += (_, _) =>
        {
            try
            {
                Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
            }
            catch
            {
                // Ignore.
            }
        };
        return link;
    }
}
