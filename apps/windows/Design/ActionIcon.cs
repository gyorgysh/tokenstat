// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using FluentSymbol = Microsoft.UI.Xaml.Controls.Symbol;

namespace Tokenstat.Design;

/// <summary>
/// One glyph per action. Case names match the Mac ActionIcon and
/// shared/web/actionIcons.js. WinUI maps them onto Segoe Fluent Symbols.
/// </summary>
internal enum ActionIcon
{
    Save, Claim, Create, Upload, Copy, Download,
    SignIn, SignOut, Account, Settings, Security, Edit,
    Plans, Billing, AppStore, PlayStore, AutoRenew, Downgrade, CancelPlan,
    Token, Preview, Visibility, Theme, Layout,
    Connect, Disconnect, Approve, Pair, Refresh, Revoke, Device,
    Run, Stop, History, Move, Archive, Restore, Pin, Pinned, Browser, Collapse, Commit,
    Merge, Comment, Reopen, Checkout, Filter, EnterFullScreen, ExitFullScreen,
    Delete,
    External, Next, Latest, Back, More, Search, SearchAll, Reveal, Docs, Source, Profile, Home, Help,
    Send, Attach, Persona, Plan, Allow, Deny, Apply, Calculate, Compare, Benchmarks,
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

    /// <summary>
    /// A FontIcon for one Segoe code unit. All codes are in the BMP, so one
    /// char each. Written as hex rather than escapes so the code stays
    /// greppable and no invisible character can hide in the source.
    /// </summary>
    private static FontIcon Glyph(int code) => new() { Glyph = char.ToString((char)code), FontFamily = IconFont };

    private static SymbolIcon Sigil(FluentSymbol symbol) => new() { Symbol = symbol };

