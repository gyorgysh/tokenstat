// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui

import ai.tokenstat.tokenstat.ui.components.ForegroundEffect
import ai.tokenstat.tokenstat.ui.components.TsDangerButton

import androidx.compose.ui.draw.shadow
import androidx.compose.foundation.shape.CircleShape

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.text.ClickableText
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.filled.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import android.content.ClipData
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.notifications.NotificationOpen
import ai.tokenstat.tokenstat.ClientState
import ai.tokenstat.tokenstat.billing.PlayBillingManager
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.EmptyKind
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.TsFitFigure
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.SectionTitle
import ai.tokenstat.tokenstat.ui.components.SegmentedCapsulePicker
import ai.tokenstat.tokenstat.ui.components.SkeletonCard
import ai.tokenstat.tokenstat.ui.components.SkeletonRows
import ai.tokenstat.tokenstat.ui.components.Stat
import ai.tokenstat.tokenstat.ui.components.TsBrandSwitch
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.components.cardPaddingDp
import ai.tokenstat.tokenstat.ui.components.tsPanel
import ai.tokenstat.tokenstat.ui.heatmap.DayDetailSheet
import ai.tokenstat.tokenstat.ui.heatmap.YearHeatmap
import ai.tokenstat.tokenstat.ui.heatmap.calendarFreshness
import ai.tokenstat.tokenstat.ui.home.ClearHomeCard
import ai.tokenstat.tokenstat.ui.home.ContinueSection
import ai.tokenstat.tokenstat.ui.home.GettingStartedCard
import ai.tokenstat.tokenstat.ui.home.HomeEditor
import ai.tokenstat.tokenstat.ui.home.HomeMachine
import ai.tokenstat.tokenstat.ui.home.HomeStatusBlock
import ai.tokenstat.tokenstat.ui.home.HomeStores
import ai.tokenstat.tokenstat.ui.home.MachinesSection
import ai.tokenstat.tokenstat.ui.home.PinnedSection
import ai.tokenstat.tokenstat.ui.logic.DeviceCopy
import ai.tokenstat.tokenstat.ui.logic.HomeGreeting
import ai.tokenstat.tokenstat.ui.logic.HomeSection
import ai.tokenstat.tokenstat.ui.logic.HostStatsFormat
import ai.tokenstat.tokenstat.ui.logic.LimitLogic
import ai.tokenstat.tokenstat.ui.logic.PinnedWork
import ai.tokenstat.tokenstat.ui.logic.RecentPlaces
import ai.tokenstat.tokenstat.ui.logic.RelativeClock
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.compactTokens
import ai.tokenstat.tokenstat.ui.logic.groupedCount
import ai.tokenstat.tokenstat.ui.logic.deviceHistoryDays
import ai.tokenstat.tokenstat.ui.logic.friendlyError
import ai.tokenstat.tokenstat.ui.logic.harnessName
import ai.tokenstat.tokenstat.ui.logic.insightFactPanels
import ai.tokenstat.tokenstat.ui.logic.money
import ai.tokenstat.tokenstat.ui.logic.moneyValue
import ai.tokenstat.tokenstat.ui.logic.shortDate
import ai.tokenstat.tokenstat.ui.logic.normalizedRecovery
import ai.tokenstat.tokenstat.ui.logic.vaultPasswordProblems
import ai.tokenstat.tokenstat.ui.devices.DeviceDetailScreen
import ai.tokenstat.tokenstat.ui.devices.DevicesHeader
import ai.tokenstat.tokenstat.ui.logic.DeviceUsage
import ai.tokenstat.tokenstat.ui.insights.InsightStatPanels
import ai.tokenstat.tokenstat.ui.sample.SampleSheet
import ai.tokenstat.tokenstat.ui.search.SearchOpen
import ai.tokenstat.tokenstat.ui.search.WorkSearchSheet
import ai.tokenstat.tokenstat.ui.setup.SetupWizard
import ai.tokenstat.tokenstat.ui.terminal.SshTerminalScreen
import ai.tokenstat.tokenstat.ui.terminal.TerminalScreen
import ai.tokenstat.tokenstat.ui.workspace.CloneRepositoryScreen
import ai.tokenstat.tokenstat.ui.workspace.EmptyWorkspacesCard
import ai.tokenstat.tokenstat.ui.workspace.FolderChooserDialog
import ai.tokenstat.tokenstat.ui.workspace.FolderPickerScreen
import ai.tokenstat.tokenstat.ui.workspace.HostCard
import ai.tokenstat.tokenstat.ui.workspace.RequestAccessCard
import ai.tokenstat.tokenstat.ui.workspace.SecurityCard
import ai.tokenstat.tokenstat.ui.workspace.WorkSection
import ai.tokenstat.tokenstat.ui.workspace.WorkspaceChatRow
import ai.tokenstat.tokenstat.ui.workspace.WorkspaceFolderRow
import ai.tokenstat.tokenstat.ui.workspace.WorkspaceLayoutStore
import ai.tokenstat.tokenstat.ui.workspace.WorkspaceSection
import ai.tokenstat.tokenstat.ui.workspace.WorkspaceSessionRow
import ai.tokenstat.tokenstat.ui.workspace.WorkspaceHub
import ai.tokenstat.tokenstat.ui.workspace.WorkspacesEditor
import ai.tokenstat.tokenstat.ui.chrome.ConnectionChip
import ai.tokenstat.tokenstat.ui.components.TsSearchField
import ai.tokenstat.tokenstat.ui.chrome.FloatingTabBar
import ai.tokenstat.tokenstat.ui.chrome.LocalTabBarPresence
import ai.tokenstat.tokenstat.ui.chrome.TabBarPresence
import ai.tokenstat.tokenstat.ui.chrome.backdropSource
import ai.tokenstat.tokenstat.ui.chrome.rememberBackdrop
import ai.tokenstat.tokenstat.ui.chrome.rememberTabBarMinimizeScroll
import ai.tokenstat.tokenstat.ui.chrome.rememberTabBarMinimizeState
import ai.tokenstat.tokenstat.ui.chrome.SharedPrefsTabs
import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import ai.tokenstat.tokenstat.ui.chrome.TabCustomization
import ai.tokenstat.tokenstat.ui.chrome.TabDef
import ai.tokenstat.tokenstat.ui.chrome.TabEditorSheet
import ai.tokenstat.tokenstat.ui.chrome.TabSpec
import ai.tokenstat.tokenstat.ui.chrome.TabsCard
import ai.tokenstat.tokenstat.ui.chrome.TsRefresh
import ai.tokenstat.tokenstat.ui.chrome.tabSummary
import ai.tokenstat.tokenstat.ui.legal.LicensesCard
import ai.tokenstat.tokenstat.ui.legal.LicensesSheet
import ai.tokenstat.tokenstat.ui.billing.PaywallSheet
import ai.tokenstat.tokenstat.ui.billing.Plans
import ai.tokenstat.tokenstat.ui.browser.PortBrowserScreen
import ai.tokenstat.tokenstat.ui.screen.ScreenViewerScreen
import ai.tokenstat.tokenstat.ui.ssh.SshConnectDialog
import ai.tokenstat.tokenstat.ui.ssh.SshHostRow
import ai.tokenstat.tokenstat.ui.ssh.SshKeyImportDialog
import ai.tokenstat.tokenstat.ui.ssh.SshKeyRenameDialog
import ai.tokenstat.tokenstat.ui.ssh.SshKeyRow
import ai.tokenstat.tokenstat.ui.ssh.SshOpenSessionsSection
import ai.tokenstat.tokenstat.ui.ssh.SshSessionEntry
import ai.tokenstat.tokenstat.ui.ssh.SshSnippetRow
import ai.tokenstat.tokenstat.ui.ssh.TunnelStatusBanner
import ai.tokenstat.tokenstat.ui.ssh.VaultLockRow
import ai.tokenstat.tokenstat.ui.ssh.startupCommands
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.marks.FeatureMark
import ai.tokenstat.tokenstat.ui.marks.HarnessMark
import ai.tokenstat.tokenstat.ui.ssh.SshSecrets
import ai.tokenstat.tokenstat.ui.ssh.SshVaultSync
import ai.tokenstat.tokenstat.ui.ssh.vaultEnvelopeOf
import ai.tokenstat.tokenstat.ui.marks.TierMark
import ai.tokenstat.tokenstat.notifications.PushRegistrar
import ai.tokenstat.tokenstat.ui.components.TierBadge
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsProminentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.auth.Onboarding
import ai.tokenstat.tokenstat.ui.marks.Avatar
import ai.tokenstat.tokenstat.ui.marks.AwakeDot
import ai.tokenstat.tokenstat.ui.marks.DeviceGlyph
import ai.tokenstat.tokenstat.ui.marks.LogoMark
import ai.tokenstat.tokenstat.ui.marks.formatRelativeDate
import ai.tokenstat.tokenstat.ui.marks.sortMachines
import ai.tokenstat.tokenstat.ui.marks.Wordmark
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.TsMotion
import ai.tokenstat.tokenstat.ui.theme.TsTheme
import ai.tokenstat.tokenstat.ui.theme.toColorScheme
import ai.tokenstat.tokenstat.ui.components.cardPaddingDp
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.rememberReduceMotion
import ai.tokenstat.tokenstat.ui.theme.smoothEnter
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*

/// The brand accent from the shared token system.
@Composable
private fun tsAccent(): Color = LocalTsColors.current.accent

private enum class Destination(val id: String, val label: String, val icon: ImageVector, val detail: String) {
    Home("home", "Home", Icons.Default.GridView, "Spend, activity and limits"),
    Workspaces("workspaces", "Workspaces", Icons.Default.Folder, "Folders and sessions on your machines"),
    Insights("insights", "Insights", Icons.Default.BarChart, "Breakdowns by model and project"),
    // The id is `machines`, like the iOS raw value, so the two tab stores
    // stay comparable. SSH stays last: entries order is the default bar.
    Devices("machines", "Devices", Icons.Default.Laptop, "Computers on your account"),
    Ssh("ssh", "SSH", Icons.Default.Terminal, "Saved servers and keys"),
}

/// Five doors after onboarding, not three: still checking, could not check
/// (usually offline), an honest signed-out answer, and the app. Folding a
/// failed check into "signed out" is the cold-start bug that flashed Sign in
/// at a phone that still had a token.
private enum class Door { Onboarding, Loading, AuthRetry, Login, SignedIn }

@Composable
fun TokenstatApp(model: AppViewModel) {
    val state by model.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var hasOnboarded by remember {
        mutableStateOf(
            runCatching {
                context.getSharedPreferences("client", android.content.Context.MODE_PRIVATE)
                    .getBoolean("hasOnboarded", false)
            }.getOrDefault(false),
        )
    }
    // A pending notification tap belongs to the account that was signed in
    // when it arrived. Signing out drops it, the way the Apple root clears
    // its tap on a scope change, so it cannot open somebody else's work. A
    // sign-in drops an unnamed one for the same reason: a named tap only
    // resolves when its machine is in the new account's directory, but an
    // unnamed tap falls back to the connected host and could open the wrong
    // account's chat.
    var wasSignedIn by remember { mutableStateOf<Boolean?>(null) }
    val tapScope = rememberCoroutineScope()
    LaunchedEffect(state.signedIn) {
        if (wasSignedIn == true && !state.signedIn) NotificationOpen.take()
        if (wasSignedIn == false && state.signedIn) {
            if (NotificationOpen.request.value?.machineID == null) NotificationOpen.take()
            // The cold-start half of the foreground tunnel nudge. `onResume`
            // fires before the account lands, so it cannot cover a fresh
            // process, and this transition is where the sign-in completes.
            tapScope.launch { model.nudgeTunnelOnForeground() }
        }
        wasSignedIn = state.signedIn
    }
    TsTheme {
        val colors = LocalTsColors.current
        MaterialTheme(colorScheme = colors.toColorScheme(), typography = TsType.typography) {
            Surface(Modifier.fillMaxSize(), color = colors.background) {
                val door = when {
                    state.signedIn -> Door.SignedIn
                    !hasOnboarded -> Door.Onboarding
                    // Above the loading clause on purpose: a retry keeps its
                    // screen and shows Checking, instead of swapping to the
                    // spinner and back. The first check has no error yet, so it
                    // still falls through to Loading.
                    state.authNeedsRetry -> Door.AuthRetry
                    state.loading && state.account == null -> Door.Loading
                    state.authPending -> Door.Loading
                    else -> Door.Login
                }
                AnimatedContent(
                    targetState = door,
                    transitionSpec = {
                        fadeIn(tween(TsMotion.doorMillis, easing = TsMotion.easeInOut)) togetherWith
                            fadeOut(tween(TsMotion.doorMillis, easing = TsMotion.easeInOut))
                    },
                    label = "door",
                ) { shown ->
                    when (shown) {
                        Door.SignedIn -> SignedInApp(model, state)
                        Door.Onboarding -> Onboarding {
                            runCatching {
                                context.getSharedPreferences("client", android.content.Context.MODE_PRIVATE)
                                    .edit().putBoolean("hasOnboarded", true).apply()
                            }
                            hasOnboarded = true
                        }
                        Door.Loading -> LoadingScreen()
                        Door.AuthRetry -> AuthRetryScreen(
                            message = state.authError,
                            isLoading = state.loading,
                            offline = state.connection.offline,
                            onRetry = { model.retryConnection() },
                        )
                        Door.Login -> LoginScreen(model, state.error) {
                            runCatching {
                                context.getSharedPreferences("client", android.content.Context.MODE_PRIVATE)
                                    .edit().putBoolean("hasOnboarded", false).apply()
                            }
                            hasOnboarded = false
                        }
                    }
                }
            }
        }
    }
}

/// The cold-launch flow: the mark rising on paper, not a spinner in an empty pane.
@Composable
/// What a cold start shows while the account check runs: the mark alone
/// on the window paper, the port of iOS `LaunchSplashView`. The wordmark
/// stays off, like there, and the screens behind it load as skeletons.
private fun LoadingScreen() {
    val reduceMotion = rememberReduceMotion()
    val colors = LocalTsColors.current
    Column(
        Modifier.fillMaxSize().background(colors.background),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        LogoMark(size = 44, animated = !reduceMotion, loops = true)
    }
}

/// The account could not be checked, which is not the same thing as being
/// signed out. Port of `ClientAuthRetryView`.
///
/// `account.status` asks the account service, so no internet means no answer,
/// and a phone holding a valid token must not be shown the Sign in door for
/// it. The mark, the app's own words for the failure, and one button.
@Composable
private fun AuthRetryScreen(
    message: String?,
    isLoading: Boolean,
    offline: Boolean,
    onRetry: () -> Unit,
) {
    val colors = LocalTsColors.current
    val friendly = remember(message) { friendlyError(message) }
    Column(
        Modifier
            .fillMaxSize()
            .background(colors.background)
            .systemBarsPadding()
            .padding(horizontal = Space.l),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.weight(1f))
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            LogoMark(size = 46, animated = false)
            Text(
                // Offline rewrites this whatever the call happened to say. A
                // device with no internet produces a different sentence per
                // subsystem, and all of them have one cause and one answer.
                if (offline) "You are offline" else friendly.title,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary,
                textAlign = TextAlign.Center,
            )
            Text(
                if (offline) {
                    "This device cannot reach the internet. You are still signed in, and " +
                        "everything comes back on its own."
                } else {
                    friendly.message
                },
                style = MaterialTheme.typography.bodyMedium,
                color = colors.textSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.widthIn(max = 320.dp),
            )
        }
        Spacer(Modifier.weight(1f))
        TsAccentButton(
            label = if (isLoading) "Checking…" else "Try again",
            icon = ActionIcon.Refresh.vector,
            enabled = !isLoading,
            onClick = onRetry,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(Space.xl))
    }
}

@Composable
private fun LoginScreen(model: AppViewModel, error: String?, onReboard: () -> Unit) {
    val context = LocalContext.current
    val colors = LocalTsColors.current
    val reduceMotion = rememberReduceMotion()
    val pending by model.pendingLogin.collectAsStateWithLifecycle()
    val notice by model.signInNotice.collectAsStateWithLifecycle()
    val signInError by model.signInError.collectAsStateWithLifecycle()
    fun openPage(url: String) {
        CustomTabsIntent.Builder().build().launchUrl(context, url.toUri())
    }
    // The shape of `ClientLoginView`: the mark and the name centred in the
    // room above the actions, the actions themselves against the bottom
    // edge. Full width on a tablet, the way the iPad draws it, rather than a
    // narrow card in the middle of a wide screen.
    //
    // Edge-to-edge draws behind the status bar, so safeDrawing keeps the top
    // clear of the clock and the bottom clear of the gesture bar.
    Column(
        Modifier
            .fillMaxSize()
            .background(colors.background)
            .windowInsetsPadding(WindowInsets.safeDrawing),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.weight(1f))
        // Mark, name, sentence. No "Sign in" heading: the button at the
        // bottom of the same screen says it, and saying it twice made the
        // product's own name look like a subtitle to the word above it.
        // The mark rising once and landing: an intro page, not a spinner.
        LogoMark(size = 52, animated = !reduceMotion, loops = false)
        Spacer(Modifier.height(Space.m))
        Wordmark(size = 28, showsMark = false)
        Spacer(Modifier.height(Space.m))
        Text(
            "Your coding agents, projects, and AI usage. Together, wherever you are.",
            style = TsType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 320.dp),
        )
        Spacer(Modifier.weight(1f))
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = Space.l)
                .padding(bottom = Space.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            if (pending != null) {
                // The approval is happening in the browser tab. Shown for the
                // same reason iOS shows it: the tab can be dismissed while the
                // sign-in is alive underneath, and without this the screen would
                // look exactly as it did before the tap.
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    CircularProgressIndicator(color = colors.accent)
                    Text(
                        "Waiting for approval",
                        style = TsType.title3.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
                    Text(
                        notice ?: "Approve this device on tokenstat.ai. This screen updates by itself.",
                        style = TsType.subheadline,
                        color = colors.textSecondary,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        pending!!.code,
                        style = TsType.mono(20, FontWeight.SemiBold).copy(letterSpacing = 2.sp),
                        color = colors.textPrimary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(10.dp))
                            .background(colors.accentSoft)
                            .padding(vertical = Space.s, horizontal = Space.m),
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        TsSecondaryButton(
                            label = "Open the page",
                            icon = ActionIcon.External.vector,
                            small = true,
                            onClick = { model.presentSignInPage(::openPage) },
                        )
                        TsSecondaryButton(
                            label = "Cancel",
                            icon = ActionIcon.Dismiss.vector,
                            small = true,
                            onClick = { model.cancelSignIn() },
                        )
                    }
                }
            } else {
                // Prominent, and the only prominent button on the screen:
                // this is the door, and everything under it is a footnote to
                // it. Same weight the iPhone gives it.
                TsProminentButton(
                    label = "Sign in",
                    icon = ActionIcon.SignIn.vector,
                    onClick = { model.signIn(::openPage) },
                    modifier = Modifier.fillMaxWidth(),
                )
                // There is no separate "create account" button, and that is
                // not an omission: an account is made the first time somebody
                // signs in with a provider they already have. This line says
                // what happens instead of offering a fake choice.
                Text(
                    "No password to make. Signing in with GitHub, Google, X or Apple creates your account the first time.",
                    style = TsType.caption,
                    color = colors.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }
            val shown = signInError ?: error
            if (shown != null) {
                Text(
                    shown,
                    style = TsType.caption,
                    color = colors.danger,
                    textAlign = TextAlign.Center,
                )
            }
            // A way back to the intro, for anyone who skipped it and then
            // wondered what this is. A plain line of text like the iPhone's,
            // not a bordered box: a box here reads as a second offer beside
            // the one button this screen is for.
            TextButton(onClick = onReboard, modifier = Modifier.padding(top = Space.xs)) {
                Icon(
                    ActionIcon.Help.vector,
                    contentDescription = null,
                    tint = colors.accent,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(6.dp))
                Text("What is tokenstat?", style = TsType.subheadline, color = colors.accent)
            }
            // Signing in creates the account, so the two documents that govern
            // it belong on this screen and not only in Settings.
            LegalLine(onOpen = { openPage("$it?mobile=1") })
        }
    }
}

