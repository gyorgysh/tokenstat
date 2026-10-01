// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.auth

import ai.tokenstat.tokenstat.ui.localization.L10n

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
        L10n.text("android.onboarding.welcome.0e2226b5"),
        L10n.text("android.onboarding.your_coding_agents_within_reach.e0c0e724"),
        L10n.text("android.onboarding.run_coding_agents_on_your_computer_or_a_se.79e445d7"),
    ),
    OnboardingPage(
        OnboardingArtKind.Agents,
        L10n.text("android.onboarding.agents.279b44d2"),
        L10n.text("android.onboarding.keep_the_conversation_going.4656fe2c"),
        L10n.text("android.onboarding.give_an_agent_a_task_follow_its_progress_a.1c37d4c6"),
    ),
    OnboardingPage(
        OnboardingArtKind.Workspaces,
        L10n.text("common.projects"),
        L10n.text("android.onboarding.go_from_the_chat_to_the_code.612842a3"),
        L10n.text("android.onboarding.open_a_folder_or_clone_a_repository_read_a.1ff55f95"),
    ),
    OnboardingPage(
        OnboardingArtKind.OnTheGo,
        L10n.text("android.onboarding.machines.c061da19"),
        L10n.text("android.onboarding.choose_where_the_work_runs.0e0fe3ac"),
        L10n.text("android.onboarding.use_a_computer_you_own_or_a_cloud_server_c.2293108d"),
    ),
    OnboardingPage(
        OnboardingArtKind.Heatmap,
        L10n.text("android.onboarding.usage.8d59829c"),
        L10n.text("android.onboarding.know_where_the_tokens_go.fc548566"),
        L10n.text("android.onboarding.see_activity_and_estimated_cost_by_tool_mo.feb3684a"),
    ),
    OnboardingPage(
        OnboardingArtKind.Privacy,
        L10n.text("android.onboarding.privacy.54a57c31"),
        L10n.text("android.onboarding.your_machines_your_say.71812757"),
        L10n.text("android.onboarding.remote_work_travels_over_an_end_to_end_enc.6cfdbc5b"),
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
                    L10n.text("common.skip"),
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
                    L10n.text("android.onboarding.0_of_1.9fea8201", "${page + 1}", "${onboardingPages.size}"),
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
                    L10n.text("android.onboarding.next_sign_in_you_can_connect_a_machine_whe.71155587"),
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
                        label = L10n.text("common.back"),
                        onClick = { scope.launch { pagerState.animateScrollToPage(page - 1) } },
                    )
                }
                // The prominent action, like the client's prominent Continue:
                // this is the one step the whole screen exists to take.
                TsProminentButton(
                    label = if (page == onboardingPages.lastIndex) L10n.text("android.onboarding.get_started.61e8d44a") else L10n.text("android.onboarding.continue.31fbef16"),
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
