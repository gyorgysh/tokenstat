// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using FluentSymbol = Microsoft.UI.Xaml.Controls.Symbol;

namespace Tokenstat.Design;

internal enum ActionIcon
{
    Save, Claim, Create, Upload, Copy, Download,
    SignIn, SignOut, Account, Settings, Security, Edit,
    Plans, Billing, AppStore, PlayStore, AutoRenew, Downgrade, CancelPlan,
    Token, Preview, Visibility, Theme, Layout, Sidebar,
    Connect, Disconnect, Approve, Pair, Refresh, Revoke, Device, Computer,
    Run, Stop, History, Move, Archive, Restore, Pin, Pinned, Browser, Collapse, Commit,
    Merge, Comment, Reopen, Checkout, Filter, EnterFullScreen, ExitFullScreen,
    Delete,
    External, Next, Latest, Back, More, Search, SearchAll, Reveal, Docs, Source, Profile, Home, Help,
    Send, Attach, Dictate, FastMode, Persona, Plan, Allow, Deny, Apply, Calculate, Compare, Benchmarks,
    Dismiss, Done, HideKeyboard, Scheduled, CurrentPlan,
}

internal static class ActionIconGlyph
{
    /// <summary>
    /// Fluent artwork where the OS ships it, MDL2 where it does not. Every
    /// code below exists in both fonts, so Windows 10 falls back to the older
    /// drawing rather than to a missing-character box.
    /// </summary>
    private static readonly FontFamily IconFont = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    private static FontIcon Glyph(int code) => new() { Glyph = char.ToString((char)code), FontFamily = IconFont };

    private static SymbolIcon Sigil(FluentSymbol symbol) => new() { Symbol = symbol };

    private static PathIcon Pane(bool leading)
    {
        var frame = new GeometryGroup();
        foreach (var rect in new[]
        {
            new Windows.Foundation.Rect(0, 0, 16, 1), new Windows.Foundation.Rect(0, 13, 16, 1),
            new Windows.Foundation.Rect(0, 1, 1, 12), new Windows.Foundation.Rect(15, 1, 1, 12),
            new Windows.Foundation.Rect(leading ? 5 : 10, 1, 1, 12),
        }) frame.Children.Add(new RectangleGeometry { Rect = rect });
        return new PathIcon { Data = frame };
    }

