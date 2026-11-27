// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Windows.UI;

namespace Tokenstat.Design.Persona;

internal enum PersonaMood
{
    Idle,

    Bouncing,

    Thinking,

    Working,

    Speaking,

    Juggling,

    Dancing,

    Waiting,

    Ok,

    Failed,

    Sleeping,

    Reading,

    Gaming,

    Pacing,

    Typing,

    Sipping,

    Sketching,

    Stargazing,

    Gardening,

    Bubbling,

    Snacking,
}

internal static class PersonaMoodMeaning
{
    public static Color? Tint(this PersonaMood mood) => mood switch
    {
        PersonaMood.Waiting => Theme.Warning,
        PersonaMood.Failed => Theme.Danger,
        _ => null,
    };

    public static double FrameRate(this PersonaMood mood) => mood switch
    {
        PersonaMood.Idle or PersonaMood.Sleeping or PersonaMood.Waiting
            or PersonaMood.Stargazing or PersonaMood.Gardening => 30,
        _ => 60,
    };

    public static double StoryLength(this PersonaMood mood) => mood switch
    {
        PersonaMood.Idle => 11.5,
        PersonaMood.Bouncing => 3.0,
        PersonaMood.Thinking => 7.2,
        PersonaMood.Working => 4.2,
        PersonaMood.Juggling => 3.12,
        PersonaMood.Dancing => 3.84,
        PersonaMood.Waiting => 5.6,
        PersonaMood.Sleeping => 13.0,
        PersonaMood.Reading => 16.8,
        PersonaMood.Gaming => PersonaMoodTiming.GamePeriod,
        PersonaMood.Pacing => 9.1,
        PersonaMood.Typing => 6.4,
        PersonaMood.Sipping => PersonaMoodTiming.TeaPeriod,
        PersonaMood.Sketching => 8.6,
        PersonaMood.Stargazing => 9.4,
        PersonaMood.Gardening => 11.2,
        PersonaMood.Bubbling => 5.4,
        PersonaMood.Snacking => 7.6,
        _ => 0,
    };

    public static string Label(this PersonaMood mood) => mood switch
    {
        PersonaMood.Idle => L10n.Text("common.idle"),
        PersonaMood.Bouncing => L10n.Text("windows.personamood.bouncing.640dcae5"),
        PersonaMood.Thinking => L10n.Text("windows.personamood.thinking.a20d12c5"),
        PersonaMood.Working => L10n.Text("common.working"),
        PersonaMood.Speaking => L10n.Text("windows.personamood.replying.b2663dd7"),
        PersonaMood.Juggling => L10n.Text("windows.personamood.juggling.126aab73"),
        PersonaMood.Dancing => L10n.Text("windows.personamood.dancing.9879cda2"),
        PersonaMood.Waiting => L10n.Text("common.waiting"),
        PersonaMood.Ok => L10n.Text("common.done"),
        PersonaMood.Failed => L10n.Text("common.failed"),
        PersonaMood.Sleeping => L10n.Text("windows.personamood.asleep.60135e8f"),
        PersonaMood.Reading => L10n.Text("windows.personamood.reading.463816d0"),
        PersonaMood.Gaming => L10n.Text("windows.personamood.playing.deaf6f9d"),
        PersonaMood.Pacing => L10n.Text("windows.personamood.thinking.a20d12c5"),
        PersonaMood.Typing => L10n.Text("windows.personamood.typing.25dfb9b4"),
        PersonaMood.Sipping => L10n.Text("windows.personamood.tea_break.08af9306"),
        PersonaMood.Sketching => L10n.Text("windows.personamood.sketching.edf49874"),
        PersonaMood.Stargazing => L10n.Text("windows.personamood.stargazing.94665327"),
        PersonaMood.Gardening => L10n.Text("windows.personamood.gardening.0fe4b0b9"),
        PersonaMood.Bubbling => L10n.Text("windows.personamood.blowing_bubbles.8f2744ed"),
        PersonaMood.Snacking => L10n.Text("windows.personamood.snack_break.5d92c6d3"),
        _ => L10n.Text("common.idle"),
    };
}