@Composable
private fun LegalLine(onOpen: (String) -> Unit, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    val terms = "Terms"
    val privacy = "Privacy policy"
    // Word for word with the iPhone's line, which reads it as one sentence
    // with two links in it rather than a sentence about two documents.
    val text = "By signing in you accept the $terms and $privacy"
    val annotated = remember {
        buildAnnotatedString {
            append(text)
            addStyle(
                SpanStyle(color = colors.accent, fontWeight = FontWeight.Medium),
                text.indexOf(terms),
                text.indexOf(terms) + terms.length,
            )
            addStringAnnotation("url", "https://tokenstat.ai/terms", text.indexOf(terms), text.indexOf(terms) + terms.length)
            addStyle(
                SpanStyle(color = colors.accent, fontWeight = FontWeight.Medium),
                text.indexOf(privacy),
                text.indexOf(privacy) + privacy.length,
            )
            addStringAnnotation("url", "https://tokenstat.ai/privacy", text.indexOf(privacy), text.indexOf(privacy) + privacy.length)
        }
    }
    ClickableText(
        annotated,
        style = TsType.caption.copy(color = colors.textTertiary, textAlign = TextAlign.Center),
        modifier = modifier.padding(top = Space.xs),
        onClick = { offset ->
            annotated.getStringAnnotations("url", offset, offset).firstOrNull()?.let { onOpen(it.item) }
        },
    )
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun SignedInApp(model: AppViewModel, state: ClientState) {
    var selected by rememberSaveable { mutableStateOf(Destination.Home) }
    var pendingWorkHostId by rememberSaveable { mutableStateOf<String?>(null) }
    var pendingWorkFolderId by rememberSaveable { mutableStateOf<String?>(null) }
    var accountOpen by remember { mutableStateOf(false) }
    var wizardOpen by remember { mutableStateOf(false) }
    var searchOpen by remember { mutableStateOf(false) }
    var pendingDeviceId by rememberSaveable { mutableStateOf<String?>(null) }
    var sshSignal by remember { mutableStateOf(0) }
    val context = LocalContext.current
    val homeStores = remember { HomeStores(context) }
    val billing = remember { PlayBillingManager(context) }
    billing.appAccountToken = state.appAccountToken
    billing.trialUsed = state.trialUsed
    billing.onActivated = { model.applyAccount(it) }
    DisposableEffect(billing) {
        billing.start()
        onDispose { billing.close() }
    }
    // The real window width, not the rounded Configuration value: the rail
    // appears exactly when the window is wide enough to carry both panes.
    val density = LocalDensity.current
    val expanded = with(density) {
        LocalWindowInfo.current.containerSize.width.toDp() >= 840.dp
    }
    // This device's tabs, arranged by the person holding it. Every tab is
    // shown to begin with, SSH included, which is the bar the iPhone gets.
    // Somebody who does not live in servers can still put it away in the tab
    // editor, and a phone that already stored a choice keeps it.
    val customization = remember(context) {
        TabCustomization(
            SharedPrefsTabs(context),
            Destination.entries.map { it.id },
            emptySet(),
        )
    }
    val displayed = customization.displayed(selected.id)
        .mapNotNull { id -> Destination.entries.find { it.id == id } }
    // Hiding the open tab lands on the first visible one rather than on a
    // blank bar. The editor refuses the last tab, so this is a move, never
    // a guess at nothing.
    LaunchedEffect(customization.visibleTabs) {
        if (displayed.none { it == selected }) selected = displayed.first()
    }
    // The tab bar gets out of the way while a list scrolls, like iOS, and
    // comes back at the top, on a tap, or when the tab changes.
    val tabBar = rememberTabBarMinimizeState()
    val tabBarScroll = rememberTabBarMinimizeScroll(tabBar)
    // A pushed screen (a conversation) takes the bar off the screen, the
    // way `clientTabBarHidden` does on iOS. Held here so the bar can read it
    // and any depth of screen can claim it.
    val tabBarPresence = remember { TabBarPresence() }
    // What the floating bar is glass over. Recorded from the tab content
    // only: the bar is its sibling, never its child, or the blur would be
    // sampling itself.
    val backdrop = rememberBackdrop()
    LaunchedEffect(selected) { tabBar.expand() }
    // A notification tap heads for Workspaces, like the Apple root: every
    // notification is about work on a machine, so the machine list is both
    // where the tap was heading and the screen that resolves it. Without
    // remote access there is nothing to resolve, so the tap is dropped and
    // the app simply stays where it is.
    val pushTap by NotificationOpen.request.collectAsStateWithLifecycle()
    LaunchedEffect(pushTap, state.canRemote) {
        if (pushTap == null) return@LaunchedEffect
        if (!state.canRemote) {
            NotificationOpen.take()
        } else if (selected != Destination.Workspaces) {
            selected = Destination.Workspaces
        }
    }

    val colors = LocalTsColors.current
    CompositionLocalProvider(LocalTabBarPresence provides tabBarPresence) {
    Scaffold(
        containerColor = colors.background,
        topBar = {
            // A pushed screen brings its own header. Stacking the wordmark
            // above it was two headers and a fifth of the screen.
            if (tabBarPresence.topHidden) return@Scaffold
            TopAppBar(
                // Avatar leading, wordmark centred: the same chrome shape as
                // the Apple client's toolbar.
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = colors.background,
                    titleContentColor = colors.textPrimary,
                    navigationIconContentColor = colors.textPrimary,
                    actionIconContentColor = colors.textPrimary,
                ),
                title = {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        Wordmark(size = 22, showsMark = true)
                    }
                },
                navigationIcon = {
                    // Ringed, the way the Apple toolbar rings it: the photo
                    // needs an edge of its own or it bleeds into the
                    // background on a light theme.
                    IconButton(onClick = { accountOpen = true }) {
                        Box(
                            Modifier
                                .size(38.dp)
                                .shadow(2.dp, CircleShape)
                                .clip(CircleShape)
                                .background(colors.panel),
                            contentAlignment = Alignment.Center,
                        ) {
                        Avatar(
                            state.account?.string("displayName") ?: state.account?.string("handle") ?: "your account",
                            size = 34,
                            avatarUrl = state.account?.string("avatar"),
                            signedIn = state.signedIn,
                        )
                        }
                    }
                },
                actions = {
                    // A chip, not a naked glyph. On iPhone this is a circular
                    // raised surface and it reads as a control; the bare icon
                    // beside a wordmark read as part of the decoration.
                    IconButton(onClick = { searchOpen = true }) {
                        Box(
                            Modifier
                                .size(34.dp)
                                .shadow(2.dp, CircleShape)
                                .clip(CircleShape)
                                .background(colors.panel),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                ActionIcon.Search.vector,
                                "Search",
                                tint = colors.accent,
                                modifier = Modifier.size(19.dp),
                            )
                        }
                    }
                    ConnectionChip(state.connection, onRetry = { model.retryConnection() })
                    // No refresh button: like iOS, every tab refreshes with
                    // a pull, and the wordmark dips while it runs.
                },
            )
        },
    ) { padding ->
        // The bar floats over the tab content like the iOS 26 dock: rows
        // scroll behind its glass, and every scrollable under it ends at
        // `TabBarChrome.contentBottomInset` so the last row rests clear of it.
        Box(
            Modifier.fillMaxSize()
                .padding(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding()),
        ) {
        Row(Modifier.fillMaxSize().backdropSource(backdrop)) {
            if (expanded) {
                NavigationRail(containerColor = colors.tabStrip, contentColor = colors.textSecondary) {
                    Spacer(Modifier.height(8.dp))
                    displayed.forEach { destination ->
                        NavigationRailItem(
                            selected = selected == destination,
                            onClick = { selected = destination },
                            icon = { Icon(destination.icon, null) },
                            label = { Text(destination.label) },
                            colors = NavigationRailItemDefaults.colors(
                                selectedIconColor = colors.accent,
                                selectedTextColor = colors.accent,
                                indicatorColor = colors.accentSoft,
                                unselectedIconColor = colors.controlGlyph,
                                unselectedTextColor = colors.controlGlyph,
                            ),
                        )
                    }
                }
            }
            Box(Modifier.weight(1f).fillMaxHeight()) {
                // Tab switches crossfade like the iOS TabView: a short
                // fade with the door easing. A fade stays readable under
                // Reduce Motion, so no second path is needed.
                AnimatedContent(
                    targetState = selected,
                    transitionSpec = {
                        fadeIn(TsMotion.door()) togetherWith fadeOut(TsMotion.door())
                    },
                    label = "destination",
                ) { destination ->
                when (destination) {
                    Destination.Home -> HomeScreen(
                        model = model,
                        state = state,
                        stores = homeStores,
                        tabBarScroll = tabBarScroll,
                        onOpenWork = { hostId, folderId ->
                            pendingWorkHostId = hostId
                            pendingWorkFolderId = folderId
                            selected = Destination.Workspaces
                        },
                        onOpenDevices = { selected = Destination.Devices },
                        onSetupWizard = { wizardOpen = true },
                        onSignIn = {
                            model.signIn { url ->
                                runCatching {
                                    CustomTabsIntent.Builder().build().launchUrl(context, url.toUri())
                                }
                            }
                        },
                    )
                    Destination.Workspaces -> if (state.canRemote) {
                        WorkspacesScreen(
                            model = model,
                            state = state,
                            expanded = expanded,
                            tabBarScroll = tabBarScroll,
                            pendingHostId = pendingWorkHostId,
                            pendingFolderId = pendingWorkFolderId,
                            stores = homeStores,
                            onPendingConsumed = {
                                pendingWorkHostId = null
                                pendingWorkFolderId = null
                            },
                            onSetupWizard = { wizardOpen = true },
                            onOpenDevice = { id ->
                                pendingDeviceId = id
                                selected = Destination.Devices
                            },
                        )
                    } else {
                        RemoteGateScreen(
                            signedIn = state.signedIn,
                            onPlans = { Plans.open() },
                        )
                    }
                    Destination.Insights -> InsightsScreen(model, state, onHome = { selected = Destination.Home }, tabBarScroll = tabBarScroll)
                    Destination.Devices -> DevicesScreen(
                        model,
                        state,
                        tabBarScroll = tabBarScroll,
                        onPlans = { Plans.open() },
                        onOpenWork = { id ->
                            pendingWorkHostId = id
                            selected = Destination.Workspaces
                        },
                        onSetupWizard = { wizardOpen = true },
                        sshOpenSignal = sshSignal,
                        pendingDeviceId = pendingDeviceId,
                        onPendingDeviceConsumed = { pendingDeviceId = null },
                    )
                    // Saved servers, for somebody who lives in them. No back
                    // button: the bar behind it is the way out.
                    Destination.Ssh -> AndroidSSHScreen(model, state, onPlans = { Plans.open() }, tabBarScroll = tabBarScroll)
                }
                }
            }
        }
        if (!expanded && !tabBarPresence.hidden) {
            FloatingTabBar(
                selected = displayed.indexOf(selected).coerceAtLeast(0),
                tabs = displayed.map { TabSpec(it.label, it.icon) },
                onSelect = { selected = displayed[it] },
                minimized = tabBar.minimized,
                onExpandRequest = { tabBar.expand() },
                backdrop = backdrop,
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
        }
    }
    }
    if (searchOpen) {
        WorkSearchSheet(
            model = model,
            state = state,
            stores = homeStores,
            onOpen = { open ->
                when (open) {
                    is SearchOpen.Tab -> selected = when (open.name) {
                        "home" -> Destination.Home
                        "workspaces" -> Destination.Workspaces
                        "insights" -> Destination.Insights
                        "ssh" -> Destination.Ssh
                        else -> Destination.Devices
                    }
                    is SearchOpen.Device -> {
                        pendingDeviceId = open.machineId
                        selected = Destination.Devices
                    }
                    SearchOpen.Account -> accountOpen = true
                    is SearchOpen.Folder -> {
                        pendingWorkHostId = open.hostId
                        pendingWorkFolderId = open.folderId
                        selected = Destination.Workspaces
                    }
                }
            },
            onDismiss = { searchOpen = false },
        )
    }
    if (accountOpen) AccountDialog(state, model, billing, customization, onDismiss = { accountOpen = false })
    // The one paywall for every gate outside the account sheet. Hosted here
    // so a lock anywhere in the app reaches the plans in one tap instead of
    // opening Account and asking somebody to find the card. See `Plans`.
    val planRequests by Plans.openRequests.collectAsStateWithLifecycle()
    var planRequestSeen by rememberSaveable { mutableStateOf(planRequests) }
    // Greater, not different: the counter resets to zero when the process
    // dies while the seen mark restores, and `!=` would open the sheet on
    // its own on the next launch.
    val planSheetOpen = planRequests > planRequestSeen
    if (planSheetOpen && !accountOpen) {
        PaywallSheet(
            billing = billing,
            onDismiss = { planRequestSeen = planRequests },
            currentTier = state.account?.string("tier"),
            currentInterval = run {
                val serverBilling = state.account?.get("billing") as? JsonObject
                when {
                    serverBilling?.string("interval") == PlayBillingManager.INTERVAL_MONTH ->
                        PlayBillingManager.INTERVAL_MONTH
                    state.account?.string("tier")?.lowercase() in listOf("supporter", "patron", "legend") ->
                        PlayBillingManager.INTERVAL_YEAR
                    else -> null
                }
            },
        )
    }
    if (wizardOpen) {
        SetupWizard(
            model = model,
            state = state,
            onClose = { wizardOpen = false },
            onOpenSsh = {
                wizardOpen = false
                selected = Destination.Devices
                sshSignal += 1
            },
            onOpenWork = { hostId, folderId ->
                wizardOpen = false
                pendingWorkHostId = hostId
                pendingWorkFolderId = folderId
                selected = Destination.Workspaces
            },
        )
    }
}

/// Remote work, on an account whose plan does not include it. Port of the
/// `needsAccount` empty state in `ClientWorkspacesView`.
///
/// The same card every other empty screen uses, so "the answer is no, and
/// upgrading is the fix" is told in the app's own language rather than by a
/// centred paragraph with a button under it. Signed out is a different
/// answer and gets a different sentence: quoting a plan at somebody who has
/// not signed in tells them to buy their way out of a sign-in screen.
@Composable
private fun RemoteGateScreen(signedIn: Boolean, onPlans: () -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .padding(Space.l),
        verticalArrangement = Arrangement.Center,
    ) {
        if (signedIn) {
            EmptyState(
                kind = EmptyKind.NeedsAccount,
                title = "Remote is on Patron",
                message = "This device already shares the account and sees the usage from " +
                    "every device on it. Opening folders and terminals on the computer is " +
                    "a paid feature.",
                art = { EmptyArt(EmptyArtKind.RemoteGate) },
                action = {
                    TsAccentButton(
                        label = "See plans",
                        icon = ActionIcon.Plans.vector,
                        onClick = onPlans,
                    )
                },
            )
        } else {
            EmptyState(
                kind = EmptyKind.NeedsAccount,
                title = "Sign in to reach your computers",
                message = "Remote work runs over your account. Sign in on this device and " +
                    "the computers on it show up here.",
                art = { EmptyArt(EmptyArtKind.RemoteGate) },
            )
        }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun HomeScreen(
    model: AppViewModel,
    state: ClientState,
    stores: HomeStores,
    onOpenWork: (hostId: String, folderId: String?) -> Unit,
    onOpenDevices: () -> Unit,
    onSetupWizard: (() -> Unit)? = null,
    onSignIn: (() -> Unit)? = null,
    tabBarScroll: NestedScrollConnection? = null,
) {
    val calendar = state.home
    val rows = calendar?.get("rows") as? JsonArray
    val cells = rows.orEmpty().flatMap { row ->
        (row as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
    }
    var selectedDay by remember { mutableStateOf<JsonObject?>(null) }
    // A hold is picking a day out of the grid: the page holds still while
    // it does, or the page fights the finger. Mirrors `pickingADay`.
    var pickingDay by remember { mutableStateOf(false) }
    var customizing by rememberSaveable { mutableStateOf(false) }
    val reduceMotion = rememberReduceMotion()
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    fun retry() {
        scope.launch {
            refreshing = true
            TsRefresh.run("home") { model.refresh() }
            refreshing = false
        }
    }

    val accountHandle = state.account?.string("handle")
        ?: state.account?.string("displayName") ?: ""
    // Device furniture scopes to the account's host and identity, the same
    // key the Apple client reads and writes.
    val accountIdentity = RecentPlaces.accountIdentity(
        state.account?.string("handle"),
        state.account?.string("accountId"),
    )
    val accountHost = state.account?.string("host").orEmpty()
    // Read once for the whole pass. The stores decode on every access, and
    // reading them again inside the rows is what lets a list change shape
    // underneath.
    stores.revision.value
    val (order, hidden) = stores.layout()
    val sections = order.filter { it !in hidden }
    val places = stores.places(accountIdentity, accountHost)
    val pins = stores.pins(accountHandle)
    val machines = ((state.account?.get("machines") as? JsonArray).orEmpty())
        .mapNotNull { it as? JsonObject }
    val thisId = state.account?.string("thisMachineId")
    fun machineByPeer(peer: String): JsonObject? =
        machines.find { it.string("publicIdentity") == peer }
    fun machineName(peer: String): String? =
        machineByPeer(peer)?.let {
            DeviceCopy.displayName(it.string("label"), it.string("platform"), it.string("kind") != "client")
        }
    fun machineOnline(peer: String): Boolean? =
        machineByPeer(peer)?.get("online")?.jsonPrimitive?.booleanOrNull
    val awakeHosts = machines.filter { machine ->
        val id = machine.string("id")
        machine.string("kind") != "client" && machine.bool("online") &&
            !id.isNullOrEmpty() && id != thisId
    }.map { machine ->
        HomeMachine(
            id = machine.string("id") ?: "",
            peer = machine.string("publicIdentity"),
            name = DeviceCopy.displayName(machine.string("label"), machine.string("platform"), true),
            online = machine.get("online")?.jsonPrimitive?.booleanOrNull,
            label = machine.string("label"),
            platform = machine.string("platform"),
        )
    }
    fun openPlace(peer: String, workspaceId: String?) {
        val id = machineByPeer(peer)?.string("id")
        if (id != null) onOpenWork(id, workspaceId) else onOpenDevices()
    }
    fun emptyReason(section: HomeSection): String? = when (section) {
        HomeSection.CONTINUE -> if (places.isEmpty()) "Appears after you open a folder or conversation." else null
        HomeSection.PINNED -> if (pins.isEmpty()) "Pin a folder or conversation to keep it here." else null
        HomeSection.MACHINES -> if (machines.isEmpty()) "Appears when your account has linked devices." else null
        HomeSection.LIMITS -> if (state.limits.isEmpty() && state.limitsError == null) {
            "Readings appear after a linked computer shares plan limits."
        } else null
        else -> null
    }

    if (customizing) {
        HomeEditor(
            order = order,
            hidden = hidden,
            preset = stores.preset(),
            emptyReason = ::emptyReason,
            onDone = { nextOrder, nextHidden, nextPreset ->
                stores.saveLayout(nextOrder, nextHidden, nextPreset)
                customizing = false
            },
            onCancel = { customizing = false },
        )
        return
    }
    PullToRefreshBox(
        isRefreshing = refreshing,
        onRefresh = { retry() },
        modifier = if (tabBarScroll == null) Modifier.fillMaxSize() else Modifier.fillMaxSize().nestedScroll(tabBarScroll),
    ) {
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = cardPaddingDp, top = cardPaddingDp, end = cardPaddingDp, bottom = cardPaddingDp + TabBarChrome.contentBottomInset),
        verticalArrangement = Arrangement.spacedBy(Space.m),
        userScrollEnabled = !pickingDay,
    ) {
        item {
            // Same line the website and the Apple home use: a local-clock
            // phrase, the first name, and the tier mark next to it.
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                Text(
                    homeGreeting(state.account, cells.isNotEmpty()),
                    style = MaterialTheme.typography.headlineSmall,
                    color = LocalTsColors.current.textPrimary,
                    maxLines = 2,
                    modifier = Modifier.weight(1f, fill = false),
                )
                val tier = state.account?.string("tier")
                if (!tier.isNullOrEmpty()) {
                    TierMark(tier.lowercase(), markSize = 16)
                }
            }
        }
        // Outside the arrangement, deliberately. Whether the account could
        // be read at all is the screen talking, not a card somebody chose
        // to keep, and hiding Activity must not hide "you are offline".
        if (calendar == null && !state.loading) {
            if (state.error == null && state.signedIn) {
                item {
                    val phoneName = machines.firstOrNull { it.string("kind") == "client" }?.let {
                        DeviceCopy.displayName(it.string("label"), it.string("platform"), false)
                    }
                    GettingStartedCard(phoneName = phoneName, onSetup = onSetupWizard ?: onOpenDevices)
                }
            } else {
                item { HomeStatusBlock(state.error, state.connection.offline, onRetry = ::retry) }
            }
        }
        // In the order this device was arranged in. A card with nothing to
        // say draws nothing and keeps its place.
        sections.forEach { section ->
            when (section) {
                HomeSection.USAGE -> if (calendar != null) {
                    item {
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.m)) {
                            TotalTile("Today", money(spendSince(cells, calendar.string("last"), 1)), "mark_day", Modifier.weight(1f))
                            TotalTile("This week", money(spendSince(cells, calendar.string("last"), 7)), "mark_week", Modifier.weight(1f))
                        }
                    }
                } else if (state.loading) {
                    item { SkeletonCard() }
                }
                HomeSection.CONTINUE -> if (places.isNotEmpty()) {
                    item {
                        ContinueSection(
                            places = places,
                            machineName = ::machineName,
                            machineOnline = ::machineOnline,
                            offline = state.connection.offline,
                            onOpen = { place -> openPlace(place.id.peer, place.id.workspaceId) },
                            isPinned = { place ->
                                stores.isPinned(
                                    accountHandle, place.id.peer, place.id.workspaceId ?: "",
                                    if (place.id.kind == RecentPlaces.Kind.CHAT) PinnedWork.Kind.CONVERSATION else PinnedWork.Kind.WORKSPACE,
                                    place.id.itemId,
                                )
                            },
                            onTogglePin = { place ->
                                stores.togglePin(
                                    accountHandle, place.id.peer, place.id.workspaceId ?: "",
                                    if (place.id.kind == RecentPlaces.Kind.CHAT) PinnedWork.Kind.CONVERSATION else PinnedWork.Kind.WORKSPACE,
                                    place.id.itemId,
                                    RecentPlaces.title(place),
                                    place.workspaceName,
                                )
                            },
                        )
                    }
                }
                HomeSection.MACHINES -> if (awakeHosts.isNotEmpty()) {
                    item {
                        MachinesSection(
                            machines = awakeHosts,
                            onOpenWork = { id -> onOpenWork(id, null) },
                            onOpenDevices = onOpenDevices,
                        )
                    }
                }
                HomeSection.PINNED -> if (pins.isNotEmpty()) {
                    item {
                        PinnedSection(
                            pins = pins,
                            machineName = ::machineName,
                            machineOnline = ::machineOnline,
                            offline = state.connection.offline,
                            onOpen = { pin -> openPlace(pin.hostIdentity, pin.workspaceId) },
                            onUnpin = { pin -> stores.unpin(accountHandle, pin) },
                        )
                    }
                }
                HomeSection.ACTIVITY -> if (calendar != null) {
                    item {
                        Arrive(reduceMotion) {
                            Column(
                                Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(cardRadiusDp))
                                    .tsPanel()
                                    .padding(Space.m),
                                verticalArrangement = Arrangement.spacedBy(Space.s),
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    SectionTitle("Activity", "mark_activity")
                                    Spacer(Modifier.weight(1f))
                                    Column(horizontalAlignment = Alignment.End) {
                                        Text(
                                            "${calendar.int("activeDays") ?: 0} active days",
                                            style = TsType.caption,
                                            color = LocalTsColors.current.textSecondary,
                                        )
                                        // The host sends the fetch stamp, not
                                        // the sentence: the client phrases it.
                                        calendarFreshness(
                                            calendar.long("fetchedAtMs"),
                                            calendar.string("noticeCode"),
                                        )?.let { (freshness, stale) ->
                                            Text(
                                                freshness,
                                                style = TsType.caption,
                                                color = if (stale) LocalTsColors.current.warning
                                                else LocalTsColors.current.textSecondary.copy(alpha = 0.8f),
                                            )
                                        }
                                    }
                                }
                                if (cells.isEmpty()) Text("No synced activity yet.", color = LocalTsColors.current.textSecondary)
                                else {
                                    YearHeatmap(
                                        rows!!,
                                        calendar.get("months") as? JsonArray ?: JsonArray(emptyList()),
                                        onSelectDay = { selectedDay = it },
                                        onScrub = { pickingDay = it },
                                    )
                                }
                            }
                        }
                    }
                    // The same Free-year note the public profile puts under the heatmap.
                    if (rows.orEmpty().any { (it as? JsonArray).orEmpty().any { c -> (c as? JsonObject)?.bool("locked") == true } }) {
                        item { HistoryLockBanner() }
                    }
                } else if (state.loading) {
                    item { SkeletonCard() }
                }
                HomeSection.LIMITS -> if (calendar != null) {
                    item { SectionTitle("Plan limits", "mark_plan") }
                    val planError = state.limitsError
                    if (planError != null) {
                        item {
                            Text(
                                "Plan readings could not be refreshed. Pull to try again.",
                                style = TsType.caption,
                                color = LocalTsColors.current.controlGlyph,
                            )
                        }
                    }
                    // Only providers with an actual reading. A host posts
                    // readings only when sharing is on, so windowless rows
                    // stay off this screen the way they do on the Apple one.
                    val sorted = LimitLogic.closestToFullFirst(
                        state.limits.mapNotNull { it as? JsonObject }.filter { reading ->
                            ((reading["windows"] as? JsonArray).orEmpty()).isNotEmpty()
                        },
                    ) { reading ->
                        LimitLogic.peakPercent(
                            ((reading["windows"] as? JsonArray).orEmpty())
                                .mapNotNull { (it as? JsonObject)?.doubleOrNull("percent") },
                        )
                    }
                    if (sorted.isEmpty() && planError == null) {
                        item {
                            // Not an error. Until a host shares readings the
                            // honest line is empty, not zero.
                            Text(
                                "No readings yet. On a Mac, turn on Share plan limits with my devices in Account, then refresh limits or sync.",
                                style = TsType.subheadline,
                                color = LocalTsColors.current.textSecondary,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    } else itemsIndexed(sorted) { index, reading ->
                        Arrive(reduceMotion, staggerIndex = index) { LimitCard(reading) }
                    }
                }
            }
        }
        if (sections.isEmpty()) {
            item { ClearHomeCard() }
        }
        // A sentence the host sent about why this is not the answer that
        // was asked for, with a sign-in button when signing in is the fix.
        val notice = calendar?.string("notice")
        if (calendar != null && notice != null) {
            item {
                NoticeCard(
                    text = notice,
                    showSignIn = calendar.string("noticeCode") == "auth" && onSignIn != null,
                    onSignIn = { onSignIn?.invoke() },
                )
            }
        }
        item {
            // At the bottom, under everything it arranges. A control for
            // changing the furniture does not belong above the furniture.
            TsSecondaryButton(
                label = "Customize Home",
                onClick = { customizing = true },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
    }
    DayDetailSheet(selectedDay, onDismiss = { selectedDay = null })
}