    public static IconElement Icon(this ActionIcon icon) => icon switch
    {
        ActionIcon.Claim or ActionIcon.Approve => Glyph(0xEC61),
        ActionIcon.Commit or ActionIcon.Allow => Glyph(0xE930),
        ActionIcon.Save or ActionIcon.CurrentPlan or ActionIcon.Done => Sigil(FluentSymbol.Accept),
        ActionIcon.Create => Sigil(FluentSymbol.Add),
        ActionIcon.Upload => Sigil(FluentSymbol.Upload),
        ActionIcon.Copy => Sigil(FluentSymbol.Copy),
        ActionIcon.Download => Sigil(FluentSymbol.Download),
        ActionIcon.SignIn or ActionIcon.Account or ActionIcon.Profile => Sigil(FluentSymbol.Contact),
        ActionIcon.SignOut => Glyph(0xE7E8),
        ActionIcon.Settings => Sigil(FluentSymbol.Setting),
        ActionIcon.Security => Sigil(FluentSymbol.Permissions),
        ActionIcon.Edit => Sigil(FluentSymbol.Edit),
        ActionIcon.Plans => Sigil(FluentSymbol.Favorite),
        ActionIcon.Billing => Sigil(FluentSymbol.Shop),
        ActionIcon.AppStore => Glyph(0xE71D),
        ActionIcon.PlayStore => Sigil(FluentSymbol.Video),
        ActionIcon.AutoRenew => Glyph(0xE8EE),
        ActionIcon.Latest or ActionIcon.Downgrade => Glyph(0xE74B),
        ActionIcon.CancelPlan or ActionIcon.Dismiss => Sigil(FluentSymbol.Cancel),
        ActionIcon.Token or ActionIcon.Pair => Sigil(FluentSymbol.Link),
        ActionIcon.Preview or ActionIcon.Visibility => Sigil(FluentSymbol.View),
        ActionIcon.Theme => Sigil(FluentSymbol.Highlight),
        ActionIcon.Layout => Glyph(0xECA5),
        ActionIcon.Sidebar => Pane(true),
        ActionIcon.Connect => Glyph(0xE701),
        ActionIcon.Disconnect or ActionIcon.Deny => Glyph(0xE894),
        ActionIcon.Refresh => Sigil(FluentSymbol.Refresh),
        ActionIcon.Revoke => Glyph(0xE738),
        ActionIcon.Device => Sigil(FluentSymbol.CellPhone),
        ActionIcon.Computer => Glyph(0xE770),
        ActionIcon.Run => Sigil(FluentSymbol.Play),
        ActionIcon.Stop => Sigil(FluentSymbol.Stop),
        ActionIcon.History => Glyph(0xE81C),
        ActionIcon.Scheduled => Sigil(FluentSymbol.Clock),
        ActionIcon.Move => Glyph(0xE8AD),
        ActionIcon.Archive => Sigil(FluentSymbol.Save),
        ActionIcon.Restore => Sigil(FluentSymbol.Undo),
        ActionIcon.Pin => Sigil(FluentSymbol.Pin),
        ActionIcon.Pinned => Sigil(FluentSymbol.UnPin),
        ActionIcon.Browser => Sigil(FluentSymbol.Globe),
        ActionIcon.Collapse => Pane(false),
        ActionIcon.Merge => Sigil(FluentSymbol.Switch),
        ActionIcon.Comment => Sigil(FluentSymbol.Message),
        ActionIcon.Reopen => Glyph(0xE7A6),
        ActionIcon.Checkout => Glyph(0xE8B5),
        ActionIcon.Filter => Sigil(FluentSymbol.Filter),
        ActionIcon.EnterFullScreen => Glyph(0xE740),
        ActionIcon.ExitFullScreen => Glyph(0xE73F),
        ActionIcon.Delete => Sigil(FluentSymbol.Delete),
        ActionIcon.External => Glyph(0xE8A7),
        ActionIcon.Next => Sigil(FluentSymbol.Forward),
        ActionIcon.Back => Sigil(FluentSymbol.Back),
        ActionIcon.More => Sigil(FluentSymbol.More),
        ActionIcon.Search => Sigil(FluentSymbol.Find),
        ActionIcon.SearchAll => Glyph(0xE773),
        ActionIcon.Reveal => Sigil(FluentSymbol.Folder),
        ActionIcon.Docs => Sigil(FluentSymbol.Library),
        ActionIcon.Source => Glyph(0xE943),
        ActionIcon.Home => Sigil(FluentSymbol.Home),
        ActionIcon.Help => Sigil(FluentSymbol.Help),
        ActionIcon.Send => Sigil(FluentSymbol.Send),
        ActionIcon.Attach => Sigil(FluentSymbol.Attach),
        ActionIcon.Dictate => Glyph(0xE720),
        ActionIcon.FastMode => Glyph(0xE945),
        ActionIcon.Persona => Glyph(0xE779),
        ActionIcon.Plan => Sigil(FluentSymbol.Document),
        ActionIcon.Apply => Glyph(0xE9D5),
        ActionIcon.Calculate => Glyph(0xE8EF),
        ActionIcon.Compare => Glyph(0xE89A),
        ActionIcon.Benchmarks => Glyph(0xE9D2),
        ActionIcon.HideKeyboard => Glyph(0xE92F),
        _ => Sigil(FluentSymbol.Placeholder),
    };

