// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui

import android.app.Activity
import androidx.browser.customtabs.CustomTabsIntent
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
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ClientState
import ai.tokenstat.tokenstat.billing.PlayBillingManager
import java.text.NumberFormat
import kotlin.math.roundToInt
import kotlinx.coroutines.launch
import kotlinx.serialization.json.*

private val Accent = Color(0xFF8B5CF6)

private enum class Destination(val label: String, val icon: ImageVector) {
    Home("Home", Icons.Default.Home),
    Workspaces("Workspaces", Icons.Default.Folder),
    Insights("Insights", Icons.Default.BarChart),
    Devices("Devices", Icons.Default.Computer),
}

@Composable
fun TokenstatApp(model: AppViewModel) {
    val state by model.state.collectAsStateWithLifecycle()
    MaterialTheme(colorScheme = darkColorScheme(primary = Accent, secondary = Color(0xFF22D3EE))) {
        Surface(Modifier.fillMaxSize()) {
            when {
                state.loading && state.account == null -> LoadingScreen()
                !state.signedIn -> LoginScreen(model, state.error)
                else -> SignedInApp(model, state)
            }
        }
    }
}

@Composable
private fun LoadingScreen() = Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
    CircularProgressIndicator(color = Accent)
}

@Composable
private fun LoginScreen(model: AppViewModel, error: String?) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var loginError by remember { mutableStateOf<String?>(null) }
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("tokenstat", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(12.dp))
        Text("Your AI coding activity, wherever your machines are.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        val shown = loginError ?: error
        if (shown != null) {
            Spacer(Modifier.height(20.dp)); Text(shown, color = MaterialTheme.colorScheme.error)
        }
        Spacer(Modifier.height(28.dp))
        Button(onClick = {
            scope.launch {
                runCatching { model.beginLogin() }
                    .onSuccess { url ->
                        loginError = null
                        CustomTabsIntent.Builder().build().launchUrl(context, url.toUri())
                    }
                    .onFailure { loginError = it.message ?: "Starting sign-in failed." }
            }
        }, modifier = Modifier.fillMaxWidth()) { Text("Sign in") }
        TextButton(onClick = model::refresh) { Text("I already signed in") }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun SignedInApp(model: AppViewModel, state: ClientState) {
    var selected by rememberSaveable { mutableStateOf(Destination.Home) }
    var accountOpen by remember { mutableStateOf(false) }
    // The real window width, not the rounded Configuration value: the rail
    // appears exactly when the window is wide enough to carry both panes.
    val density = LocalDensity.current
    val expanded = with(density) {
        LocalWindowInfo.current.containerSize.width.toDp() >= 840.dp
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("tokenstat", fontWeight = FontWeight.Bold) },
                actions = {
                    IconButton(onClick = model::refresh) { Icon(Icons.Default.Refresh, "Refresh") }
                    IconButton(onClick = { accountOpen = true }) { Icon(Icons.Default.AccountCircle, "Account") }
                },
            )
        },
        bottomBar = {
            if (!expanded) NavigationBar {
                Destination.entries.forEach { destination ->
                    NavigationBarItem(
                        selected = selected == destination,
                        onClick = { selected = destination },
                        icon = { Icon(destination.icon, null) },
                        label = { Text(destination.label) },
                    )
                }
            }
        },
    ) { padding ->
        Row(Modifier.fillMaxSize().padding(padding)) {
            if (expanded) NavigationRail {
                Spacer(Modifier.height(8.dp))
                Destination.entries.forEach { destination ->
                    NavigationRailItem(
                        selected = selected == destination,
                        onClick = { selected = destination },
                        icon = { Icon(destination.icon, null) },
                        label = { Text(destination.label) },
                    )
                }
            }
            Box(Modifier.weight(1f).fillMaxHeight()) {
                when (selected) {
                    Destination.Home -> HomeScreen(state)
                    Destination.Workspaces -> WorkspacesScreen(model, state, expanded)
                    Destination.Insights -> InsightsScreen(state)
                    Destination.Devices -> DevicesScreen(state)
                }
            }
        }
    }
    if (accountOpen) AccountDialog(state, model, onDismiss = { accountOpen = false })
}