/// A sentence the host sent about why this is not the answer that was asked
/// for, with a sign-in button when signing in is the fix. Ported from
/// `NoticeCard` in `ClientHomeView.swift`.
@Composable
private fun NoticeCard(text: String, showSignIn: Boolean, onSignIn: () -> Unit) {
    val colors = LocalTsColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .tsPanel()
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(Space.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Outlined.Info,
                contentDescription = null,
                tint = colors.textSecondary,
                modifier = Modifier.size(16.dp),
            )
            Text(text, style = TsType.caption, color = colors.textSecondary)
        }
        if (showSignIn) {
            TsSecondaryButton(label = "Sign in", icon = ActionIcon.SignIn.vector, onClick = onSignIn)
        }
    }
}

/// The `smoothIn` arrival of loaded content replacing its skeleton: a short
/// fade with a small rise, collapsing to a plain fade under Reduce Motion.
@Composable
fun Arrive(reduceMotion: Boolean, staggerIndex: Int = 0, content: @Composable () -> Unit) {
    val visibleState = remember { MutableTransitionState(false).apply { targetState = true } }
    LaunchedEffect(Unit) {
        if (staggerIndex > 0) delay(staggerIndex * 40L)
        visibleState.targetState = true
    }
    AnimatedVisibility(visibleState = visibleState, enter = smoothEnter(reduceMotion)) { content() }
}

/// The Free-tier history-lock note under the heatmap
/// (`HistoryLockBanner.swift`).
///
/// Not a wall. The year is already on screen. This says why the older squares
/// are muted and offers the sheet that unlocks them.
///
/// **One paragraph, not two labels in a row.** The lead-in and the
/// explanation are one sentence that wraps, the way the Apple banner
/// concatenates its two runs. Side by side in a `Row` they cannot wrap into
/// each other, so on a narrow phone the second one was squeezed to a column
/// of single words or clipped off the edge entirely.
@Composable
private fun HistoryLockBanner(days: Int = 30) {
    val colors = LocalTsColors.current
    val note = remember(days, colors.textPrimary, colors.textSecondary) {
        buildAnnotatedString {
            withStyle(SpanStyle(color = colors.textPrimary, fontWeight = FontWeight.SemiBold)) {
                append("Older history is locked. ")
            }
            withStyle(SpanStyle(color = colors.textSecondary)) {
                append("Free shows the last $days days in full. Older days keep the year shape only.")
            }
        }
    }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.accentSoft.copy(alpha = 0.55f))
            .border(1.dp, colors.border, RoundedCornerShape(10.dp))
            .padding(horizontal = Space.m, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(note, style = TextStyle(fontSize = 12.sp))
        // The in-app sheet, not the pricing page. A plan on this platform is
        // a Play subscription, and a link out of the app is a route nobody
        // can buy from. See `Plans`.
        Text(
            "See plans",
            style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold),
            color = colors.accent,
            modifier = Modifier.clickable(
                indication = null,
                interactionSource = remember { MutableInteractionSource() },
            ) { Plans.open() },
        )
    }
}

/// Spend across the trailing `days` ending on `last`, the way the Apple
/// client's Today and This week tiles read the same grid.
private fun spendSince(cells: List<JsonObject>, last: String?, days: Int): Long {
    if (last == null) return 0
    val window = cells.mapNotNull { it.string("date") }
        .filter { it.isNotBlank() }
        .distinct()
        .sortedDescending()
        .take(days)
        .toSet()
    return cells.filter { it.string("date") in window }.sumOf { it.long("value") ?: 0L }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun InsightsScreen(
    model: AppViewModel,
    state: ClientState,
    onHome: () -> Unit,
    tabBarScroll: NestedScrollConnection? = null,
) {
    val colors = LocalTsColors.current
    val reduceMotion = rememberReduceMotion()
    // Three cuts only — Models/Harnesses/Days — the privacy boundary the iOS
    // client draws: the account holds no projects and no sessions.
    var cut by rememberSaveable { mutableStateOf(0) }
    var query by rememberSaveable { mutableStateOf("") }
    val cutNames = listOf("Models", "Harnesses", "Days")
    val cutKeys = listOf("model", "source", "day")
    // Rows per cut. Null means "not asked yet", which is not the same as an
    // empty account and must not draw like one.
    val cached = remember { mutableStateMapOf<String, List<JsonObject>>() }
    var isLoading by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var needsSignIn by remember { mutableStateOf(false) }
    var fetchedAtMs by remember { mutableStateOf<Long?>(null) }
    var stale by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    suspend fun fetch(asked: Int) {
        isLoading = true
        runCatching { model.accountReport(cutKeys[asked]) }
            .onSuccess { report ->
                cached[cutKeys[asked]] = (report["rows"] as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
                fetchedAtMs = report["fetchedAtMs"]?.jsonPrimitive?.longOrNull
                stale = report["stale"]?.jsonPrimitive?.booleanOrNull == true
                if (asked == cut) {
                    errorMessage = null
                    needsSignIn = false
                }
            }
            .onFailure {
                if (asked == cut) {
                    val text = it.message ?: "The request failed."
                    needsSignIn = text.contains("sign in", ignoreCase = true)
                    errorMessage = text
                }
            }
        if (asked == cut) isLoading = false
    }
    LaunchedEffect(cut) {
        // Each cut keeps its own rows, so going back to one already seen is
        // instant and costs nothing.
        if (!cached.containsKey(cutKeys[cut])) fetch(cut)
    }
    fun refresh() {
        scope.launch {
            // Drop everything rather than the current cut alone: they are
            // three views of one series.
            cached.clear()
            fetch(cut)
        }
    }
    val rows = cached[cutKeys[cut]]
    val term = query.trim()
    val shown = rows.orEmpty().filter { row ->
        val key = row.string("key") ?: ""
        term.isBlank() || key.contains(term, ignoreCase = true) ||
            cutTitle(cut, key).contains(term, ignoreCase = true)
    }
    // A share bar needs something to be a share of, and the largest shown
    // row is a steadier reference than the total.
    val peak = shown.maxOfOrNull { it.long("valueMicros") ?: 0L } ?: 1L
    PullToRefreshBox(
        isRefreshing = isLoading,
        onRefresh = { scope.launch { TsRefresh.run("insights") { cached.clear(); fetch(cut) } } },
        modifier = if (tabBarScroll == null) Modifier.fillMaxSize() else Modifier.fillMaxSize().nestedScroll(tabBarScroll),
    ) {
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = cardPaddingDp, top = cardPaddingDp, end = cardPaddingDp, bottom = cardPaddingDp + TabBarChrome.contentBottomInset),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        item {
            // The field first, then the cut: long identifiers are exactly
            // the thing worth filtering. The prompt names the cut in
            // lowercase, where "Filter models" reads as a description of
            // the field and "Filter Models" would read as a command.
            // The app's own search field, not a bare Material box: every
            // other place you type a filter here has a magnifier in front of
            // it and a clear button once there is something to clear, and
            // this one looked like a stray text input beside them.
            TsSearchField(
                prompt = "Filter ${cutNames[cut].lowercase()}",
                query = query,
                onQueryChange = { query = it },
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(Space.s))
            SegmentedCapsulePicker(
                options = cutNames.mapIndexed { i, name -> Triple(i, name, null as ImageVector?) },
                selection = cut,
                onSelect = { cut = it },
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (rows == null) {
            if (isLoading) {
                item { SkeletonRows(count = 5) }
            } else if (errorMessage != null) {
                item {
                    val offline = state.connection.offline
                    EmptyState(
                        // Refused and unreachable are different answers and
                        // must not read alike.
                        kind = if (needsSignIn) EmptyKind.NeedsAccount else EmptyKind.Unreachable,
                        title = if (offline) "You are offline" else "Could not load your usage",
                        message = if (offline) {
                            "This updates by itself when the connection is back."
                        } else {
                            friendlyError(errorMessage).message
                        },
                        action = if (!offline) {
                            {
                                TsAccentButton(
                                    label = "Try again",
                                    icon = ActionIcon.Refresh.vector,
                                    small = true,
                                    onClick = { refresh() },
                                )
                            }
                        } else {
                            null
                        },
                    )
                }
            }
        } else if (rows.isEmpty()) {
            // Not a dead end. An account with nothing on it has one thing
            // to do next, and it is on Home.
            item {
                EmptyState(
                    icon = Icons.Default.BarChart,
                    title = "Nothing recorded yet",
                    message = "Add a computer to this account and what it counts shows up here.",
                    art = { EmptyArt(EmptyArtKind.FirstBars) },
                    action = {
                        TsAccentButton(
                            label = "How to start",
                            icon = ActionIcon.Home.vector,
                            small = true,
                            onClick = onHome,
                        )
                    },
                )
            }
        } else {
            item {
                Arrive(reduceMotion) {
                    InsightSummary(
                        rows = rows,
                        cutName = cutNames[cut],
                        stale = stale,
                        fetchedAtMs = fetchedAtMs,
                    )
                }
            }
            if (cut == 2) {
                item {
                    Arrive(reduceMotion) {
                        InsightDayChart(rows = rows)
                    }
                }
            }
            if (shown.isEmpty()) {
                item {
                    Text(
                        "Nothing matches \"$term\".",
                        style = TsType.subheadline,
                        color = colors.textSecondary,
                    )
                }
            } else {
                item { SectionTitle(cutNames[cut], "mark_insights") }
                itemsIndexed(shown) { index, row ->
                    Arrive(reduceMotion, staggerIndex = index.coerceAtMost(8)) {
                        InsightRow(row = row, cut = cut, peak = peak)
                    }
                }
            }
        }
    }
    }
}

/// A row's key as a person reads it, port of `Cut.title`: a harness id is
/// a slug, and a day is an ISO date nobody says out loud. Cut 0 models,
/// 1 harnesses, 2 days.
private fun cutTitle(cut: Int, key: String): String = when (cut) {
    1 -> harnessName(key)
    2 -> shortDate(key)
    else -> key
}

/// "This period": the total at list rates plus the three fact panels, like
/// the iOS summary. A remembered answer says how old it is.
@Composable
private fun InsightSummary(rows: List<JsonObject>, cutName: String, stale: Boolean, fetchedAtMs: Long?) {
    val colors = LocalTsColors.current
    val total = rows.sumOf { it.long("valueMicros") ?: 0L }
    val estimated = rows.any { it["estimated"]?.jsonPrimitive?.booleanOrNull == true }
    val complete = rows.all { ((it["unpricedModels"] as? JsonArray)?.size ?: 0) == 0 }
    val tokens = rows.sumOf { it["counters"]?.jsonObject?.long("total") ?: 0L }
    val events = rows.sumOf { it.long("events") ?: 0L }
    TsCard {
        Column(verticalArrangement = Arrangement.spacedBy(Space.m)) {
            SectionTitle("This period", "mark_insights")
            Text(
                moneyValue(total, estimated, complete),
                style = TsType.numeric(34, FontWeight.SemiBold),
                color = tsAccent(),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "at list rates, across every device",
                style = TsType.caption,
                color = colors.textSecondary,
            )
            InsightStatPanels(insightFactPanels(tokens, events, rows.size, cutName) { compactTokens(it) })
            if (stale && fetchedAtMs != null) {
                Text(
                    "The refresh did not go through. Showing what this device last fetched, " +
                        "${RelativeClock.label(fetchedAtMs, System.currentTimeMillis())}.",
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

/// Tokens per day as bars, the Day cut's chart on iOS. Drawn on a Canvas:
/// 53 accent bars need no chart dependency.
@Composable
private fun InsightDayChart(rows: List<JsonObject>) {
    val colors = LocalTsColors.current
    val days = rows.sortedBy { it.string("key") ?: "" }
    val peak = days.maxOfOrNull { it["counters"]?.jsonObject?.long("total") ?: 0L } ?: 0L
    TsCard {
        val bars = days.map { it["counters"]?.jsonObject?.long("total") ?: 0L }
        Column(verticalArrangement = Arrangement.spacedBy(Space.m)) {
        SectionTitle("Daily activity", "mark_activity")
        Text(
            "Tokens per day · cache included",
            style = MaterialTheme.typography.bodySmall,
            color = colors.textSecondary,
        )
        Canvas(Modifier.fillMaxWidth().height(180.dp)) {
            if (bars.isEmpty() || peak <= 0) return@Canvas
            val gap = 2.dp.toPx()
            val width = (size.width - gap * (bars.size - 1).coerceAtLeast(0)) / bars.size
            val brush = androidx.compose.ui.graphics.Brush.verticalGradient(
                listOf(colors.accent, colors.accent.copy(alpha = 0.55f)),
            )
            bars.forEachIndexed { index, total ->
                val height = (total.toFloat() / peak) * size.height
                drawRoundRect(
                    brush = brush,
                    topLeft = Offset(index * (width + gap), size.height - height),
                    size = Size(width.coerceAtLeast(1f), height.coerceAtLeast(0f)),
                    cornerRadius = CornerRadius(3.dp.toPx()),
                )
            }
        }
        Row {
            Text(
                days.firstOrNull()?.string("key") ?: "",
                style = MaterialTheme.typography.bodySmall,
                color = colors.textSecondary,
            )
            Spacer(Modifier.weight(1f))
            Text(
                days.lastOrNull()?.string("key") ?: "",
                style = MaterialTheme.typography.bodySmall,
                color = colors.textSecondary,
            )
        }
        }
    }
}

/// One breakdown row: what it is, what it was worth, and how big a share
/// of the largest shown row that is.
@Composable
private fun InsightRow(row: JsonObject, cut: Int, peak: Long) {
    val colors = LocalTsColors.current
    val value = row.long("valueMicros") ?: 0L
    val share = if (peak > 0) (value.toFloat() / peak).coerceIn(0f, 1f) else 0f
    val complete = ((row["unpricedModels"] as? JsonArray)?.size ?: 0) == 0
    val estimated = row["estimated"]?.jsonPrimitive?.booleanOrNull == true
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .border(1.dp, colors.border, RoundedCornerShape(cardRadiusDp))
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (cut == 1) {
                HarnessMark(id = row.string("key") ?: "")
                Spacer(Modifier.width(Space.s))
            }
            Column(Modifier.weight(1f)) {
                Text(
                    cutTitle(cut, row.string("key") ?: ""),
                    style = TsType.subheadline,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                val tokens = row["counters"]?.jsonObject?.long("total") ?: 0L
                val events = row.long("events") ?: 0L
                Text(
                    "${compactTokens(tokens)} tokens, ${groupedCount(events)} events",
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            }
            Spacer(Modifier.width(Space.s))
            Text(moneyValue(value, estimated, complete), color = tsAccent(), style = TsType.numeric(16))
        }
        // A quiet share bar in the accent, not a system meter.
        Box(
            Modifier
                .fillMaxWidth()
                .height(4.dp)
                .clip(RoundedCornerShape(50))
                .background(colors.accentSoft),
        ) {
            val animated by animateFloatAsState(share, tween(320), label = "shareBar")
            Box(
                Modifier
                    .fillMaxWidth(animated)
                    .height(4.dp)
                    .clip(RoundedCornerShape(50))
                    .background(colors.accent.copy(alpha = 0.55f)),
            )
        }
    }
}

@Composable
private fun DevicesScreen(
    model: AppViewModel,
    state: ClientState,
    onPlans: () -> Unit,
    onOpenWork: (String) -> Unit,
    onSetupWizard: () -> Unit = {},
    sshOpenSignal: Int = 0,
    pendingDeviceId: String? = null,
    onPendingDeviceConsumed: () -> Unit = {},
    tabBarScroll: NestedScrollConnection? = null,
) {
    var sshOpen by rememberSaveable { mutableStateOf(false) }
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    LaunchedEffect(sshOpenSignal) {
        if (sshOpenSignal > 0) sshOpen = true
    }
    LaunchedEffect(pendingDeviceId) {
        if (pendingDeviceId != null) {
            selectedId = pendingDeviceId
            onPendingDeviceConsumed()
        }
    }
    val unsorted = state.account?.get("machines") as? JsonArray ?: JsonArray(emptyList())
    val thisId = state.account?.string("thisMachineId")
    // Each host's share of spend, fetched once when the screen opens like
    // `ClientDevicesModel`: one request per device on the host's side.
    var usageByMachine by remember { mutableStateOf<Map<String, DeviceUsage>>(emptyMap()) }
    var usageError by remember { mutableStateOf<String?>(null) }
    val tierDays = deviceHistoryDays(state.account?.string("tier"))
    LaunchedEffect(unsorted, tierDays) {
        val ids = unsorted.mapNotNull { (it as? JsonObject)?.takeIf { m -> m.string("kind") != "client" }?.string("id") }
        if (ids.isEmpty()) {
            usageByMachine = emptyMap()
            usageError = null
            return@LaunchedEffect
        }
        runCatching {
            model.core(
                "account.machineUsage",
                buildJsonObject {
                    put("machines", buildJsonArray { ids.forEach { add(it) } })
                    put("days", tierDays)
                },
            ) as JsonArray
        }.onSuccess { rows ->
            usageByMachine = rows.mapNotNull { (it as? JsonObject)?.let { row ->
                row.string("machine")?.let { m ->
                    m to DeviceUsage(
                        valueMicros = row.long("valueMicros") ?: 0L,
                        events = row.long("events") ?: 0L,
                        activeDays = row.int("activeDays") ?: 0,
                        days = row.int("days") ?: tierDays,
                    )
                }
            } }.toMap()
            usageError = null
        }.onFailure {
            // The list still drew. What failed is the share of spend beside
            // each name, which is worth one quiet line and not an error card
            // where the devices should be.
            usageError = "Could not work out what each device spent."
        }
    }
    // This device first, then awake machines by spend, then everyone else by
    // recency: the same order the Apple devices list reads in.
    val machines = remember(unsorted, usageByMachine) {
        sortMachines(
            unsorted.mapNotNull { it as? JsonObject },
            thisId,
        ) { machine -> machine.string("id")?.let { usageByMachine[it]?.valueMicros } }
    }
    val selected = machines.find { it.string("id") == selectedId }
    // The iPhone leads this screen with a search field. Eight devices fit;
    // the limit is ten and people run more than one account's worth of
    // machines, so the list is one the eye has to hunt through without it.
    var deviceQuery by rememberSaveable { mutableStateOf("") }
    val shownMachines = remember(machines, deviceQuery) {
        val q = deviceQuery.trim()
        if (q.isEmpty()) {
            machines
        } else {
            machines.filter {
                (it.string("label") ?: "").contains(q, ignoreCase = true) ||
                    (it.string("platform") ?: "").contains(q, ignoreCase = true) ||
                    (it.string("id") ?: "").contains(q, ignoreCase = true)
            }
        }
    }
    BackHandler(enabled = sshOpen || selected != null) {
        if (sshOpen) sshOpen = false else selectedId = null
    }
    when {
        sshOpen -> AndroidSSHScreen(model, state, onPlans = onPlans, onBack = { sshOpen = false })
        selected != null -> DeviceDetailScreen(
            model = model,
            state = state,
            machine = selected,
            thisId = thisId,
            usage = selected.string("id")?.let { usageByMachine[it] },
            accountTotalMicros = usageByMachine.values.sumOf { it.valueMicros },
            onBack = { selectedId = null },
            onPlans = onPlans,
            onOpenWork = { selected.string("id")?.let(onOpenWork) },
        )
        else -> PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = {
                scope.launch {
                    refreshing = true
                    TsRefresh.run("devices") { model.refresh() }
                    refreshing = false
                }
            },
            modifier = if (tabBarScroll == null) Modifier.fillMaxSize() else Modifier.fillMaxSize().nestedScroll(tabBarScroll),
        ) {
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = 16.dp, top = 16.dp, end = 16.dp, bottom = 16.dp + TabBarChrome.contentBottomInset),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
            item {
                    TsSearchField(
                        prompt = "Search devices",
                        query = deviceQuery,
                        onQueryChange = { deviceQuery = it },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                item {
                    val colors = LocalTsColors.current
                    TsCard(Modifier.clickable { onSetupWizard() }) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Cloud, null, tint = colors.accent)
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text("Set up a machine", fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
                                Text(
                                    "A cloud server, a Mac you own, or one over SSH",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = colors.textSecondary,
                                )
                            }
                            Icon(ActionIcon.Disclosure.vector, null, tint = colors.textTertiary)
                        }
                    }
                }
                item {
                    val colors = LocalTsColors.current
                    TsCard(Modifier.clickable { sshOpen = true }) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Terminal, null, tint = colors.accent)
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text("SSH hosts", fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
                                Text("Connect to a saved server", color = colors.textSecondary)
                            }
                            Icon(ActionIcon.Disclosure.vector, null, tint = colors.textTertiary)
                        }
                    }
                }
                // The count belongs above the list it counts, which is where
                // the iPhone puts it, rather than above the two rows that add
                // to it.
                item {
                    DevicesHeader(
                        machineCount = machines.size,
                        machineLimit = state.account?.int("machineLimit"),
                        canRemote = state.canRemote,
                    )
                }
                if (shownMachines.isEmpty() && deviceQuery.isNotBlank()) {
                    item {
                        Text(
                            "No device matches \"${deviceQuery.trim()}\".",
                            style = MaterialTheme.typography.bodySmall,
                            color = LocalTsColors.current.textSecondary,
                        )
                    }
                }
                items(shownMachines) { value ->
                    val isHost = value.string("kind") != "client"
                    val online = value.get("online")?.jsonPrimitive?.booleanOrNull
                    val isThis = thisId != null && value.string("id") == thisId
                    val name = DeviceCopy.displayName(value.string("label"), value.string("platform"), isHost)
                    val status = DeviceCopy.statusLine(
                        isThisDevice = isThis,
                        online = online,
                        isHost = isHost,
                        hasKey = !value.string("publicIdentity").isNullOrEmpty(),
                        lastSeenText = formatRelativeDate(value.string("lastSeenAt")),
                    )
                    // Phones, tablets and "this device" never upload an archive.
                    // A $0.00 figure there is noise, not a measurement.
                    val showsSpend = isHost && !isThis
                    val colors = LocalTsColors.current
                    TsCard(Modifier.clickable { selectedId = value.string("id") }) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            AwakeDot(online = if (isThis) true else online)
                            Spacer(Modifier.width(8.dp))
                            DeviceGlyph(
                                name = name,
                                label = value.string("label"),
                                platform = value.string("platform"),
                                isHost = isHost,
                                tint = if (isThis) colors.accent else colors.textSecondary,
                            )
                            Spacer(Modifier.width(8.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    name,
                                    fontWeight = FontWeight.Medium,
                                    color = colors.textPrimary,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    DeviceCopy.caption(value.string("label"), value.string("id"), status),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = colors.textSecondary,
                                )
                            }
                            if (showsSpend) {
                                val micros = value.string("id")?.let { usageByMachine[it]?.valueMicros }
                                // Not zero. A device whose share has not been
                                // fetched has not been shown to have spent
                                // nothing.
                                Text(
                                    if (micros != null) money(micros) else "n/a",
                                    style = TsType.numeric(15, FontWeight.SemiBold),
                                    color = if (micros != null) colors.accent else colors.controlGlyph,
                                )
                                Spacer(Modifier.width(8.dp))
                            } else if (isThis) {
                                Box(
                                    Modifier.background(colors.accent.copy(alpha = 0.12f), RoundedCornerShape(50)),
                                ) {
                                    Text(
                                        "You",
                                        style = MaterialTheme.typography.bodySmall,
                                        fontWeight = FontWeight.SemiBold,
                                        color = colors.accent,
                                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                                    )
                                }
                                Spacer(Modifier.width(8.dp))
                            }
                            Icon(ActionIcon.Disclosure.vector, null, tint = colors.textTertiary)
                        }
                    }
                }
                if (state.account == null) {
                    item { SkeletonRows(count = 4) }
                }
                usageError?.let { message ->
                    item {
                        Text(
                            message,
                            style = MaterialTheme.typography.bodySmall,
                            color = LocalTsColors.current.textSecondary,
                        )
                    }
                }
            }
        }
    }
}