    public static Symbol Symbol(this ActionIcon icon) => icon switch
    {
        ActionIcon.Save or ActionIcon.CurrentPlan or ActionIcon.Done or ActionIcon.Commit or ActionIcon.Apply
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
        ActionIcon.Token => Microsoft.UI.Xaml.Controls.Symbol.Permissions,
        ActionIcon.AppStore or ActionIcon.External or ActionIcon.Next or ActionIcon.Move
            => Microsoft.UI.Xaml.Controls.Symbol.Forward,
        ActionIcon.PlayStore => Microsoft.UI.Xaml.Controls.Symbol.Video,
        ActionIcon.Refresh or ActionIcon.AutoRenew => Microsoft.UI.Xaml.Controls.Symbol.Refresh,
        ActionIcon.CancelPlan or ActionIcon.Dismiss or ActionIcon.Disconnect or ActionIcon.Revoke
            => Microsoft.UI.Xaml.Controls.Symbol.Cancel,
        // The Symbol enum has no chevrons, so the three down-arrow cases
        // borrow the closest stand-in with the same meaning: the keyboard
        // for hiding it, the tray arrow for fetching or stepping down, and
        // the closing pane for folding a section away.
        ActionIcon.HideKeyboard => Microsoft.UI.Xaml.Controls.Symbol.Keyboard,
        ActionIcon.Preview or ActionIcon.Visibility or ActionIcon.Compare
            => Microsoft.UI.Xaml.Controls.Symbol.View,
        ActionIcon.Theme => Microsoft.UI.Xaml.Controls.Symbol.Highlight,
        ActionIcon.Layout => Microsoft.UI.Xaml.Controls.Symbol.ViewAll,
        // Apple and the website both draw a plug for this. The Symbol enum has
        // no plug in it, and reaching for a raw Segoe glyph for one case would
        // put a second icon mechanism in this file, so Link stands in. Swap it
        // the day anything else here needs a FontIcon.
        ActionIcon.Connect or ActionIcon.Pair => Microsoft.UI.Xaml.Controls.Symbol.Link,
        ActionIcon.Device => Microsoft.UI.Xaml.Controls.Symbol.CellPhone,
        ActionIcon.Run => Microsoft.UI.Xaml.Controls.Symbol.Play,
        ActionIcon.Stop => Microsoft.UI.Xaml.Controls.Symbol.Stop,
        ActionIcon.History or ActionIcon.Scheduled => Microsoft.UI.Xaml.Controls.Symbol.Clock,
        ActionIcon.Archive => Microsoft.UI.Xaml.Controls.Symbol.Save,
        ActionIcon.Restore => Microsoft.UI.Xaml.Controls.Symbol.Undo,
        ActionIcon.Pin => Microsoft.UI.Xaml.Controls.Symbol.Pin,
        ActionIcon.Pinned => Microsoft.UI.Xaml.Controls.Symbol.UnPin,
        ActionIcon.Merge => Microsoft.UI.Xaml.Controls.Symbol.Switch,
        ActionIcon.Comment => Microsoft.UI.Xaml.Controls.Symbol.Message,
        ActionIcon.Reopen => Microsoft.UI.Xaml.Controls.Symbol.Undo,
        ActionIcon.Checkout => Microsoft.UI.Xaml.Controls.Symbol.Download,
        ActionIcon.Filter => Microsoft.UI.Xaml.Controls.Symbol.Filter,
        // The Symbol enum has no fullscreen glyph, so the pair borrows the
        // view family (enter) and the restore arrow (exit) like Collapse does.
        ActionIcon.EnterFullScreen => Microsoft.UI.Xaml.Controls.Symbol.ViewAll,
        ActionIcon.ExitFullScreen => Microsoft.UI.Xaml.Controls.Symbol.Undo,
        ActionIcon.Collapse => Microsoft.UI.Xaml.Controls.Symbol.ClosePane,
        ActionIcon.Benchmarks => Microsoft.UI.Xaml.Controls.Symbol.ViewAll,
        ActionIcon.Browser => Microsoft.UI.Xaml.Controls.Symbol.Globe,
        ActionIcon.Delete => Microsoft.UI.Xaml.Controls.Symbol.Delete,
        ActionIcon.Latest or ActionIcon.Downgrade => Microsoft.UI.Xaml.Controls.Symbol.Download,
        ActionIcon.Back => Microsoft.UI.Xaml.Controls.Symbol.Back,
        ActionIcon.More => Microsoft.UI.Xaml.Controls.Symbol.More,
        ActionIcon.Search or ActionIcon.SearchAll => Microsoft.UI.Xaml.Controls.Symbol.Find,
        ActionIcon.Reveal or ActionIcon.Source => Microsoft.UI.Xaml.Controls.Symbol.Folder,
        ActionIcon.Docs => Microsoft.UI.Xaml.Controls.Symbol.Library,
        ActionIcon.Home => Microsoft.UI.Xaml.Controls.Symbol.Home,
        ActionIcon.Help => Microsoft.UI.Xaml.Controls.Symbol.Help,
        ActionIcon.Send => Microsoft.UI.Xaml.Controls.Symbol.Send,
        ActionIcon.Attach => Microsoft.UI.Xaml.Controls.Symbol.Attach,
        ActionIcon.Dictate => Microsoft.UI.Xaml.Controls.Symbol.Microphone,
        ActionIcon.FastMode => (Microsoft.UI.Xaml.Controls.Symbol)0xE945,
        ActionIcon.Persona => Microsoft.UI.Xaml.Controls.Symbol.Contact,
        ActionIcon.Plan or ActionIcon.Calculate => Microsoft.UI.Xaml.Controls.Symbol.Document,
        ActionIcon.Allow => Microsoft.UI.Xaml.Controls.Symbol.Accept,
        ActionIcon.Deny => Microsoft.UI.Xaml.Controls.Symbol.Cancel,
        _ => Microsoft.UI.Xaml.Controls.Symbol.Placeholder,
    };

