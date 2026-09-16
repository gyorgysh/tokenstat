// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui

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
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
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
import ai.tokenstat.tokenstat.ClientState
import ai.tokenstat.tokenstat.billing.PlayBillingManager
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.SegmentedCapsulePicker
import ai.tokenstat.tokenstat.ui.components.SkeletonCard
import ai.tokenstat.tokenstat.ui.components.SkeletonRows
import ai.tokenstat.tokenstat.ui.components.Stat
import ai.tokenstat.tokenstat.ui.components.TsBrandSwitch
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.components.cardPaddingDp
import ai.tokenstat.tokenstat.ui.heatmap.DayDetailSheet
import ai.tokenstat.tokenstat.ui.heatmap.YearHeatmap
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
import ai.tokenstat.tokenstat.ui.logic.friendlyError
import ai.tokenstat.tokenstat.ui.logic.harnessName
import ai.tokenstat.tokenstat.ui.logic.money
import ai.tokenstat.tokenstat.ui.logic.moneyValue
import ai.tokenstat.tokenstat.ui.logic.shortDate
import ai.tokenstat.tokenstat.ui.logic.normalizedRecovery
import ai.tokenstat.tokenstat.ui.logic.vaultPasswordProblems
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
import ai.tokenstat.tokenstat.ui.workspace.WorkSection
import ai.tokenstat.tokenstat.ui.workspace.WorkspaceChatRow
import ai.tokenstat.tokenstat.ui.workspace.WorkspaceFolderRow
import ai.tokenstat.tokenstat.ui.workspace.WorkspaceLayoutStore
import ai.tokenstat.tokenstat.ui.workspace.WorkspaceSection
import ai.tokenstat.tokenstat.ui.workspace.WorkspaceSessionRow
import ai.tokenstat.tokenstat.ui.workspace.WorkspacesEditor
import ai.tokenstat.tokenstat.ui.chrome.ConnectionChip
import ai.tokenstat.tokenstat.ui.chrome.FloatingTabBar
import ai.tokenstat.tokenstat.ui.chrome.TabSpec
import ai.tokenstat.tokenstat.ui.chrome.TsRefresh
import ai.tokenstat.tokenstat.ui.billing.PaywallSheet
import ai.tokenstat.tokenstat.ui.browser.PortBrowserScreen
import ai.tokenstat.tokenstat.ui.screen.ScreenViewerScreen
import ai.tokenstat.tokenstat.ui.ssh.SshConnectDialog
import ai.tokenstat.tokenstat.ui.ssh.SshHostRow
import ai.tokenstat.tokenstat.ui.ssh.SshKeyImportDialog
import ai.tokenstat.tokenstat.ui.ssh.SshKeyRenameDialog
import ai.tokenstat.tokenstat.ui.ssh.SshKeyRow
import ai.tokenstat.tokenstat.ui.ssh.SshSnippetRow
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.marks.HarnessMark
import ai.tokenstat.tokenstat.ui.ssh.SshSecrets
import ai.tokenstat.tokenstat.ui.ssh.SshVaultSync
import ai.tokenstat.tokenstat.ui.ssh.vaultEnvelopeOf
import ai.tokenstat.tokenstat.ui.marks.TierMark
import ai.tokenstat.tokenstat.notifications.PushRegistrar
import ai.tokenstat.tokenstat.ui.components.TierBadge
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.auth.Onboarding
import ai.tokenstat.tokenstat.ui.marks.Avatar
import ai.tokenstat.tokenstat.ui.marks.AwakeDot
import ai.tokenstat.tokenstat.ui.marks.DeviceGlyph
import ai.tokenstat.tokenstat.ui.marks.LogoMark
import ai.tokenstat.tokenstat.ui.marks.formatRelativeDate
import ai.tokenstat.tokenstat.ui.marks.UiSignals
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
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*

/// The brand accent from the shared token system.
@Composable
private fun tsAccent(): Color = LocalTsColors.current.accent

private enum class Destination(val label: String, val icon: ImageVector) {
    Home("Home", Icons.Default.GridView),
    Workspaces("Workspaces", Icons.Default.Folder),
    Insights("Insights", Icons.Default.BarChart),
    Devices("Devices", Icons.Default.Laptop),
}