// Typed confirmation rather than one tap. This is the one control in the
// app that destroys data for every device on the account at once.
@Composable
private fun VaultDeleteDialog(
    model: AppViewModel,
    tier: String,
    localKeys: List<JsonObject>,
    onDismiss: () -> Unit,
    onDeleted: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var typed by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var stranded by remember { mutableStateOf<List<String>?>(null) }
    LaunchedEffect(Unit) {
        // Keys whose private half only ever lived in the vault. Nothing
        // recovers these, so they are named before the button, not after.
        runCatching {
            val answer = model.core(
                "ssh.vault.record.list",
                buildJsonObject { put("recovery", ""); put("tier", tier) },
            ) as? JsonObject
            val records = (answer?.get("records") as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
            val names = mutableListOf<String>()
            for (record in records) {
                val key = vaultEnvelopeOf(record)?.get("key") as? JsonObject ?: continue
                val id = key.string("id") ?: continue
                val local = localKeys.firstOrNull { it.string("id") == id }
                val hasLocal = local?.string("secretRef")?.let {
                    withContext(Dispatchers.IO) { SshSecrets.get(context, it) }
                } != null
                val hasPulled = withContext(Dispatchers.IO) { SshSecrets.get(context, "android:$id") } != null
                if (!hasLocal && !hasPulled) {
                    names.add(key.string("label")?.takeIf { it.isNotBlank() } ?: id)
                }
            }
            names
        }.onSuccess { stranded = it }.onFailure { stranded = emptyList() }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Delete the vault and start over") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("For when the password is forgotten and no other device can open it.")
                if (stranded?.isNotEmpty() == true) {
                    Text("Nothing recovers these keys:", fontWeight = FontWeight.SemiBold)
                    stranded!!.forEach { Text("· $it") }
                }
                OutlinedTextField(
                    value = typed,
                    onValueChange = { typed = it },
                    label = { Text("Type DELETE to confirm") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            Button(
                enabled = typed.trim().uppercase() == "DELETE" && !working,
                onClick = {
                    working = true
                    scope.launch {
                        runCatching { model.core("ssh.vault.reset") }
                            .onSuccess { onDeleted() }
                            .onFailure { error = it.message; working = false }
                    }
                },
            ) { Text(if (working) "Deleting…" else "Delete vault") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun AndroidSSHScreen(
    model: AppViewModel,
    state: ClientState,
    onPlans: () -> Unit,
    onBack: (() -> Unit)? = null,
    tabBarScroll: NestedScrollConnection? = null,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val tabs = listOf("Hosts", "Keys", "Snippets")
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var hosts by remember { mutableStateOf(JsonArray(emptyList())) }
    var keys by remember { mutableStateOf(JsonArray(emptyList())) }
    var snippets by remember { mutableStateOf(JsonArray(emptyList())) }
    var folders by remember { mutableStateOf(JsonArray(emptyList())) }
    var query by remember { mutableStateOf("") }
    var vault by remember { mutableStateOf<JsonObject?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var vaultError by remember { mutableStateOf<String?>(null) }
    var addHost by remember { mutableStateOf(false) }
    var addSnippet by remember { mutableStateOf(false) }
    var addKey by remember { mutableStateOf(false) }
    var connecting by remember { mutableStateOf<JsonObject?>(null) }
    // Shells live in the host process and outlast this screen: the model
    // holds them, so leaving SSH and coming back finds them still listed.
    val connections = model.sshConnections
    val openSessions by connections.sessions.collectAsState()
    val selectedSessionId by connections.selectedId.collectAsState()
    var startupBySession by remember { mutableStateOf<Map<String, List<String>>>(emptyMap()) }
    var vaultSetup by remember { mutableStateOf(false) }
    var recoveryWords by remember { mutableStateOf<String?>(null) }
    var showingRecovery by remember { mutableStateOf(false) }
    var confirmDrop by remember { mutableStateOf(false) }
    var editHost by remember { mutableStateOf<JsonObject?>(null) }
    var editSnippet by remember { mutableStateOf<JsonObject?>(null) }
    var editKey by remember { mutableStateOf<JsonObject?>(null) }
    val vaultAllowed = state.vaultAllowed
    val clipboard = LocalClipboard.current
    fun copyText(label: String, text: String) {
        scope.launch {
            clipboard.setClipEntry(ClipEntry(ClipData.newPlainText(label, text)))
        }
    }

    suspend fun loadLists() {
        hosts = model.core("ssh.host.list") as? JsonArray ?: JsonArray(emptyList())
        keys = model.core("ssh.key.list") as? JsonArray ?: JsonArray(emptyList())
        snippets = model.core("ssh.snippet.list") as? JsonArray ?: JsonArray(emptyList())
        folders = model.core("ssh.folder.list") as? JsonArray ?: JsonArray(emptyList())
        if (vaultAllowed) vault = model.core("ssh.vault.status") as? JsonObject
    }

    suspend fun load(syncAsked: Boolean = false) {
        runCatching { loadLists() }.onFailure { error = it.message; return }
        // An unlocked vault syncs on every arrival, like the iOS library:
        // without the pull a second device unlocks into empty lists.
        if (!vaultAllowed || vault?.bool("created") != true || vault?.bool("locked") == true) return
        val tier = state.account?.string("tier")?.lowercase() ?: "legend"
        val result = SshVaultSync.sync(
            model = model,
            context = context,
            tier = tier,
            hosts = hosts.filterIsInstance<JsonObject>(),
            keys = keys.filterIsInstance<JsonObject>(),
            snippets = snippets.filterIsInstance<JsonObject>(),
            folders = folders.filterIsInstance<JsonObject>(),
            asked = syncAsked,
        )
        result.error?.let { error = it }
        vaultError = result.vaultError
        if (result.changed) runCatching { loadLists() }.onFailure { error = it.message }
    }

    // Discard a vault that was just created here and never confirmed. No
    // typing: there is nothing in it no other device could rebuild.
    suspend fun dropFreshVault() {
        runCatching { model.core("ssh.vault.reset") }
            .onSuccess {
                recoveryWords = null
                showingRecovery = false
                vaultSetup = false
                load()
            }
            .onFailure { error = it.message }
    }
    LaunchedEffect(Unit) {
        load()
        connections.reconcile()
    }

    val live = openSessions.firstOrNull { it.id == selectedSessionId }
    if (live != null) {
        SshTerminalScreen(
            model = model,
            sessionId = live.id,
            hostLabel = live.label,
            snippets = snippets,
            onClose = { connections.dismiss() },
            startup = startupBySession[live.id].orEmpty(),
            onEnded = {
                scope.launch { connections.close(live) }
                startupBySession = startupBySession - live.id
            },
        )
        return
    }

    Column(Modifier.fillMaxSize()) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (onBack != null) {
                    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
                }
                // No title: the tab that opened this already says SSH, and
                // repeating it cost a row the host list wanted. The pushed
                // form (reached from Devices) still needs one, because there
                // the tab bar says Devices.
                if (onBack != null) {
                    Text("SSH", style = MaterialTheme.typography.headlineSmall)
                }
            }
            if (!vaultAllowed) {
                Spacer(Modifier.height(10.dp))
                VaultUpgradeCard(onPlans)
            } else {
                Spacer(Modifier.height(10.dp))
                // The row shows the last-known state at once; the actions
                // stay visible until the vault needs nothing, then tuck away
                // behind a tap.
                val vaultNeedsAction = recoveryWords != null ||
                    vault?.bool("created") != true ||
                    vault?.bool("locked") == true ||
                    vault?.bool("enrolled") != true
                // What the comment above always meant: open while the vault
                // wants something, behind the row once it does not. It was
                // hard-coded open, so a vault with nothing to do still put
                // three buttons under its own row.
                var vaultActions by remember(vaultNeedsAction) { mutableStateOf(vaultNeedsAction) }
                VaultLockRow(
                    status = vault,
                    canWrite = state.account?.string("tier")?.lowercase() in listOf("supporter", "patron", "legend"),
                    unconfirmedRecovery = recoveryWords != null,
                    onOpen = { vaultActions = !vaultActions },
                )
                if (vaultActions && (vaultNeedsAction || vault?.bool("created") == true)) {
                    Spacer(Modifier.height(10.dp))
                    TsCard {
                        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                if (recoveryWords != null) {
                                    TsAccentButton(label = "Show code", small = true, onClick = { showingRecovery = true })
                                    TsSecondaryButton(label = "Discard vault", small = true, onClick = { scope.launch { dropFreshVault() } })
                                } else if (vault?.bool("created") != true) {
                                    TsAccentButton(label = "Set up", small = true, onClick = { vaultSetup = true })
                                } else if (vault?.bool("locked") == true || vault?.bool("enrolled") != true) {
                                    TsAccentButton(label = "Unlock", small = true, onClick = { vaultSetup = true })
                                }
                            }
                            // Sync and delete stay one tap away on a vault
                            // that exists: the typed confirmation dialog still
                            // carries the destroy-everywhere warning.
                            if (vault?.bool("created") == true && recoveryWords == null) {
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    TsSecondaryButton(label = "Sync now", small = true, onClick = { scope.launch { load(syncAsked = true) } })
                                    TsSecondaryButton(label = "Delete vault", small = true, onClick = { confirmDrop = true })
                                }
                            }
                        }
                    }
                }
                vaultError?.let {
                    Spacer(Modifier.height(10.dp))
                    Banner(it, BannerSeverity.WARNING)
                }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp)) }
        }
        if (openSessions.isNotEmpty()) {
            Spacer(Modifier.height(10.dp))
            SshOpenSessionsSection(
                state = connections,
                onOpen = { connections.select(it) },
                onEnd = { scope.launch { connections.close(it) } },
            )
        }
        SegmentedCapsulePicker(
            options = tabs.mapIndexed { i, name -> Triple(i, name, null as ImageVector?) },
            selection = tab,
            onSelect = { tab = it },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        )
        Spacer(Modifier.height(Space.s))
        // Search across the width and Add as a button beside it. A bare text
        // link next to a labelled Material field sat on a different baseline
        // and read as a caption rather than the way to add a host.
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(Space.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TsSearchField(
                prompt = "Search ${tabs[tab].lowercase()}",
                query = query,
                onQueryChange = { query = it },
                modifier = Modifier.weight(1f),
            )
            TsAccentButton(
                label = "Add",
                icon = ActionIcon.Create.vector,
                small = true,
                onClick = {
                    if (tab == 0) addHost = true
                    else if (tab == 2) addSnippet = true
                    else addKey = true
                },
            )
        }
        Spacer(Modifier.height(Space.s))
        val all = when (tab) { 0 -> hosts; 1 -> keys; else -> snippets }
        // Searching looks at everything a person might remember about a record:
        // its name, where it points, and what it runs.
        val rows = if (query.isBlank()) all else JsonArray(
            all.filter { value ->
                val item = value.jsonObject
                listOf("label", "title", "hostname", "username", "command", "algorithm", "fingerprint")
                    .mapNotNull { item.string(it) }
                    .any { it.contains(query.trim(), ignoreCase = true) }
            },
        )
        if (rows.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                if (vaultAllowed) {
                    EmptyState(
                        icon = if (tab == 0) ActionIcon.Device.vector else if (tab == 1) ActionIcon.Token.vector else ActionIcon.Docs.vector,
                        title = "No ${tabs[tab].lowercase()} yet",
                        message = if (tab == 0) "Save a server address and choose authentication when connecting." else if (tab == 1) "Generated and imported keys are protected on this device." else "Save commands you use often.",
                        action = {
                            TsAccentButton(
                                label = "Add ${tabs[tab].lowercase().trimEnd('s')}",
                                onClick = {
                                    if (tab == 0) addHost = true
                                    else if (tab == 2) addSnippet = true
                                    else addKey = true
                                },
                            )
                        },
                    )
                }
            }
        } else {
            LazyColumn(
                if (tabBarScroll == null) Modifier.weight(1f) else Modifier.weight(1f).nestedScroll(tabBarScroll),
                contentPadding = PaddingValues(start = 16.dp, top = 16.dp, end = 16.dp, bottom = 16.dp + TabBarChrome.contentBottomInset),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(rows) { value ->
                    val item = value.jsonObject
                    val folderName = item.string("folderId")?.let { id ->
                        folders.firstOrNull { it.jsonObject.string("id") == id }?.jsonObject?.string("name")
                    }
                    fun mergedWith(patch: (MutableMap<String, JsonElement>) -> Unit): JsonObject {
                        val map = item.toMutableMap()
                        patch(map)
                        return JsonObject(map)
                    }
                    when (tab) {
                        0 -> SshHostRow(
                            host = item,
                            folderName = folderName,
                            searching = query.isNotBlank(),
                            onConnect = { connecting = item },
                            onEdit = { editHost = item },
                            onDelete = {
                                scope.launch {
                                    runCatching {
                                        item.string("id")?.let {
                                            model.core("ssh.host.delete", buildJsonObject { put("id", it) })
                                            model.sshConnections.closeAll(it)
                                        }
                                        load()
                                    }.onFailure { error = it.message }
                                }
                            },
                            onToggleFavorite = {
                                scope.launch {
                                    runCatching {
                                        val saved = mergedWith { it["favorite"] = JsonPrimitive(!item.bool("favorite")) }
                                        model.core("ssh.host.save", saved)
                                        load()
                                    }.onFailure { error = it.message }
                                }
                            },
                        )
                        1 -> SshKeyRow(
                            key = item,
                            onEdit = { editKey = item },
                            onCopyPublic = {
                                item.string("publicKey")?.let { copyText("public key", it) }
                            },
                            onCopyFingerprint = {
                                item.string("fingerprint")?.let { copyText("fingerprint", it) }
                            },
                            onDelete = {
                                scope.launch {
                                    runCatching {
                                        item.string("id")?.let { model.core("ssh.key.delete", buildJsonObject { put("id", it) }) }
                                        item.string("secretRef")?.let { ref ->
                                            withContext(Dispatchers.IO) { SshSecrets.delete(context, ref) }
                                        }
                                        load()
                                    }.onFailure { error = it.message }
                                }
                            },
                        )
                        else -> SshSnippetRow(
                            snippet = item,
                            onEdit = { editSnippet = item },
                            onCopy = { item.string("command")?.let { copyText("command", it) } },
                            onToggleRunOnConnect = {
                                scope.launch {
                                    runCatching {
                                        val saved = mergedWith { it["runOnConnect"] = JsonPrimitive(!item.bool("runOnConnect")) }
                                        model.core("ssh.snippet.save", saved)
                                        load()
                                    }.onFailure { error = it.message }
                                }
                            },
                            onDelete = {
                                scope.launch {
                                    runCatching {
                                        item.string("id")?.let { model.core("ssh.snippet.delete", buildJsonObject { put("id", it) }) }
                                        load()
                                    }.onFailure { error = it.message }
                                }
                            },
                        )
                    }
                }
            }
        }
    }
    if (addHost) SSHHostDialog(folders = folders, keys = keys, onDismiss = { addHost = false }) { body ->
        scope.launch { runCatching { model.core("ssh.host.save", body); load() }.onFailure { error = it.message }; addHost = false }
    }
    editHost?.let { host ->
        SSHHostDialog(folders = folders, keys = keys, existing = host, onDismiss = { editHost = null }) { body ->
            scope.launch { runCatching { model.core("ssh.host.save", body); load() }.onFailure { error = it.message }; editHost = null }
        }
    }
    if (addSnippet) SSHSnippetDialog(onDismiss = { addSnippet = false }) { body ->
        scope.launch { runCatching { model.core("ssh.snippet.save", body); load() }.onFailure { error = it.message }; addSnippet = false }
    }
    editSnippet?.let { snippet ->
        SSHSnippetDialog(existing = snippet, onDismiss = { editSnippet = null }) { body ->
            scope.launch { runCatching { model.core("ssh.snippet.save", body); load() }.onFailure { error = it.message }; editSnippet = null }
        }
    }
    editKey?.let { key ->
        SshKeyRenameDialog(
            model = model,
            key = key,
            onDismiss = { editKey = null },
            onSaved = { editKey = null; scope.launch { load() } },
        )
    }
    if (vaultSetup) AndroidVaultDialog(
        existing = vault?.bool("created") == true,
        onDismiss = { vaultSetup = false },
        onCreate = { password ->
            scope.launch {
                runCatching {
                    model.core("ssh.vault.create", buildJsonObject { put("password", password) }).jsonObject.string("recovery")!!
                }.onSuccess { recoveryWords = it; showingRecovery = true; load(syncAsked = true); vaultSetup = false }.onFailure { error = it.message }
            }
        },
        onUnlock = { password ->
            scope.launch {
                runCatching {
                    model.core("ssh.vault.unlock", buildJsonObject {
                        put("password", password); put("migrate", true)
                    }).jsonObject.string("recovery")?.let { recoveryWords = it; showingRecovery = true }
                }.onSuccess { load(syncAsked = true); vaultSetup = false }.onFailure { error = it.message }
            }
        },
        onReset = { code, password ->
            scope.launch {
                runCatching {
                    model.core(
                        "ssh.vault.password.set",
                        buildJsonObject { put("recovery", code); put("newPassword", password) },
                    ).jsonObject.string("recovery")
                }.onSuccess { code ->
                    if (code != null) {
                        recoveryWords = code
                        showingRecovery = true
                    }
                    load(syncAsked = true)
                    vaultSetup = false
                }.onFailure { error = it.message }
            }
        },
        onDrop = { vaultSetup = false; confirmDrop = true },
    )
    if (showingRecovery) recoveryWords?.let { phrase ->
        RecoveryCodeDialog(
            phrase,
            onDone = { recoveryWords = null; showingRecovery = false },
            onDismiss = { showingRecovery = false },
            onDiscard = { showingRecovery = false; scope.launch { dropFreshVault() } },
        )
    }
    if (confirmDrop) VaultDeleteDialog(
        model = model,
        tier = state.account?.string("tier")?.lowercase() ?: "legend",
        localKeys = keys.filterIsInstance<JsonObject>(),
        onDismiss = { confirmDrop = false },
        onDeleted = {
            confirmDrop = false
            recoveryWords = null
            showingRecovery = false
            vaultSetup = false
            scope.launch { load() }
        },
    )
    connecting?.let { host ->
        SshConnectDialog(
            model = model,
            host = host,
            keys = keys,
            onDismiss = { connecting = null },
            onOpened = { id ->
                val label = host.string("label") ?: host.string("hostname") ?: "SSH"
                connecting = null
                connections.adopt(
                    SshSessionEntry(
                        id = id,
                        hostId = host.string("id"),
                        label = label,
                        alive = true,
                    ),
                )
                startupBySession = startupBySession + (id to startupCommands(host.string("id"), snippets))
            },
        )
    }
    if (addKey) {
        SshKeyImportDialog(
            model = model,
            onDismiss = { addKey = false },
            onSaved = {
                addKey = false
                scope.launch { load() }
            },
        )
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun SSHHostDialog(
    folders: JsonArray,
    keys: JsonArray = JsonArray(emptyList()),
    existing: JsonObject? = null,
    onDismiss: () -> Unit,
    onSave: (JsonObject) -> Unit,
) {
    var label by remember { mutableStateOf(existing?.string("label") ?: "") }
    var host by remember { mutableStateOf(existing?.string("hostname") ?: "") }
    var user by remember { mutableStateOf(existing?.string("username") ?: "root") }
    var directory by remember { mutableStateOf(existing?.string("initialDirectory") ?: "~") }
    var port by remember { mutableStateOf(existing?.get("port")?.toString() ?: "22") }
    var folderId by remember { mutableStateOf(existing?.string("folderId")) }
    // Which key this host connects with, like the iOS host editor. Empty is
    // the password, asked for at connect time and never saved.
    var credentialId by remember { mutableStateOf(existing?.string("credentialId") ?: "") }
    var authOpen by remember { mutableStateOf(false) }
    val savedKeys = remember(keys) { keys.filterIsInstance<JsonObject>() }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(if (existing == null) "Add SSH host" else "Edit SSH host") }, text = {
        Column(
            Modifier.verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedTextField(label, { label = it }, label = { Text("Name") }, singleLine = true)
            OutlinedTextField(host, { host = it }, label = { Text("Address") }, singleLine = true)
            OutlinedTextField(user, { user = it }, label = { Text("Username") }, singleLine = true)
            OutlinedTextField(port, { value -> port = value.filter { it.isDigit() }.take(5) }, label = { Text("Port") }, singleLine = true)
            OutlinedTextField(directory, { directory = it }, label = { Text("Starting directory") }, singleLine = true)
            if (folders.isNotEmpty()) {
                Text("Folder", style = MaterialTheme.typography.labelMedium)
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = folderId == null, onClick = { folderId = null }, label = { Text("Top level") })
                    folders.forEach { value ->
                        val id = value.jsonObject.string("id") ?: return@forEach
                        FilterChip(
                            selected = folderId == id,
                            onClick = { folderId = id },
                            label = { Text(value.jsonObject.string("name") ?: "Folder") },
                        )
                    }
                }
            }
            if (savedKeys.isNotEmpty()) {
                Text("Authentication", style = MaterialTheme.typography.labelMedium)
                Box {
                    OutlinedTextField(
                        value = savedKeys.find { it.string("id") == credentialId }?.string("label") ?: "Password",
                        onValueChange = {},
                        readOnly = true,
                        trailingIcon = {
                            IconButton(onClick = { authOpen = true }) {
                                Icon(ActionIcon.More.vector, "Choose authentication")
                            }
                        },
                        modifier = Modifier.fillMaxWidth().clickable { authOpen = true },
                        singleLine = true,
                    )
                    DropdownMenu(expanded = authOpen, onDismissRequest = { authOpen = false }) {
                        DropdownMenuItem(
                            text = { Text("Password") },
                            onClick = { credentialId = ""; authOpen = false },
                        )
                        savedKeys.forEach { key ->
                            DropdownMenuItem(
                                text = { Text(key.string("label") ?: "Key") },
                                onClick = { credentialId = key.string("id") ?: ""; authOpen = false },
                            )
                        }
                    }
                }
            }
            Text("You will verify the host fingerprint and choose a password or saved key before connecting.", style = MaterialTheme.typography.bodySmall)
        }
    }, confirmButton = {
        Button(
            enabled = label.isNotBlank() && host.isNotBlank() && user.isNotBlank(),
            onClick = {
                // An edit keeps what it does not show: the id, the trusted
                // server keys, the folder depth. A save that dropped the
                // host keys would ask for trust again on next connect.
                val map = existing?.toMutableMap() ?: mutableMapOf()
                map["id"] = JsonPrimitive(existing?.string("id") ?: "")
                map["label"] = JsonPrimitive(label)
                map["hostname"] = JsonPrimitive(host)
                map["port"] = JsonPrimitive(port.toIntOrNull() ?: 22)
                map["username"] = JsonPrimitive(user)
                map["initialDirectory"] = JsonPrimitive(directory.ifBlank { "~" })
                if (folderId != null) map["folderId"] = JsonPrimitive(folderId!!) else map.remove("folderId")
                if (credentialId.isNotEmpty()) map["credentialId"] = JsonPrimitive(credentialId) else map.remove("credentialId")
                if (existing == null) {
                    map["tags"] = JsonArray(emptyList())
                    map["hostKeys"] = JsonArray(emptyList())
                }
                onSave(JsonObject(map))
            },
        ) { Text("Save") }
    }, dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } })
}

