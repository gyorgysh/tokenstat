// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui

import android.net.Uri
import android.app.Activity
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ClientState
import ai.tokenstat.tokenstat.billing.PlayBillingManager
import java.text.NumberFormat
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
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("tokenstat", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(12.dp))
        Text("Your AI coding activity, wherever your machines are.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (error != null) {
            Spacer(Modifier.height(20.dp)); Text(error, color = MaterialTheme.colorScheme.error)
        }
        Spacer(Modifier.height(28.dp))
        Button(onClick = {
            scope.launch {
                runCatching { model.beginLogin() }.onSuccess { url ->
                    CustomTabsIntent.Builder().build().launchUrl(context, Uri.parse(url))
                }
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
    val expanded = LocalConfiguration.current.screenWidthDp >= 840

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
    val total = calendar?.long("total") ?: 0
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Text(greeting(state.account), style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                MetricCard("Account value", money(total), Modifier.weight(1f))
                MetricCard("Active days", "${calendar?.int("activeDays") ?: 0}", Modifier.weight(1f))
            }
        }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Text("Activity", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(12.dp))
                    if (rows == null) Text("No synced activity yet.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    else Heatmap(rows)
                }
            }
        }
        item { Text("Plan limits", style = MaterialTheme.typography.titleMedium) }
        if (state.limits.isEmpty()) item {
            EmptyCard("No provider reading yet", "Limits appear after one of your hosts shares a reading.")
        } else items(state.limits) { item -> JsonSummaryCard(item.jsonObject) }
        state.error?.let { item { ErrorCard(it) } }
    }
}

@Composable
private fun Heatmap(rows: JsonArray) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        rows.forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                (row as? JsonArray)?.forEach { cell ->
                    val value = (cell as? JsonObject)?.long("value") ?: 0L
                    val alpha = when { value == 0L -> .10f; value < 50_000 -> .30f; value < 500_000 -> .55f; else -> .95f }
                    Box(Modifier.size(8.dp).background(Accent.copy(alpha), RoundedCornerShape(2.dp)))
                }
            }
        }
    }
}

@Composable
private fun InsightsScreen(state: ClientState) {
    val report = state.insights as? JsonObject
    val buckets = (report?.get("buckets") ?: report?.get("rows")) as? JsonArray ?: JsonArray(emptyList())
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Text("Models", style = MaterialTheme.typography.headlineSmall) }
        if (buckets.isEmpty()) item { EmptyCard("No breakdown yet", "Model activity appears after your machines sync.") }
        items(buckets) { JsonSummaryCard(it.jsonObject) }
    }
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
                        Text(value.string("platform") ?: value.string("lastSeenAt") ?: "", color = MaterialTheme.colorScheme.onSurfaceVariant)
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
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                hosts.take(3).forEachIndexed { index, machine ->
                    SegmentedButton(
                        selected = selectedHost == machine,
                        onClick = { onHost(machine) },
                        shape = SegmentedButtonDefaults.itemShape(index, hosts.take(3).size),
                    ) { Text(machine.string("label") ?: "Host", maxLines = 1) }
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

private data class WorkspacePart(val label: String, val method: String, val icon: ImageVector)
private val workspaceParts = listOf(
    WorkspacePart("Sessions", "pty.list", Icons.Default.Terminal),
    WorkspacePart("Changes", "workspace.status", Icons.Default.Difference),
    WorkspacePart("Tasks", "todo.list", Icons.Default.Checklist),
    WorkspacePart("Notes", "todo.list", Icons.Default.Notes),
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
            if (onBack != null) IconButton(onClick = onBack) { Icon(Icons.Default.ArrowBack, "Back") }
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
                                .onSuccess { result = it; error = null }
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
@Composable private fun EmptyCard(title: String, message: String) = Card(Modifier.fillMaxWidth()) {
    Column(Modifier.padding(16.dp)) { Text(title, fontWeight = FontWeight.SemiBold); Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant) }
}
@Composable private fun ErrorCard(message: String) = Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)) {
    Text(message, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onErrorContainer)
}
@Composable private fun JsonSummaryCard(value: JsonObject) = Card(Modifier.fillMaxWidth()) {
    ListItem(
        headlineContent = { Text(value.string("label") ?: value.string("name") ?: value.string("source") ?: "Usage") },
        supportingContent = { Text(value.string("resetAt") ?: value.string("date") ?: "") },
        trailingContent = { Text(value.string("percent") ?: value.string("value") ?: value.string("valueMicros") ?: "") },
    )
}

private fun greeting(account: JsonObject?): String {
    val name = account?.string("displayName") ?: account?.string("handle") ?: "there"
    return "Hello, ${name.substringBefore(' ')}"
}
private fun money(micros: Long): String = NumberFormat.getCurrencyInstance().format(micros / 1_000_000.0)
private fun JsonObject.string(key: String): String? = this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.contentOrNull
private fun JsonObject.long(key: String): Long? = this[key]?.jsonPrimitive?.longOrNull
private fun JsonObject.int(key: String): Int? = this[key]?.jsonPrimitive?.intOrNull
private fun JsonObject.bool(key: String): Boolean = this[key]?.jsonPrimitive?.booleanOrNull == true
