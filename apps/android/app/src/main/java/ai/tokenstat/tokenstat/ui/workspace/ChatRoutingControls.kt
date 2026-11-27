// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.theme.onAccent
import ai.tokenstat.tokenstat.ui.components.*
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.theme.*
import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.HourglassTop
import androidx.compose.material.icons.filled.Warning
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.alpha
import androidx.compose.foundation.clickable
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import java.text.DateFormat
import java.util.Date
import androidx.compose.ui.platform.LocalConfiguration
import kotlinx.coroutines.launch
import kotlinx.serialization.json.*

private fun JsonObject.routeText(key: String): String =
    (this[key] as? JsonPrimitive)?.contentOrNull.orEmpty()

private fun routeActivityLabel(kind: String): String =
    when (kind) {
        "usage" -> L10n.text("common.chat_route_event_usage")
        "throttle" -> L10n.text("common.chat_route_event_throttle")
        "error" -> L10n.text("common.chat_route_event_error")
        "auth" -> L10n.text("common.chat_route_event_auth")
        "failure" -> L10n.text("common.chat_route_event_failure")
        "settings" -> L10n.text("common.chat_route_event_settings")
        "switched" -> L10n.text("common.chat_route_event_switched")
        "resumed" -> L10n.text("common.chat_route_event_resumed")
        "returned" -> L10n.text("common.chat_route_event_returned")
        "cancelled" -> L10n.text("common.chat_route_event_cancelled")
        "skipped" -> L10n.text("common.chat_route_event_skipped")
        else -> L10n.text("common.chat_route_event_paused")
    }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ChatRoutingControls(
    chat: JsonObject,
    backends: List<JsonObject>,
    call: suspend (String, JsonObject) -> JsonElement,
    onChanged: suspend () -> Unit,
    showNotice: Boolean = true,
    showSection: Boolean = true,
    showShortcut: Boolean = false,
    onHandOff: (() -> Unit)? = null,
) {
    val scope = rememberCoroutineScope()
    val colors = LocalTsColors.current
    fun agentLabel(id: String): String =
        backends
            .firstOrNull { it.routeText("id") == id }
            ?.routeText("label")
            ?.takeIf { it.isNotBlank() } ?: id
    var showing by remember(chat.routeText("id")) { mutableStateOf(false) }
    var error by remember(chat.routeText("id")) { mutableStateOf<String?>(null) }
    var applying by remember(chat.routeText("id")) { mutableStateOf(false) }
    val state = chat["routing"] as? JsonObject
    val policy = state?.get("policy") as? JsonObject
    val limit = state?.get("limit") as? JsonObject
    fun apply(method: String, extra: JsonObject) {
        if (applying) return
        applying = true
        scope.launch {
            runCatching {
                call(
                    method,
                    buildJsonObject {
                        put("id", chat.routeText("id"))
                        chat["sendRevision"]?.let { put("expectedRevision", it) }
                        extra.forEach { (key, value) -> put(key, value) }
                    },
                )
            }
                .onSuccess {
                    error = null
                    onChanged()
                }
                .onFailure { error = it.message }
            applying = false
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(Space.m)) {
        if (showShortcut) {
            val automatic = policy?.bol("enabled") == true || policy?.bol("waitForReset") == true
            val mode = L10n.text(if (policy?.bol("enabled") == true) {
                if (policy.bol("waitForReset")) "common.chat_route_combined_mode" else "common.chat_route_fallback_mode"
            } else {
                if (policy?.bol("waitForReset") == true) "common.chat_route_wait_mode" else "common.chat_route_manual"
            })
            TooltipBox(
                positionProvider = TooltipDefaults.rememberTooltipPositionProvider(TooltipAnchorPosition.Above),
                tooltip = { PlainTooltip { Text(L10n.text("common.chat_routing_intro")) } },
                state = rememberTooltipState(),
            ) {
                IconButton(
                    onClick = { showing = true },
                    modifier = Modifier.semantics { stateDescription = mode }.background(
                        if (automatic) colors.accentSoft else androidx.compose.ui.graphics.Color.Transparent,
                        RoundedCornerShape(8.dp),
                    ),
                ) {
                    Icon(
                        ActionIcon.Routing.vector,
                        L10n.text("common.chat_routing"),
                        tint = if (automatic) colors.accent else colors.textSecondary,
                    )
                }
            }
        }
        if (showNotice && limit != null)
            RoutingLimitCard(
                chat = chat,
                state = state,
                policy = policy,
                limit = limit,
                backends = backends,
                applying = applying,
                agentLabel = ::agentLabel,
                apply = ::apply,
                onRouting = { showing = true },
                onHandOff = onHandOff,
            )
        if (showSection) ChatSetupDisclosure(
            title = L10n.text("common.chat_routing"),
            summary = L10n.text(if (policy?.bol("enabled") == true) {
                if (policy.bol("waitForReset")) "common.chat_route_combined_mode" else "common.chat_route_fallback_mode"
            } else if (policy?.bol("waitForReset") == true) "common.chat_route_wait_mode" else "common.chat_route_manual"),
            owner = chat.routeText("id"),
            primary = {
                TsAccentButton(label = L10n.text("common.chat_route_setup"), icon = ActionIcon.Settings.vector,
                    small = true, onClick = { showing = true })
            },
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                Text(
                    if (policy?.bol("enabled") == true) {
                        if (policy.bol("waitForReset")) L10n.text("common.chat_route_combined_mode")
                        else L10n.text("common.chat_route_fallback_mode")
                    } else {
                        if (policy?.bol("waitForReset") == true)
                            L10n.text("common.chat_route_wait_mode")
                        else L10n.text("common.chat_route_manual")
                    },
                    style = TsType.footnote,
                )
                val destinations =
                    (policy?.get("routes") as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
                if (destinations.isNotEmpty())
                    Text(
                        destinations.joinToString(" → ") { agentLabel(it.routeText("backend")) },
                        style = TsType.footnote,
                    )
                if (policy?.bol("returnPreferred") == true)
                    Text(
                        L10n.text(
                            "common.chat_route_preferred",
                            ((policy["preferred"] as? JsonObject)
                                    ?: (state?.get("preferred") as? JsonObject))
                                ?.routeText("backend") ?: chat.routeText("backend"),
                        ),
                        style = TsType.footnote,
                    )
            }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
    if (showing) ChatRoutingDialog(chat, backends, call, { showing = false }, onChanged)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChatRoutingDialog(
    chat: JsonObject,
    backends: List<JsonObject>,
    call: suspend (String, JsonObject) -> JsonElement,
    dismiss: () -> Unit,
    changed: suspend () -> Unit,
) {
    val scope = rememberCoroutineScope()
    fun agentLabel(id: String): String =
        backends
            .firstOrNull { it.routeText("id") == id }
            ?.routeText("label")
            ?.takeIf { it.isNotBlank() } ?: id
    var enabled by remember { mutableStateOf(false) }
    var wait by remember { mutableStateOf(false) }
    var returns by remember { mutableStateOf(false) }
    var defaults by remember { mutableStateOf(false) }
    var throttles by remember { mutableStateOf(false) }
    var outages by remember { mutableStateOf(false) }
    var auth by remember { mutableStateOf(false) }
    var failures by remember { mutableStateOf(false) }
    var advanced by remember { mutableStateOf(false) }
    var notifies by remember { mutableStateOf(true) }
    var preferred by remember { mutableStateOf<JsonObject?>(null) }
    var historyPage by remember { mutableStateOf<List<JsonObject>?>(null) }
    var historyCursor by remember { mutableStateOf<String?>(null) }
    var historyLoading by remember { mutableStateOf(false) }
    var routes by remember { mutableStateOf<List<JsonObject>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(chat.routeText("id")) {
        runCatching {
            val protocol = call("protocol", buildJsonObject {}) as? JsonObject
            val number = HostContracts.protocolOf(protocol)
            if (number == null || number < 34)
                throw IllegalStateException(L10n.text("common.chat_route_unavailable"))
            call("chat.routing", buildJsonObject { put("id", chat.routeText("id")) }) as JsonObject
        }
            .onSuccess {
                val policy = it["policy"] as? JsonObject
                enabled = policy?.bol("enabled") == true
                wait = policy?.bol("waitForReset") == true
                returns = policy?.bol("returnPreferred") == true
                defaults = policy?.bol("useAsDefault") == true
                throttles = policy?.bol("failoverOnThrottle") == true
                outages = policy?.bol("failoverOnErrors") == true
                auth = policy?.bol("failoverOnAuth") == true
                failures = policy?.bol("failoverOnFailures") == true
                notifies = policy?.get("notify") != JsonPrimitive(false)
                preferred = policy?.get("preferred") as? JsonObject
                routes =
                    (policy?.get("routes") as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
                loaded = true
            }
            .onFailure { error = it.message }
    }
    fun loadHistory(cursor: String? = null) {
        if (historyLoading) return
        historyLoading = true
        scope.launch {
            runCatching {
                call(
                    "chat.routingHistory",
                    buildJsonObject {
                        put("id", chat.routeText("id"))
                        if (cursor != null) put("cursor", cursor)
                    },
                )
                    as JsonObject
            }
                .onSuccess { page ->
                    historyPage =
                        (page["activity"] as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
                    historyCursor = (page["cursor"] as? JsonPrimitive)?.contentOrNull
                    error = null
                }
                .onFailure { error = it.message }
            historyLoading = false
        }
    }
    fun updateRoute(index: Int, key: String, value: String) {
        if (saving) return
        val old = routes[index]
        val updated =
            JsonObject(
                old + (key to (value.takeIf { it.isNotBlank() }?.let(::JsonPrimitive) ?: JsonNull))
            )
        if (preferred == old) preferred = updated
        routes = routes.mapIndexed { i, route -> if (i == index) updated else route }
    }
    val colors = LocalTsColors.current
    ai.tokenstat.tokenstat.ui.components.TsBottomSheet(
        onDismissRequest = { if (!saving) dismiss() },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = colors.background,
    ) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.92f)) {
            Row(
                Modifier.fillMaxWidth().background(colors.accentSoft).padding(Space.m),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                Icon(ActionIcon.Settings.vector, null, tint = colors.accent)
                Column {
                    Text(
                        L10n.text("common.chat_routing"),
                        style = TsType.headline,
                        color = colors.textPrimary,
                    )
                    Text(
                        L10n.text("common.chat_routing_intro"),
                        style = TsType.footnote,
                        color = colors.textSecondary,
                    )
                }
            }
            HorizontalDivider(color = colors.border)
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(Space.m),
                verticalArrangement = Arrangement.spacedBy(Space.m),
            ) {
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (loaded) {
                    BrandCheckbox(
                        enabled,
                        { if (!saving) enabled = !enabled },
                        L10n.text("common.chat_routing_enabled"),
                    )
                    Text(L10n.text("common.chat_route_order"), style = TsType.headline)
                    routes.forEachIndexed { index, route ->
                        TsCard {
                            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                                Text(
                                    "${index+1}. ${agentLabel(route.routeText("backend"))}",
                                    style = TsType.headline,
                                )
                                if (
                                    route.routeText("backend") == "muse" &&
                                        chat.routeText("autonomy") != "bypass"
                                )
                                    Text(
                                        L10n.text("common.chat_route_permissions"),
                                        color = MaterialTheme.colorScheme.error,
                                        style = TsType.footnote,
                                    )
                                val models =
                                    (backends
                                            .firstOrNull {
                                                it.routeText("id") == route.routeText("backend")
                                            }
                                            ?.get("models") as? JsonArray)
                                        ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                                        .orEmpty()
                                var menu by remember(route, index) { mutableStateOf(false) }
                                Box {
                                    TsPickerFieldRow(
                                        label = L10n.text("android.chatagentpanel.model.5e2c614c"),
                                        summary =
                                            route.routeText("model").ifBlank {
                                                L10n.text("android.chatagentpanel.default.21b111cb")
                                            },
                                        onOpen = { if (!saving) menu = true },
                                    )
                                    DropdownMenu(menu, { menu = false }) {
                                        (listOf("") + models).forEach { model ->
                                            DropdownMenuItem(
                                                text = {
                                                    Text(
                                                        model.ifBlank {
                                                            L10n.text(
                                                                "android.chatagentpanel.default.21b111cb"
                                                            )
                                                        }
                                                    )
                                                },
                                                onClick = {
                                                    updateRoute(index, "model", model)
                                                    menu = false
                                                },
                                            )
                                        }
                                    }
                                }
                                val efforts =
                                    (backends
                                            .firstOrNull {
                                                it.routeText("id") == route.routeText("backend")
                                            }
                                            ?.get("efforts") as? JsonArray)
                                        ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                                        .orEmpty()
                                if (efforts.isNotEmpty()) {
                                    var effortMenu by
                                        remember(route, index) { mutableStateOf(false) }
                                    Box {
                                        TsPickerFieldRow(
                                            label =
                                                L10n.text("android.chatagentpanel.effort.4387e5d3"),
                                            summary =
                                                route.routeText("effort").ifBlank {
                                                    L10n.text(
                                                        "android.chatagentpanel.default.21b111cb"
                                                    )
                                                },
                                            onOpen = { if (!saving) effortMenu = true },
                                        )
                                        DropdownMenu(effortMenu, { effortMenu = false }) {
                                            (listOf("") + efforts).forEach { effort ->
                                                DropdownMenuItem(
                                                    text = {
                                                        Text(
                                                            effort.ifBlank {
                                                                L10n.text(
                                                                    "android.chatagentpanel.default.21b111cb"
                                                                )
                                                            }
                                                        )
                                                    },
                                                    onClick = {
                                                        updateRoute(index, "effort", effort)
                                                        effortMenu = false
                                                    },
                                                )
                                            }
                                        }
                                    }
                                }
                                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                                    TsSecondaryButton(
                                        label = L10n.text("common.move_up"),
                                        icon = ActionIcon.Move.vector,
                                        small = true,
                                        enabled = index > 0 && !saving,
                                        onClick = {
                                            routes =
                                                routes.toMutableList().also {
                                                    java.util.Collections.swap(it, index, index - 1)
                                                }
                                        },
                                    )
                                    TsSecondaryButton(
                                        label = L10n.text("common.remove"),
                                        icon = ActionIcon.Delete.vector,
                                        small = true,
                                        onClick = {
                                            if (saving) return@TsSecondaryButton
                                            if (preferred == routes[index]) preferred = null
                                            routes = routes.filterIndexed { i, _ -> i != index }
                                        },
                                    )
                                }
                            }
                        }
                    }
                    var addMenu by remember { mutableStateOf(false) }
                    Box {
                        TsSecondaryButton(
                            label = L10n.text("common.add"),
                            icon = ActionIcon.Create.vector,
                            small = true,
                            enabled = routes.size < 8 && !saving,
                            onClick = { addMenu = true },
                        )
                        DropdownMenu(addMenu, { addMenu = false }) {
                            backends
                                .filter {
                                    it.routeText("id") != "sh" &&
                                        it["installed"] != JsonPrimitive(false)
                                }
                                .forEach { backend ->
                                    DropdownMenuItem(
                                        text = { Text(backend.routeText("label")) },
                                        onClick = {
                                            if (saving) return@DropdownMenuItem
                                            routes =
                                                routes +
                                                    buildJsonObject {
                                                        put("backend", backend.routeText("id"))
                                                    }
                                            addMenu = false
                                        },
                                    )
                                }
                        }
                    }
                    HorizontalDivider(color = LocalTsColors.current.border)
                    Text(L10n.text("common.chat_route_reset_options"), style = TsType.headline)
                    Text(
                        L10n.text("common.chat_route_priority_help"),
                        style = TsType.footnote,
                    )
                    BrandCheckbox(wait, { if (!saving) wait = !wait }, L10n.text("common.chat_wait_reset"))
                    BrandCheckbox(
                        returns,
                        { if (!saving) returns = !returns },
                        L10n.text("common.chat_return_preferred"),
                    )
                    if (returns) {
                        var preferredMenu by remember { mutableStateOf(false) }
                        Box {
                            TsPickerFieldRow(
                                label = L10n.text("common.chat_route_preferred_picker"),
                                summary =
                                    preferred?.let {
                                        listOf(
                                                agentLabel(it.routeText("backend")),
                                                it.routeText("model"),
                                                it.routeText("effort"),
                                            )
                                            .filter { value -> value.isNotBlank() }
                                            .joinToString(" · ")
                                    } ?: L10n.text("common.chat_route_current_preferred"),
                                onOpen = { if (!saving) preferredMenu = true },
                            )
                            DropdownMenu(preferredMenu, { preferredMenu = false }) {
                                DropdownMenuItem(
                                    text = {
                                        Text(L10n.text("common.chat_route_current_preferred"))
                                    },
                                    onClick = {
                                        if (saving) return@DropdownMenuItem
                                        preferred = null
                                        preferredMenu = false
                                    },
                                )
                                routes.forEach { route ->
                                    DropdownMenuItem(
                                        text = {
                                            Text(
                                                listOf(
                                                        route.routeText("backend"),
                                                        route.routeText("model"),
                                                        route.routeText("effort"),
                                                    )
                                                    .filter { it.isNotBlank() }
                                                    .joinToString(" · ")
                                            )
                                        },
                                        onClick = {
                                            if (saving) return@DropdownMenuItem
                                            preferred = route
                                            preferredMenu = false
                                        },
                                    )
                                }
                            }
                        }
                    }
                    if (returns)
                        Text(
                            L10n.text(
                                "common.chat_route_preferred",
                                (preferred ?: ((chat["routing"] as? JsonObject)?.get("preferred") as? JsonObject))
                                    ?.routeText("backend")
                                    .orEmpty()
                                    .ifBlank { chat.routeText("backend") },
                            ),
                            style = TsType.footnote,
                        )

                    HorizontalDivider(color = colors.border)
                    BrandCheckbox(
                        defaults,
                        { if (!saving) defaults = !defaults },
                        L10n.text("common.chat_route_default"),
                    )
                    TsSecondaryButton(
                        label = L10n.text("common.settings"),
                        modifier = Modifier.fillMaxWidth(),
                        icon = ActionIcon.Settings.vector,
                        small = true,
                        onClick = { advanced = !advanced },
                    )
                    if (advanced) {
                        BrandCheckbox(
                            throttles,
                            { if (!saving) throttles = !throttles },
                            L10n.text("common.chat_route_throttle"),
                        )
                        BrandCheckbox(
                            outages,
                            { if (!saving) outages = !outages },
                            L10n.text("common.chat_route_errors"),
                        )
                        BrandCheckbox(
                            notifies,
                            { if (!saving) notifies = !notifies },
                            L10n.text("common.chat_route_notify"),
                        )
                        BrandCheckbox(auth, { if (!saving) auth = !auth }, L10n.text("common.chat_route_auth"))
                        BrandCheckbox(
                            failures,
                            { if (!saving) failures = !failures },
                            L10n.text("common.chat_route_agent_errors"),
                        )
                    }
                    var history by remember { mutableStateOf(false) }
                    TsSecondaryButton(
                        label = L10n.text("common.chat_route_history"),
                        modifier = Modifier.fillMaxWidth(),
                        icon = ActionIcon.History.vector,
                        small = true,
                        onClick = {
                            history = !history
                            if (history) loadHistory()
                        },
                    )
                    if (history) {
                        val activity =
                            historyPage
                                ?: ((chat["routing"] as? JsonObject)?.get("activity") as? JsonArray)
                                    ?.filterIsInstance<JsonObject>()
                                    .orEmpty()
                        if (activity.isEmpty()) Text(L10n.text("common.chat_route_empty_history"))
                        activity.reversed().forEach { entry ->
                            HorizontalDivider()
                            Text(
                                routeActivityLabel(entry.routeText("kind")) +
                                    " · " +
                                    DateFormat.getDateTimeInstance(
                                            DateFormat.MEDIUM,
                                            DateFormat.SHORT,
                                        )
                                        .format(
                                            Date((entry["atMs"] as? JsonPrimitive)?.longOrNull ?: 0)
                                        ),
                                style = TsType.caption,
                            )
                            (entry["source"] as? JsonObject)?.let { Text(it.routeText("backend")) }
                            (entry["target"] as? JsonObject)?.let {
                                Text(
                                    "→ " +
                                        it.routeText("backend") +
                                        " · " +
                                        it.routeText("model") +
                                        " · " +
                                        it.routeText("effort")
                                )
                            }
                            Text(
                                entry.routeText("reason"),
                                style = TsType.footnote,
                            )
                        }
                    }
                    if (history)
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            TsSecondaryButton(
                                label = L10n.text("common.refresh"),
                                icon = ActionIcon.Refresh.vector,
                                small = true,
                                enabled = !historyLoading,
                                onClick = { loadHistory() },
                            )
                            historyCursor?.let { cursor ->
                                TsSecondaryButton(
                                    label = L10n.text("common.chat_route_older"),
                                    icon = ActionIcon.History.vector,
                                    small = true,
                                    enabled = !historyLoading,
                                    onClick = { loadHistory(cursor) },
                                )
                            }
                        }
                }
            }
            HorizontalDivider(color = colors.border)
            Row(
                Modifier.fillMaxWidth().padding(Space.m),
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                TsSecondaryButton(
                    label = L10n.text("common.cancel"),
                    icon = ActionIcon.Dismiss.vector,
                    modifier = Modifier.weight(1f),
                    enabled = !saving,
                    onClick = dismiss,
                )
                TsAccentButton(
                    label = L10n.text("common.save"),
                    icon = ActionIcon.Save.vector,
                    modifier = Modifier.weight(1f),
                    enabled = loaded && !saving,
                    onClick = {
                        if (saving) return@TsAccentButton
                        saving = true
                        scope.launch {
                            runCatching {
                                call(
                                    "chat.routing",
                                    buildJsonObject {
                                        put("id", chat.routeText("id"))
                                        chat["sendRevision"]?.let { put("expectedRevision", it) }
                                        put(
                                            "routing",
                                            buildJsonObject {
                                                put("enabled", enabled)
                                                put("waitForReset", wait)
                                                put("returnPreferred", returns)
                                                put("useAsDefault", defaults)
                                                put("failoverOnThrottle", throttles)
                                                put("failoverOnErrors", outages)
                                                put("failoverOnAuth", auth)
                                                put("failoverOnFailures", failures)
                                                put("notify", notifies)
                                                put("preferred", preferred ?: JsonNull)
                                                put("routes", JsonArray(routes))
                                            },
                                        )
                                    },
                                )
                            }
                                .onSuccess {
                                    changed()
                                    dismiss()
                                }
                                .onFailure { error = it.message }
                            saving = false
                        }
                    },
                )
            }
        }
    }
}


