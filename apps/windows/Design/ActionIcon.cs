// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Tokenstat.Design;

/// <summary>
/// One glyph per action. Case names match the Mac ActionIcon and
/// shared/web/actionIcons.js. WinUI maps them onto Segoe Fluent Symbols.
/// </summary>
internal enum ActionIcon
{
    Save, Claim, Create, Upload, Copy, Download,
    SignIn, SignOut, Account, Settings, Security, Edit,
    Plans, Billing, AppStore, AutoRenew, Downgrade, CancelPlan,
    Token, Preview, Visibility, Theme, Layout,
    Connect, Disconnect, Approve, Pair, Refresh, Revoke, Device,
    Run, Stop, History, Move, Archive, Restore, Browser, Collapse, Commit,
    Merge, Comment, Reopen, Checkout, Filter,
    Delete,
    External, Next, Back, More, Search, Reveal, Docs, Source, Profile, Home, Help,
    Send, Apply, Calculate, Compare, Benchmarks,
    Dismiss, Done, Scheduled, CurrentPlan,
}

internal static class ActionIconGlyph
{
    public static Symbol Symbol(this ActionIcon icon) => icon switch
    {
        ActionIcon.Save or ActionIcon.CurrentPlan or ActionIcon.Done or ActionIcon.Commit
            => Microsoft.UI.Xaml.Controls.Symbol.Accept,
        ActionIcon.Claim or ActionIcon.Approve => Microsoft.UI.Xaml.Controls.Symbol.Accept,
        ActionIcon.Create => Microsoft.UI.Xaml.Controls.Symbol.Add,
        ActionIcon.Upload => Microsoft.UI.Xaml.Controls.Symbol.Upload,
        ActionIcon.Copy => Microsoft.UI.Xaml.Controls.Symbol.Copy,
        ActionIcon.Download => Microsoft.UI.Xaml.Controls.Symbol.Download,
        ActionIcon.SignIn or ActionIcon.Account or ActionIcon.Profile
            => Microsoft.UI.Xaml.Controls.Symbol.Contact,
        ActionIcon.SignOut => Microsoft.UI.Xaml.Controls.Symbol.Cancel,
        ActionIcon.Settings => Microsoft.UI.Xaml.Controls.Symbol.Setting,
        ActionIcon.Security => Microsoft.UI.Xaml.Controls.Symbol.Permissions,
        ActionIcon.Edit => Microsoft.UI.Xaml.Controls.Symbol.Edit,
        ActionIcon.Plans => Microsoft.UI.Xaml.Controls.Symbol.Favorite,
        ActionIcon.Billing => Microsoft.UI.Xaml.Controls.Symbol.Shop,
        ActionIcon.Refresh or ActionIcon.AutoRenew => Microsoft.UI.Xaml.Controls.Symbol.Refresh,
        ActionIcon.CancelPlan or ActionIcon.Dismiss or ActionIcon.Disconnect
            => Microsoft.UI.Xaml.Controls.Symbol.Cancel,
        ActionIcon.Preview or ActionIcon.Visibility => Microsoft.UI.Xaml.Controls.Symbol.View,
        ActionIcon.Theme => Microsoft.UI.Xaml.Controls.Symbol.Highlight,
        ActionIcon.Layout => Microsoft.UI.Xaml.Controls.Symbol.ViewAll,
        // Apple and the website both draw a plug for this. The Symbol enum has
        // no plug in it, and reaching for a raw Segoe glyph for one case would
        // put a second icon mechanism in this file, so Link stands in. Swap it
        // the day anything else here needs a FontIcon.
        ActionIcon.Connect => Microsoft.UI.Xaml.Controls.Symbol.Link,
        ActionIcon.Device => Microsoft.UI.Xaml.Controls.Symbol.CellPhone,
        ActionIcon.Run => Microsoft.UI.Xaml.Controls.Symbol.Play,
        ActionIcon.Stop => Microsoft.UI.Xaml.Controls.Symbol.Stop,
        ActionIcon.History or ActionIcon.Scheduled => Microsoft.UI.Xaml.Controls.Symbol.Clock,
        ActionIcon.Archive => Microsoft.UI.Xaml.Controls.Symbol.Save,
        ActionIcon.Restore => Microsoft.UI.Xaml.Controls.Symbol.Undo,
        ActionIcon.Merge => Microsoft.UI.Xaml.Controls.Symbol.Switch,
        ActionIcon.Comment => Microsoft.UI.Xaml.Controls.Symbol.Message,
        ActionIcon.Reopen => Microsoft.UI.Xaml.Controls.Symbol.Undo,
        ActionIcon.Checkout => Microsoft.UI.Xaml.Controls.Symbol.Download,
        ActionIcon.Filter => Microsoft.UI.Xaml.Controls.Symbol.Filter,
        ActionIcon.Browser => Microsoft.UI.Xaml.Controls.Symbol.Globe,
        ActionIcon.Delete => Microsoft.UI.Xaml.Controls.Symbol.Delete,
        ActionIcon.External or ActionIcon.Next => Microsoft.UI.Xaml.Controls.Symbol.Forward,
        ActionIcon.Back => Microsoft.UI.Xaml.Controls.Symbol.Back,
        ActionIcon.More => Microsoft.UI.Xaml.Controls.Symbol.More,
        ActionIcon.Search => Microsoft.UI.Xaml.Controls.Symbol.Find,
        ActionIcon.Reveal => Microsoft.UI.Xaml.Controls.Symbol.Folder,
        ActionIcon.Docs => Microsoft.UI.Xaml.Controls.Symbol.Library,
        ActionIcon.Home => Microsoft.UI.Xaml.Controls.Symbol.Home,
        ActionIcon.Help => Microsoft.UI.Xaml.Controls.Symbol.Help,
        ActionIcon.Send => Microsoft.UI.Xaml.Controls.Symbol.Send,
        _ => Microsoft.UI.Xaml.Controls.Symbol.Placeholder,
    };

    public static Button Button(string title, ActionIcon icon, RoutedEventHandler click)
    {
        var btn = new Button
        {
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children =
                {
                    new SymbolIcon { Symbol = icon.Symbol() },
                    new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center },
                },
            },
        };
        btn.Click += click;
        return btn;
    }
}