@Composable
private fun SSHSnippetDialog(existing: JsonObject? = null, onDismiss: () -> Unit, onSave: (JsonObject) -> Unit) {
    var title by remember { mutableStateOf(existing?.string("title") ?: "") }
    var command by remember { mutableStateOf(existing?.string("command") ?: "") }
    // Placeholders are read back the same way every client reads them, so a
    // snippet written here asks for the same values on a Mac.
    val variables = Regex("\\{\\{\\s*([^}]+?)\\s*\\}\\}")
        .findAll(command)
        .map { it.groupValues[1] }
        .distinct()
        .toList()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (existing == null) "Add snippet" else "Edit snippet") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(title, { title = it }, label = { Text("Name") }, singleLine = true)
                OutlinedTextField(
                    command,
                    { command = it },
                    Modifier.fillMaxWidth(),
                    label = { Text("Command") },
                    minLines = 8,
                    textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace),
                )
                Text(
                    if (variables.isEmpty()) "Wrap a value in {{braces}} to be asked for it every time this runs."
                    else "Asks for: ${variables.joinToString(", ")}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            Button(enabled = title.isNotBlank() && command.isNotBlank(), onClick = {
                val map = existing?.toMutableMap() ?: mutableMapOf()
                map["id"] = JsonPrimitive(existing?.string("id") ?: "")
                map["title"] = JsonPrimitive(title)
                map["command"] = JsonPrimitive(command)
                map["variables"] = JsonArray(variables.map { JsonPrimitive(it) })
                if (existing == null) {
                    map["tags"] = JsonArray(emptyList())
                    map["hostIDs"] = JsonArray(emptyList())
                }
                onSave(JsonObject(map))
            }) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun AndroidVaultDialog(
    existing: Boolean,
    onDismiss: () -> Unit,
    onCreate: (String) -> Unit,
    onUnlock: (String) -> Unit,
    onReset: (String, String) -> Unit,
    onDrop: () -> Unit,
) {
    var password by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    var recovery by remember { mutableStateOf("") }
    var forgot by remember { mutableStateOf(false) }
    val problems = vaultPasswordProblems(password)
    val matches = password == confirm
    val canSubmit = if (!existing) {
        problems.isEmpty() && matches
    } else if (forgot) {
        recovery.trim().isNotEmpty() && problems.isEmpty() && matches
    } else {
        password.isNotEmpty()
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (existing) "Unlock your vault" else "Create your vault") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (existing && forgot) {
                    Text("Enter your recovery code and choose a new password. The code is spent once this works.")
                    OutlinedTextField(recovery, { recovery = it }, label = { Text("Recovery code") }, minLines = 2)
                    OutlinedTextField(password, { password = it }, label = { Text("New password") }, visualTransformation = PasswordVisualTransformation())
                    OutlinedTextField(confirm, { confirm = it }, label = { Text("Type it again") }, visualTransformation = PasswordVisualTransformation())
                    problems.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
                    TextButton(onClick = { forgot = false }) { Text("Use the password instead") }
                } else if (existing) {
                    OutlinedTextField(password, { password = it }, label = { Text("Vault password") }, visualTransformation = PasswordVisualTransformation())
                    TextButton(onClick = { forgot = true }) { Text("I forgot the password") }
                } else {
                    Text("One password protects every saved server and key, on all your devices.")
                    OutlinedTextField(password, { password = it }, label = { Text("Vault password") }, visualTransformation = PasswordVisualTransformation())
                    OutlinedTextField(confirm, { confirm = it }, label = { Text("Type it again") }, visualTransformation = PasswordVisualTransformation())
                    problems.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
                }
            }
        },
        confirmButton = {
            Button(
                enabled = canSubmit,
                onClick = {
                    when {
                        !existing -> onCreate(password)
                        forgot -> onReset(recovery, password)
                        else -> onUnlock(password)
                    }
                },
            ) { Text(if (!existing) "Create vault" else if (forgot) "Reset password" else "Unlock") }
        },
        dismissButton = {
            Row {
                if (existing) TextButton(onClick = onDrop) { Text("Delete vault") }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )
}

@Composable
private fun RecoveryCodeDialog(phrase: String, onDone: () -> Unit, onDismiss: () -> Unit, onDiscard: () -> Unit) {
    var step by remember { mutableStateOf(0) }
    var typed by remember { mutableStateOf("") }
    val match = normalizedRecovery(phrase).isNotEmpty() && normalizedRecovery(phrase) == normalizedRecovery(typed)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (step == 0) "Save your recovery code" else "Type the recovery code") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (step == 0) {
                    Text(phrase, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Medium)
                    Text("Store this offline. Screenshots are not a reliable backup. You can close this and confirm later, or discard the vault and create a new one.")
                } else {
                    Text("The code is off screen on purpose. Type it from where you saved it.")
                    OutlinedTextField(typed, { typed = it }, label = { Text("Recovery code") })
                    if (typed.isNotBlank()) {
                        Text(if (match) "Recovery code matches." else "That is not what was generated.")
                    }
                    TextButton(onClick = { step = 0; typed = "" }) { Text("Show the code again") }
                }
            }
        },
        confirmButton = {
            if (step == 0) Button(onClick = { step = 1 }) { Text("I have saved this") }
            else Button(enabled = match, onClick = onDone) { Text("Done") }
        },
        dismissButton = {
            Row {
                TextButton(onClick = onDiscard) { Text("Discard vault") }
                TextButton(onClick = onDismiss) { Text("Close") }
            }
        },
    )
}