    /// <summary>
    /// The de-collided mark for an action. Where the Mac draws two different
    /// pictures, this returns two different glyphs: a SymbolIcon where the old
    /// Symbol was already unique and correct, otherwise a FontIcon with the
    /// Segoe code in the comment. Every content button picks from here.
    /// </summary>
    public static IconElement Icon(this ActionIcon icon) => icon switch
    {
        // Certified actions. The Mac draws a seal, Windows a filled circle
        // check, one step stronger than the outline Commit and Allow carry.
        ActionIcon.Claim or ActionIcon.Approve => Glyph(0xEC61), // CompletedSolid
        // Circled checks. The Mac draws checkmark.circle for both.
        ActionIcon.Commit or ActionIcon.Allow => Glyph(0xE930), // Completed
        ActionIcon.Save or ActionIcon.CurrentPlan or ActionIcon.Done => Sigil(FluentSymbol.Accept),
        ActionIcon.Create => Sigil(FluentSymbol.Add),
        ActionIcon.Upload => Sigil(FluentSymbol.Upload),
        ActionIcon.Copy => Sigil(FluentSymbol.Copy),
        ActionIcon.Download => Sigil(FluentSymbol.Download),
        ActionIcon.SignIn or ActionIcon.Account or ActionIcon.Profile => Sigil(FluentSymbol.Contact),
        // Logging out ends the session, so the power mark. The Mac draws a
        // figure walking out of a door, which Segoe has no version of.
        ActionIcon.SignOut => Glyph(0xE7E8), // PowerButton
        ActionIcon.Settings => Sigil(FluentSymbol.Setting),
        ActionIcon.Security => Sigil(FluentSymbol.Permissions),
        ActionIcon.Edit => Sigil(FluentSymbol.Edit),
        ActionIcon.Plans => Sigil(FluentSymbol.Favorite),
        ActionIcon.Billing => Sigil(FluentSymbol.Shop),
        // A shelf of apps for one store, a play frame for the other. The Mac
        // draws the share arrow and a play rectangle.
        ActionIcon.AppStore => Glyph(0xE71D), // AllApps
        ActionIcon.PlayStore => Sigil(FluentSymbol.Video),
        // The repeating cycle. Refresh keeps the single arrow.
        ActionIcon.AutoRenew => Glyph(0xE8EE), // RepeatAll
        // Plain down arrows. The Mac groups these two as arrow.down.
        ActionIcon.Latest or ActionIcon.Downgrade => Glyph(0xE74B), // Down
        ActionIcon.CancelPlan or ActionIcon.Dismiss => Sigil(FluentSymbol.Cancel),
        // A token pairs an account, so it shares the link with Pair. The Mac
        // groups both as one key, which Segoe has no version of.
        ActionIcon.Token or ActionIcon.Pair => Sigil(FluentSymbol.Link),
        ActionIcon.Preview or ActionIcon.Visibility => Sigil(FluentSymbol.View),
        ActionIcon.Theme => Sigil(FluentSymbol.Highlight),
        ActionIcon.Layout => Glyph(0xECA5), // Tiles
        // Link went to Token and Pair, so connecting reads as joining the
        // network. The Mac draws a plain link here.
        ActionIcon.Connect => Glyph(0xE701), // Wifi
        // Circled crosses. The Mac draws xmark.circle for both.
        ActionIcon.Disconnect or ActionIcon.Deny => Glyph(0xE894), // Clear
        ActionIcon.Refresh => Sigil(FluentSymbol.Refresh),
        ActionIcon.Revoke => Glyph(0xE738), // Remove
        ActionIcon.Device => Sigil(FluentSymbol.CellPhone),
        ActionIcon.Run => Sigil(FluentSymbol.Play),
        ActionIcon.Stop => Sigil(FluentSymbol.Stop),
        // The clock with an arrow. Scheduled keeps the plain clock.
        ActionIcon.History => Glyph(0xE81C), // History
        ActionIcon.Scheduled => Sigil(FluentSymbol.Clock),
        ActionIcon.Move => Glyph(0xE8AD), // Go
        ActionIcon.Archive => Sigil(FluentSymbol.Save),
        ActionIcon.Restore => Sigil(FluentSymbol.Undo),
        ActionIcon.Pin => Sigil(FluentSymbol.Pin),
        ActionIcon.Pinned => Sigil(FluentSymbol.UnPin),
        ActionIcon.Browser => Sigil(FluentSymbol.Globe),
        ActionIcon.Collapse => Sigil(FluentSymbol.ClosePane),
        ActionIcon.Merge => Sigil(FluentSymbol.Switch),
        ActionIcon.Comment => Sigil(FluentSymbol.Message),
        ActionIcon.Reopen => Glyph(0xE7A6), // Redo
        ActionIcon.Checkout => Glyph(0xE8B5), // Import
        ActionIcon.Filter => Sigil(FluentSymbol.Filter),
        ActionIcon.EnterFullScreen => Glyph(0xE740), // FullScreen
        ActionIcon.ExitFullScreen => Glyph(0xE73F), // BackToWindow
        ActionIcon.Delete => Sigil(FluentSymbol.Delete),
        ActionIcon.External => Glyph(0xE8A7), // OpenInNewWindow
        ActionIcon.Next => Sigil(FluentSymbol.Forward),
        ActionIcon.Back => Sigil(FluentSymbol.Back),
        ActionIcon.More => Sigil(FluentSymbol.More),
        ActionIcon.Search => Sigil(FluentSymbol.Find),
        ActionIcon.SearchAll => Glyph(0xE773), // SearchAndApps
        ActionIcon.Reveal => Sigil(FluentSymbol.Folder),
        ActionIcon.Docs => Sigil(FluentSymbol.Library),
        ActionIcon.Source => Glyph(0xE943), // Code
        ActionIcon.Home => Sigil(FluentSymbol.Home),
        ActionIcon.Help => Sigil(FluentSymbol.Help),
        ActionIcon.Send => Sigil(FluentSymbol.Send),
        ActionIcon.Attach => Sigil(FluentSymbol.Attach),
        ActionIcon.Persona => Glyph(0xE779), // ContactInfo
        ActionIcon.Plan => Sigil(FluentSymbol.Document),
        ActionIcon.Apply => Glyph(0xE9D5), // CheckList
        ActionIcon.Calculate => Glyph(0xE8EF), // Calculator
        ActionIcon.Compare => Glyph(0xE89A), // TwoPage
        ActionIcon.Benchmarks => Glyph(0xE9D2), // AreaChart
        ActionIcon.HideKeyboard => Glyph(0xE92F), // KeyboardDismiss
        _ => Sigil(FluentSymbol.Placeholder),
    };

    /// <summary>
    /// The legacy Symbol mapping, kept stable for the existing direct users
    /// (nav marks, row glyphs). Buttons use Icon(), which breaks the
    /// collisions this keeps. Do not add new users.
    /// </summary>
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
        ActionIcon.Persona => Microsoft.UI.Xaml.Controls.Symbol.Contact,
        ActionIcon.Plan or ActionIcon.Calculate => Microsoft.UI.Xaml.Controls.Symbol.Document,
        ActionIcon.Allow => Microsoft.UI.Xaml.Controls.Symbol.Accept,
        ActionIcon.Deny => Microsoft.UI.Xaml.Controls.Symbol.Cancel,
        _ => Microsoft.UI.Xaml.Controls.Symbol.Placeholder,
    };

    public static Button Button(string title, ActionIcon icon, RoutedEventHandler click)
    {
        var btn = new Button
        {
            Background = Theme.AccentSoftBrush,
            Foreground = Theme.AccentBrush,
            BorderBrush = Theme.Brush(Theme.Accent),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children =
                {
                    icon.Icon(),
                    new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center },
                },
            },
        };
        btn.Click += click;
        return btn;
    }

    public static Button PrimaryButton(string title, ActionIcon icon, RoutedEventHandler click)
    {
        var button = Button(title, icon, click);
        button.Background = Theme.AccentBrush;
        button.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(
            Microsoft.UI.Colors.White);
        button.BorderBrush = Theme.AccentBrush;
        return button;
    }
}
