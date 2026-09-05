// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.text.TextStyle
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
import ai.tokenstat.tokenstat.ui.components.Stat
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.components.cardPaddingDp
import ai.tokenstat.tokenstat.ui.heatmap.DayDetailSheet
import ai.tokenstat.tokenstat.ui.heatmap.YearHeatmap
import ai.tokenstat.tokenstat.ui.logic.HomeGreeting
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.compactTokens
import ai.tokenstat.tokenstat.ui.logic.normalizedRecovery
import ai.tokenstat.tokenstat.ui.logic.vaultPasswordProblems
import ai.tokenstat.tokenstat.ui.terminal.SshTerminalScreen
import ai.tokenstat.tokenstat.ui.terminal.TerminalScreen
import ai.tokenstat.tokenstat.ui.workspace.WorkspaceSection
import ai.tokenstat.tokenstat.ui.chrome.ConnectionChip
import ai.tokenstat.tokenstat.ui.chrome.TsRefresh
import ai.tokenstat.tokenstat.ui.billing.PaywallSheet
import ai.tokenstat.tokenstat.ui.browser.PortBrowserScreen
import ai.tokenstat.tokenstat.ui.screen.ScreenViewerScreen
import ai.tokenstat.tokenstat.ui.ssh.SshConnectDialog
import ai.tokenstat.tokenstat.ui.ssh.SshKeyImportDialog
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.marks.TierMark
import ai.tokenstat.tokenstat.notifications.PushRegistrar
import ai.tokenstat.tokenstat.ui.components.TierBadge
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.auth.Onboarding
import ai.tokenstat.tokenstat.ui.marks.Avatar
import ai.tokenstat.tokenstat.ui.marks.LogoMark
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
import java.text.NumberFormat
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
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
        MaterialTheme(colorScheme = colors.toColorScheme()) {
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
    val scope = rememberCoroutineScope()
    var pendingLogin by remember { mutableStateOf(false) }
    var loginError by remember { mutableStateOf<String?>(null) }
    val colors = LocalTsColors.current
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // The mark rising once and landing: an intro page, not a spinner.
        LogoMark(size = 44, animated = true, loops = false)
        Spacer(Modifier.height(Space.s))
        Wordmark(size = 22, showsMark = false)
        Spacer(Modifier.height(12.dp))
        Text("Your AI coding activity, wherever your machines are.", color = colors.textSecondary)
        if (pendingLogin) {
            Spacer(Modifier.height(20.dp))
            Text("Waiting for the browser to confirm you…", color = colors.textSecondary)
        }
        val shown = loginError ?: error
        if (shown != null) {
            Spacer(Modifier.height(20.dp))
            Text(shown, color = colors.danger)
        }
        Spacer(Modifier.height(28.dp))
        TsAccentButton(
            label = "Sign in",
            onClick = {
                scope.launch {
                    pendingLogin = true
                    runCatching { model.beginLogin() }
                        .onSuccess { url ->
                            loginError = null
                            CustomTabsIntent.Builder().build().launchUrl(context, url.toUri())
                        }
                        .onFailure { loginError = it.message ?: "Starting sign-in failed." }
                    pendingLogin = false
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(Space.s))
        TsSecondaryButton(
            label = "I already signed in",
            onClick = { UiSignals.beganRefreshing(); model.refresh() },
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(Space.s))
        TsSecondaryButton(
            label = "What is tokenstat?",
            onClick = onReboard,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun SignedInApp(model: AppViewModel, state: ClientState) {
    var selected by rememberSaveable { mutableStateOf(Destination.Home) }
    var pendingWorkHostId by rememberSaveable { mutableStateOf<String?>(null) }
    var accountOpen by remember { mutableStateOf(false) }
    val context = LocalContext.current
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
    val navItemColors = NavigationBarItemDefaults.colors(
        selectedIconColor = colors.accent,
        selectedTextColor = colors.accent,
        indicatorColor = colors.accentSoft,
        unselectedIconColor = colors.controlGlyph,
        unselectedTextColor = colors.controlGlyph,
    )
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
                        Wordmark(size = 22, showsMark = false)
                    }
                },
                navigationIcon = {
                    IconButton(onClick = { accountOpen = true }) {
                        Avatar(state.account?.string("displayName") ?: state.account?.string("handle") ?: "?")
                    }
                },
                actions = {
                    ConnectionChip(state.connection, onRetry = { model.retryConnection() })
                    Box(Modifier.padding(end = Space.s), contentAlignment = Alignment.Center) {
                        LogoMark(size = 18)
                    }
                    IconButton(onClick = {
                        UiSignals.beganRefreshing()
                        model.refresh()
                    }) { Icon(ActionIcon.Refresh.vector, "Refresh", tint = colors.controlGlyph) }
                },
            )
        },
        bottomBar = {
            if (!expanded) {
                NavigationBar(containerColor = colors.tabStrip, contentColor = colors.textSecondary) {
                    Destination.entries.forEach { destination ->
                        NavigationBarItem(
                            selected = selected == destination,
                            onClick = { selected = destination },
                            icon = { Icon(destination.icon, null) },
                            label = { Text(destination.label) },
                            colors = navItemColors,
                        )
                    }
                }
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
                when (selected) {
                    Destination.Home -> HomeScreen(model, state)
                    Destination.Workspaces -> if (state.canRemote) {
                        WorkspacesScreen(model, state, expanded, pendingWorkHostId) {
                            pendingWorkHostId = null
                        }
                    } else {
                        RemotePaywall { accountOpen = true }
                    }
                    Destination.Insights -> InsightsScreen(model, state)
                    Destination.Devices -> DevicesScreen(
                        model,
                        state,
                        onPlans = { accountOpen = true },
                        onOpenWork = { id ->
                            pendingWorkHostId = id
                            selected = Destination.Workspaces
                        },
                    )
                }
            }
        }
    }
    if (accountOpen) AccountDialog(state, model, billing, onDismiss = { accountOpen = false })
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
            "This phone already shares the account and sees the usage from every device on it. Opening folders and terminals on the computer is a paid feature.",
            color = colors.textSecondary,
        )
        Spacer(Modifier.height(20.dp))
        TsAccentButton(label = "See plans", onClick = onPlans)
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun HomeScreen(model: AppViewModel, state: ClientState) {
    val calendar = state.home
    val rows = calendar?.get("rows") as? JsonArray
    val cells = rows.orEmpty().flatMap { row ->
        (row as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
    }
    var selectedDay by remember { mutableStateOf<JsonObject?>(null) }
    val reduceMotion = rememberReduceMotion()
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    PullToRefreshBox(
        isRefreshing = refreshing,
        onRefresh = {
            scope.launch {
                refreshing = true
                TsRefresh.run("home") { model.refresh() }
                refreshing = false
            }
        },
        modifier = Modifier.fillMaxSize(),
    ) {
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(cardPaddingDp),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        item {
            Text(
                homeGreeting(state.account, cells.isNotEmpty()),
                style = MaterialTheme.typography.headlineSmall,
                color = LocalTsColors.current.textPrimary,
            )
            Spacer(Modifier.height(Space.m))
            Row(horizontalArrangement = Arrangement.spacedBy(Space.m)) {
                MetricCard("Today", money(spendSince(cells, calendar?.string("last"), 1)), Modifier.weight(1f))
                MetricCard("This week", money(spendSince(cells, calendar?.string("last"), 7)), Modifier.weight(1f))
            }
        }
        item {
            Arrive(reduceMotion) {
                TsCard(
                    title = "Activity",
                    accessory = {
                        Text(
                            "${calendar?.int("activeDays") ?: 0} active days",
                            style = MaterialTheme.typography.bodySmall,
                            color = LocalTsColors.current.textSecondary,
                        )
                    },
                ) {
                    if (cells.isEmpty()) Text("No synced activity yet.", color = LocalTsColors.current.textSecondary)
                    else YearHeatmap(
                        rows!!,
                        calendar?.get("months") as? JsonArray ?: JsonArray(emptyList()),
                        onSelectDay = { selectedDay = it },
                    )
                }
            }
        }
        // The same Free-year note the public profile puts under the heatmap.
        if (rows.orEmpty().any { (it as? JsonArray).orEmpty().any { c -> (c as? JsonObject)?.bool("locked") == true } }) {
            item { HistoryLockBanner() }
        }
        item { SectionLabel("Plan limits") }
        if (state.limits.isEmpty()) item {
            Arrive(reduceMotion) { EmptyCard("No provider reading yet", "Limits appear after one of your hosts shares a reading.") }
        } else itemsIndexed(state.limits) { index, item ->
            Arrive(reduceMotion, staggerIndex = index) { LimitCard(item.jsonObject) }
        }
        state.error?.let { item { ErrorCard(it) } }
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
private fun InsightsScreen(model: AppViewModel, state: ClientState) {
    val colors = LocalTsColors.current
    val reduceMotion = rememberReduceMotion()
    // Three cuts only — Models/Tools/Days — the privacy boundary the Apple
    // client draws: the account holds no projects and no sessions.
    var cut by rememberSaveable { mutableStateOf(0) }
    var query by rememberSaveable { mutableStateOf("") }
    val cutNames = listOf("Models", "Tools", "Days")
    val cutKeys = listOf("models", "tools", "days")
    val report = state.insights as? JsonObject
    val buckets = ((report?.get(cutKeys[cut]) ?: report?.get("rows") ?: report?.get("buckets")) as? JsonArray)
        ?.filterIsInstance<JsonObject>().orEmpty()
        .filter { query.isBlank() || (it.string("key") ?: "").contains(query, ignoreCase = true) }
    val total = buckets.sumOf { it.long("valueMicros") ?: 0L }
    val peak = buckets.maxOfOrNull { it.long("valueMicros") ?: 0L } ?: 0L
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    PullToRefreshBox(
        isRefreshing = refreshing,
        onRefresh = {
            scope.launch {
                refreshing = true
                TsRefresh.run("insights") { model.refresh() }
                refreshing = false
            }
        },
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
        if (buckets.isEmpty()) {
            item { EmptyCard("No breakdown yet", "Activity appears after your machines sync.") }
        } else {
            item {
                Arrive(reduceMotion) {
                    TsCard(title = "Total", subtitle = "at list rates, across every device") {
                        Text(money(total), style = TsType.numeric(26, FontWeight.Medium), color = tsAccent())
                    }
                }
            }
            itemsIndexed(buckets) { index, row ->
                val value = row.long("valueMicros") ?: 0L
                val share = if (peak > 0) (value.toFloat() / peak).coerceIn(0f, 1f) else 0f
                Arrive(reduceMotion, staggerIndex = index.coerceAtMost(8)) {
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
                            Column(Modifier.weight(1f)) {
                                Text(row.string("key") ?: "Model", fontWeight = FontWeight.Medium, maxLines = 1)
                                val counters = row["counters"]?.jsonObject?.long("total")
                                val events = row.long("events")
                                val bits = buildList {
                                    counters?.let { add("${compactTokens(it)} tokens") }
                                    events?.let { add("$it events") }
                                }
                                if (bits.isNotEmpty()) Text(
                                    bits.joinToString(" · "),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = colors.textSecondary,
                                )
                            }
                            Spacer(Modifier.width(Space.s))
                            Text(money(value), color = tsAccent(), style = TsType.numeric(14))
                        }
                        // A quiet share bar in the accent, not a system meter.
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .height(5.dp)
                                .clip(RoundedCornerShape(50))
                                .background(colors.accentSoft),
                        ) {
                            val animated by animateFloatAsState(share, tween(320), label = "shareBar")
                            Box(
                                Modifier
                                    .fillMaxWidth(animated)
                                    .height(5.dp)
                                    .clip(RoundedCornerShape(50))
                                    .background(colors.accent),
                            )
                        }
                    }
                }
            }
        }
    }
    }
}