@Composable
private fun WorkspacesScreen(
    model: AppViewModel,
    state: ClientState,
    expanded: Boolean,
    pendingHostId: String? = null,
    pendingFolderId: String? = null,
    stores: HomeStores? = null,
    onPendingConsumed: () -> Unit = {},
    onSetupWizard: (() -> Unit)? = null,
    onOpenDevice: (String) -> Unit = {},
    tabBarScroll: NestedScrollConnection? = null,
) {
    // The host list the iOS model keeps: hosts only, without this phone
    // (by account id and by its own key, for records that predate kinds),
    // and without keyless records, which cannot be dialled.
    var selfKey by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        runCatching { model.machineIdentity() }
            .onSuccess { selfKey = it.string("key")?.lowercase() }
    }
    val thisId = state.account?.string("thisMachineId")
    val hosts = ((state.account?.get("machines") as? JsonArray) ?: JsonArray(emptyList()))
        .map { it.jsonObject }
        .filter { it.string("kind") != "client" }
        .filter { thisId == null || it.string("id") != thisId }
        .filter { key -> selfKey == null || key.string("publicIdentity")?.lowercase() != selfKey }
        .filter { !it.string("publicIdentity").isNullOrEmpty() }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val layoutStore = remember(context) { WorkspaceLayoutStore(context) }
    var layoutOrder by remember { mutableStateOf(layoutStore.order()) }
    var layoutHidden by remember { mutableStateOf(layoutStore.hidden()) }
    // The session lives on the model, so leaving the tab does not dial
    // again on return. The tunnel underneath never dropped; only the screen
    // went away. The stored host is re-resolved against the live account
    // list, so a rename or a presence flip behind our back still reads
    // current the moment it arrives.
    val session = model.workspacesConnection
    val storedHost by session.host.collectAsStateWithLifecycle()
    val connectedPeer by session.connectedPeer.collectAsStateWithLifecycle()
    val allowed by session.allowed.collectAsStateWithLifecycle()
    val folders by session.folders.collectAsStateWithLifecycle()
    val sessions by session.sessions.collectAsStateWithLifecycle()
    val chats by session.chats.collectAsStateWithLifecycle()
    val error by session.error.collectAsStateWithLifecycle()
    val requestNotice by session.requestNotice.collectAsStateWithLifecycle()
    val host = hosts.find { it.string("publicIdentity") == storedHost?.string("publicIdentity") } ?: storedHost
    var connectingPeer by remember { mutableStateOf<String?>(null) }
    var requesting by remember { mutableStateOf(false) }
    // Automatic dials fail silently into the log until they settle. The
    // account refreshes every couple of minutes and each one redials, so a
    // transient first failure used to flash red for a frame on its way to a
    // connection nobody could read. Three in a row is stable, and stable
    // failures surface with a retry.
    var autoFailures by remember { mutableStateOf(0) }
    var search by remember { mutableStateOf("") }
    var customizing by remember { mutableStateOf(false) }
    var picking by remember { mutableStateOf(false) }
    var choosingFor by remember { mutableStateOf<String?>(null) }
    var initialSection by remember { mutableStateOf<String?>(null) }
    // A navigation that names a conversation opens exactly it, and arriving
    // to start work opens the conversation worth returning to. Plain folder
    // taps clear both, so an old destination cannot hijack a later visit.
    var pendingChatId by remember { mutableStateOf<String?>(null) }
    var pendingOpenConversation by remember { mutableStateOf(false) }
    var autoTick by remember { mutableStateOf(0) }
    // The open folder by id, resolved against the session's folder list, so
    // leaving the tab neither closes the workspace nor dials again on
    // return: the tunnel underneath never dropped, and a reconnect
    // re-reading the same folders reopens it. Saveable, so a process death
    // restores it once the folders reload.
    var selectedFolderId by rememberSaveable { mutableStateOf<String?>(null) }
    val selectedFolder = folders.mapNotNull { it as? JsonObject }.find { it.string("id") == selectedFolderId }

    suspend fun requestAccess(peer: String) {
        requesting = true
        runCatching {
            model.workspaceSection(peer, "workspace.access.ask", buildJsonObject {}) as JsonObject
        }.onSuccess { answer ->
            session.setRequestNotice(if (answer.bool("granted")) {
                "This device already has access. Pull to refresh."
            } else {
                "Asked. On that computer run `tokenstat host access approve` (over SSH is fine) and pick this device."
            })
        }.onFailure {
            if (it is CancellationException) throw it
            session.setRequestNotice(it.message)
        }
        requesting = false
    }

    suspend fun connect(machine: JsonObject, automatic: Boolean = false) {
        val peer = machine.string("publicIdentity") ?: return
        if (connectingPeer != null) return
        connectingPeer = peer
        // Cleared in `finally`, because this dial does not always run to
        // the last line. Setting `connectingPeer` changes a key of the
        // effect that starts an automatic dial, so that effect cancels
        // the very coroutine it just started, and leaving the screen
        // cancels a manual one. Either way the clear used to be skipped,
        // the card kept saying "Connecting…" for the rest of the
        // session, and the guard above then refused every later tap for
        // every host.
        try {
            session.setHost(machine)
            session.setAllowed(null)
            // An explicit dial clears the readable failure it retries. An
            // automatic one leaves it: clearing on every account refresh is
            // what made failures flash past unreadably.
            if (!automatic) {
                session.setError(null)
                autoFailures = 0
            }
            session.setRequestNotice(null)
            // The work still on screen belongs to the previous host; showing it
            // beside the new host's name is one lie waiting to be clicked.
            session.clearLists()
            runCatching {
                model.prepareHost(peer, machine.string("label") ?: "Host")
                // Asked before anything is loaded. Being paired is not being let
                // in: that computer allows each device to open its work
                // explicitly.
                val check = model.workspaceSection(peer, "workspace.access.check", buildJsonObject {}) as? JsonObject
                session.setAllowed(check?.bool("allowed"))
                if (check?.bool("allowed") != true) {
                    if (session.requestNotice.value == null) requestAccess(peer)
                    return@runCatching
                }
                val loadedSessions = runCatching {
                    model.workspaceSection(peer, "pty.list", buildJsonObject { put("includeRemote", false) }) as? JsonArray
                }.getOrNull() ?: JsonArray(emptyList())
                val loadedChats = runCatching {
                    model.workspaceSection(peer, "chat.recent", buildJsonObject { put("limit", 50) }) as? JsonArray
                }.getOrNull() ?: JsonArray(emptyList())
                session.setLists(model.workspaces(peer), loadedSessions, loadedChats)
                session.setConnected(peer, true)
                autoFailures = 0
                session.setError(null)
                layoutStore.setLastConnectedHost(peer)
            }.onFailure {
                // Leaving the screen mid-dial cancels the scope. That is not a
                // failure worth recording: the session keeps whatever it had.
                if (it is CancellationException) throw it
                android.util.Log.e("ts-workspaces", "connect failed: ${it::class.java.name}", it)
                if (automatic) {
                    autoFailures += 1
                    if (autoFailures >= 3) session.setError(it.message)
                } else {
                    session.setError(it.message)
                    autoFailures = 0
                }
                session.setConnected(null, null)
            }
        } finally {
            connectingPeer = null
        }
    }

    fun disconnect() {
        session.disconnect()
        selectedFolderId = null
    }

    fun refreshHost() {
        host?.let { scope.launch { connect(it) } }
    }

    // The one place that dials without being asked: the last host, when it
    // is awake and its switch is on. Fires as the host list arrives and as
    // machines wake, which is what makes "keep trying until online" work.
    LaunchedEffect(hosts, connectedPeer, connectingPeer, autoFailures) {
        if (connectedPeer != null || connectingPeer != null) return@LaunchedEffect
        // Three silent failures already surfaced as a readable error with a
        // retry. Dialling on behind it would flash that card on every
        // account refresh; the next dial is the user's tap.
        if (autoFailures >= 3) return@LaunchedEffect
        val last = layoutStore.lastConnectedHost() ?: return@LaunchedEffect
        if (!layoutStore.isAutoConnectEnabled(last)) return@LaunchedEffect
        val machine = hosts.find { it.string("publicIdentity") == last } ?: return@LaunchedEffect
        if (machine.get("online")?.jsonPrimitive?.booleanOrNull == false) return@LaunchedEffect
        // On the composition scope, not this effect's: the first thing the
        // dial does is move `connectingPeer`, which is a key here, and an
        // effect cannot survive cancelling itself halfway through its own
        // work.
        scope.launch { connect(machine, automatic = true) }
    }
    // Somebody who walks over, approves and comes back is not looking at the
    // same refusal with no sign that anything changed: while refused, ask
    // again every few seconds and load when the answer lands.
    ForegroundEffect(connectedPeer, allowed, host) {
        if (connectedPeer != null || allowed != false) return@ForegroundEffect
        val machine = host ?: return@ForegroundEffect
        while (true) {
            delay(4000)
            val peer = machine.string("publicIdentity") ?: return@ForegroundEffect
            val now = runCatching {
                (model.workspaceSection(peer, "workspace.access.check", buildJsonObject {}) as? JsonObject)?.bool("allowed")
            }.getOrNull()
            if (now == true) {
                // Same reason as the automatic dial above: `connect` clears
                // `allowed` on its way in, and `allowed` is a key here.
                scope.launch { connect(machine, automatic = true) }
                return@ForegroundEffect
            }
        }
    }
    LaunchedEffect(pendingHostId, hosts) {
        val id = pendingHostId ?: return@LaunchedEffect
        val match = hosts.find { it.string("id") == id } ?: return@LaunchedEffect
        session.setHost(match)
        if (connectedPeer != match.string("publicIdentity")) connect(match)
        if (pendingFolderId == null) onPendingConsumed()
    }
    var terminalSession by remember { mutableStateOf<WorkspaceTerminalRequest?>(null) }
    var browser by remember { mutableStateOf<Pair<String, Int>?>(null) }
    var cloning by remember { mutableStateOf(false) }
    var folderRefresh by remember { mutableStateOf(0) }
    var pendingSelectFolderId by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(host, folders, pendingFolderId) {
        val folderId = pendingFolderId ?: return@LaunchedEffect
        val match = folders.mapNotNull { it as? JsonObject }.find { it.string("id") == folderId }
            ?: return@LaunchedEffect
        selectedFolderId = match.string("id")
        onPendingConsumed()
    }
    // Home reads device history: opening a folder files it on the continue
    // shelf. String keys, so an account refresh re-reading the same folder
    // does not count as another visit.
    val peerKey = host?.string("publicIdentity")
    val folderId = selectedFolder?.string("id")
    val folderName = selectedFolder?.string("name")
    LaunchedEffect(peerKey, folderId) {
        val peer = peerKey ?: return@LaunchedEffect
        val id = folderId ?: return@LaunchedEffect
        val record = stores ?: return@LaunchedEffect
        val identity = RecentPlaces.accountIdentity(
            state.account?.string("handle"),
            state.account?.string("accountId"),
        )
        val host = state.account?.string("host").orEmpty()
        record.recordPlace(identity, host, peer, id, folderName ?: "Workspace", RecentPlaces.Kind.WORKSPACE)
    }
    LaunchedEffect(folders, pendingSelectFolderId) {
        val id = pendingSelectFolderId ?: return@LaunchedEffect
        val match = folders.mapNotNull { it as? JsonObject }.find { it.string("id") == id }
            ?: return@LaunchedEffect
        selectedFolderId = match.string("id")
        pendingSelectFolderId = null
    }
    LaunchedEffect(folderRefresh) {
        if (folderRefresh == 0) return@LaunchedEffect
        host?.let { connect(it) }
    }
    val boundHost = host
    val boundFolder = selectedFolder
    val request = terminalSession
    val browsing = browser
    // Home reads device history: opening a chat or terminal files it on the
    // continue shelf beside folders, the way the Apple client records what
    // is on screen. Labels only: chat titles can contain the first prompt.
    val placesIdentity = RecentPlaces.accountIdentity(
        state.account?.string("handle"),
        state.account?.string("accountId"),
    )
    val placesHost = state.account?.string("host").orEmpty()
    fun recordChatOpened(chatId: String) {
        val peer = boundHost?.string("publicIdentity") ?: return
        val folder = boundFolder ?: return
        stores?.recordPlace(
            placesIdentity, placesHost, peer, folder.string("id"),
            folder.string("name") ?: "Workspace", RecentPlaces.Kind.CHAT, chatId,
        )
    }
    fun recordTerminalOpened(sessionId: String) {
        if (sessionId.startsWith("pending-")) return
        val peer = boundHost?.string("publicIdentity") ?: return
        val folderId = request?.workspaceId ?: return
        val folderName = folders.mapNotNull { it as? JsonObject }
            .find { it.string("id") == folderId }?.string("name") ?: "Workspace"
        stores?.recordPlace(
            placesIdentity, placesHost, peer, folderId,
            folderName, RecentPlaces.Kind.TERMINAL, sessionId,
        )
    }
    // This phone's own record, for the row that opens nothing.
    val thisMachine = ((state.account?.get("machines") as? JsonArray).orEmpty())
        .mapNotNull { it as? JsonObject }
        .find { it.string("id") == thisId }
    fun openSession(session: JsonObject) {
        val workspaceId = session.string("workspaceId") ?: boundFolder?.string("id") ?: ""
        terminalSession = WorkspaceTerminalRequest(
            session.string("id"),
            workspaceId,
            boundHost?.string("label") ?: "Host",
        )
    }
    fun openChat(chat: JsonObject) {
        val folder = folders.mapNotNull { it as? JsonObject }
            .find { it.string("id") == chat.string("workspaceId") } ?: return
        selectedFolderId = folder.string("id")
        initialSection = "Chat"
        pendingChatId = chat.string("id")
        pendingOpenConversation = false
    }
    // A tap on a push opens the conversation it names, the way the iOS
    // workspaces view fulfills it: the tap already re-read the account on
    // its way in, so this waits for the pieces (hosts, connection, recent
    // chats) and opens the chat once they resolve. Peek first, consume only
    // once the tap resolves. Anything unresolvable is dropped at patience,
    // landing on this list, never a crash and never a second move.
    val pushTap by NotificationOpen.request.collectAsStateWithLifecycle()
    var tapDialled by remember(pushTap) { mutableStateOf<String?>(null) }
    LaunchedEffect(pushTap, hosts, connectedPeer, connectingPeer, chats, folders) {
        val tap = pushTap ?: return@LaunchedEffect
        val target = NotificationOpen.pickHost(hosts, tap.machineID, connectedPeer)
        if (target == null) {
            // The named machine is not in the directory, or there are no
            // hosts at all: the account refresh may still be landing. Keep
            // the tap while it is fresh.
            NotificationOpen.dropIfStale()
            return@LaunchedEffect
        }
        val peer = target.string("publicIdentity")
        if (peer.isNullOrEmpty()) {
            NotificationOpen.dropIfStale()
            return@LaunchedEffect
        }
        if (connectedPeer != peer) {
            // A dial already in flight finishes on its own and reruns this.
            // One dial per tap otherwise: a failure surfaces on the list
            // with its retry, and tapping retry still completes the tap.
            if (connectingPeer != null) return@LaunchedEffect
            if (tapDialled == peer) {
                NotificationOpen.dropIfStale()
                return@LaunchedEffect
            }
            tapDialled = peer
            // On the composition scope, not this effect's: the first thing
            // the dial does is move `connectingPeer`, which is a key here,
            // and an effect cannot survive cancelling itself halfway through
            // its own work.
            scope.launch { connect(target) }
            return@LaunchedEffect
        }
        val chat = NotificationOpen.pickChat(chats.mapNotNull { it as? JsonObject }, tap.waiting)
        val folderId = chat?.string("workspaceId")
        if (chat == null || folderId.isNullOrEmpty() ||
            folders.mapNotNull { it as? JsonObject }.none { it.string("id") == folderId }
        ) {
            NotificationOpen.dropIfStale()
            return@LaunchedEffect
        }
        // Compare before consuming: `take` always clears, so a newer tap
        // that arrived mid-resolve would otherwise be swallowed with this one.
        // Still fresh, too: a tap that sat past patience resolving must not
        // yank the user into its chat now that the data happens to be here.
        if (NotificationOpen.request.value != tap) return@LaunchedEffect
        if (NotificationOpen.dropIfStale()) return@LaunchedEffect
        NotificationOpen.take()
        openChat(chat)
    }
    var wsRefreshing by remember { mutableStateOf(false) }

    @Composable
    fun listPane(modifier: Modifier) {
        // Pulling the list re-reads the account and redials the host, and
        // the logo dips the way it does on every other screen.
        PullToRefreshBox(
            isRefreshing = wsRefreshing,
            onRefresh = {
                scope.launch {
                    wsRefreshing = true
                    TsRefresh.run("workspaces") {
                        model.refresh()
                        host?.let { connect(it) }
                    }
                    wsRefreshing = false
                }
            },
            modifier = if (tabBarScroll == null) modifier else modifier.nestedScroll(tabBarScroll),
        ) {
            WorkspaceList(
            model = model,
            hosts = hosts,
            thisMachine = thisMachine,
            dialledHost = host,
            connectedPeer = connectedPeer,
            connectingPeer = connectingPeer,
            folders = folders,
            sessions = sessions,
            chats = chats,
            error = error,
            allowed = allowed,
            requesting = requesting,
            requestNotice = requestNotice,
            search = search,
            onSearch = { search = it },
            layoutOrder = layoutOrder,
            layoutHidden = layoutHidden,
            autoConnect = { peer -> autoTick.let { layoutStore.isAutoConnectEnabled(peer) } },
            onAutoConnect = { peer, enabled ->
                layoutStore.setAutoConnectEnabled(peer, enabled)
                autoTick += 1
            },
            onConnect = { scope.launch { connect(it) } },
            onDisconnect = { disconnect() },
            onFolder = { selectedFolderId = it.string("id"); initialSection = null; pendingChatId = null; pendingOpenConversation = false },
            onSession = { openSession(it) },
            onChat = { openChat(it) },
            onNewChat = { choosingFor = "Chat" },
            onNewSession = { choosingFor = "Sessions" },
            onChooseFolder = { picking = true },
            onClone = { cloning = true },
            onRequestAccess = { peer -> scope.launch { requestAccess(peer) } },
            onCustomize = { customizing = true },
            onOpenDevice = onOpenDevice,
            onSetup = onSetupWizard,
            onRetry = host?.let { h -> { scope.launch { connect(h) } } },
            modifier = Modifier.fillMaxSize(),
            )
        }
    }
    if (cloning && boundHost != null) {
        CloneRepositoryScreen(
            model = model,
            peer = boundHost.string("publicIdentity") ?: "",
            hostLabel = boundHost.string("label") ?: "Host",
            onClose = { cloning = false },
            onCloned = { id ->
                cloning = false
                pendingSelectFolderId = id
                folderRefresh += 1
            },
        )
    } else if (picking && boundHost != null) {
        FolderPickerScreen(
            model = model,
            peer = boundHost.string("publicIdentity") ?: "",
            hostName = boundHost.string("label") ?: "Host",
            onClose = { picking = false },
            onAdded = { folder ->
                picking = false
                pendingSelectFolderId = folder.string("id")
                folderRefresh += 1
            },
        )
    } else if (request != null && boundHost != null) {
        TerminalScreen(
            model = model,
            peer = boundHost.string("publicIdentity") ?: "",
            hostLabel = request.hostLabel,
            workspaceId = request.workspaceId,
            existingSessionId = request.sessionId,
            onClose = { terminalSession = null; folderRefresh += 1 },
            onSessionOpened = ::recordTerminalOpened,
        )
    } else if (browsing != null && boundHost != null) {
        PortBrowserScreen(
            model = model,
            peer = boundHost.string("publicIdentity") ?: "",
            url = browsing.first,
            port = browsing.second,
            onClose = { browser = null },
        )
    } else if (expanded && boundFolder != null && boundHost != null) {
        Row(Modifier.fillMaxSize()) {
            listPane(Modifier.width(340.dp))
            VerticalDivider()
            WorkspaceDetail(
                model, boundHost, boundFolder, Modifier.weight(1f),
                initialSection = initialSection,
                onBack = null,
                onOpenTerminal = { id -> terminalSession = WorkspaceTerminalRequest(id, boundFolder.string("id") ?: "", boundHost.string("label") ?: "Host") },
                onOpenBrowser = { url, port -> browser = url to port },
                onRecordChat = ::recordChatOpened,
                initialChatId = pendingChatId,
                openConversationOnAppear = pendingOpenConversation,
            )
        }
    } else if (boundFolder != null && boundHost != null) {
        WorkspaceDetail(
            model, boundHost, boundFolder, Modifier.fillMaxSize(),
            initialSection = initialSection,
            onBack = { selectedFolderId = null; initialSection = null; pendingChatId = null; pendingOpenConversation = false },
            onOpenTerminal = { id -> terminalSession = WorkspaceTerminalRequest(id, boundFolder.string("id") ?: "", boundHost.string("label") ?: "Host") },
            onOpenBrowser = { url, port -> browser = url to port },
            onRecordChat = ::recordChatOpened,
            initialChatId = pendingChatId,
            openConversationOnAppear = pendingOpenConversation,
        )
    } else {
        listPane(Modifier.fillMaxSize())
    }
    if (customizing) {
        AlertDialog(
            onDismissRequest = { customizing = false },
            title = { Text("Customize Workspaces") },
            text = {
                WorkspacesEditor(
                    order = layoutOrder,
                    hidden = layoutHidden,
                    onDone = { order, hidden ->
                        layoutStore.save(order, hidden)
                        layoutOrder = order
                        layoutHidden = hidden
                        customizing = false
                    },
                    onCancel = { customizing = false },
                )
            },
            confirmButton = {},
        )
    }
    choosingFor?.let { section ->
        FolderChooserDialog(
            title = if (section == "Chat") "New chat in…" else "New session in…",
            folders = folders.mapNotNull { it as? JsonObject },
            onPick = { folder ->
                selectedFolderId = folder.string("id")
                initialSection = section
                pendingChatId = null
                pendingOpenConversation = section == "Chat"
                choosingFor = null
            },
            onDismiss = { choosingFor = null },
        )
    }
}

private data class WorkspaceTerminalRequest(val sessionId: String?, val workspaceId: String, val hostLabel: String)