private enum class Door { Onboarding, Loading, Login, SignedIn }

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
    TsTheme {
        val colors = LocalTsColors.current
        MaterialTheme(colorScheme = colors.toColorScheme(), typography = TsType.typography) {
            Surface(Modifier.fillMaxSize(), color = colors.background) {
                val door = when {
                    state.signedIn -> Door.SignedIn
                    !hasOnboarded -> Door.Onboarding
                    state.loading && state.account == null -> Door.Loading
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
private fun LoadingScreen() {
    val reduceMotion = rememberReduceMotion()
    Column(
        Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        LogoMark(size = 44, animated = !reduceMotion, loops = true)
        Spacer(Modifier.height(Space.s))
        Wordmark(size = 22, showsMark = false)
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
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // The mark rising once and landing: an intro page, not a spinner.
        LogoMark(size = 44, animated = !reduceMotion, loops = false)
        Spacer(Modifier.height(Space.s))
        Wordmark(size = 22, showsMark = false)
        Spacer(Modifier.height(12.dp))
        Text("Your AI coding activity, wherever your machines are.", color = colors.textSecondary)
        Spacer(Modifier.height(28.dp))
        if (pending != null) {
            // The approval is happening in the browser tab. Shown for the
            // same reason iOS shows it: the tab can be dismissed while the
            // sign-in is alive underneath, and without this the screen would
            // look exactly as it did before the tap.
            CircularProgressIndicator(color = colors.accent)
            Spacer(Modifier.height(Space.s))
            Text("Waiting for approval", style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(Space.xs))
            Text(
                notice ?: "Approve this device on tokenstat.ai. This screen updates by itself.",
                style = MaterialTheme.typography.bodySmall,
                color = colors.textSecondary,
            )
            Spacer(Modifier.height(Space.s))
            Text(
                pending!!.code,
                style = TextStyle(
                    fontFamily = FontFamily.Monospace,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 2.sp,
                ),
                modifier = Modifier
                    .clip(RoundedCornerShape(10.dp))
                    .background(colors.accentSoft)
                    .padding(vertical = Space.s, horizontal = Space.m),
            )
            Spacer(Modifier.height(Space.s))
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
        } else {
            TsAccentButton(
                label = "Sign in",
                icon = ActionIcon.SignIn.vector,
                onClick = { model.signIn(::openPage) },
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(Space.xs))
            Text(
                "No password to make. Signing in with GitHub, Google, X or Apple creates your account the first time.",
                style = MaterialTheme.typography.bodySmall,
                color = colors.textSecondary,
            )
        }
        val shown = signInError ?: error
        if (shown != null) {
            Spacer(Modifier.height(20.dp))
            Text(shown, color = colors.danger)
        }
        Spacer(Modifier.height(Space.s))
        TsSecondaryButton(
            label = "What is tokenstat?",
            icon = ActionIcon.Help.vector,
            onClick = onReboard,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(Space.s))
        // Signing in creates the account, so the two documents that govern
        // it belong on this screen and not only in Settings.
        LegalLine(
            onOpen = { openPage("$it?mobile=1") },
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun LegalLine(onOpen: (String) -> Unit, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    val terms = "Terms"
    val privacy = "Privacy policy"
    val text = "By signing in you accept the $terms and the $privacy."
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
        style = MaterialTheme.typography.bodySmall.copy(color = colors.textSecondary),
        modifier = modifier,
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

    val colors = LocalTsColors.current
    Scaffold(
        containerColor = colors.background,
        topBar = {
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
                    IconButton(onClick = { accountOpen = true }) {
                        Avatar(state.account?.string("displayName") ?: state.account?.string("handle") ?: "?")
                    }
                },
                actions = {
                    IconButton(onClick = { searchOpen = true }) {
                        Icon(ActionIcon.Search.vector, "Search", tint = colors.controlGlyph)
                    }
                    ConnectionChip(state.connection, onRetry = { model.retryConnection() })
                    IconButton(onClick = {
                        UiSignals.beganRefreshing()
                        model.refresh()
                    }) { Icon(ActionIcon.Refresh.vector, "Refresh", tint = colors.controlGlyph) }
                },
            )
        },
        bottomBar = {
            if (!expanded) {
                FloatingTabBar(
                    selected = Destination.entries.indexOf(selected),
                    tabs = Destination.entries.map { TabSpec(it.label, it.icon) },
                    onSelect = { selected = Destination.entries[it] },
                )
            }
        },
    ) { padding ->
        Row(Modifier.fillMaxSize().padding(padding)) {
            if (expanded) {
                NavigationRail(containerColor = colors.tabStrip, contentColor = colors.textSecondary) {
                    Spacer(Modifier.height(8.dp))
                    Destination.entries.forEach { destination ->
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
                        onOpenWork = { hostId, folderId ->
                            pendingWorkHostId = hostId
                            pendingWorkFolderId = folderId
                            selected = Destination.Workspaces
                        },
                        onOpenDevices = { selected = Destination.Devices },
                        onSetupWizard = { wizardOpen = true },
                    )
                    Destination.Workspaces -> if (state.canRemote) {
                        WorkspacesScreen(
                            model = model,
                            state = state,
                            expanded = expanded,
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
                        RemotePaywall { accountOpen = true }
                    }
                    Destination.Insights -> InsightsScreen(model, state, onHome = { selected = Destination.Home })
                    Destination.Devices -> DevicesScreen(
                        model,
                        state,
                        onPlans = { accountOpen = true },
                        onOpenWork = { id ->
                            pendingWorkHostId = id
                            selected = Destination.Workspaces
                        },
                        onSetupWizard = { wizardOpen = true },
                        sshOpenSignal = sshSignal,
                        pendingDeviceId = pendingDeviceId,
                        onPendingDeviceConsumed = { pendingDeviceId = null },
                    )
                }
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
    if (accountOpen) AccountDialog(state, model, billing, onDismiss = { accountOpen = false })
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

@Composable
private fun RemotePaywall(onPlans: () -> Unit) {
    val colors = LocalTsColors.current
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Remote is on Patron", style = MaterialTheme.typography.headlineSmall, color = colors.textPrimary)
        Spacer(Modifier.height(8.dp))
        Text(
            "This device already shares the account and sees the usage from every device on it. Opening folders and terminals on the computer is a paid feature.",
            color = colors.textSecondary,
        )
        Spacer(Modifier.height(20.dp))
        TsAccentButton(label = "See plans", onClick = onPlans)
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
) {
    val calendar = state.home
    val rows = calendar?.get("rows") as? JsonArray
    val cells = rows.orEmpty().flatMap { row ->
        (row as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
    }
    var selectedDay by remember { mutableStateOf<JsonObject?>(null) }
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
    // Read once for the whole pass. The stores decode on every access, and
    // reading them again inside the rows is what lets a list change shape
    // underneath.
    stores.revision.value
    val (order, hidden) = stores.layout()
    val sections = order.filter { it !in hidden }
    val places = stores.places(accountHandle)
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
        modifier = Modifier.fillMaxSize(),
    ) {
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(cardPaddingDp),
        verticalArrangement = Arrangement.spacedBy(Space.m),
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
                            MetricCard("Today", money(spendSince(cells, calendar.string("last"), 1)), Modifier.weight(1f))
                            MetricCard("This week", money(spendSince(cells, calendar.string("last"), 7)), Modifier.weight(1f))
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
                            TsCard(
                                title = "Activity",
                                accessory = {
                                    Column(horizontalAlignment = Alignment.End) {
                                        Text(
                                            "${calendar.int("activeDays") ?: 0} active days",
                                            style = MaterialTheme.typography.bodySmall,
                                            color = LocalTsColors.current.textSecondary,
                                        )
                                        calendar.string("freshness")?.let {
                                            Text(
                                                it,
                                                style = MaterialTheme.typography.bodySmall,
                                                color = LocalTsColors.current.textSecondary.copy(alpha = 0.8f),
                                            )
                                        }
                                    }
                                },
                            ) {
                                if (cells.isEmpty()) Text("No synced activity yet.", color = LocalTsColors.current.textSecondary)
                                else {
                                    Text(
                                        "Swipe for the whole year, hold a day to read it",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = LocalTsColors.current.textSecondary,
                                    )
                                    YearHeatmap(
                                        rows!!,
                                        calendar.get("months") as? JsonArray ?: JsonArray(emptyList()),
                                        onSelectDay = { selectedDay = it },
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
                    item { SectionLabel("Plan limits") }
                    val planError = state.limitsError
                    if (planError != null) {
                        item {
                            Text(
                                "Plan readings could not be refreshed. Pull to try again.",
                                style = MaterialTheme.typography.bodySmall,
                                color = LocalTsColors.current.textSecondary,
                            )
                        }
                    }
                    val sorted = LimitLogic.closestToFullFirst(
                        state.limits.mapNotNull { it as? JsonObject },
                    ) { reading ->
                        LimitLogic.peakPercent(
                            ((reading["windows"] as? JsonArray).orEmpty())
                                .mapNotNull { (it as? JsonObject)?.doubleOrNull("percent") },
                        )
                    }
                    if (sorted.isEmpty() && planError == null) {
                        item {
                            Arrive(reduceMotion) {
                                EmptyCard(
                                    "No readings yet",
                                    "On a Mac, turn on Share plan limits with my devices in Account, then refresh limits or sync.",
                                )
                            }
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
@Composable
private fun HistoryLockBanner() {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.accentSoft.copy(alpha = 0.55f))
            .border(1.dp, colors.border, RoundedCornerShape(10.dp))
            .padding(horizontal = Space.m, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Older history is locked. ", style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
            Text(
                "Free shows the last 30 days in full. Older days keep the year shape only.",
                style = TextStyle(fontSize = 12.sp),
                color = colors.textSecondary,
            )
        }
        Text(
            "Upgrade to see the year",
            style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold),
            color = colors.accent,
            modifier = Modifier.clickable(
                indication = null,
                interactionSource = remember { MutableInteractionSource() },
            ) {
                runCatching {
                    CustomTabsIntent.Builder().build().launchUrl(context, "https://tokenstat.ai/pricing".toUri())
                }
            },
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
private fun InsightsScreen(model: AppViewModel, state: ClientState, onHome: () -> Unit) {
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
        modifier = Modifier.fillMaxSize(),
    ) {
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(cardPaddingDp),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        item {
            Text("Insights", style = MaterialTheme.typography.headlineSmall, color = colors.textPrimary)
            Spacer(Modifier.height(Space.s))
            SegmentedCapsulePicker(
                options = cutNames.mapIndexed { i, name -> Triple(i, name, null as ImageVector?) },
                selection = cut,
                onSelect = { cut = it },
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(Space.s))
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                placeholder = { Text("Search") },
                singleLine = true,
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
                        icon = if (needsSignIn) Icons.Default.Person else Icons.Default.Warning,
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
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.textSecondary,
                    )
                }
            } else {
                item { SectionLabel(cutNames[cut]) }
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
    TsCard(title = "This period") {
        Text(
            moneyValue(total, estimated, complete),
            style = TsType.numeric(26, FontWeight.Medium),
            color = tsAccent(),
            maxLines = 1,
        )
        Text(
            "at list rates, across every device",
            style = MaterialTheme.typography.bodySmall,
            color = colors.textSecondary,
        )
        Spacer(Modifier.height(Space.s))
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            InsightFactPanel(label = "Tokens", value = compactTokens(tokens), modifier = Modifier.weight(1f))
            InsightFactPanel(label = "Events", value = compactTokens(events), modifier = Modifier.weight(1f))
            InsightFactPanel(label = cutName, value = rows.size.toString(), modifier = Modifier.weight(1f))
        }
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

@Composable
private fun InsightFactPanel(label: String, value: String, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    Column(modifier) {
        Text(value, style = TsType.numeric(16, FontWeight.Medium), color = colors.accent, maxLines = 1)
        Text(label, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary, maxLines = 1)
    }
}

/// Tokens per day as bars, the Day cut's chart on iOS. Drawn on a Canvas:
/// 53 accent bars need no chart dependency.
@Composable
private fun InsightDayChart(rows: List<JsonObject>) {
    val colors = LocalTsColors.current
    val days = rows.sortedBy { it.string("key") ?: "" }
    val peak = days.maxOfOrNull { it["counters"]?.jsonObject?.long("total") ?: 0L } ?: 0L
    TsCard(title = "Daily activity") {
        Text(
            "Tokens per day · cache included",
            style = MaterialTheme.typography.bodySmall,
            color = colors.textSecondary,
        )
        Spacer(Modifier.height(Space.s))
        val bars = days.map { it["counters"]?.jsonObject?.long("total") ?: 0L }
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
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                )
                val tokens = row["counters"]?.jsonObject?.long("total") ?: 0L
                val events = row.long("events") ?: 0L
                Text(
                    "${compactTokens(tokens)} tokens, ${compactTokens(events)} events",
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.textSecondary,
                )
            }
            Spacer(Modifier.width(Space.s))
            Text(moneyValue(value, estimated, complete), color = tsAccent(), style = TsType.numeric(14))
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
    val machines = state.account?.get("machines") as? JsonArray ?: JsonArray(emptyList())
    val selected = machines.map { it.jsonObject }.find { it.string("id") == selectedId }
    val thisId = state.account?.string("thisMachineId")
    // Each host's share of spend, fetched once when the screen opens like
    // `ClientDevicesModel`: one request per device on the host's side.
    var usageByMachine by remember { mutableStateOf<Map<String, Long>>(emptyMap()) }
    var usageError by remember { mutableStateOf<String?>(null) }
    val tierDays = when (state.account?.string("tier")?.lowercase()) {
        "legend", "patron" -> 3650
        "supporter" -> 365
        else -> 30
    }
    LaunchedEffect(machines, tierDays) {
        val ids = machines.mapNotNull { (it as? JsonObject)?.takeIf { m -> m.string("kind") != "client" }?.string("id") }
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
            usageByMachine = rows.mapNotNull { (it as? JsonObject)?.let { row -> row.string("machine")?.let { m -> m to (row.long("valueMicros") ?: 0L) } } }.toMap()
            usageError = null
        }.onFailure {
            // The list still drew. What failed is the share of spend beside
            // each name, which is worth one quiet line and not an error card
            // where the devices should be.
            usageError = "Could not work out what each device spent."
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
            modifier = Modifier.fillMaxSize(),
        ) {
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
            item {
                    Text(
                        "Devices",
                        style = MaterialTheme.typography.headlineSmall,
                        color = LocalTsColors.current.textPrimary,
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
                            Icon(ActionIcon.Next.vector, null, tint = colors.controlGlyph)
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
                            Icon(ActionIcon.Next.vector, null, tint = colors.controlGlyph)
                        }
                    }
                }
                items(machines) { machine ->
                    val value = machine.jsonObject
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
                                )
                                Text(
                                    DeviceCopy.caption(value.string("label"), value.string("id"), status),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = colors.textSecondary,
                                )
                            }
                            if (showsSpend) {
                                val micros = value.string("id")?.let { usageByMachine[it] }
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
                            Icon(ActionIcon.Next.vector, null, tint = colors.controlGlyph)
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

@Composable
private fun DeviceDetailScreen(
    model: AppViewModel,
    state: ClientState,
    machine: JsonObject,
    thisId: String?,
    onBack: () -> Unit,
    onPlans: () -> Unit,
    onOpenWork: () -> Unit,
) {
    val isThis = thisId != null && machine.string("id") == thisId
    val isHost = machine.string("kind") != "client"
    val peer = machine.string("publicIdentity")
    val online = machine.get("online")?.jsonPrimitive?.booleanOrNull
    val hasKey = !peer.isNullOrEmpty()
    val label = DeviceCopy.displayName(machine.string("label"), machine.string("platform"), isHost)
    var viewing by remember { mutableStateOf(false) }
    val detailScope = rememberCoroutineScope()
    // Naming a device, in the row where the name is read. Empty is the undo
    // rather than an error: the machine goes back to naming itself.
    var renaming by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    var savingName by remember { mutableStateOf(false) }
    var renameError by remember { mutableStateOf<String?>(null) }
    var renamedTo by remember { mutableStateOf<String?>(null) }
    val currentName = renamedTo ?: machine.string("label") ?: label
    fun saveName() {
        val id = machine.string("id")
        if (id.isNullOrEmpty()) {
            renameError = "This device has no id on the account yet."
            return
        }
        savingName = true
        detailScope.launch {
            runCatching {
                model.core(
                    "account.renameMachine",
                    buildJsonObject {
                        put("id", id)
                        put("name", draft.trim())
                    },
                )
            }.onSuccess {
                renamedTo = draft.trim().ifEmpty { null }
                renameError = null
                renaming = false
                model.refresh()
            }.onFailure {
                renameError = friendlyError(it.message).message
            }
            savingName = false
        }
    }
    if (viewing && !peer.isNullOrEmpty()) {
        ScreenViewerScreen(
            model = model,
            peer = peer,
            hostLabel = currentName,
            onClose = { viewing = false },
        )
        return
    }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            Text(currentName, style = MaterialTheme.typography.headlineSmall)
        }
        if (!isThis && !peer.isNullOrEmpty() && online == true) {
            HostStatsBar(model, peer)
        }
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Reach", style = MaterialTheme.typography.titleMedium)
                Text(
                    DeviceCopy.reach(isThis, online, hasKey),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("What this is", style = MaterialTheme.typography.titleMedium)
                if (renaming) {
                    Text("Name", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    OutlinedTextField(
                        value = draft,
                        onValueChange = { draft = it },
                        placeholder = { Text("Name this device") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TsAccentButton(
                            label = if (savingName) "Saving…" else "Save",
                            enabled = !savingName,
                            onClick = { saveName() },
                        )
                        TsSecondaryButton(
                            label = "Cancel",
                            onClick = { renaming = false; renameError = null },
                        )
                    }
                    Text(
                        "Empty puts back the name the device gives itself.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("Name", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(
                                machine.string("label")?.ifEmpty { null } ?: "not named on this account",
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                        }
                        // Any device on the account, not only this phone. A
                        // Linux server with nothing but the CLI on it has no
                        // other way to be named.
                        TsSecondaryButton(
                            label = "Rename",
                            small = true,
                            onClick = {
                                draft = machine.string("label") ?: ""
                                renaming = true
                            },
                        )
                    }
                }
                renameError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                machine.string("platform")?.let {
                    Column {
                        Text("What it runs", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(it, color = MaterialTheme.colorScheme.onSurface)
                    }
                }
                machine.string("id")?.let {
                    Column {
                        Text("Device id", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurface)
                    }
                }
                // Hosts upload an archive, so their sync time is a product
                // fact. Phones never do: lastSyncAt there is not a fact.
                if (isHost) {
                    Column {
                        Text("Last sync", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(
                            DeviceCopy.lastSync(true, machine.string("lastSyncAt")),
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                } else {
                    formatRelativeDate(machine.string("lastSeenAt"))?.let { seen ->
                        Column {
                            Text("Last used", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(seen, color = MaterialTheme.colorScheme.onSurface)
                        }
                    }
                }
            }
        }
        if (!isThis && isHost && !peer.isNullOrEmpty()) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("From this device", style = MaterialTheme.typography.titleMedium)
                    if (state.canRemote) {
                        TsAccentButton(label = "Open work", onClick = onOpenWork, modifier = Modifier.fillMaxWidth())
                        Text(
                            if (online == true) "Folders, terminals and sessions on this computer."
                            else "It is asleep. Opening this will wake nothing, but it will try.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    } else {
                        Text("Opening folders and terminals on this computer is on Patron.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        TsAccentButton(label = "See plans", onClick = onPlans)
                    }
                    TsSecondaryButton(
                        label = "View screen",
                        onClick = { viewing = true },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Text(
                        if ((state.account?.string("tier") ?: "").equals("legend", ignoreCase = true)) {
                            "End-to-end encrypted from this device."
                        } else {
                            "Requires Legend."
                        },
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun HostStatsBar(model: AppViewModel, peer: String) {
    val colors = LocalTsColors.current
    var stats by remember { mutableStateOf<JsonObject?>(null) }
    var failed by remember { mutableStateOf(false) }
    var route by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(peer) {
        runCatching { model.prepareHost(peer, "Host") }
        runCatching { model.core("remote.status") as? JsonObject }
            .onSuccess { status ->
                val peers = ((status?.get("traffic") as? JsonObject)?.get("peers") as? JsonArray)
                    .orEmpty().mapNotNull { it as? JsonObject }
                // Missing stays missing: never invent a path nobody observed.
                route = peers.find { (it.string("peer") ?: "").equals(peer, ignoreCase = true) }
                    ?.string("route")?.takeIf { it == "direct" || it == "relay" }
            }
        while (true) {
            runCatching { model.hostStats(peer) }
                .onSuccess { stats = it; failed = false }
                .onFailure { if (stats == null) failed = true }
            delay(2500)
        }
    }
    // Missing readings stay off the bar rather than drawing as zero.
    val power = HostStatsFormat.powerLabel(
        charging = stats?.bool("charging") == true,
        percent = stats?.int("percent"),
        power = stats?.string("power"),
        failed = failed,
        hadStats = stats != null,
    )
    val cpu = stats?.doubleOrNull("cpu")?.let { HostStatsFormat.cpuLabel(it) }
        ?: if (stats == null && !failed) "…" else "n/a"
    val ram = run {
        val used = stats?.long("ramUsedBytes")
        val total = stats?.long("ramTotalBytes")
        if (used != null && total != null && total > 0) HostStatsFormat.ramLabel(used, total)
        else if (stats == null && !failed) "…"
        else "n/a"
    }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                HostStatCell(title = "Power", value = power, modifier = Modifier.weight(1f))
                HostStatCell(title = "CPU", value = cpu, modifier = Modifier.weight(1f))
                HostStatCell(title = "Memory", value = ram, modifier = Modifier.weight(1f))
            }
            // The same wording and colours the screen viewer uses.
            when (route) {
                "direct" -> Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(7.dp).background(colors.success, RoundedCornerShape(4.dp)))
                    Spacer(Modifier.width(6.dp))
                    Text("Direct connection", style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                }
                "relay" -> Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(7.dp).background(colors.warning, RoundedCornerShape(4.dp)))
                    Spacer(Modifier.width(6.dp))
                    Text("Encrypted relay", style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                }
            }
            Text(
                "Read from this computer over the encrypted tunnel. It is not uploaded with usage.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun HostStatCell(title: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier) {
        Text(value, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
        Text(title, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
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
    var sshSession by remember { mutableStateOf<Pair<String, String>?>(null) }
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
    LaunchedEffect(Unit) { load() }

    val live = sshSession
    if (live != null) {
        SshTerminalScreen(
            model = model,
            sessionId = live.first,
            hostLabel = live.second,
            snippets = snippets,
            onClose = { sshSession = null },
        )
        return
    }

    Column(Modifier.fillMaxSize()) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (onBack != null) {
                    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
                }
                Text("SSH", style = MaterialTheme.typography.headlineSmall)
            }
            if (!vaultAllowed) {
                Spacer(Modifier.height(10.dp))
                VaultUpgradeCard(onPlans)
            } else if (vaultAllowed) {
                Spacer(Modifier.height(10.dp))
                ElevatedCard(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.EnhancedEncryption, null, tint = tsAccent())
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    when {
                                        recoveryWords != null -> "Recovery code not confirmed"
                                        vault?.bool("locked") == true -> "Encrypted vault · locked"
                                        vault?.bool("created") == true -> "Encrypted vault ready"
                                        else -> "Encrypted cross-device vault"
                                    },
                                    fontWeight = FontWeight.SemiBold,
                                )
                                Text(
                                    if (recoveryWords != null) "Close is allowed. Confirm the code when you have stored it, or discard the vault and create a new one."
                                    else "One password protects every saved server and key, on all your devices.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            // Sync and delete live in the popup menu, not as
                            // full-width sections: this card is a status, and
                            // the typed confirmation dialog still carries the
                            // destroy-everywhere warning where it is read.
                            if (vault?.bool("created") == true && recoveryWords == null) {
                                var vaultMenu by remember { mutableStateOf(false) }
                                IconButton(onClick = { vaultMenu = true }) {
                                    Icon(ActionIcon.More.vector, "Vault actions")
                                }
                                DropdownMenu(expanded = vaultMenu, onDismissRequest = { vaultMenu = false }) {
                                    DropdownMenuItem(
                                        text = { Text("Sync now") },
                                        onClick = {
                                            vaultMenu = false
                                            scope.launch { load(syncAsked = true) }
                                        },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Delete vault", color = LocalTsColors.current.danger) },
                                        onClick = { vaultMenu = false; confirmDrop = true },
                                    )
                                }
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (recoveryWords != null) {
                                Button(onClick = { showingRecovery = true }) { Text("Show code") }
                                TextButton(onClick = { scope.launch { dropFreshVault() } }) { Text("Discard vault") }
                            } else if (vault?.bool("created") != true) {
                                Button(onClick = { vaultSetup = true }) { Text("Set up") }
                            } else if (vault?.bool("locked") == true || vault?.bool("enrolled") != true) {
                                Button(onClick = { vaultSetup = true }) { Text("Unlock") }
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
        PrimaryTabRow(selectedTabIndex = tab) {
            tabs.forEachIndexed { index, title -> Tab(selected = tab == index, onClick = { tab = index }, text = { Text(title) }) }
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                query,
                { query = it },
                Modifier.weight(1f),
                label = { Text("Search ${tabs[tab].lowercase()}") },
                singleLine = true,
            )
            TextButton(onClick = {
                if (tab == 0) addHost = true
                else if (tab == 2) addSnippet = true
                else addKey = true
            }) { Text("Add") }
        }
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
            LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
                                        item.string("id")?.let { model.core("ssh.host.delete", buildJsonObject { put("id", it) }) }
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
                sshSession = id to label
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
    // The connected machine is one at a time. Selecting shows the card;
    // connecting dials it, and only a connected host loads work.
    var host by remember { mutableStateOf<JsonObject?>(null) }
    var connectedPeer by remember { mutableStateOf<String?>(null) }
    var connectingPeer by remember { mutableStateOf<String?>(null) }
    var folders by remember { mutableStateOf(JsonArray(emptyList())) }
    var sessions by remember { mutableStateOf(JsonArray(emptyList())) }
    var chats by remember { mutableStateOf(JsonArray(emptyList())) }
    var allowed by remember { mutableStateOf<Boolean?>(null) }
    var requesting by remember { mutableStateOf(false) }
    var requestNotice by remember { mutableStateOf<String?>(null) }
    var search by remember { mutableStateOf("") }
    var customizing by remember { mutableStateOf(false) }
    var picking by remember { mutableStateOf(false) }
    var choosingFor by remember { mutableStateOf<String?>(null) }
    var initialSection by remember { mutableStateOf<String?>(null) }
    var autoTick by remember { mutableStateOf(0) }
    var selectedFolder by remember { mutableStateOf<JsonObject?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun requestAccess(peer: String) {
        requesting = true
        runCatching {
            model.workspaceSection(peer, "workspace.access.ask", buildJsonObject {}) as JsonObject
        }.onSuccess { answer ->
            requestNotice = if (answer.bool("granted")) {
                "This device already has access. Pull to refresh."
            } else {
                "Asked. On that computer run `tokenstat host access approve` (over SSH is fine) and pick this device."
            }
        }.onFailure { requestNotice = it.message }
        requesting = false
    }

    suspend fun connect(machine: JsonObject) {
        val peer = machine.string("publicIdentity") ?: return
        if (connectingPeer != null) return
        connectingPeer = peer
        host = machine
        allowed = null
        error = null
        requestNotice = null
        // The work still on screen belongs to the previous host; showing it
        // beside the new host's name is one lie waiting to be clicked.
        folders = JsonArray(emptyList())
        sessions = JsonArray(emptyList())
        chats = JsonArray(emptyList())
        runCatching {
            model.prepareHost(peer, machine.string("label") ?: "Host")
            // Asked before anything is loaded. Being paired is not being let
            // in: that computer allows each device to open its work
            // explicitly.
            val check = model.workspaceSection(peer, "workspace.access.check", buildJsonObject {}) as? JsonObject
            allowed = check?.bool("allowed")
            if (allowed != true) {
                if (requestNotice == null) requestAccess(peer)
                return@runCatching
            }
            folders = model.workspaces(peer)
            sessions = runCatching {
                model.workspaceSection(peer, "pty.list", buildJsonObject { put("includeRemote", false) }) as? JsonArray
            }.getOrNull() ?: JsonArray(emptyList())
            chats = runCatching {
                model.workspaceSection(peer, "chat.recent", buildJsonObject { put("limit", 50) }) as? JsonArray
            }.getOrNull() ?: JsonArray(emptyList())
            connectedPeer = peer
            layoutStore.setLastConnectedHost(peer)
        }.onFailure {
            android.util.Log.e("ts-workspaces", "connect failed: ${it::class.java.name}", it)
            error = it.message
            allowed = null
            connectedPeer = null
        }
        connectingPeer = null
    }

    fun disconnect() {
        connectedPeer = null
        allowed = null
        requestNotice = null
        folders = JsonArray(emptyList())
        sessions = JsonArray(emptyList())
        chats = JsonArray(emptyList())
        selectedFolder = null
    }

    fun refreshHost() {
        host?.let { scope.launch { connect(it) } }
    }

    // The one place that dials without being asked: the last host, when it
    // is awake and its switch is on. Fires as the host list arrives and as
    // machines wake, which is what makes "keep trying until online" work.
    LaunchedEffect(hosts, connectedPeer, connectingPeer) {
        if (connectedPeer != null || connectingPeer != null) return@LaunchedEffect
        val last = layoutStore.lastConnectedHost() ?: return@LaunchedEffect
        if (!layoutStore.isAutoConnectEnabled(last)) return@LaunchedEffect
        val machine = hosts.find { it.string("publicIdentity") == last } ?: return@LaunchedEffect
        if (machine.get("online")?.jsonPrimitive?.booleanOrNull == false) return@LaunchedEffect
        connect(machine)
    }
    // Somebody who walks over, approves and comes back is not looking at the
    // same refusal with no sign that anything changed: while refused, ask
    // again every few seconds and load when the answer lands.
    LaunchedEffect(connectedPeer, allowed, host) {
        if (connectedPeer != null || allowed != false) return@LaunchedEffect
        val machine = host ?: return@LaunchedEffect
        while (true) {
            delay(4000)
            val peer = machine.string("publicIdentity") ?: return@LaunchedEffect
            val now = runCatching {
                (model.workspaceSection(peer, "workspace.access.check", buildJsonObject {}) as? JsonObject)?.bool("allowed")
            }.getOrNull()
            if (now == true) {
                connect(machine)
                return@LaunchedEffect
            }
        }
    }
    LaunchedEffect(pendingHostId, hosts) {
        val id = pendingHostId ?: return@LaunchedEffect
        val match = hosts.find { it.string("id") == id } ?: return@LaunchedEffect
        host = match
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
        selectedFolder = match
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
        val handle = state.account?.string("handle") ?: state.account?.string("displayName") ?: ""
        record.recordPlace(handle, peer, id, folderName ?: "Workspace", RecentPlaces.Kind.WORKSPACE)
    }
    LaunchedEffect(folders, pendingSelectFolderId) {
        val id = pendingSelectFolderId ?: return@LaunchedEffect
        val match = folders.mapNotNull { it as? JsonObject }.find { it.string("id") == id }
            ?: return@LaunchedEffect
        selectedFolder = match
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
        selectedFolder = folder
        initialSection = "Chat"
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
            modifier = modifier,
        ) {
            WorkspaceList(
            hosts = hosts,
            thisMachine = thisMachine,
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
            onFolder = { selectedFolder = it; initialSection = null },
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
            )
        }
    } else if (boundFolder != null && boundHost != null) {
        WorkspaceDetail(
            model, boundHost, boundFolder, Modifier.fillMaxSize(),
            initialSection = initialSection,
            onBack = { selectedFolder = null; initialSection = null },
            onOpenTerminal = { id -> terminalSession = WorkspaceTerminalRequest(id, boundFolder.string("id") ?: "", boundHost.string("label") ?: "Host") },
            onOpenBrowser = { url, port -> browser = url to port },
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
                selectedFolder = folder
                initialSection = section
                choosingFor = null
            },
            onDismiss = { choosingFor = null },
        )
    }
}

private data class WorkspaceTerminalRequest(val sessionId: String?, val workspaceId: String, val hostLabel: String)

@Composable
private fun WorkspaceList(
    hosts: List<JsonObject>,
    thisMachine: JsonObject?,
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
    modifier: Modifier,
) {
    val colors = LocalTsColors.current
    val connectedHost = hosts.find { it.string("publicIdentity") == connectedPeer }
    val folderRows = folders.mapNotNull { it as? JsonObject }
    val sessionRows = sessions.mapNotNull { it as? JsonObject }
    val chatRows = chats.mapNotNull { it as? JsonObject }
    val visibleSections = layoutOrder.filter { it !in layoutHidden }
    var chatsExpanded by remember { mutableStateOf(false) }
    LazyColumn(modifier, contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Text("Workspaces", style = MaterialTheme.typography.headlineSmall, color = colors.textPrimary) }
        error?.let { item { ErrorCard(it) } }
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
        item { SectionLabel("Hosts on your account") }
        items(hosts) { machine ->
            val peer = machine.string("publicIdentity") ?: ""
            val name = DeviceCopy.displayName(machine.string("label"), machine.string("platform"), true)
            HostCard(
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
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                ) {
                    AwakeDot(online = true)
                    Spacer(Modifier.width(Space.s))
                    DeviceGlyph(name = name, label = machine.string("label"), platform = machine.string("platform"), isHost = false, sizeDp = 22)
                    Spacer(Modifier.width(Space.s))
                    Column(Modifier.weight(1f)) {
                        Text(name, fontWeight = FontWeight.Medium, color = colors.textPrimary, maxLines = 1)
                        Text("This device", style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                    }
                    Text("Online", style = MaterialTheme.typography.bodySmall, color = colors.accent)
                }
            }
        }
        val host = connectedHost ?: return@LazyColumn
        val hostName = DeviceCopy.displayName(host.string("label"), host.string("platform"), true)
        val peer = host.string("publicIdentity") ?: ""
        if (allowed == false) {
            item {
                RequestAccessCard(
                    hostName = hostName,
                    requesting = requesting,
                    notice = requestNotice,
                    onRequest = { onRequestAccess(peer) },
                )
            }
            return@LazyColumn
        }
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
            OutlinedTextField(
                value = search,
                onValueChange = onSearch,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Search folders or paths") },
                leadingIcon = { Icon(ActionIcon.Search.vector, null) },
                singleLine = true,
            )
        }
        visibleSections.forEach { section ->
            when (section) {
                WorkSection.FOLDERS -> if (folderRows.isNotEmpty()) {
                    item {
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                            SectionLabel("Folders", modifier = Modifier.weight(1f))
                            TextButton(onClick = onChooseFolder) {
                                Text("Choose", style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, color = colors.accent)
                            }
                            TextButton(onClick = onClone) {
                                Text("Clone", style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, color = colors.accent)
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
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                            SectionLabel("Recent chats", modifier = Modifier.weight(1f))
                            if (folderRows.isNotEmpty()) {
                                TextButton(onClick = onNewChat) {
                                    Text("New chat", style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, color = colors.accent)
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
                            TextButton(onClick = { chatsExpanded = !chatsExpanded }, modifier = Modifier.fillMaxWidth()) {
                                Text(if (chatsExpanded) "Show less" else "Show more", color = colors.accent)
                            }
                        }
                    }
                }
                WorkSection.SESSIONS -> if (sessionRows.isNotEmpty() || folderRows.isNotEmpty()) {
                    item {
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                            SectionLabel("All sessions", modifier = Modifier.weight(1f))
                            if (folderRows.isNotEmpty()) {
                                TextButton(onClick = onNewSession) {
                                    Text("New session", style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, color = colors.accent)
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
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.textSecondary,
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

private data class WorkspacePart(val label: String, val method: String, val icon: ImageVector, val kind: String? = null)
private val workspaceParts = listOf(
    WorkspacePart("Sessions", "pty.list", Icons.Default.Terminal),
    WorkspacePart("Chat", "chat.list", Icons.Default.ChatBubble),
    WorkspacePart("Pulls", "pulls.list", Icons.Default.MergeType),
    WorkspacePart("Changes", "workspace.status", Icons.Default.Difference),
    WorkspacePart("History", "workspace.log", Icons.Default.History),
    WorkspacePart("Tasks", "todo.list", Icons.Default.Checklist),
    // Notes share the todo board's method; the Apple client filters the same
    // answer down to note cards, so the tab is not a second Tasks.
    WorkspacePart("Notes", "todo.list", Icons.AutoMirrored.Filled.Notes, kind = "note"),
    WorkspacePart("Workflows", "workflow.list", Icons.Default.AccountTree),
    WorkspacePart("Automations", "automation.list", Icons.Default.Bolt),
    WorkspacePart("Files", "workspace.tree", Icons.Default.FolderOpen),
    WorkspacePart("Browser", "proxy.listen", Icons.Default.Language),
)

@Composable
private fun WorkspaceDetail(
    model: AppViewModel, host: JsonObject, folder: JsonObject, modifier: Modifier,
    initialSection: String? = null,
    onBack: (() -> Unit)? = null,
    onOpenTerminal: (String?) -> Unit = {},
    onOpenBrowser: (String, Int) -> Unit = { _, _ -> },
) {
    var section by rememberSaveable(folder.string("id"), initialSection) { mutableStateOf(initialSection ?: "Sessions") }
    val peer = host.string("publicIdentity") ?: ""
    val workspace = folder.string("id") ?: ""
    Column(modifier.padding(cardPaddingDp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (onBack != null) IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            Column {
                Text(folder.string("name") ?: "Workspace", style = MaterialTheme.typography.headlineSmall, color = LocalTsColors.current.textPrimary)
                Text(section, style = MaterialTheme.typography.bodySmall, color = LocalTsColors.current.textSecondary)
            }
        }
        Spacer(Modifier.height(Space.s))
        // Section picker in the app's own capsule language.
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            workspaceParts.forEach { part ->
                val selectedChip = section == part.label
                if (selectedChip) {
                    TsAccentButton(label = part.label, small = true, onClick = { section = part.label })
                } else {
                    TsSecondaryButton(label = part.label, small = true, onClick = { section = part.label })
                }
            }
        }
        Spacer(Modifier.height(Space.m))
        WorkspaceSection(
            model = model,
            peer = peer,
            workspace = workspace,
            hostLabel = host.string("label") ?: "Host",
            section = section,
            protocol = HostContracts.protocolOf(host),
            folderName = folder.string("name") ?: "",
            // The sections scroll themselves. A scrolled modifier here hands
            // their LazyColumns infinite height and crashes on open.
            modifier = Modifier.weight(1f),
            onOpenTerminal = onOpenTerminal,
            onOpenBrowser = onOpenBrowser,
            onOpenSection = { section = it },
        )
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun AccountDialog(
    state: ClientState,
    model: AppViewModel,
    billing: PlayBillingManager,
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
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.l)
                .padding(bottom = Space.xl),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                Avatar(state.account?.string("displayName") ?: state.account?.string("handle") ?: "?", size = 44)
                Column {
                    Text(
                        state.account?.string("displayName")
                            ?: state.account?.string("handle") ?: "Account",
                        style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        TierMark((state.account?.string("tier") ?: "free").lowercase(), markSize = 16)
                        TierBadge(state.account?.string("tier") ?: "free")
                        Text("${(state.account?.get("machines") as? JsonArray)?.size ?: 0} linked devices", style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
                    }
                }
            }
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
                    TsAccentButton(
                        label = "See plans",
                        onClick = { paywall = true },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    RelayUsageCard(state.account, onRefresh = { scope.launch { TsRefresh.run("relay") { model.refresh() } } })
                    SyncPrivacyCard()
                    TsSecondaryButton(label = "Sign out", onClick = { model.signOut(); onDismiss() }, modifier = Modifier.fillMaxWidth())
                    // Ending the account, kept apart from everything above
                    // it. It is not a document, so it lives at the end of
                    // the account rather than under Legal.
                    HorizontalDivider(color = colors.border)
                    Text(
                        "Danger zone",
                        style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold),
                        color = colors.danger,
                    )
                    Text(
                        "Permanent. Confirmed on the website's data settings. The account, linked providers, sessions and usage are removed outright.",
                        style = TextStyle(fontSize = 12.sp),
                        color = colors.textSecondary,
                    )
                    TsSecondaryButton(
                        label = "Delete on website…",
                        onClick = { open("https://tokenstat.ai/settings/data?mobile=1&focus=delete#delete") },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                1 -> {
                    // Notifications first. That switch is why most people
                    // open this pane.
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("Notify this device", fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
                            Text(
                                "When an agent run or a chat on one of your machines finishes, or stops to ask you something. The notification says which machine, and nothing about the work.",
                                style = TextStyle(fontSize = 12.sp),
                                color = colors.textSecondary,
                            )
                        }
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
                    if (notifyOn) {
                        TsSecondaryButton(
                            label = "Send a test",
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
                    LocalTrafficCard(model)
                    Text("Identity and credentials stay in Android's no-backup app storage.", style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
                }
                else -> {
                    TsSecondaryButton(label = "Terms", onClick = { open("https://tokenstat.ai/terms?mobile=1") }, modifier = Modifier.fillMaxWidth())
                    TsSecondaryButton(label = "Privacy", onClick = { open("https://tokenstat.ai/privacy?mobile=1") }, modifier = Modifier.fillMaxWidth())
                    Text(
                        "Everything happens on your machine. tokenstat reads your local logs, extracts counters, and discards the rest. Only aggregate numbers are eligible for sync.",
                        style = TextStyle(fontSize = 12.sp),
                        color = colors.textSecondary,
                    )
                }
            }
        }
    }
    if (paywall) {
        PaywallSheet(
            billing = billing,
            onDismiss = { paywall = false },
            currentTier = state.account?.string("tier"),
        )
    }
}

@Composable
private fun RelayUsageCard(account: JsonObject?, onRefresh: () -> Unit) {
    val usage = account?.get("relayUsage") as? JsonObject
    val supported = usage?.string("policy") == "rolling_30_utc_days"
        && usage?.int("windowDays") == 30
        && usage?.string("timezone") == "UTC"
    TsCard(title = "Relay usage", subtitle = "One allowance across your devices") {
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
                Text("Daily usage (UTC)", fontWeight = FontWeight.SemiBold, color = LocalTsColors.current.textPrimary)
                if (days.isEmpty()) {
                    Text("No relayed traffic in this window.", style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                } else {
                    days.forEach { day ->
                        UsageRow(day.string("day") ?: "", day.long("bytes") ?: 0L)
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
    var traffic by remember { mutableStateOf<JsonObject?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(true) }
    val scope = rememberCoroutineScope()
    fun load() {
        scope.launch {
            loading = true
            runCatching { model.core("remote.status") as? JsonObject ?: error("The host answered remote.status with an unexpected shape.") }
                .onSuccess {
                    traffic = it["traffic"] as? JsonObject
                    error = null
                }
                .onFailure { error = it.message ?: "Could not load local traffic." }
            loading = false
        }
    }
    LaunchedEffect(Unit) { load() }
    TsCard(title = "This device", subtitle = "How connections leave this machine") {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            error?.let { Text(it, color = LocalTsColors.current.warning) }
            val snapshot = traffic
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

@Composable
private fun MetricCard(label: String, value: String, modifier: Modifier = Modifier) {
    TsCard(modifier) {
        Stat(label = label, value = value, tint = tsAccent())
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
    // A reading with no date is not a reading.
    val observedAt = reading.long("observed_at_ms")?.takeIf { it > 0 }
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
                Column(Modifier.weight(1f)) {
                    Text(
                        harnessName(source.ifEmpty { "Provider" }),
                        style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Medium),
                        color = colors.textPrimary,
                        maxLines = 1,
                    )
                    reading.string("plan")?.let {
                        Text(
                            it,
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.textSecondary,
                            maxLines = 1,
                        )
                    }
                }
                Text(
                    observed,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (stale) colors.warning else colors.textSecondary,
                    maxLines = 1,
                )
            }
            if (windows.isEmpty()) {
                Text(
                    reading.string("note") ?: "No window data in this reading.",
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.textSecondary,
                )
            } else {
                windows.forEach { window ->
                    LimitGauge(window.jsonObject)
                }
                reading.string("note")?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
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
    // as one limit stated twice.
    val label = value.string("label") ?: ""
    val scope = value.string("scope")
    val shown = when (scope) {
        null, "", "primary" -> label
        "secondary" -> "$label (all models)"
        "current model" -> "$label (secondary)"
        else -> "$label ($scope)"
    }
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                shown,
                style = MaterialTheme.typography.bodySmall,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(
                "${percent.roundToInt()}%",
                style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.SemiBold),
                color = gauge,
                maxLines = 1,
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
                    .height(6.dp)
                    .clip(RoundedCornerShape(50))
                    .background(gauge),
            )
        }
        val resetsAt = value.long("resetsAtMs")?.takeIf { it > 0 }
        if (resetsAt != null) {
            Text(
                "resets ${RelativeClock.until(resetsAt)}",
                style = MaterialTheme.typography.bodySmall,
                color = colors.textTertiary,
            )
        }
    }
}

@Composable
private fun VaultUpgradeCard(onPlans: () -> Unit) {
    ElevatedCard(Modifier.fillMaxWidth()) {
        Column(
            Modifier.padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
                    EmptyArt(EmptyArtKind.Vault)
            Text("Sync SSH between your devices", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(
                "An encrypted vault keeps hosts and keys on every device signed in to this account. Supporter and above.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Button(onClick = onPlans) { Text("See plans") }
        }
    }
}

@Composable
private fun VaultEmptyArt() {
    val accent = tsAccent()
    Canvas(Modifier.size(128.dp, 84.dp)) {
        val stroke = Stroke(width = 3.5f, cap = StrokeCap.Round, join = StrokeJoin.Round)
        drawRoundRect(
            color = accent.copy(alpha = 0.55f),
            topLeft = Offset(size.width * 0.16f, size.height * 0.16f),
            size = Size(size.width * 0.18f, size.height * 0.58f),
            cornerRadius = CornerRadius(10f, 10f),
            style = stroke,
        )
        drawRoundRect(
            color = accent.copy(alpha = 0.55f),
            topLeft = Offset(size.width * 0.62f, size.height * 0.32f),
            size = Size(size.width * 0.26f, size.height * 0.36f),
            cornerRadius = CornerRadius(8f, 8f),
            style = stroke,
        )
        drawArc(
            color = accent,
            startAngle = 200f,
            sweepAngle = 140f,
            useCenter = false,
            topLeft = Offset(size.width * 0.445f, size.height * 0.26f),
            size = Size(size.width * 0.11f, size.height * 0.24f),
            style = stroke,
        )
        drawRoundRect(
            color = accent,
            topLeft = Offset(size.width * 0.435f, size.height * 0.46f),
            size = Size(size.width * 0.13f, size.height * 0.22f),
            cornerRadius = CornerRadius(6f, 6f),
            style = stroke,
        )
    }
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
