// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Windows.UI;

namespace Tokenstat.Design.Persona;

/// <summary>
/// What the character is doing, which is what the conversation is doing. A
/// mood is not a picture. It is three pure functions of elapsed time: the
/// forces to apply, where the face is looking, and what is in the air around
/// it. Nothing here positions a node, so every mood inherits weight, overshoot
/// and settle from the soft body underneath.
/// </summary>
internal enum PersonaMood
{
    /// <summary>Alive and doing nothing. Breathes, sways, blinks, and every so often has an enormous yawn about it.</summary>
    Idle,

    /// <summary>A ball. Real gravity, a real floor, squash on landing, and a fresh kick whenever it runs out of bounce.</summary>
    Bouncing,

    /// <summary>Something is turning over inside. Churn, a lean back, eyes up on a thought that orbits.</summary>
    Thinking,

    /// <summary>A tiny construction worker: hard hat on, hammering the ground with overly serious little thuds.</summary>
    Working,

    /// <summary>Talking. The body pulses with the mouth, so a streaming reply has a voice rather than a spinner.</summary>
    Speaking,

    /// <summary>Keeping a ball up, leaning left and right to meet it, and every fourth throw very nearly losing it.</summary>
    Juggling,

    /// <summary>On the beat: squash down, spring up, sway, a hop every fourth.</summary>
    Dancing,

    /// <summary>A tool is waiting on a person. Leans in, eyes wide, and wears the colour that already means "your turn".</summary>
    Waiting,

    /// <summary>It worked. One big jump, a stretch at the top, sparks, confetti, and a second smaller hop.</summary>
    Ok,

    /// <summary>It failed. A hard shake, then the whole thing gives up and melts into a puddle that keeps trying to stand back up.</summary>
    Failed,

    /// <summary>Out cold. Flat, slow, closed, with z's and the occasional good dream.</summary>
    Sleeping,

    /// <summary>Reading the paper. Eyes scan a line at a time.</summary>
    Reading,

    /// <summary>Playing something handheld. Wins occasionally, loses occasionally, and takes both far too seriously.</summary>
    Gaming,

    /// <summary>Walking the floor and thinking about it, until it stops dead because it has got it.</summary>
    Pacing,

    /// <summary>Trying to type by landing on the keys. The small liquid squashes are the whole joke.</summary>
    Typing,

    /// <summary>Tea. The first sip is always too hot and it never learns.</summary>
    Sipping,

    /// <summary>Painting directly onto the floor with a comically large brush, then standing back to look.</summary>
    Sketching,

    /// <summary>Looking up. Something crosses the sky and it makes a wish on it.</summary>
    Stargazing,

    /// <summary>Tending a tiny sprout until it flowers, which it finds overwhelming.</summary>
    Gardening,

    /// <summary>Blowing a bubble, watching it get too big, and being startled by the entirely predictable consequence.</summary>
    Bubbling,

    /// <summary>A biscuit, in three bites, with an unreasonable amount of pleasure.</summary>
    Snacking,
}

/// <summary>What a mood means to the app around it: its tint, its frame rate, its story length, its name.</summary>
internal static class PersonaMoodMeaning
{
    /// <summary>
    /// An outline and ink colour that overrides the persona's own, for the two
    /// states that carry a meaning the app already has a colour for.
    /// </summary>
    public static Color? Tint(this PersonaMood mood) => mood switch
    {
        PersonaMood.Waiting => Theme.Warning,
        PersonaMood.Failed => Theme.Danger,
        _ => null,
    };

    /// <summary>
    /// Frames per second worth spending. Half rate is invisible on a slow
    /// breathe and halves the cost of a transcript full of faces.
    /// </summary>
    public static double FrameRate(this PersonaMood mood) => mood switch
    {
        PersonaMood.Idle or PersonaMood.Sleeping or PersonaMood.Waiting
            or PersonaMood.Stargazing or PersonaMood.Gardening => 30,
        _ => 60,
    };

    /// <summary>
    /// How long one telling of this mood takes, in seconds. Zero means the
    /// mood has no story: it can be held for as long as anybody likes.
    /// </summary>
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
