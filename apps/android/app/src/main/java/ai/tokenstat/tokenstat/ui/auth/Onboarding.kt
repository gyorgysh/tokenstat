// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.auth

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.marks.Wordmark
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.TsMotion
import kotlinx.coroutines.launch

private data class OnboardingPage(val kind: OnboardingArtKind, val title: String, val body: String)

// The ten pages of `ClientOnboarding.swift`, same copy, same order.
private val onboardingPages = listOf(
    OnboardingPage(
        OnboardingArtKind.Intro,
        "What tokenstat is",
        "One place for the AI coding tools you already use. Usage, plan windows, workspaces, and live sessions, on the computers you work on and on this phone.",
    ),
    OnboardingPage(
        OnboardingArtKind.Heatmap,
        "Your AI Heatmap",
        "Every day, every model, every tool, as one year you can read. Counts stay on the devices that made them unless you opt to sync totals.",
    ),
    OnboardingPage(
        OnboardingArtKind.Devices,
        "All your devices",
        "Laptops and phones share one account. Open the phone while every computer is asleep, and the numbers are still there.",
    ),
    OnboardingPage(
        OnboardingArtKind.Spend,
        "Where it went",
        "Split by tool, model, and project. See what actually used the tokens, not a single total that hides the expensive day.",
    ),
    OnboardingPage(
        OnboardingArtKind.Remaining,
        "What is left",
        "How much of each plan window you have used, and when it resets. Plan usage is not a bill. A number with no date is not shown.",
    ),
    OnboardingPage(
        OnboardingArtKind.Workspaces,
        "Workspaces",
        "The folders you registered on the Mac. Browse the tree, read a file, save an edit. Nothing happens that you did not ask for.",
    ),
    OnboardingPage(
        OnboardingArtKind.Sessions,
        "Sessions",
        "Live terminals on the host, from the desktop or from this phone. Spawn an agent, watch it work, type when you need to.",
    ),
    OnboardingPage(
        OnboardingArtKind.OnTheGo,
        "On the go",
        "This phone is a client of a Mac that is on. Folders and sessions travel over an encrypted tunnel. Usage is already on the account, so the heatmap does not need the laptop open.",
    ),
    OnboardingPage(
        OnboardingArtKind.Privacy,
        "We never see your files",
        "The tunnel is end to end encrypted. We cannot read the files you open or the terminals you type in. Counting happens on your machine. Only aggregate totals you opt to sync are eligible for the account.",
    ),
    OnboardingPage(
        OnboardingArtKind.Control,
        "You are in control",
        "The account is private until you turn a profile on. Sync is opt in. Remote reach is a switch you flip. Most of this stays off until you ask.",
    ),
)

/// The first thing a new install shows: ten swipeable pages, then Get started.
/// Shown once; a second launch goes straight to sign-in.
@Composable
fun Onboarding(onFinished: () -> Unit) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    val pagerState = rememberPagerState(pageCount = { onboardingPages.size })
    Column(Modifier.fillMaxSize().background(colors.background)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = Space.m, vertical = Space.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Wordmark(size = 18, showsMark = false)
            Spacer(Modifier.weight(1f))
            // A way past the pitch for anyone who does not want it. On the
            // last page it would duplicate the button below, so it goes.
            if (pagerState.currentPage < onboardingPages.lastIndex) {
                Text(
                    "Skip",
                    color = colors.accent,
                    style = TextStyle(fontSize = 14.sp),
                    modifier = Modifier.clickable(onClick = onFinished),
                )
            }
        }
        Box(
            Modifier
                .padding(horizontal = Space.m)
                .fillMaxWidth()
                .height(3.dp)
                .clip(RoundedCornerShape(50))
                .background(colors.accent.copy(alpha = 0.16f)),
        ) {
            val progress by animateFloatAsState(
                (pagerState.currentPage + 1f) / onboardingPages.size,
                tween(TsMotion.doorMillis, easing = TsMotion.easeInOut),
                label = "onboardingProgress",
            )
            Box(
                Modifier
                    .fillMaxWidth(progress)
                    .height(3.dp)
                    .clip(RoundedCornerShape(50))
                    .background(colors.accent),
            )
        }
        HorizontalPager(state = pagerState, modifier = Modifier.weight(1f)) { index ->
            val page = onboardingPages[index]
            Column(
                Modifier.fillMaxSize().padding(Space.xl),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                OnboardingScene(page.kind, active = index == pagerState.currentPage)
                Spacer(Modifier.height(Space.l))
                Text(
                    page.title,
                    style = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                Spacer(Modifier.height(Space.s))
                Text(
                    page.body,
                    style = TextStyle(fontSize = 15.sp),
                    color = colors.textSecondary,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        Box(Modifier.padding(Space.l)) {
            TsAccentButton(
                label = if (pagerState.currentPage < onboardingPages.lastIndex) "Continue" else "Get started",
                onClick = {
                    if (pagerState.currentPage < onboardingPages.lastIndex) {
                        scope.launch { pagerState.animateScrollToPage(pagerState.currentPage + 1) }
                    } else {
                        onFinished()
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