    /// <summary>
    /// Glyphs are set at font size rather than shrunk from their 20px default
    /// inside a Viewbox, which is a scale transform and rasterizes soft. A
    /// Symbol's value is its Segoe code point, so a SymbolIcon becomes the
    /// same glyph.
    /// </summary>
    public static FrameworkElement Mark(this ActionIcon icon, double size)
    {
        var element = icon.Icon();
        switch (element)
        {
            case SymbolIcon symbol:
                return new FontIcon
                {
                    Glyph = char.ToString((char)(int)symbol.Symbol),
                    FontFamily = IconFont,
                    FontSize = size,
                    VerticalAlignment = VerticalAlignment.Center,
                };
            case FontIcon glyph:
                glyph.FontSize = size;
                glyph.VerticalAlignment = VerticalAlignment.Center;
                return glyph;
            default:
                return new Viewbox { Width = size, Height = size, Child = element, VerticalAlignment = VerticalAlignment.Center };
        }
    }

    public static Button Button(string title, ActionIcon icon, RoutedEventHandler click)
    {
        var btn = new Button
        {
            Background = Theme.AccentSoftBrush,
            Foreground = Theme.AccentBrush,
            BorderBrush = Theme.Brush(static () => Theme.Accent),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            MinWidth = 0, MinHeight = 30,
            Padding = new Thickness(14, 0, 14, 0),
            FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children =
                {
                    icon.Mark(12),
                    new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center },
                },
            },
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(btn, title);
        btn.Click += click;
        return btn;
    }

    public static Button MoreButton(string help, MenuFlyout menu)
    {
        var button = Buttons.ToolbarIcon(ActionIcon.More, help, (_, _) => { });
        button.Flyout = menu;
        button.VerticalAlignment = VerticalAlignment.Center;
        return button;
    }

    public static Button PrimaryButton(string title, ActionIcon icon, RoutedEventHandler click)
    {
        var button = Button(title, icon, click);
        button.Background = Theme.AccentBrush;
        button.Foreground = Theme.OnAccentBrush;
        button.BorderBrush = Theme.AccentBrush;
        return button;
    }
}