@Composable
private fun HomeScreen(state: ClientState) {
    val calendar = state.home
    val rows = calendar?.get("rows") as? JsonArray
    val cells = rows.orEmpty().flatMap { row ->
        (row as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
    }
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Text(greeting(state.account), style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                MetricCard("Today", money(spendSince(cells, calendar?.string("last"), 1)), Modifier.weight(1f))
                MetricCard("This week", money(spendSince(cells, calendar?.string("last"), 7)), Modifier.weight(1f))
            }
        }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Activity", style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.weight(1f))
                        Text(
                            "${calendar?.int("activeDays") ?: 0} active days",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Spacer(Modifier.height(12.dp))
                    if (cells.isEmpty()) Text("No synced activity yet.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    else Heatmap(rows!!, calendar?.get("months") as? JsonArray ?: JsonArray(emptyList()))
                }
            }
        }
        item { Text("Plan limits", style = MaterialTheme.typography.titleMedium) }
        if (state.limits.isEmpty()) item {
            EmptyCard("No provider reading yet", "Limits appear after one of your hosts shares a reading.")
        } else items(state.limits) { item -> LimitCard(item.jsonObject) }
        state.error?.let { item { ErrorCard(it) } }
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
private fun Heatmap(rows: JsonArray, months: JsonArray) {
    // The Apple client draws a fixed cell and scrolls the year, opening on
    // the most recent week. Fitting 53 weeks to a phone width shrinks a day
    // below anything a finger can hit, so the same answer is copied here.
    val cell = 15.dp
    val gap = 3.dp
    val step = cell + gap
    // Seven rows, Monday first; a row's length is the number of weeks.
    val weeks = (rows.firstOrNull() as? JsonArray)?.size ?: rows.size
    val gridWidth = step * weeks - gap
    val scroll = rememberScrollState()
    LaunchedEffect(rows) {
        // Open on the latest week, which is the part anybody wants first.
        // maxValue is zero until the grid has been laid out, so follow it.
        snapshotFlow { scroll.maxValue }.collect { scroll.scrollTo(it) }
    }
    Row {
        Column(Modifier.width(16.dp)) {
            Spacer(Modifier.height(14.dp))
            listOf("M", "", "W", "", "F", "", "").forEach { letter ->
                Box(Modifier.height(cell), contentAlignment = Alignment.CenterStart) {
                    Text(letter, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline)
                }
            }
        }
        Column(Modifier.horizontalScroll(scroll)) {
            Box(Modifier.height(14.dp).width(gridWidth)) {
                // The core sends [column, name] pairs, the same marks the
                // Apple client offsets across its grid.
                months.forEach { month ->
                    val entry = (month as? JsonArray) ?: return@forEach
                    val column = entry.firstOrNull()?.jsonPrimitive?.intOrNull ?: return@forEach
                    val name = entry.getOrNull(1)?.jsonPrimitive?.contentOrNull ?: return@forEach
                    Text(
                        name,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.offset(x = step * column),
                    )
                }
            }
            rows.forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(gap)) {
                    ((row as? JsonArray) ?: JsonArray(emptyList())).forEachIndexed { _, day ->
                        // A null cell is outside the rendered range, not an
                        // idle day: it leaves a hole rather than a square.
                        val value = (day as? JsonObject)
                        val level = value?.int("level")?.coerceIn(0, 4)
                            ?: when (val v = value?.long("value") ?: 0L) {
                                0L -> 0; in 1..49_999 -> 1; in 50_000..499_999 -> 2; else -> 3
                            }
                        var alpha = when (level) {
                            0 -> .10f; 1 -> .30f; 2 -> .52f; 3 -> .74f; else -> 1f
                        }
                        if (day is JsonObject && day.bool("locked")) alpha *= .28f
                        Box(Modifier.size(cell).background(Accent.copy(alpha), RoundedCornerShape(3.dp)))
                    }
                }
                Spacer(Modifier.height(gap))
            }
        }
    }
}

@Composable
private fun InsightsScreen(state: ClientState) {
    val report = state.insights as? JsonObject
    val buckets = ((report?.get("rows") ?: report?.get("buckets")) as? JsonArray)
        ?.filterIsInstance<JsonObject>() ?: emptyList()
    val total = buckets.sumOf { it.long("valueMicros") ?: 0L }
    val peak = buckets.maxOfOrNull { it.long("valueMicros") ?: 0L } ?: 0L
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Text("Models", style = MaterialTheme.typography.headlineSmall) }
        if (buckets.isEmpty()) {
            item { EmptyCard("No breakdown yet", "Model activity appears after your machines sync.") }
        } else {
            item {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp)) {
                        Text(money(total), style = MaterialTheme.typography.headlineSmall, color = Accent)
                        Text("at list rates, across every device", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            items(buckets) { row ->
                val value = row.long("valueMicros") ?: 0L
                val share = if (peak > 0) (value.toFloat() / peak).coerceIn(0f, 1f) else 0f
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(row.string("key") ?: "Model", fontWeight = FontWeight.Medium, maxLines = 1)
                                Text(
                                    "${tokens(row["counters"]?.jsonObject?.long("total"))} tokens · ${row.long("events") ?: 0} events",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Spacer(Modifier.width(8.dp))
                            Text(money(value), color = Accent)
                        }
                        LinearProgressIndicator(
                            progress = { share },
                            modifier = Modifier.fillMaxWidth(),
                            trackColor = Accent.copy(alpha = .12f),
                        )
                    }
                }
            }
        }
    }
}

