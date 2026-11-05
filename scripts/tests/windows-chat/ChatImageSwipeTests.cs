// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Tokenstat.Pages;

internal static class ChatImageSwipeTests
{
    internal static void Run(Action<bool, string> check)
    {
        var swipe = new ChatImageSwipe();
        check(swipe.Press(1, 200, 150, 1, 600, 1, true) == ChatImageSwipe.Start.Observe,
            "A fitted single contact is observed for image navigation");
        check(swipe.Release(1, 50, 160, 1, 1) == 1, "A left swipe selects the next image");
        swipe.Press(2, 100, 150, .5, 600, 1, true);
        check(swipe.Release(2, 250, 150, .5, 1) == -1, "A fitted or smaller image swipes to the previous image");

        swipe.Press(1, 200, 150, 1, 600, 1, true);
        check(swipe.Press(2, 250, 150, 1, 600, 1, true) == ChatImageSwipe.Start.HandOff,
            "The second contact hands the gesture to native pinch zoom");
        check(swipe.Release(1, 0, 150, 1, 1) == 0 && swipe.Release(2, 0, 150, 1, 1) == 0,
            "Ending a pinch at fitted size never navigates");
        swipe.Press(3, 200, 150, 1, 600, 1, true);
        check(swipe.Release(3, 50, 150, 1, 1) == 1, "A pinch without native movement does not disable the next swipe");

        check(swipe.Press(1, 200, 150, 2, 600, 1, true) == ChatImageSwipe.Start.Native,
            "A zoomed image keeps native panning");
        swipe.NativeStarted();
        swipe.Cancel(1);
        check(swipe.Press(2, 200, 150, 1, 600, 1, true) == ChatImageSwipe.Start.Native,
            "Additional contacts during native zoom cannot steal the gesture");
        check(swipe.Release(2, 0, 150, 1, 1) == 0, "Returning to fit during native zoom does not navigate");
        swipe.NativeCompleted();
        swipe.Press(4, 200, 150, 1, 600, 1, true);
        check(swipe.Release(4, 50, 150, 1, 1) == 1, "Finishing native zoom restores swiping");

        foreach (var end in new[] { (190d, 150d), (100d, 300d), (double.NaN, 150d) }) {
            swipe.Press(1, 200, 150, 1, 600, 1, true);
            check(swipe.Release(1, end.Item1, end.Item2, 1, 1) == 0, "Taps, vertical drags and invalid coordinates cannot navigate");
        }
        swipe.Press(1, 200, 150, 1, 600, 1, true);
        check(swipe.Release(1, 0, 150, 2, 1) == 0, "A zoom change cancels a fitted swipe");
        swipe.Press(1, 200, 150, 1, 600, 1, true);
        check(swipe.Release(1, 0, 150, 1, 2) == 0, "Changing the image cancels the prior gesture");
        swipe.Press(1, 200, 150, 1, 600, 1, true);
        swipe.Invalidate();
        check(swipe.Release(1, 0, 150, 1, 1) == 0, "Layout changes cancel a pending swipe");
        swipe.Press(1, 200, 150, 1, 600, 1, true);
        swipe.Cancel(1);
        check(swipe.Release(1, 0, 150, 1, 1) == 0, "Cancelled contacts never navigate");
        swipe.Press(1, 200, 150, 1, 600, 1, true);
        swipe.NativeStarted();
        check(!swipe.NativeCompleted(), "Finishing cancelled system input cannot cancel a new fitted swipe");
        check(swipe.Release(1, 0, 150, 1, 1) == 1, "A fitted swipe survives obsolete native callbacks");
        swipe.Press(1, 200, 150, 1, 600, 1, true);
        swipe.Press(2, 250, 150, 1, 600, 1, true);
        swipe.NativeStarted(); swipe.Cancel(1); swipe.Cancel(2); swipe.NativeFailed();
        swipe.Press(3, 200, 150, 1, 600, 1, true);
        check(swipe.Release(3, 0, 150, 1, 1) == 1, "A rejected native handoff does not disable later swipes");
        swipe.Press(1, 200, 150, 1, 600, 1, true);
        check(swipe.Release(99, 0, 150, 1, 1) == 0, "An unrelated pointer cannot finish a swipe");
        check(swipe.Release(1, 0, 150, 1, 1) == 1, "The original pointer can still finish its swipe");
        check(swipe.Release(1, 0, 150, 1, 1) == 0, "Duplicate releases do not navigate twice");
        check(swipe.Press(1, 200, 150, 1, 600, 1, false) == ChatImageSwipe.Start.Native,
            "Unavailable images leave native input alone");
        swipe.Reset();
        check(swipe.Release(1, 0, 150, 1, 1) == 0, "A closed viewer cannot finish a gesture");
        Console.WriteLine("Image swipe: fitted navigation, pinch handoff, native panning, cancellation and ownership passed");
    }
}
