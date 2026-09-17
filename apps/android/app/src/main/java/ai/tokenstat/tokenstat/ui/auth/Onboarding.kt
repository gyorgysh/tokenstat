// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.auth

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.ui.components.TsProminentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.marks.Wordmark
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch

private data class OnboardingPage(
    val kind: OnboardingArtKind,
    val topic: String,
    val title: String,
    val body: String,
)

// The six pages of `ClientOnboarding.swift`, same copy, same order. The only
// words that differ name this device: the client it was written for says
// "iPhone or iPad" where this one says "Android phone or tablet".
private val onboardingPages = listOf(
    OnboardingPage(
        OnboardingArtKind.Intro,
        "Welcome",
        "Your coding agents,\nwithin reach.",
        "Run coding agents on your computer or a server. Pick up the " +
            "conversation, work on your projects, and see your AI usage " +
            "from your Android phone or tablet.",
    ),
    OnboardingPage(
        OnboardingArtKind.Agents,
        "Agents",
        "Keep the conversation going",
        "Give an agent a task, follow its progress, and reply when it " +
            "needs you. Return to the same chat later, or open a live " +
            "terminal when you want to work directly.",
    ),
    OnboardingPage(
        OnboardingArtKind.Workspaces,
        "Projects",
        "Go from the chat\nto the code",
        "Open a folder or clone a repository. Read and edit files, " +
            "review changes, and keep tasks beside the code. Your " +
            "projects stay on the machine that runs them.",
    ),
    OnboardingPage(
        OnboardingArtKind.OnTheGo,
        "Machines",
        "Choose where the work runs",
        "Use a computer you own or a cloud server. Connect it from " +
            "this device, with guided setup for a server. That machine " +
            "needs to be awake while you work; your Android phone or tablet is " +
            "how you reach it.",
    ),
    OnboardingPage(
        OnboardingArtKind.Heatmap,
        "Usage",
        "Know where the tokens go",
        "See activity and estimated cost by tool, model, and project, " +
            "plus supported plans\u2019 usage and reset times. Synced numbers " +
            "stay available with every computer asleep. Plan usage is " +
            "shown separately from cost.",
    ),
    OnboardingPage(
        OnboardingArtKind.Privacy,
        "Privacy",
        "Your machines.\nYour say.",
        "Remote work travels over an end-to-end encrypted connection. " +
            "You choose which devices can open your work and which usage " +
            "totals to sync. Your account stays private unless you turn " +
            "on a public profile.",
    ),
)

/// The first thing a new install shows: six short pages that explain the work
/// first, then the machine that holds it, the numbers, and the privacy
/// boundary. Sign-in stays a deliberate next step. Shown once; a second launch
/// goes straight to the sign-in card.
@Composable
fun Onboarding(onFinished: () -> Unit) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    val pagerState = rememberPagerState(pageCount = { onboardingPages.size })
    val page = pagerState.currentPage
    // Edge-to-edge draws behind the status bar; safeDrawing keeps the
    // wordmark and Skip clear of the clock. Sections cap at a phone-like
    // width so a tablet reads as a centred column, not a stretched row.
    Column(
        Modifier.fillMaxSize().background(colors.background)
            .windowInsetsPadding(WindowInsets.safeDrawing),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(
            Modifier.widthIn(max = 640.dp).fillMaxWidth()
                .align(Alignment.CenterHorizontally)
                .padding(horizontal = Space.m, vertical = Space.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Wordmark(size = 18, showsMark = false)
            Spacer(Modifier.weight(1f))
            // A way past the pitch for anyone who does not want it. On the last
            // page it would duplicate the button below, so it goes.
            if (page < onboardingPages.lastIndex) {
                Text(
                    "Skip",
                    color = colors.accent,
                    style = TextStyle(fontSize = 14.sp),
                    modifier = Modifier.clickable(onClick = onFinished),
                )
            }
        }
        // Named steps and a finite rail make the length clear before the first swipe.
        Column(
            Modifier.widthIn(max = 640.dp).fillMaxWidth()
                .align(Alignment.CenterHorizontally)
                .padding(horizontal = Space.l).padding(top = Space.l, bottom = Space.s),
            verticalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    onboardingPages[page].topic,
                    style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.accent,
                )
                Spacer(Modifier.weight(1f))
                Text(
                    "${page + 1} of ${onboardingPages.size}",
                    style = TsType.numeric(12),
                    color = colors.accent,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                onboardingPages.indices.forEach { index ->
                    Spacer(
                        Modifier
                            .weight(1f)
                            .height(4.dp)
                            .clip(RoundedCornerShape(50))
                            .background(if (index <= page) colors.accent else colors.accentSoft),
                    )
                }
            }
        }
        HorizontalPager(state = pagerState, modifier = Modifier.weight(1f)) { index ->
            val item = onboardingPages[index]
            Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = Space.l),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Column(
                    Modifier.widthIn(max = 560.dp).fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                Spacer(Modifier.height(Space.s))
                OnboardingScene(item.kind, active = index == page)
                Spacer(Modifier.height(Space.m))
                Text(
                    item.title,
                    style = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(Space.m))
                Text(
                    item.body,
                    style = TextStyle(fontSize = 17.sp),
                    color = colors.textSecondary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(0.9f),
                )
                Spacer(Modifier.height(Space.l))
                }
            }
        }
        Column(
            Modifier.widthIn(max = 640.dp).fillMaxWidth()
                .align(Alignment.CenterHorizontally)
                .padding(horizontal = Space.l).padding(top = Space.s, bottom = Space.l),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            if (page == onboardingPages.lastIndex) {
                Text(
                    "Next, sign in. You can connect a machine whenever you are ready.",
                    style = TextStyle(fontSize = 12.sp),
                    color = colors.textSecondary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(Space.m),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (page > 0) {
                    TsSecondaryButton(
                        label = "Back",
                        onClick = { scope.launch { pagerState.animateScrollToPage(page - 1) } },
                    )
                }
                // The prominent action, like the client's prominent Continue:
                // this is the one step the whole screen exists to take.
                TsProminentButton(
                    label = if (page == onboardingPages.lastIndex) "Get started" else "Continue",
                    onClick = {
                        if (page == onboardingPages.lastIndex) {
                            onFinished()
                        } else {
                            scope.launch { pagerState.animateScrollToPage(page + 1) }
                        }
                    },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}