/// Compact token counts, the way the Apple client renders them beside a model
/// name: "1.6M" is a size, the full ten digits is a wall.
private fun tokens(count: Long?): String = when {
    count == null || count <= 0 -> "0"
    count >= 1_000_000_000 -> "%.1fB".format(count / 1_000_000_000.0)
    count >= 1_000_000 -> "%.1fM".format(count / 1_000_000.0)
    count >= 1_000 -> "%.1fK".format(count / 1_000.0)
    else -> count.toString()
}

@Composable
private fun DevicesScreen(state: ClientState) {
    val machines = state.account?.get("machines") as? JsonArray ?: JsonArray(emptyList())
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Text("Devices", style = MaterialTheme.typography.headlineSmall) }
        items(machines) { machine ->
            val value = machine.jsonObject
            Card(Modifier.fillMaxWidth()) {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(if (value.string("kind") == "client") Icons.Default.PhoneAndroid else Icons.Default.Computer, null)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(value.string("label") ?: value.string("id") ?: "Device", fontWeight = FontWeight.SemiBold)
                        val platform = value.string("platform")
                        val lastSeen = value.string("lastSeenAt")
                        Text(
                            listOfNotNull(platform, lastSeen).joinToString(" · "),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Box(Modifier.size(10.dp).background(if (value.bool("online")) Color(0xFF34D399) else Color.Gray, RoundedCornerShape(5.dp)))
                }
            }
        }
    }
}

@Composable
private fun WorkspacesScreen(model: AppViewModel, state: ClientState, expanded: Boolean) {
    val hosts = ((state.account?.get("machines") as? JsonArray) ?: JsonArray(emptyList()))
        .map { it.jsonObject }.filter { it.string("kind") != "client" }
    var host by remember { mutableStateOf<JsonObject?>(null) }
    var folders by remember { mutableStateOf(JsonArray(emptyList())) }
    var selectedFolder by remember { mutableStateOf<JsonObject?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(host) {
        val key = host?.string("publicIdentity") ?: host?.string("id") ?: return@LaunchedEffect
        // The folders still on screen belong to the previous host; showing
        // them beside the new host's name is one lie waiting to be clicked.
        folders = JsonArray(emptyList())
        runCatching { model.workspaces(key) }
            .onSuccess { folders = it; error = null }
            .onFailure { error = it.message }
    }
    if (expanded && selectedFolder != null && host != null) {
        Row(Modifier.fillMaxSize()) {
            WorkspaceList(hosts, host, folders, { host = it }, { selectedFolder = it }, Modifier.width(340.dp))
            VerticalDivider()
            WorkspaceDetail(model, host!!, selectedFolder!!, Modifier.weight(1f))
        }
    } else if (selectedFolder != null && host != null) {
        WorkspaceDetail(model, host!!, selectedFolder!!, Modifier.fillMaxSize(), onBack = { selectedFolder = null })
    } else {
        WorkspaceList(hosts, host, folders, { host = it }, { selectedFolder = it }, Modifier.fillMaxSize(), error)
    }
}

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
    WorkspacePart("Changes", "workspace.status", Icons.Default.Difference),
    WorkspacePart("Tasks", "todo.list", Icons.Default.Checklist),
    // Notes share the todo board's method; the Apple client filters the same
    // answer down to note cards, so the tab is not a second Tasks.
    WorkspacePart("Notes", "todo.list", Icons.AutoMirrored.Filled.Notes, kind = "note"),
    WorkspacePart("Workflows", "workflow.list", Icons.Default.AccountTree),
    WorkspacePart("Automations", "automation.list", Icons.Default.Bolt),
    WorkspacePart("Files", "workspace.tree", Icons.Default.FolderOpen),
)