@Composable
private fun DevicesScreen(
    model: AppViewModel,
    state: ClientState,
    onPlans: () -> Unit,
    onOpenWork: (String) -> Unit,
) {
    var sshOpen by rememberSaveable { mutableStateOf(false) }
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    val machines = state.account?.get("machines") as? JsonArray ?: JsonArray(emptyList())
    val selected = machines.map { it.jsonObject }.find { it.string("id") == selectedId }
    val thisId = state.account?.string("thisMachineId")
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
        else -> LazyColumn(
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
                val online = value.bool("online")
                val colors = LocalTsColors.current
                TsCard(Modifier.clickable { selectedId = value.string("id") }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            if (value.string("kind") == "client") Icons.Default.PhoneAndroid else Icons.Default.Laptop,
                            null,
                            tint = colors.controlGlyph,
                        )
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(
                                value.string("label") ?: value.string("id") ?: "Device",
                                fontWeight = FontWeight.SemiBold,
                                color = colors.textPrimary,
                            )
                            Text(
                                when {
                                    isHost && online && !value.string("publicIdentity").isNullOrEmpty() ->
                                        "Awake. Open work from this phone."
                                    else -> listOfNotNull(value.string("platform"), value.string("lastSeenAt")).joinToString(" · ")
                                },
                                color = colors.textSecondary,
                            )
                        }
                        Box(
                            Modifier.size(10.dp).background(
                                if (online) colors.success else colors.stateIdle,
                                RoundedCornerShape(5.dp),
                            ),
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
    val online = machine.bool("online")
    val label = machine.string("label") ?: machine.string("id") ?: "Device"
    var viewing by remember { mutableStateOf(false) }
    if (viewing && !peer.isNullOrEmpty()) {
        ScreenViewerScreen(
            model = model,
            peer = peer,
            hostLabel = label,
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
            Text(label, style = MaterialTheme.typography.headlineSmall)
        }
        if (!isThis && !peer.isNullOrEmpty() && online) {
            HostStatsBar(model, peer)
        }
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Reach", style = MaterialTheme.typography.titleMedium)
                Text(
                    when {
                        isThis -> "This is the device you are holding."
                        online -> "Awake and reachable through the tunnel from this phone, and from any other device signed in to this account."
                        !peer.isNullOrEmpty() -> "Asleep. It has a connection key, so it can be reached from this phone once it is awake."
                        else -> "Not set up for remote reach. Turn on Reach devices from anywhere on that computer."
                    },
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        if (!isThis && isHost && !peer.isNullOrEmpty()) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("From this phone", style = MaterialTheme.typography.titleMedium)
                    if (state.canRemote) {
                        TsAccentButton(label = "Open work", onClick = onOpenWork, modifier = Modifier.fillMaxWidth())
                        Text(
                            if (online) "Folders, terminals and sessions on this computer."
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
        machine.string("platform")?.let { Text("Runs $it", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        machine.string("id")?.let { Text("Device id $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
private fun HostStatsBar(model: AppViewModel, peer: String) {
    var stats by remember { mutableStateOf<JsonObject?>(null) }
    LaunchedEffect(peer) {
        runCatching { model.prepareHost(peer, "Host") }
        while (true) {
            runCatching { model.hostStats(peer) }.onSuccess { stats = it }
            delay(2500)
        }
    }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                HostStatCell(
                    title = "Power",
                    value = powerLabel(stats),
                    modifier = Modifier.weight(1f),
                )
                HostStatCell(
                    title = "CPU",
                    value = stats?.doubleOrNull("cpu")?.let { "${(it * 100).roundToInt()}%" } ?: if (stats == null) "…" else "n/a",
                    modifier = Modifier.weight(1f),
                )
                HostStatCell(
                    title = "Memory",
                    value = ramLabel(stats) ?: if (stats == null) "…" else "n/a",
                    modifier = Modifier.weight(1f),
                )
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

private fun powerLabel(stats: JsonObject?): String {
    if (stats == null) return "…"
    val percent = stats.int("percent")
    val charging = stats.bool("charging")
    val power = stats.string("power")
    if (charging && percent != null) return "$percent%"
    if (power == "ac" && percent == null) return "Plugged in"
    if (percent != null) return "$percent%"
    if (power == "battery") return "On battery"
    if (power == "ac") return "Plugged in"
    return "n/a"
}

private fun ramLabel(stats: JsonObject?): String? {
    val used = stats?.long("ramUsedBytes") ?: return null
    val total = stats.long("ramTotalBytes") ?: return null
    if (total <= 0L) return null
    val g = 1024.0 * 1024 * 1024
    val u = used / g
    val t = total / g
    return if (t >= 10) "%.0f / %.0f GB".format(u, t) else "%.1f / %.1f GB".format(u, t)
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
    val tabs = listOf("Hosts", "Keys", "Snippets")
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var hosts by remember { mutableStateOf(JsonArray(emptyList())) }
    var keys by remember { mutableStateOf(JsonArray(emptyList())) }
    var snippets by remember { mutableStateOf(JsonArray(emptyList())) }
    var folders by remember { mutableStateOf(JsonArray(emptyList())) }
    var query by remember { mutableStateOf("") }
    var vault by remember { mutableStateOf<JsonObject?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var addHost by remember { mutableStateOf(false) }
    var addSnippet by remember { mutableStateOf(false) }
    var addKey by remember { mutableStateOf(false) }
    var connecting by remember { mutableStateOf<JsonObject?>(null) }
    var sshSession by remember { mutableStateOf<Pair<String, String>?>(null) }
    var vaultSetup by remember { mutableStateOf(false) }
    var recoveryWords by remember { mutableStateOf<String?>(null) }
    var showingRecovery by remember { mutableStateOf(false) }
    var confirmDrop by remember { mutableStateOf(false) }
    val vaultAllowed = state.vaultAllowed

    suspend fun load() {
        runCatching {
            hosts = model.core("ssh.host.list") as? JsonArray ?: JsonArray(emptyList())
            keys = model.core("ssh.key.list") as? JsonArray ?: JsonArray(emptyList())
            snippets = model.core("ssh.snippet.list") as? JsonArray ?: JsonArray(emptyList())
            folders = model.core("ssh.folder.list") as? JsonArray ?: JsonArray(emptyList())
            if (vaultAllowed) vault = model.core("ssh.vault.status") as? JsonObject
        }.onFailure { error = it.message }
    }
    LaunchedEffect(Unit) { load() }

    val live = sshSession
    if (live != null) {
        SshTerminalScreen(
            model = model,
            sessionId = live.first,
            hostLabel = live.second,
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
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (recoveryWords != null) {
                                Button(onClick = { showingRecovery = true }) { Text("Show code") }
                                TextButton(onClick = { confirmDrop = true }) { Text("Discard vault") }
                            } else if (vault?.bool("created") != true) {
                                Button(onClick = { vaultSetup = true }) { Text("Set up") }
                            } else if (vault?.bool("locked") == true || vault?.bool("enrolled") != true) {
                                Button(onClick = { vaultSetup = true }) { Text("Unlock") }
                            }
                            if (vault?.bool("created") == true && recoveryWords == null) {
                                TextButton(onClick = { confirmDrop = true }) { Text("Delete vault") }
                            }
                        }
                    }
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
                    val port = item["port"]?.toString() ?: "22"
                    TsCard(
                        title = item.string(if (tab == 2) "title" else "label") ?: "SSH item",
                        subtitle = when (tab) {
                            0 -> "${item.string("username") ?: "root"}@${item.string("hostname") ?: ""}:$port"
                            1 -> item.string("fingerprint")?.takeIf { it.isNotBlank() }
                                ?: item.string("algorithm") ?: "Key"
                            else -> item.string("command") ?: ""
                        },
                        accessory = {
                            if (tab == 0 && folderName != null) {
                                Text(folderName, style = MaterialTheme.typography.labelSmall, color = LocalTsColors.current.textSecondary)
                            }
                        },
                        modifier = Modifier.clickable {
                            if (tab == 0) connecting = item
                        },
                    )
                }
            }
        }
    }
    if (addHost) SSHHostDialog(folders = folders, onDismiss = { addHost = false }) { body ->
        scope.launch { runCatching { model.core("ssh.host.save", body); load() }.onFailure { error = it.message }; addHost = false }
    }
    if (addSnippet) SSHSnippetDialog(onDismiss = { addSnippet = false }) { body ->
        scope.launch { runCatching { model.core("ssh.snippet.save", body); load() }.onFailure { error = it.message }; addSnippet = false }
    }
    if (vaultSetup) AndroidVaultDialog(
        existing = vault?.bool("created") == true,
        onDismiss = { vaultSetup = false },
        onCreate = { password ->
            scope.launch {
                runCatching {
                    model.core("ssh.vault.create", buildJsonObject { put("password", password) }).jsonObject.string("recovery")!!
                }.onSuccess { recoveryWords = it; showingRecovery = true; load(); vaultSetup = false }.onFailure { error = it.message }
            }
        },
        onUnlock = { password ->
            scope.launch {
                runCatching {
                    model.core("ssh.vault.unlock", buildJsonObject {
                        put("password", password); put("migrate", true)
                    })?.string("recovery")?.let { recoveryWords = it; showingRecovery = true }
                }.onSuccess { load(); vaultSetup = false }.onFailure { error = it.message }
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
                    load()
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
            onDiscard = { showingRecovery = false; confirmDrop = true },
        )
    }
    if (confirmDrop) AlertDialog(
        onDismissRequest = { confirmDrop = false },
        title = { Text("Delete this vault?") },
        text = { Text("Every encrypted SSH secret in the vault is permanently lost. Other devices will need to set up a new vault. This cannot be undone.") },
        confirmButton = {
            Button(onClick = {
                confirmDrop = false
                scope.launch {
                    runCatching { model.core("ssh.vault.reset") }
                        .onSuccess { recoveryWords = null; showingRecovery = false; vaultSetup = false; load() }
                        .onFailure { error = it.message }
                }
            }) { Text("Delete vault") }
        },
        dismissButton = { TextButton(onClick = { confirmDrop = false }) { Text("Cancel") } },
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
private fun SSHHostDialog(folders: JsonArray, onDismiss: () -> Unit, onSave: (JsonObject) -> Unit) {
    var label by remember { mutableStateOf("") }; var host by remember { mutableStateOf("") }
    var user by remember { mutableStateOf("root") }; var directory by remember { mutableStateOf("~") }
    var port by remember { mutableStateOf("22") }
    var folderId by remember { mutableStateOf<String?>(null) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Add SSH host") }, text = {
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
            Text("You will verify the host fingerprint and choose a password or saved key before connecting.", style = MaterialTheme.typography.bodySmall)
        }
    }, confirmButton = {
        Button(
            enabled = label.isNotBlank() && host.isNotBlank() && user.isNotBlank(),
            onClick = {
                onSave(buildJsonObject {
                    put("id", ""); put("label", label); put("hostname", host)
                    put("port", port.toIntOrNull() ?: 22)
                    put("username", user); put("initialDirectory", directory.ifBlank { "~" })
                    folderId?.let { put("folderId", it) }
                    put("tags", JsonArray(emptyList())); put("hostKeys", JsonArray(emptyList()))
                })
            },
        ) { Text("Save") }
    }, dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } })
}

@Composable
private fun SSHSnippetDialog(onDismiss: () -> Unit, onSave: (JsonObject) -> Unit) {
    var title by remember { mutableStateOf("") }; var command by remember { mutableStateOf("") }
    // Placeholders are read back the same way every client reads them, so a
    // snippet written here asks for the same values on a Mac.
    val variables = Regex("\\{\\{\\s*([^}]+?)\\s*\\}\\}")
        .findAll(command)
        .map { it.groupValues[1] }
        .distinct()
        .toList()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add snippet") },
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
                onSave(buildJsonObject {
                    put("id", ""); put("title", title); put("command", command)
                    put("tags", JsonArray(emptyList())); put("hostIDs", JsonArray(emptyList()))
                    put("variables", JsonArray(variables.map { JsonPrimitive(it) }))
                })
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
    onPendingConsumed: () -> Unit = {},
) {
    val hosts = ((state.account?.get("machines") as? JsonArray) ?: JsonArray(emptyList()))
        .map { it.jsonObject }.filter { it.string("kind") != "client" }
    var host by remember { mutableStateOf<JsonObject?>(null) }
    LaunchedEffect(pendingHostId, hosts) {
        val id = pendingHostId ?: return@LaunchedEffect
        val match = hosts.find { it.string("id") == id } ?: return@LaunchedEffect
        host = match
        onPendingConsumed()
    }
    var folders by remember { mutableStateOf(JsonArray(emptyList())) }
    var selectedFolder by remember { mutableStateOf<JsonObject?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var terminalSession by remember { mutableStateOf<WorkspaceTerminalRequest?>(null) }
    var browser by remember { mutableStateOf<Pair<String, Int>?>(null) }
    LaunchedEffect(host) {
        val key = host?.string("publicIdentity")
        if (host != null && key == null) {
            folders = JsonArray(emptyList())
            error = "This host has no public identity yet."
            return@LaunchedEffect
        }
        if (key == null) return@LaunchedEffect
        // The folders still on screen belong to the previous host; showing
        // them beside the new host's name is one lie waiting to be clicked.
        folders = JsonArray(emptyList())
        runCatching {
            model.prepareHost(key, host?.string("label") ?: "Host")
            model.workspaces(key)
        }
            .onSuccess { folders = it; error = null }
            .onFailure { error = it.message }
    }
    val boundHost = host
    val boundFolder = selectedFolder
    val request = terminalSession
    val browsing = browser
    if (request != null && boundFolder != null && boundHost != null) {
        TerminalScreen(
            model = model,
            peer = boundHost.string("publicIdentity") ?: "",
            hostLabel = request.hostLabel,
            workspaceId = request.workspaceId,
            existingSessionId = request.sessionId,
            onClose = { terminalSession = null },
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
            WorkspaceList(hosts, boundHost, folders, { host = it }, { selectedFolder = it }, Modifier.width(340.dp))
            VerticalDivider()
            WorkspaceDetail(
                model, boundHost, boundFolder, Modifier.weight(1f),
                onBack = null,
                onOpenTerminal = { id -> terminalSession = WorkspaceTerminalRequest(id, boundFolder.string("id") ?: "", boundHost.string("label") ?: "Host") },
                onOpenBrowser = { url, port -> browser = url to port },
            )
        }
    } else if (boundFolder != null && boundHost != null) {
        WorkspaceDetail(
            model, boundHost, boundFolder, Modifier.fillMaxSize(),
            onBack = { selectedFolder = null },
            onOpenTerminal = { id -> terminalSession = WorkspaceTerminalRequest(id, boundFolder.string("id") ?: "", boundHost.string("label") ?: "Host") },
            onOpenBrowser = { url, port -> browser = url to port },
        )
    } else {
        WorkspaceList(hosts, host, folders, { host = it }, { selectedFolder = it }, Modifier.fillMaxSize(), error)
    }
}

private data class WorkspaceTerminalRequest(val sessionId: String?, val workspaceId: String, val hostLabel: String)

@Composable
private fun WorkspaceList(
    hosts: List<JsonObject>, selectedHost: JsonObject?, folders: JsonArray,
    onHost: (JsonObject) -> Unit, onFolder: (JsonObject) -> Unit,
    modifier: Modifier, error: String? = null,
) {
    LazyColumn(modifier, contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Text("Workspaces", style = MaterialTheme.typography.headlineSmall) }
        item {
            // A fourth machine must not become unreachable just because a
            // segmented row was drawn for three, so the row scrolls.
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
                SingleChoiceSegmentedButtonRow {
                    hosts.forEachIndexed { index, machine ->
                        SegmentedButton(
                            selected = selectedHost == machine,
                            onClick = { onHost(machine) },
                            shape = SegmentedButtonDefaults.itemShape(index, hosts.size),
                        ) { Text(machine.string("label") ?: "Host", maxLines = 1) }
                    }
                }
            }
        }
        if (selectedHost == null) item { EmptyCard("Choose a host", "Select an awake computer to see its folders.") }
        error?.let { item { ErrorCard(it) } }
        items(folders) { folder ->
            val value = folder.jsonObject
            ListItem(
                headlineContent = { Text(value.string("name") ?: "Workspace") },
                supportingContent = { Text(value.string("path") ?: "") },
                leadingContent = { Icon(Icons.Default.Folder, null) },
                trailingContent = { Icon(Icons.Default.ChevronRight, null) },
                modifier = Modifier.clickable { onFolder(value) },
            )
        }
    }
}

private data class WorkspacePart(val label: String, val method: String, val icon: ImageVector, val kind: String? = null)
private val workspaceParts = listOf(
    WorkspacePart("Sessions", "pty.list", Icons.Default.Terminal),
    WorkspacePart("Chat", "chat.list", Icons.Default.ChatBubble),
    WorkspacePart("Pulls", "pulls.list", Icons.Default.MergeType),
    WorkspacePart("Changes", "workspace.status", Icons.Default.Difference),
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
    onBack: (() -> Unit)? = null,
    onOpenTerminal: (String?) -> Unit = {},
    onOpenBrowser: (String, Int) -> Unit = { _, _ -> },
) {
    var section by rememberSaveable { mutableStateOf("Sessions") }
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
            modifier = Modifier.verticalScroll(rememberScrollState()),
            onOpenTerminal = onOpenTerminal,
            onOpenBrowser = onOpenBrowser,
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
    var notifyOn by remember { mutableStateOf(PushRegistrar.registered()) }
    var notifyError by remember { mutableStateOf<String?>(null) }
    fun open(url: String) {
        runCatching { CustomTabsIntent.Builder().build().launchUrl(context, url.toUri()) }
    }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .fillMaxWidth()
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
            TsAccentButton(
                label = "See plans",
                onClick = { paywall = true },
                modifier = Modifier.fillMaxWidth(),
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Notify this device", fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
                    Text(
                        "When an agent run on one of your machines finishes, or stops to ask you something. The notification says which machine, and nothing about the work.",
                        style = TextStyle(fontSize = 12.sp),
                        color = colors.textSecondary,
                    )
                }
                Switch(
                    checked = notifyOn,
                    onCheckedChange = { on ->
                        scope.launch {
                            runCatching {
                                if (on) PushRegistrar.refresh() else PushRegistrar.unregister()
                            }.onSuccess { notifyOn = on; notifyError = null }
                                .onFailure { notifyError = it.message }
                        }
                    },
                )
            }
            if (notifyOn) {
                TsSecondaryButton(
                    label = "Send a test",
                    small = true,
                    onClick = { scope.launch { runCatching { PushRegistrar.test() }.onFailure { notifyError = it.message } } },
                )
            }
            notifyError?.let { Text(it, color = colors.warning) }
            TsSecondaryButton(label = "Terms", onClick = { open("https://tokenstat.ai/terms?mobile=1") }, modifier = Modifier.fillMaxWidth())
            TsSecondaryButton(label = "Privacy", onClick = { open("https://tokenstat.ai/privacy?mobile=1") }, modifier = Modifier.fillMaxWidth())
            TsSecondaryButton(
                label = "Delete account",
                onClick = { open("https://tokenstat.ai/settings/data?mobile=1&focus=delete#delete") },
                modifier = Modifier.fillMaxWidth(),
            )
            TsSecondaryButton(label = "Sign out", onClick = { model.signOut(); onDismiss() }, modifier = Modifier.fillMaxWidth())
            Text("Identity and credentials stay in Android's no-backup app storage.", style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
        }
    }
    if (paywall) PaywallSheet(billing, onDismiss = { paywall = false })
}

@Composable private fun MetricCard(label: String, value: String, modifier: Modifier = Modifier) =
    Column(modifier) { Stat(label = label, value = value, tint = tsAccent()) }

/// One provider reading with its windows, the shape `usage.limits` actually
/// returns: `windows[{label, percent, resetsAtMs}]` under a `source`. The
/// generic row card this replaces could not reach any of it.
@Composable
private fun LimitCard(reading: JsonObject) {
    val windows = reading["windows"] as? JsonArray ?: JsonArray(emptyList())
    TsCard(
        title = reading.string("source") ?: "Provider",
        subtitle = reading.string("plan"),
        accessory = {
            if (reading.bool("stale")) Text(
                "stale",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (windows.isEmpty()) {
                Text(reading.string("note") ?: "No window data in this reading.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                windows.forEach { window ->
                    val value = window.jsonObject
                    val percent = value.doubleOrNull("percent") ?: 0.0
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(value.string("label") ?: "", modifier = Modifier.width(72.dp), maxLines = 1)
                        LinearProgressIndicator(
                            progress = { (percent / 100.0).coerceIn(0.0, 1.0).toFloat() },
                            modifier = Modifier.weight(1f),
                        )
                        Text("${percent.roundToInt()}%", modifier = Modifier.width(40.dp))
                    }
                }
                reading.string("note")?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
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
                "An encrypted vault keeps hosts and keys on every computer and phone signed in to this account. Supporter and above.",
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
private fun money(micros: Long): String = NumberFormat.getCurrencyInstance().format(micros / 1_000_000.0)
private fun JsonObject.string(key: String): String? = this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.contentOrNull
private fun JsonObject.long(key: String): Long? = this[key]?.jsonPrimitive?.longOrNull
private fun JsonObject.int(key: String): Int? = this[key]?.jsonPrimitive?.intOrNull
private fun JsonObject.doubleOrNull(key: String): Double? = this[key]?.jsonPrimitive?.doubleOrNull
private fun JsonObject.bool(key: String): Boolean = this[key]?.jsonPrimitive?.booleanOrNull == true