@Composable
private fun WorkspaceList(
    model: AppViewModel,
    hosts: List<JsonObject>,
    thisMachine: JsonObject?,
    /// The machine this screen is about, which is the one being dialled and
    /// not always the one in `connectedPeer`. A refused dial leaves the
    /// previous host connected, so the two disagree exactly when it matters.
    dialledHost: JsonObject?,
    connectedPeer: String?,
    connectingPeer: String?,
    folders: JsonArray,
    sessions: JsonArray,
    chats: JsonArray,
    error: String?,
    allowed: Boolean?,
    requesting: Boolean,
    requestNotice: String?,
    search: String,
    onSearch: (String) -> Unit,
    layoutOrder: List<WorkSection>,
    layoutHidden: Set<WorkSection>,
    autoConnect: (String) -> Boolean,
    onAutoConnect: (String, Boolean) -> Unit,
    onConnect: (JsonObject) -> Unit,
    onDisconnect: () -> Unit,
    onFolder: (JsonObject) -> Unit,
    onSession: (JsonObject) -> Unit,
    onChat: (JsonObject) -> Unit,
    onNewChat: () -> Unit,
    onNewSession: () -> Unit,
    onChooseFolder: () -> Unit,
    onClone: () -> Unit,
    onRequestAccess: (String) -> Unit,
    onCustomize: () -> Unit,
    onOpenDevice: (String) -> Unit,
    onSetup: (() -> Unit)?,
    onRetry: (() -> Unit)?,
    modifier: Modifier,
) {
    val colors = LocalTsColors.current
    val connectedHost = hosts.find { it.string("publicIdentity") == connectedPeer }
    val folderRows = folders.mapNotNull { it as? JsonObject }
    val sessionRows = sessions.mapNotNull { it as? JsonObject }
    val chatRows = chats.mapNotNull { it as? JsonObject }
    val visibleSections = layoutOrder.filter { it !in layoutHidden }
    var chatsExpanded by remember { mutableStateOf(false) }
    LazyColumn(modifier, contentPadding = PaddingValues(start = 16.dp, top = 16.dp, end = 16.dp, bottom = 16.dp + TabBarChrome.contentBottomInset), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        error?.let { message ->
            item {
                // A stable failure stays readable with its retry, the way
                // `ClientErrorCard` does. Transient dials never land here,
                // so this card cannot flash past on the way to a connection.
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    ErrorCard(friendlyError(message).message)
                    if (onRetry != null) {
                        TsSecondaryButton(label = "Try again", small = true, onClick = onRetry)
                    }
                }
            }
        }
        if (hosts.isEmpty()) {
            item {
                EmptyState(
                    icon = ActionIcon.Connect.vector,
                    title = "No machine yet",
                    message = "tokenstat runs agents on a machine that stays on. Connect " +
                        "a computer you own, or give it a server and it sets one up.",
                    art = { EmptyArt(EmptyArtKind.Connect) },
                    action = if (onSetup != null) ({
                        TsAccentButton(
                            label = "Set up a machine",
                            icon = ActionIcon.Connect.vector,
                            onClick = onSetup,
                        )
                    }) else null,
                )
            }
            return@LazyColumn
        }
        item {
            Box(Modifier.fillMaxWidth().padding(horizontal = 2.dp), contentAlignment = Alignment.CenterStart) {
                SectionTitle("Hosts on your account", "mark_host")
            }
        }
        items(hosts) { machine ->
            val peer = machine.string("publicIdentity") ?: ""
            val name = DeviceCopy.displayName(machine.string("label"), machine.string("platform"), true)
            HostCard(
                model = model,
                machine = machine,
                name = name,
                connected = connectedPeer == peer,
                connecting = connectingPeer == peer,
                autoConnect = autoConnect(peer),
                onConnect = { onConnect(machine) },
                onDisconnect = onDisconnect,
                onOpenDevice = machine.string("id")?.let { id -> { onOpenDevice(id) } },
                onAutoConnect = { onAutoConnect(peer, it) },
            )
        }
        // Deliberately not a card. The host cards above open a device when
        // tapped, and this row opens nothing, so wearing the same surface
        // taught people it could be entered too.
        thisMachine?.let { machine ->
            item {
                val name = DeviceCopy.displayName(machine.string("label"), machine.string("platform"), false)
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Space.s),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Canvas(Modifier.size(9.dp)) { drawCircle(color = colors.accent) }
                        FeatureMark(name = "mark_device", tint = colors.accent, size = 22)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                            Text(
                                name,
                                style = TsType.subheadline.copy(fontWeight = FontWeight.Medium),
                                color = colors.textPrimary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text("This device", style = TsType.caption, color = colors.textSecondary)
                        }
                        Text("Online", style = TsType.caption, color = colors.accent)
                    }
                    // What the connection is, on the screen that makes them.
                    SecurityCard(
                        model = model,
                        peerKey = connectedPeer,
                        peerName = hosts.find { it.string("publicIdentity") == connectedPeer }?.let {
                            DeviceCopy.displayName(it.string("label"), it.string("platform"), true)
                        },
                    )
                }
            }
        }
        // Above the `connectedHost` gate, and resolved against the dialled
        // host: a refused dial leaves `connectedPeer` on the host before it,
        // so reading the name off that one put another computer's name on
        // this card and pointed Request access at that computer. It cannot
        // replace the gate either. `disconnect` clears `connectedPeer` and
        // leaves the dialled host set on purpose, so a list gated on the
        // dialled host would offer Choose folder for a host nobody is on.
        if (allowed == false) {
            val refused = dialledHost ?: connectedHost
            if (refused != null) {
                item {
                    RequestAccessCard(
                        hostName = DeviceCopy.displayName(
                            refused.string("label"),
                            refused.string("platform"),
                            true,
                        ),
                        requesting = requesting,
                        notice = requestNotice,
                        onRequest = { onRequestAccess(refused.string("publicIdentity") ?: "") },
                    )
                }
                return@LazyColumn
            }
        }
        val host = connectedHost ?: return@LazyColumn
        val hostName = DeviceCopy.displayName(host.string("label"), host.string("platform"), true)
        val peer = host.string("publicIdentity") ?: ""
        if (connectingPeer != null) {
            item { SkeletonRows(count = 3) }
            return@LazyColumn
        }
        if (folderRows.isEmpty() && sessionRows.isEmpty() && chatRows.isEmpty() && error == null) {
            item {
                EmptyWorkspacesCard(hostName = hostName, onChooseFolder = onChooseFolder, onClone = onClone)
            }
            return@LazyColumn
        }
        item {
            // The app's search field, like every other one. A Material box
            // with a floating label was the odd control out on a screen made
            // of cards.
            TsSearchField(
                prompt = "Search folders or paths",
                query = search,
                onQueryChange = onSearch,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        visibleSections.forEach { section ->
            when (section) {
                WorkSection.FOLDERS -> if (folderRows.isNotEmpty()) {
                    item {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 2.dp).padding(top = Space.s),
                        ) {
                            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                                SectionTitle("Folders", "mark_archive")
                            }
                            TextButton(onClick = onChooseFolder) {
                                Text("Choose", style = TsType.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.accent)
                            }
                            TextButton(onClick = onClone) {
                                Text("Clone", style = TsType.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.accent)
                            }
                        }
                    }
                    items(folderRows.filter {
                        search.isBlank() ||
                            (it.string("name") ?: "").contains(search, ignoreCase = true) ||
                            (it.string("path") ?: "").contains(search, ignoreCase = true)
                    }) { folder ->
                        WorkspaceFolderRow(folder = folder, onOpen = { onFolder(folder) })
                    }
                }
                WorkSection.RECENT_CHATS -> if (chatRows.isNotEmpty()) {
                    item {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 2.dp).padding(top = Space.s),
                        ) {
                            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                                SectionTitle("Recent chats", "mark_activity")
                            }
                            if (folderRows.isNotEmpty()) {
                                TextButton(onClick = onNewChat) {
                                    Text("New chat", style = TsType.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.accent)
                                }
                            }
                        }
                    }
                    val shown = if (chatsExpanded) chatRows else chatRows.take(5)
                    items(shown) { chat ->
                        val folderName = folderRows.find { it.string("id") == chat.string("workspaceId") }?.string("name") ?: "Workspace"
                        WorkspaceChatRow(chat = chat, folderName = folderName, onOpen = { onChat(chat) })
                    }
                    if (chatRows.size > 5) {
                        item {
                            TextButton(
                                onClick = { chatsExpanded = !chatsExpanded },
                                modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
                            ) {
                                Text(
                                    if (chatsExpanded) "Show less" else "Show more (${chatRows.size - 5} more)",
                                    style = TsType.caption.copy(fontWeight = FontWeight.SemiBold),
                                    color = colors.accent,
                                )
                                Icon(
                                    if (chatsExpanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                                    contentDescription = null,
                                    tint = colors.accent,
                                    modifier = Modifier.size(16.dp),
                                )
                            }
                        }
                    }
                }
                WorkSection.SESSIONS -> if (sessionRows.isNotEmpty() || folderRows.isNotEmpty()) {
                    item {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 2.dp).padding(top = Space.s),
                        ) {
                            Text(
                                "All sessions",
                                style = TsType.headline,
                                color = colors.textPrimary,
                                modifier = Modifier.weight(1f),
                            )
                            if (folderRows.isNotEmpty()) {
                                TextButton(onClick = onNewSession) {
                                    Text("New session", style = TsType.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.accent)
                                }
                            }
                        }
                    }
                    items(sessionRows) { session ->
                        WorkspaceSessionRow(session = session, onOpen = { onSession(session) })
                    }
                    if (sessionRows.isEmpty()) {
                        item {
                            Text(
                                "Nothing running. Start one from a folder.",
                                style = TsType.caption,
                                color = colors.textSecondary,
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 2.dp),
                            )
                        }
                    }
                }
            }
        }
        if (visibleSections.isEmpty()) {
            item {
                TsCard {
                    Column {
                        Text("Your Workspaces are clear", fontWeight = FontWeight.Medium, color = colors.textPrimary)
                        Text(
                            "Folders, chats and sessions are switched off.",
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.textSecondary,
                        )
                    }
                }
            }
        }
        item {
            TextButton(onClick = onCustomize, modifier = Modifier.fillMaxWidth()) {
                Icon(ActionIcon.Layout.vector, null, tint = colors.accent, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(Space.xs))
                Text("Customize Workspaces", color = colors.accent)
            }
        }
    }
}

@Composable
private fun WorkspaceDetail(
    model: AppViewModel, host: JsonObject, folder: JsonObject, modifier: Modifier,
    initialSection: String? = null,
    onBack: (() -> Unit)? = null,
    onOpenTerminal: (String?) -> Unit = {},
    onOpenBrowser: (String, Int) -> Unit = { _, _ -> },
    onRecordChat: (String) -> Unit = {},
    initialChatId: String? = null,
    openConversationOnAppear: Boolean = false,
) {
    WorkspaceHub(
        model = model,
        host = host,
        folder = folder,
        modifier = modifier.padding(cardPaddingDp),
        initialSection = initialSection,
        onBack = onBack,
        onOpenTerminal = onOpenTerminal,
        onOpenBrowser = onOpenBrowser,
        onRecordChat = onRecordChat,
        initialChatId = initialChatId,
        openConversationOnAppear = openConversationOnAppear,
    )
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun AccountDialog(
    state: ClientState,
    model: AppViewModel,
    billing: PlayBillingManager,
    customization: TabCustomization,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    var paywall by remember { mutableStateOf(false) }
    var notifyOn by remember { mutableStateOf(PushRegistrar.isOn()) }
    var notifyError by remember { mutableStateOf<String?>(null) }
    fun open(url: String) {
        runCatching { CustomTabsIntent.Builder().build().launchUrl(context, url.toUri()) }
    }
    // Account, this device, legal: the same three panes the iOS sheet has,
    // so a setting is found in the same place on both phones.
    var pane by rememberSaveable { mutableStateOf(0) }
    // Full height, not half. The Apple sheet fills the screen, and the panes
    // behind these tabs are long: relay usage alone is a card with a progress
    // bar, five rows and a disclosure. Opening halfway put every one of them
    // in the bottom third and made the sheet a scroll inside a scroll.
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = colors.background,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.l)
                .padding(bottom = Space.xl),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            SegmentedCapsulePicker(
                options = listOf(
                    Triple(0, "Account", null as ImageVector?),
                    Triple(1, "This device", null as ImageVector?),
                    Triple(2, "Legal", null as ImageVector?),
                ),
                selection = pane,
                onSelect = { pane = it },
                modifier = Modifier.fillMaxWidth(),
            )
            when (pane) {
                0 -> {
                    AccountIdentityCard(state = state, onOpen = ::open)
                    AccountPlanCard(state = state, onPlans = { paywall = true })
                    RelayUsageCard(state.account, onRefresh = { scope.launch { TsRefresh.run("relay") { model.refresh() } } })
                    // Sync privacy lives under Legal now, with the documents
                    // it belongs to. Leaving a copy here would be the same
                    // claim in two places, free to drift apart.
                    AccountLastSyncCard(state)
                    AccountDevicesCard(state)
                    TsDangerButton(
                        label = "Sign out",
                        icon = ActionIcon.SignOut.vector,
                        onClick = { model.signOut(); onDismiss() },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    // Ending the account, kept apart from everything above
                    // it. It is not a document, so it lives at the end of
                    // the account rather than under Legal.
                    HorizontalDivider(color = colors.border)
                    Text(
                        "Danger zone",
                        style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold),
                        color = colors.danger,
                    )
                    TsCard(
                        title = "Delete this account",
                        mark = "mark_delete",
                        markTint = colors.danger,
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                            Text(
                                if (state.account?.let {
                                        (it["billing"] as? JsonObject)?.string("provider")?.lowercase() == "google_play"
                                    } == true
                                ) {
                                    "Permanent. You can delete immediately on the website. Deletion does not cancel the Google Play subscription, so Google may keep charging until you cancel it separately."
                                } else {
                                    "Permanent. Confirmed on the website's data settings. The account, linked providers, sessions and usage are removed outright."
                                },
                                style = TextStyle(fontSize = 14.sp),
                                color = colors.textSecondary,
                            )
                            TsDangerButton(
                                label = "Delete on website…",
                                icon = ActionIcon.Delete.vector,
                                onClick = { open("https://tokenstat.ai/settings/data?mobile=1&focus=delete#delete") },
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                }
                1 -> {
                    // Notifications, Tabs, then this machine's traffic: the
                    // order the Apple sheet uses, and each in a card with a
                    // mark. The switch used to be a bare row above the cards,
                    // so the pane opened on an unlabelled toggle.
                    TsCard(title = "Notifications", mark = "mark_device") {
                        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    "Notify this device",
                                    color = colors.textPrimary,
                                    modifier = Modifier.weight(1f),
                                )
                                TsBrandSwitch(
                                    checked = notifyOn,
                                    onCheckedChange = { on ->
                                        scope.launch {
                                            runCatching {
                                                if (on) PushRegistrar.enable() else PushRegistrar.disable()
                                            }.onSuccess { notifyOn = PushRegistrar.isOn(); notifyError = null }
                                                .onFailure { notifyError = it.message }
                                        }
                                    },
                                )
                            }
                            // Not the iPhone's sentence: there the server names the
                            // machine in the banner, while here the banner is
                            // composed on the device from the reason alone and
                            // never carries a name. Promising "which machine"
                            // would be promising what never arrives.
                            Text(
                                "When an agent run or a chat on one of your machines finishes, or stops to ask you something. The notification says what happened, and nothing about the work.",
                                style = TextStyle(fontSize = 13.sp),
                                color = colors.textSecondary,
                            )
                            if (notifyOn) {
                                TsSecondaryButton(
                                    label = "Send a test",
                                    icon = ActionIcon.Send.vector,
                                    small = true,
                                    onClick = {
                                        scope.launch {
                                            runCatching { PushRegistrar.test() }
                                                .onSuccess { notifyError = it }
                                                .onFailure { notifyError = it.message }
                                        }
                                    },
                                )
                            }
                            notifyError?.let { Text(it, color = colors.warning) }
                        }
                    }
                    // This device's tab bar and rail, arranged by the person
                    // holding it, where the other device-local choices live.
                    var tabsOpen by remember { mutableStateOf(false) }
                    TabsCard(
                        summary = tabSummary(
                            customization.visibleTabs.mapNotNull { id ->
                                Destination.entries.find { it.id == id }?.label
                            },
                        ),
                        onOpen = { tabsOpen = true },
                    )
                    LocalTrafficCard(model)
                    if (tabsOpen) {
                        TabEditorSheet(
                            tabs = customization.order.mapNotNull { id ->
                                Destination.entries.find { it.id == id }?.let {
                                    TabDef(it.id, it.label, it.detail, it.icon)
                                }
                            },
                            customization = customization,
                            onDismiss = { tabsOpen = false },
                        )
                    }
                    Text("Identity and credentials stay in Android's no-backup app storage.", style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
                }
                else -> {
                    var sampleOpen by remember { mutableStateOf(false) }
                    // "Help" is the card's title, not a label floating above
                    // it, which is how the Apple sheet builds this pane.
                    TsCard(title = "Help") {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(Space.m),
                            modifier = Modifier.fillMaxWidth().clickable { sampleOpen = true },
                        ) {
                            Icon(ActionIcon.Run.vector, null, tint = colors.accent)
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                                Text("See a sample", fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
                                Text(
                                    "Explore a workspace with invented data, right on this device.",
                                    style = TextStyle(fontSize = 12.sp),
                                    color = colors.textSecondary,
                                )
                            }
                            Icon(ActionIcon.Disclosure.vector, null, tint = colors.textTertiary)
                        }
                    }
                    if (sampleOpen) SampleSheet(onDismiss = { sampleOpen = false })
                    // One card with two rows, named the way the documents are
                    // named. Two full-width buttons labelled "Terms" and
                    // "Privacy" said less and looked like actions rather than
                    // links off the device.
                    TsCard(title = "Terms and privacy", mark = "mark_license") {
                        Column {
                            LegalLinkRow("Privacy policy") { open("https://tokenstat.ai/privacy?mobile=1") }
                            HorizontalDivider(color = colors.border)
                            LegalLinkRow("Terms of service") { open("https://tokenstat.ai/terms?mobile=1") }
                        }
                    }
                    var licensesOpen by remember { mutableStateOf(false) }
                    LicensesCard(onOpen = { licensesOpen = true })
                    if (licensesOpen) LicensesSheet(onDismiss = { licensesOpen = false })
                    // Where the Apple sheet keeps it: the privacy claim reads
                    // as part of the documents, not as a footnote under them.
                    SyncPrivacyCard()
                }
            }
        }
    }
    if (paywall) {
        PaywallSheet(
            billing = billing,
            onDismiss = { paywall = false },
            currentTier = state.account?.string("tier"),
            // The server names a monthly interval and leaves a yearly one
            // unsaid, the way the account card reads it: paid and not
            // monthly means yearly.
            currentInterval = run {
                val serverBilling = state.account?.get("billing") as? JsonObject
                when {
                    serverBilling?.string("interval") == PlayBillingManager.INTERVAL_MONTH ->
                        PlayBillingManager.INTERVAL_MONTH
                    state.account?.string("tier")?.lowercase() in listOf("supporter", "patron", "legend") ->
                        PlayBillingManager.INTERVAL_YEAR
                    else -> null
                }
            },
        )
    }
}