@Composable
private fun WorkspaceDetail(
    model: AppViewModel, host: JsonObject, folder: JsonObject, modifier: Modifier,
    onBack: (() -> Unit)? = null,
) {
    val scope = rememberCoroutineScope()
    var result by remember { mutableStateOf<JsonElement?>(null) }
    var title by remember { mutableStateOf("Sessions") }
    var error by remember { mutableStateOf<String?>(null) }
    val peer = host.string("publicIdentity") ?: host.string("id") ?: ""
    val workspace = folder.string("id") ?: ""
    Column(modifier.verticalScroll(rememberScrollState()).padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (onBack != null) IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            Column { Text(folder.string("name") ?: "Workspace", style = MaterialTheme.typography.headlineSmall); Text(title) }
        }
        Spacer(Modifier.height(12.dp))
        workspaceParts.chunked(3).forEach { row ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { part ->
                    OutlinedButton(onClick = {
                        title = part.label
                        scope.launch {
                            val params = buildJsonObject {
                                when (part.method) {
                                    "pty.list" -> put("includeRemote", false)
                                    "workspace.tree" -> { put("id", workspace); put("path", "") }
                                    "workspace.status" -> put("id", workspace)
                                    "todo.list" -> put("includeArchived", true)
                                    else -> put("workspaceId", workspace)
                                }
                            }
                            runCatching { model.workspaceSection(peer, part.method, params) }
                                .onSuccess { element ->
                                    result = part.kind
                                        ?.let { kind ->
                                            (element as? JsonArray)?.filter { item ->
                                                item.jsonObject.string("kind") == kind
                                            }
                                        }
                                        ?.let(::JsonArray)
                                        ?: element
                                    error = null
                                }
                                .onFailure { error = it.message }
                        }
                    }, modifier = Modifier.weight(1f)) {
                        Icon(part.icon, null); Spacer(Modifier.width(4.dp)); Text(part.label, maxLines = 1)
                    }
                }
                repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
            }
            Spacer(Modifier.height(8.dp))
        }
        error?.let { ErrorCard(it) }
        result?.let {
            Card(Modifier.fillMaxWidth()) {
                Text(it.toString(), Modifier.padding(16.dp), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
            }
        } ?: EmptyCard("Choose a section", "Live data is read from ${host.string("label") ?: "this host"} over the encrypted tunnel.")
    }
}

@Composable
private fun AccountDialog(state: ClientState, model: AppViewModel, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val billing = remember { PlayBillingManager(context) }
    val billingState by billing.state.collectAsStateWithLifecycle()
    DisposableEffect(billing) { billing.start(); onDispose { billing.close() } }
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Icon(Icons.Default.AccountCircle, null) },
        title = { Text(state.account?.string("displayName") ?: state.account?.string("handle") ?: "Account") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("${state.account?.string("tier")?.replaceFirstChar(Char::uppercase) ?: "Free"} plan")
                Text("${(state.account?.get("machines") as? JsonArray)?.size ?: 0} linked devices")
                if (billingState.loading && billingState.products.isEmpty()) {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(Modifier.size(24.dp), color = Accent)
                    }
                }
                billingState.products.forEach { product ->
                    OutlinedButton(
                        onClick = { (context as? Activity)?.let { billing.purchase(it, product) } },
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("${product.label} · ${product.price}") }
                }
                billingState.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                Text("Identity and credentials stay in Android's no-backup app storage.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        dismissButton = { TextButton(onClick = { model.signOut(); onDismiss() }) { Text("Sign out", color = MaterialTheme.colorScheme.error) } },
    )
}

@Composable private fun MetricCard(label: String, value: String, modifier: Modifier = Modifier) = Card(modifier) {
    Column(Modifier.padding(16.dp)) { Text(value, style = MaterialTheme.typography.headlineMedium, color = Accent); Text(label) }
}

/// One provider reading with its windows, the shape `usage.limits` actually
/// returns: `windows[{label, percent, resetsAtMs}]` under a `source`. The
/// generic row card this replaces could not reach any of it.
@Composable
private fun LimitCard(reading: JsonObject) {
    val windows = reading["windows"] as? JsonArray ?: JsonArray(emptyList())
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    reading.string("source") ?: "Provider",
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                if (reading.bool("stale")) Text(
                    "stale",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            reading.string("plan")?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
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
@Composable private fun EmptyCard(title: String, message: String) = Card(Modifier.fillMaxWidth()) {
    Column(Modifier.padding(16.dp)) { Text(title, fontWeight = FontWeight.SemiBold); Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant) }
}
@Composable private fun ErrorCard(message: String) = Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)) {
    Text(message, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onErrorContainer)
}

private fun greeting(account: JsonObject?): String {
    val name = account?.string("displayName") ?: account?.string("handle") ?: "there"
    return "Hello, ${name.substringBefore(' ')}"
}
private fun money(micros: Long): String = NumberFormat.getCurrencyInstance().format(micros / 1_000_000.0)
private fun JsonObject.string(key: String): String? = this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.contentOrNull
private fun JsonObject.long(key: String): Long? = this[key]?.jsonPrimitive?.longOrNull
private fun JsonObject.int(key: String): Int? = this[key]?.jsonPrimitive?.intOrNull
private fun JsonObject.doubleOrNull(key: String): Double? = this[key]?.jsonPrimitive?.doubleOrNull
private fun JsonObject.bool(key: String): Boolean = this[key]?.jsonPrimitive?.booleanOrNull == true
