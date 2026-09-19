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
using Microsoft.UI.Xaml.Shapes;
using Tokenstat.Design;
using Tokenstat.Install;

namespace Tokenstat.Pages;

/// <summary>
/// What this is, who stands behind it, and how to reach them, over the
/// licence line. Same order as the Mac About window: the mark and the name,
/// the version, the one-sentence description, the author, the links, then
/// the licence and the copyright. The tour entry and the install note are
/// the Windows additions, kept below the line.
/// </summary>
internal sealed class AboutPage : Page
{
    public AboutPage()
    {
        var iconPath = System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "tokenstat.png");
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

        var body = new StackPanel { Spacing = Theme.SpaceM, MaxWidth = 480 };
        body.Children.Add(mark);

        var title = new StackPanel { Spacing = Theme.SpaceS };
        title.Children.Add(new TextBlock
        {
            Text = "tokenstat",
            FontSize = 22,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        title.Children.Add(new TextBlock
        {
            Text = "Version " + AppInfo.Version,
            FontSize = 12,
            Opacity = 0.7,
        });
        title.Children.Add(new TextBlock
        {
            Text = AppInfo.Company,
            FontSize = 12,
            Opacity = 0.7,
        });
        body.Children.Add(title);

        body.Children.Add(new TextBlock
        {
            Text = "Token usage from every AI coding agent on this PC, read locally.",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.8,
        });

        body.Children.Add(new Rectangle
        {
            Height = 1,
            Fill = Theme.BorderBrush,
            Margin = new Thickness(0, 2, 0, 2),
        });

        body.Children.Add(Author());
        body.Children.Add(Links());

        var licence = new StackPanel { Spacing = 2 };
        licence.Children.Add(new TextBlock
        {
            Text = "Source-available licence",
            FontSize = 10,
            Opacity = 0.6,
        });
        licence.Children.Add(new TextBlock
        {
            Text = AppInfo.Copyright,
            FontSize = 10,
            Opacity = 0.6,
        });
        body.Children.Add(licence);

        body.Children.Add(new TextBlock
        {
            Text = "Everything happens on your machine. tokenstat reads your local logs, extracts counters, and discards the rest. Only aggregate numbers are eligible for sync.",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.8,
        });
        body.Children.Add(ActionIconGlyph.Button(
            "Take the tour again", ActionIcon.Help, (_, _) => AppServices.OpenOnboarding?.Invoke()));
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

    /// <summary>Credit line, name, and what the author does.</summary>
    private static UIElement Author()
    {
        var credit = new StackPanel { Spacing = 1 };
        credit.Children.Add(new TextBlock { Text = "Made by", FontSize = 12 });
        var name = new HyperlinkButton
        {
            Content = AppInfo.Author.Name,
            FontSize = 15,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Theme.AccentBrush,
            Padding = new Thickness(0),
        };
        name.Click += (_, _) => Open(AppInfo.Author.Site);
        credit.Children.Add(name);
        credit.Children.Add(new TextBlock
        {
            Text = AppInfo.Author.Role,
            FontSize = 10,
            Opacity = 0.7,
        });
        return credit;
    }

    /// <summary>Mail, the product site, and the source, separated by hairlines.</summary>
    private static UIElement Links()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        row.Children.Add(Link("Contact", AppInfo.Author.Email));
        row.Children.Add(Separator());
        row.Children.Add(Link(AppInfo.WebsiteLabel, AppInfo.Website));
        row.Children.Add(Separator());
        row.Children.Add(Link("Source", AppInfo.Repository));
        return row;
    }

    private static TextBlock Separator() => new()
    {
        Text = "|",
        Opacity = 0.4,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private static HyperlinkButton Link(string label, string url)
    {
        var link = new HyperlinkButton
        {
            Content = label,
            NavigateUri = new Uri(url),
            Foreground = Theme.AccentBrush,
            Padding = new Thickness(0),
            FontSize = 12,
        };
        link.Click += (_, _) => Open(url);
        return link;
    }

    private static void Open(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
        }
        catch
        {
            // Ignore.
        }
    }
}