@Composable
private fun RelayUsageCard(account: JsonObject?, onRefresh: () -> Unit) {
    val usage = account?.get("relayUsage") as? JsonObject
    val supported = usage?.string("policy") == "rolling_30_utc_days"
        && usage?.int("windowDays") == 30
        && usage?.string("timezone") == "UTC"
    TsCard(title = "Relay usage", subtitle = "One allowance across your devices", mark = "mark_activity") {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            if (usage == null || !supported) {
                Text(
                    "Relay usage details are not available from this server yet.",
                    color = LocalTsColors.current.textSecondary,
                )
            } else {
                val used = usage.long("usedBytes") ?: 0L
                val limit = usage.long("limitBytes") ?: 0L
                val remaining = usage.long("remainingBytes") ?: 0L
                Text(
                    "${binaryBytes(used)} of ${binaryBytes(limit)} used",
                    fontWeight = FontWeight.SemiBold,
                    color = LocalTsColors.current.textPrimary,
                )
                LinearProgressIndicator(
                    progress = { if (limit > 0) (used.toDouble() / limit).coerceIn(0.0, 1.0).toFloat() else 0f },
                    modifier = Modifier.fillMaxWidth(),
                )
                Text("${binaryBytes(remaining)} remaining", color = LocalTsColors.current.textSecondary)
                UsageRow("Today (UTC)", usage.long("todayBytes") ?: 0L)
                UsageRow("This calendar month (UTC)", usage.long("monthBytes") ?: 0L)
                UsageRow("Rolling 30 days, used for your limit", used)
                Text(
                    "All relayed traffic shares this allowance. Direct connections do not count. The limit includes today and the previous 29 UTC days. Each day, older usage leaves the window. This is not a daily refill or a calendar-month reset.",
                    style = TextStyle(fontSize = 12.sp),
                    color = LocalTsColors.current.textSecondary,
                )
                val unlock = usage.string("nextUnlockAt")
                if (!unlock.isNullOrBlank()) {
                    val day = unlock.take(10)
                    Text(
                        "Next usage to expire: ${binaryBytes(usage.long("nextUnlockBytes") ?: 0L)} on $day at 00:00 UTC.",
                        style = TextStyle(fontSize = 12.sp),
                        color = LocalTsColors.current.textSecondary,
                    )
                }
                val days = (usage["daily"] as? JsonArray).orEmpty()
                    .mapNotNull { it as? JsonObject }
                    .filter { (it.long("bytes") ?: 0L) > 0L }
                    .reversed()
                // Thirty rows of bytes are a reference, not a headline, and
                // laid out flat they pushed the caption that dates the whole
                // card off the screen. Collapsed to start, like the
                // `DisclosureGroup` the Apple clients wrap it in.
                var daysExpanded by remember { mutableStateOf(false) }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { daysExpanded = !daysExpanded }
                        .semantics {
                            contentDescription =
                                if (daysExpanded) "Daily usage, expanded" else "Daily usage, collapsed"
                        },
                ) {
                    Text(
                        "Daily usage (UTC)",
                        fontWeight = FontWeight.SemiBold,
                        color = LocalTsColors.current.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Icon(
                        if (daysExpanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                        contentDescription = null,
                        tint = LocalTsColors.current.textTertiary,
                        modifier = Modifier.size(16.dp),
                    )
                }
                AnimatedVisibility(
                    visible = daysExpanded,
                    enter = fadeIn() + expandVertically(),
                    exit = fadeOut() + shrinkVertically(),
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                        if (days.isEmpty()) {
                            Text(
                                "No relayed traffic in this window.",
                                style = TextStyle(fontSize = 12.sp),
                                color = LocalTsColors.current.textSecondary,
                            )
                        } else {
                            days.forEach { day ->
                                UsageRow(day.string("day") ?: "", day.long("bytes") ?: 0L)
                            }
                        }
                    }
                }
                val asOf = usage.string("asOf")?.take(10).orEmpty()
                val delay = usage.int("reportingDelaySeconds") ?: 0
                Text(
                    "As of $asOf. Relay reporting can lag by about $delay seconds.",
                    style = TextStyle(fontSize = 12.sp),
                    color = LocalTsColors.current.textSecondary,
                )
            }
            TsSecondaryButton(label = "Refresh usage", onClick = onRefresh, modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun LocalTrafficCard(model: AppViewModel) {
    var status by remember { mutableStateOf<JsonObject?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(true) }
    val scope = rememberCoroutineScope()
    fun load() {
        scope.launch {
            loading = true
            runCatching { model.core("remote.status") as? JsonObject ?: error("The host answered remote.status with an unexpected shape.") }
                .onSuccess {
                    status = it
                    error = null
                }
                .onFailure { error = it.message ?: "Could not load local traffic." }
            loading = false
        }
    }
    LaunchedEffect(Unit) { load() }
    TsCard(title = "This device", subtitle = "How connections leave this machine", mark = "mark_activity") {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            error?.let { Text(it, color = LocalTsColors.current.warning) }
            TunnelStatusBanner(status = status)
            val snapshot = status?.get("traffic") as? JsonObject
            if (snapshot == null && !loading && error == null) {
                Text(
                    "This host does not report local traffic yet.",
                    color = LocalTsColors.current.textSecondary,
                )
            } else if (snapshot != null) {
                UsageRow("Direct", snapshot.long("directBytes") ?: 0L)
                UsageRow("Relayed", snapshot.long("relayBytes") ?: 0L)
                Text(
                    "Counted on this device since tokenstat started. Direct traffic does not use the account relay allowance. The relayed figure is this machine only, not the account total.",
                    style = TextStyle(fontSize = 12.sp),
                    color = LocalTsColors.current.textSecondary,
                )
                val peers = (snapshot["peers"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
                if (peers.isEmpty()) {
                    Text("No live connections right now.", style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                } else {
                    peers.forEach { peer ->
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                            Text(peer.string("label")?.ifBlank { null } ?: peer.string("peer").orEmpty())
                            Text(
                                transportLabel(peer.string("route")),
                                color = LocalTsColors.current.textSecondary,
                            )
                        }
                    }
                }
            }
            TsSecondaryButton(
                label = if (loading) "Refreshing…" else "Refresh traffic",
                onClick = { load() },
                enabled = !loading,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun SyncPrivacyCard() {
    // This phone does not upload an archive; the boundary is what the
    // computers put on the account and what a remote session carries.
    TsCard(title = "Sync privacy") {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Text(
                "Your computers put aggregate counts on the account. This device reads them. Remote folders, terminals and agents stay encrypted between devices.",
                color = LocalTsColors.current.textSecondary,
            )
            PrivacyLine("On account", "Counts per day, tool and model. Project names as salted hashes.")
            PrivacyLine("Not synced", "Prompts, replies, file contents, file paths and session ids stay on the computer.")
            PrivacyLine("Remote", "Folders, terminals and agents go device to device, encrypted. The relay cannot read them.")
        }
    }
}

@Composable
private fun PrivacyLine(title: String, detail: String) {
    Column {
        Text(title, fontWeight = FontWeight.SemiBold, color = LocalTsColors.current.textPrimary)
        Text(detail, style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
    }
}

@Composable
private fun UsageRow(label: String, bytes: Long) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, modifier = Modifier.weight(1f), color = LocalTsColors.current.textPrimary)
        Text(binaryBytes(bytes), fontFamily = FontFamily.Monospace, color = LocalTsColors.current.textPrimary)
    }
}

private fun binaryBytes(n: Long): String {
    val value = n.coerceAtLeast(0).toDouble()
    val kibi = 1024.0
    fun fmt(x: Double, unit: String): String {
        // Trim the tenth only when there is one. Trimming zeros off a whole
        // number turned a 20 GiB allowance into "2 GiB". The separator is
        // whatever the locale uses, so drop a trailing dot or comma rather
        // than assuming a dot.
        val shown = if (x >= 10) {
            "%.0f".format(x)
        } else {
            "%.1f".format(x).trimEnd('0').trimEnd('.', ',')
        }
        return shown + " " + unit
    }
    return when {
        value >= kibi * kibi * kibi -> fmt(value / (kibi * kibi * kibi), "GiB")
        value >= kibi * kibi -> fmt(value / (kibi * kibi), "MiB")
        value >= kibi -> fmt(value / kibi, "KiB")
        else -> "${n.coerceAtLeast(0)} B"
    }
}

private fun transportLabel(raw: String?): String = when (raw) {
    "direct" -> "Direct connection"
    "relay" -> "Encrypted relay"
    else -> raw ?: "Unknown"
}

/// One headline figure with its label and period mark, top trailing the way
/// every other figure card on the client carries its mark. Ported from
/// `TotalTile` in `ClientHomeView.swift`.
@Composable
private fun TotalTile(label: String, value: String, mark: String, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    Row(
        modifier
            .clip(RoundedCornerShape(cardRadiusDp))
            .tsPanel()
            .padding(Space.m),
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = TsType.subheadline, color = colors.textSecondary)
            // Shrinks to fit rather than clipping. "$1,110.16" cut to "$1,11"
            // on a narrow phone is not a smaller number, it is a wrong one.
            TsFitFigure(
                value,
                style = TsType.numeric(22, FontWeight.SemiBold),
                color = colors.accent,
            )
        }
        FeatureMark(name = mark, size = 26)
    }
}

/// One provider reading with its windows, the shape `usage.limits` actually
/// returns: `windows[{label, percent, resetsAtMs}]` under a `source`. The
/// generic row card this replaces could not reach any of it.
@Composable
private fun LimitCard(reading: JsonObject) {
    val colors = LocalTsColors.current
    val windows = reading["windows"] as? JsonArray ?: JsonArray(emptyList())
    val stale = reading.bool("stale")
    // A reading with no date is not a reading. The wire speaks camelCase;
    // the snake key stays as a fallback for older hosts.
    val observedAt = (reading.long("observedAtMs") ?: reading.long("observed_at_ms"))?.takeIf { it > 0 }
    val observed = when {
        observedAt == null -> "no date"
        stale -> "stale, ${RelativeClock.label(observedAt)}"
        else -> RelativeClock.label(observedAt)
    }
    val source = reading.string("source") ?: ""
    TsCard {
        Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                HarnessMark(id = source, size = 24.dp)
                // Both sides weighted, and both allowed to wrap. Only the
                // name column had a weight, so on a narrow phone the
                // freshness took its full natural width first and left the
                // provider a few letters, clipped mid-glyph: "OpenCod".
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Text(
                        harnessName(source.ifEmpty { "Provider" }),
                        style = TsType.subheadline.copy(fontWeight = FontWeight.Medium),
                        color = colors.textPrimary,
                    )
                    reading.string("plan")?.let {
                        Text(it, style = TsType.caption, color = colors.textSecondary)
                    }
                }
                Text(
                    observed,
                    style = TsType.caption,
                    color = if (stale) colors.warning else colors.textSecondary,
                    textAlign = TextAlign.End,
                    modifier = Modifier.weight(1f, fill = false),
                )
            }
            if (windows.isEmpty()) {
                // "We could not look" is a different answer from "nothing is
                // used", and the two must not render alike. The note shows
                // only here, never beside windows.
                reading.string("note")?.let {
                    Text(it, style = TsType.caption, color = colors.textSecondary)
                }
            } else {
                windows.forEach { window ->
                    LimitGauge(window.jsonObject)
                }
            }
        }
    }
}

/// One limit window, ported from `WindowGauge`: the label and the percent
/// on one row, a capsule bar under it, and the reset date when the host
/// sends one. Vertical, so a three-digit percent never wraps.
@Composable
private fun LimitGauge(value: JsonObject) {
    val colors = LocalTsColors.current
    val percent = value.doubleOrNull("percent") ?: 0.0
    // Severity is the renderer's decision, taken from the core's
    // thresholds rather than reinvented here.
    val gauge = when (LimitLogic.severityOf(value.string("severity"), percent)) {
        LimitLogic.Severity.CRITICAL -> colors.danger
        LimitLogic.Severity.WARNING -> colors.warning
        LimitLogic.Severity.NORMAL -> colors.accent
    }
    // Codex reports the account's own allowance beside the running
    // model's, and both are weekly. Without the scope the two rows read
    // as one limit stated twice. The same mapping `displayLabel` draws.
    val label = value.string("label") ?: ""
    val scope = value.string("scope")
    val shown = when (scope?.lowercase()) {
        null, "" -> label
        "secondary" -> "$label (all models)"
        "primary" -> "$label (primary)"
        "current model" -> "$label (secondary)"
        else -> "$label ($scope)"
    }
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                shown,
                style = TsType.caption,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(
                "${percent.roundToInt()}%",
                style = TsType.caption.copy(fontWeight = FontWeight.SemiBold),
                color = gauge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        val fraction = (percent / 100.0).coerceIn(0.0, 1.0).toFloat()
        val animated by animateFloatAsState(fraction, tween(320), label = "limitGauge")
        Box(
            Modifier
                .fillMaxWidth()
                .height(6.dp)
                .clip(RoundedCornerShape(50))
                .background(colors.border),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(animated)
                    .widthIn(min = 3.dp)
                    .height(6.dp)
                    .clip(RoundedCornerShape(50))
                    .background(gauge),
            )
        }
        val resetsAt = (value.long("resetsAtMs") ?: value.long("resets_at_ms"))?.takeIf { it > 0 }
        if (resetsAt != null) {
            Text(
                "resets ${RelativeClock.until(resetsAt)}",
                style = TsType.caption,
                color = colors.textTertiary,
            )
        }
    }
}

/// The cross-device SSH vault, on a plan that does not include it. The same
/// card every other empty screen uses, so a plan gate is told in one voice
/// across the app. Port of `vaultUpgrade` in `SSHLibraryView`.
@Composable
private fun VaultUpgradeCard(onPlans: () -> Unit) {
    EmptyState(
        kind = EmptyKind.NeedsAccount,
        title = "Sync SSH between your devices",
        message = "An encrypted vault keeps hosts and keys on every device signed in to " +
            "this account. Supporter and above.",
        art = { EmptyArt(EmptyArtKind.Vault) },
        action = {
            TsAccentButton(
                label = "See plans",
                icon = ActionIcon.Plans.vector,
                onClick = onPlans,
            )
        },
    )
}

@Composable private fun EmptyCard(title: String, message: String) {
    EmptyState(icon = ActionIcon.Help.vector, title = title, message = message, art = { EmptyArt(EmptyArtKind.Waiting) })
}
@Composable private fun ErrorCard(message: String) = Banner(message, BannerSeverity.DANGER, Modifier.fillMaxWidth())

private fun homeGreeting(account: JsonObject?, hasHistory: Boolean): String =
    HomeGreeting.line(
        account?.string("displayName") ?: account?.string("handle") ?: "there",
        hasHistory,
    )
private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
private fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.longOrNull
private fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull
private fun JsonObject.doubleOrNull(key: String): Double? = this[key]?.jsonPrimitive?.doubleOrNull
private fun JsonObject.bool(key: String): Boolean = (this[key] as? JsonPrimitive)?.booleanOrNull == true


/// Who is signed in, as a card. Port of `identityCard` in
/// `ClientAccountSheet.swift`.
///
/// It was a bare row with a tier chip and a device count, which said less
/// than the Apple sheet and said it in a shape that did not match anything
/// else on the screen. The handle and the way to the public profile are the
/// two things people actually come here for.
@Composable
private fun AccountIdentityCard(state: ClientState, onOpen: (String) -> Unit) {
    val colors = LocalTsColors.current
    val tier = (state.account?.string("tier") ?: "free").lowercase()
    val handle = state.account?.string("handle")?.ifBlank { null }
    TsCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                Avatar(
                    state.account?.string("displayName") ?: handle ?: "your account",
                    size = 56,
                    avatarUrl = state.account?.string("avatar"),
                    signedIn = state.signedIn,
                )
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Space.xs),
                    ) {
                        Text(
                            state.account?.string("displayName") ?: handle ?: "Signed in",
                            style = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.SemiBold),
                            color = colors.textPrimary,
                            maxLines = 2,
                        )
                        TierMark(tier, markSize = 18)
                    }
                    handle?.let {
                        Text("@$it", style = TextStyle(fontSize = 14.sp), color = colors.textSecondary)
                    }
                    Text(
                        tier.replaceFirstChar { it.uppercase() } + " plan",
                        style = TextStyle(fontSize = 13.sp),
                        color = colors.textSecondary,
                    )
                }
            }
            handle?.let {
                val host = state.account?.string("host")?.ifBlank { null } ?: "https://tokenstat.ai"
                TsAccentButton(
                    label = "View public profile",
                    icon = ActionIcon.External.vector,
                    onClick = { onOpen("$host/$it?mobile=1") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

/// What the account is paying for, and where that is managed. Port of
/// `planCard`.
///
/// The sheet used to jump straight from the identity row to a "See plans"
/// button, so somebody on a paid plan could not see which plan, when it
/// renews, or that it is managed on the web rather than by Apple.
@Composable
private fun AccountPlanCard(state: ClientState, onPlans: () -> Unit) {
    val colors = LocalTsColors.current
    val tier = (state.account?.string("tier") ?: "free").lowercase()
    val billing = state.account?.get("billing") as? JsonObject
    val provider = billing?.string("provider")?.lowercase()
    val paid = tier in listOf("supporter", "patron", "legend")
    TsCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                TierMark(tier, markSize = 22)
                Text(
                    "Plan",
                    style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
            }
            val period = when {
                billing?.string("interval") == "month" -> " monthly"
                paid -> " yearly"
                else -> ""
            }
            val until = billing?.string("periodEnd")?.let { shortDay(it) }?.let { " · until $it" }.orEmpty()
            Text(
                tier.replaceFirstChar { it.uppercase() } + period + until,
                style = TextStyle(fontSize = 14.sp),
                color = colors.textSecondary,
            )
            // Where it is managed decides what can be done from here, so it
            // is a sentence rather than a guess at a button. Mirrors
            // `isAppleBilled` / `isPaddleBilled` / `isWebManagedPlan` in
            // `Models.swift`, with Google Play standing where the App Store
            // stands on the iPhone: a provider alone is not enough, the
            // subscription also has to be live, or founder and family access
            // reads as a store purchase nobody can cancel.
            val live = billing?.bool("hasLiveSub") == true ||
                billing?.string("status") in listOf("active", "trialing", "past_due") ||
                billing?.bool("entitled") == true
            when {
                provider == "google_play" && live -> {
                    Text(
                        "Bought on Google Play. See every plan here, then change or cancel in Play Store subscriptions.",
                        style = TextStyle(fontSize = 14.sp),
                        color = colors.textSecondary,
                    )
                    billing.string("scheduledTier")?.ifBlank { null }?.let { next ->
                        val nextPeriod = if (billing.string("scheduledInterval") == "month") " monthly" else " yearly"
                        Text(
                            "Switches to ${next.replaceFirstChar { it.uppercase() }}$nextPeriod at the next renewal.",
                            style = TextStyle(fontSize = 12.sp),
                            color = colors.accent,
                        )
                    }
                    TsAccentButton(
                        label = "See plans",
                        icon = ActionIcon.Plans.vector,
                        onClick = onPlans,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                provider == "paddle" && live -> Text(
                    "You subscribed on the website. Manage that plan there.",
                    style = TextStyle(fontSize = 14.sp),
                    color = colors.textSecondary,
                )
                paid -> Text(
                    "This plan is not a Google Play purchase. Manage it on the web.",
                    style = TextStyle(fontSize = 14.sp),
                    color = colors.textSecondary,
                )
                else -> {
                    Text(
                        "The app stays free. A yearly plan unlocks more devices, longer history, and remote management.",
                        style = TextStyle(fontSize = 14.sp),
                        color = colors.textSecondary,
                    )
                    TsAccentButton(
                        label = "See plans",
                        icon = ActionIcon.Plans.vector,
                        onClick = onPlans,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
    }
}


/// "Aug 26, 2026" from an ISO instant, in the reader's own zone. Port of
/// `ClientAccountSheet.shortDay`. Taking the first ten characters of the
/// string instead reads the UTC day, which is the wrong one either side of
/// midnight.
private fun shortDay(iso: String): String = runCatching {
    val instant = java.time.Instant.parse(iso)
    java.time.format.DateTimeFormatter
        .ofPattern("MMM d, yyyy")
        .withZone(java.time.ZoneId.systemDefault())
        .format(instant)
}.getOrElse { iso.take(10) }


/// One document that opens off the device. The arrow says it leaves the app,
/// which a plain row does not.
@Composable
private fun LegalLinkRow(label: String, onOpen: () -> Unit) {
    val colors = LocalTsColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onOpen)
            .padding(vertical = Space.s),
    ) {
        Text(label, color = colors.textPrimary, modifier = Modifier.weight(1f))
        Icon(
            ActionIcon.External.vector,
            null,
            tint = colors.textTertiary,
            modifier = Modifier.size(16.dp),
        )
    }
}


/// When anything last put numbers on the account. Port of `lastSync`.
///
/// A phone reads the archive and never writes one, and this card is where
/// that is said. Without it the Account pane went from the relay allowance
/// straight to Sign out.
@Composable
private fun AccountLastSyncCard(state: ClientState) {
    val colors = LocalTsColors.current
    TsCard(title = "Last sync", mark = "mark_sync") {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                Text("From any device", style = TextStyle(fontSize = 14.sp), color = colors.textSecondary)
                val at = state.account?.string("lastSyncAt")
                Text(
                    at?.let { formatRelativeDate(it) } ?: "Never",
                    style = TsType.numeric(14),
                    color = colors.textPrimary,
                )
            }
            Text(
                "This device reads that data. It does not upload an archive of its own.",
                style = TextStyle(fontSize = 14.sp),
                color = colors.textSecondary,
            )
        }
    }
}

/// Every machine on the account, with the one in your hand marked. Port of
/// `devices`. The Devices tab lists them too, but somebody checking what is
/// linked to an account is in the account, not in a tab about machines.
@Composable
private fun AccountDevicesCard(state: ClientState) {
    val colors = LocalTsColors.current
    val machines = ((state.account?.get("machines") as? JsonArray) ?: JsonArray(emptyList()))
        .mapNotNull { it as? JsonObject }
    val thisId = state.account?.string("thisMachineId")
    TsCard(title = "Devices", mark = "mark_device") {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Text(
                if (machines.isEmpty()) {
                    "None linked yet. Install tokenstat on a computer and sign in there."
                } else {
                    "${machines.size} linked to this account"
                },
                style = TextStyle(fontSize = 14.sp),
                color = colors.textSecondary,
            )
            machines.forEachIndexed { index, machine ->
                if (index > 0) HorizontalDivider(color = colors.border)
                val isThis = thisId != null && machine.string("id") == thisId
                val isHost = machine.string("kind") != "client"
                val name = DeviceCopy.displayName(machine.string("label"), machine.string("platform"), isHost)
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.m),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    DeviceGlyph(
                        name = name,
                        label = machine.string("label"),
                        platform = machine.string("platform"),
                        isHost = isHost,
                        tint = if (isThis) colors.accent else colors.textSecondary,
                    )
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Text(
                                name,
                                style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium),
                                color = colors.textPrimary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            if (isThis) {
                                Text("this device", style = TextStyle(fontSize = 12.sp), color = colors.accent)
                            }
                        }
                        Text(
                            formatRelativeDate(machine.string("lastSeenAt")) ?: "Never used",
                            style = TextStyle(fontSize = 12.sp),
                            color = colors.textSecondary,
                        )
                    }
                }
            }
        }
    }
}