@Composable
private fun RoutingLimitCard(
    chat: JsonObject,
    state: JsonObject?,
    policy: JsonObject?,
    limit: JsonObject,
    backends: List<JsonObject>,
    applying: Boolean,
    agentLabel: (String) -> String,
    apply: (String, JsonObject) -> Unit,
    onRouting: () -> Unit,
    onHandOff: (() -> Unit)?,
) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(cardRadius)
    val provider = limit.routeText("provider")
    val reset = (limit["resetsAtMs"] as? JsonPrimitive)?.longOrNull
    val nextReset = state?.get("nextReset") as? JsonObject
    val deliveryCheck = state?.bol("needsDeliveryCheck") == true
    val waitAvailable = (reset != null || nextReset != null) && !deliveryCheck
    val saved = policy?.bol("waitForReset") == true
    var pendingWait by remember(chat.routeText("id")) { mutableStateOf<Boolean?>(null) }
    LaunchedEffect(saved, applying) { if (!applying) pendingWait = null }
    val waiting = pendingWait ?: saved
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.danger.copy(alpha = 0.08f))
            .border(1.dp, colors.danger.copy(alpha = 0.35f), shape)
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(Space.m), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .size(32.dp)
                    .clip(CircleShape)
                    .background(Brush.linearGradient(listOf(colors.danger, colors.danger.copy(alpha = 0.75f)))),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    if (limit.routeText("kind") == "usage") Icons.Filled.HourglassTop else Icons.Filled.Warning,
                    null,
                    tint = Color.White,
                    modifier = Modifier.size(17.dp),
                )
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    when (limit.routeText("kind")) {
                        "usage" -> L10n.text("common.chat_limit_reached", agentLabel(provider))
                        "throttle" -> L10n.text("common.chat_throttled", agentLabel(provider))
                        else -> L10n.text("common.chat_route_failure", agentLabel(provider))
                    },
                    style = TsType.headline,
                    color = colors.textPrimary,
                )
                val language = LocalConfiguration.current.locales[0].language
                Text(
                    if (reset == null) L10n.text("common.chat_reset_unknown")
                    else if (reset <= System.currentTimeMillis()) L10n.text(
                        "common.chat_reset_elapsed", DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(reset)),
                    )
                    else L10n.text(
                        "common.chat_resets_in",
                        DateUtils.getRelativeTimeSpanString(reset, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)
                            .toString()
                            .let { if (language == "en") it.replaceFirstChar { c -> c.lowercase() } else it },
                        DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(reset)),
                    ),
                    style = TsType.footnote,
                    color = colors.textSecondary,
                )
            }
        }
        limit.routeText("reason").takeIf { it.isNotBlank() }?.let {
            Text(it, style = TsType.footnote, color = colors.textSecondary)
        }
        (nextReset?.get("atMs") as? JsonPrimitive)?.longOrNull?.let { at ->
            val destination = nextReset["destination"] as? JsonObject
            if (destination?.routeText("backend") != provider)
                Text(
                    L10n.text(
                        "common.chat_route_waiting_for",
                        destination?.routeText("backend").orEmpty(),
                        DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(at)),
                    ),
                    style = TsType.footnote,
                    color = colors.textSecondary,
                )
        }
        if (deliveryCheck) Text(L10n.text("common.chat_route_delivery"), style = TsType.footnote, color = colors.warning)
        state?.routeText("note")?.takeIf { it.isNotBlank() }?.let {
            Text(it, style = TsType.footnote, color = colors.textSecondary)
        }
        val tileShape = RoundedCornerShape(10.dp)
        Column(
            Modifier
                .fillMaxWidth()
                .clip(tileShape)
                .background(colors.background.copy(alpha = 0.6f))
                .border(1.dp, colors.border, tileShape)
                .padding(horizontal = Space.m),
        ) {
            BrandCheckbox(
                checked = waiting,
                enabled = waitAvailable && !applying,
                onToggle = {
                    val next = !waiting
                    pendingWait = next
                    val changed = JsonObject(policy.orEmpty() + ("waitForReset" to JsonPrimitive(next)))
                    apply("chat.routing", buildJsonObject { put("routing", changed) })
                },
                label = L10n.text("common.chat_wait_reset"),
            )
            if (!waitAvailable && !deliveryCheck)
                Text(
                    L10n.text("common.chat_wait_reset_unavailable"),
                    style = TsType.footnote,
                    color = colors.textSecondary,
                    modifier = Modifier.padding(bottom = Space.s),
                )
        }
        val busy = chat.bol("running") || applying || deliveryCheck
        val actions = buildList {
            if (onHandOff != null)
                add(LimitAction(L10n.text("common.chat_hand_off_now"), ActionIcon.Routing.vector, true, !chat.bol("running") && !applying, onHandOff))
            add(LimitAction(L10n.text("common.chat_route_retry"), ActionIcon.Refresh.vector, false, !busy) {
                apply("chat.routeAction", buildJsonObject { put("choice", "resume") })
            })
            add(LimitAction(L10n.text("common.chat_routing"), ActionIcon.Settings.vector, false, true, onRouting))
            if (state?.bol("waiting") == true)
                add(LimitAction(L10n.text("common.cancel"), ActionIcon.Dismiss.vector, false, true) {
                    apply("chat.routeAction", buildJsonObject { put("choice", "cancel") })
                })
        }
        actions.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                row.forEach { LimitActionCell(it, Modifier.weight(1f)) }
            }
        }
    }
}

private class LimitAction(
    val label: String,
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
    val prominent: Boolean,
    val enabled: Boolean,
    val onClick: () -> Unit,
)

@Composable
private fun LimitActionCell(action: LimitAction, modifier: Modifier) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(10.dp)
    val content = if (action.prominent) colors.onAccent else colors.textPrimary
    Row(
        modifier
            .heightIn(min = 48.dp)
            .alpha(if (action.enabled) 1f else 0.42f)
            .clip(shape)
            .background(if (action.prominent) colors.accent else colors.panel)
            .border(1.dp, if (action.prominent) Color.Transparent else colors.border, shape)
            .clickable(enabled = action.enabled, role = Role.Button, onClick = action.onClick)
            .padding(horizontal = Space.s),
        horizontalArrangement = Arrangement.spacedBy(7.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(action.icon, null, tint = content, modifier = Modifier.size(18.dp))
        Text(
            action.label,
            style = TsType.subheadline.copy(fontWeight = FontWeight.SemiBold),
            color = content,
            maxLines = 1,
        )
    }
}
