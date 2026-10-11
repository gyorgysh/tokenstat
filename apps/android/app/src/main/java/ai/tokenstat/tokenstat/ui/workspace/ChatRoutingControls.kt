// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.*
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.theme.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import java.text.DateFormat
import java.util.Date
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

@Composable
internal fun ChatRoutingControls(
    chat: JsonObject,
    backends: List<JsonObject>,
    call: suspend (String, JsonObject) -> JsonElement,
    onChanged: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    fun agentLabel(id: String): String =
        backends
            .firstOrNull { it.routeText("id") == id }
            ?.routeText("label")
            ?.takeIf { it.isNotBlank() } ?: id
    var showing by remember(chat.routeText("id")) { mutableStateOf(false) }
    var error by remember(chat.routeText("id")) { mutableStateOf<String?>(null) }
    val state = chat["routing"] as? JsonObject
    val policy = state?.get("policy") as? JsonObject
    val limit = state?.get("limit") as? JsonObject
    fun apply(method: String, extra: JsonObject) {
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
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        if (limit != null)
            TsCard {
                Text(
                    if (limit.routeText("kind") == "usage")
                        L10n.text(
                            "common.chat_limit_reached",
                            agentLabel(limit.routeText("provider")),
                        )
                    else if (limit.routeText("kind") == "throttle")
                        L10n.text("common.chat_throttled", agentLabel(limit.routeText("provider")))
                    else
                        L10n.text(
                            "common.chat_route_failure",
                            agentLabel(limit.routeText("provider")),
                        ),
                    style = MaterialTheme.typography.titleSmall,
                )
                Text(limit.routeText("reason"))
                val reset = (limit["resetsAtMs"] as? JsonPrimitive)?.longOrNull
                Text(
                    if (reset == null) L10n.text("common.chat_reset_unknown")
                    else
                        L10n.text(
                            "common.chat_resets_at",
                            DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
                                .format(Date(reset)),
                        )
                )
                state?.routeText("note")?.takeIf { it.isNotBlank() }?.let { Text(it) }
                if (state?.bol("needsDeliveryCheck") == true)
                    Text(L10n.text("common.chat_route_delivery"))
                val nextReset = state?.get("nextReset") as? JsonObject
                (nextReset?.get("atMs") as? JsonPrimitive)?.longOrNull?.let { at ->
                    val destination = nextReset["destination"] as? JsonObject
                    if (destination?.routeText("backend") != limit.routeText("provider"))
                        Text(
                            L10n.text(
                                "common.chat_route_waiting_for",
                                destination?.routeText("backend").orEmpty(),
                                DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
                                    .format(Date(at)),
                            )
                        )
                }
                if (reset != null || nextReset != null)
                    BrandCheckbox(
                        checked = policy?.bol("waitForReset") == true,
                        onToggle = {
                            val changed =
                                JsonObject(
                                    policy.orEmpty() +
                                        ("waitForReset" to
                                            JsonPrimitive(policy?.bol("waitForReset") != true))
                                )
                            apply("chat.routing", buildJsonObject { put("routing", changed) })
                        },
                        label = L10n.text("common.chat_wait_reset"),
                    )
                Row {
                    TextButton(
                        enabled = !chat.bol("running") && state?.bol("needsDeliveryCheck") != true,
                        onClick = {
                            apply("chat.routeAction", buildJsonObject { put("choice", "resume") })
                        },
                    ) {
                        Text(L10n.text("common.chat_route_retry"))
                    }
                    TextButton(
                        onClick = {
                            apply("chat.routeAction", buildJsonObject { put("choice", "cancel") })
                        }
                    ) {
                        Text(L10n.text("common.cancel"))
                    }
                }
            }
        TsCard {
            Text(L10n.text("common.chat_routing"), style = MaterialTheme.typography.titleSmall)
            Text(
                L10n.text(
                    if (policy?.bol("enabled") == true) {
                        if (policy.bol("waitForReset")) "common.chat_route_combined_mode"
                        else "common.chat_route_fallback_mode"
                    } else {
                        if (policy?.bol("waitForReset") == true) "common.chat_route_wait_mode"
                        else "common.chat_route_manual"
                    }
                ),
                style = MaterialTheme.typography.bodySmall,
            )
            val destinations =
                (policy?.get("routes") as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
            if (destinations.isNotEmpty())
                Text(
                    destinations.joinToString(" → ") { agentLabel(it.routeText("backend")) },
                    style = MaterialTheme.typography.bodySmall,
                )
            if (policy?.bol("returnPreferred") == true)
                Text(
                    L10n.text(
                        "common.chat_route_preferred",
                        ((policy["preferred"] as? JsonObject)
                                ?: (state?.get("preferred") as? JsonObject))
                            ?.routeText("backend") ?: chat.routeText("backend"),
                    ),
                    style = MaterialTheme.typography.bodySmall,
                )
            TextButton(onClick = { showing = true }) { Text(L10n.text("common.chat_route_setup")) }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
    if (showing) ChatRoutingDialog(chat, backends, call, { showing = false }, onChanged)
}

@Composable
private fun ChatRoutingDialog(
    chat: JsonObject,
    backends: List<JsonObject>,
    call: suspend (String, JsonObject) -> JsonElement,
    dismiss: () -> Unit,
    changed: () -> Unit,
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
        val old = routes[index]
        val updated =
            JsonObject(
                old + (key to (value.takeIf { it.isNotBlank() }?.let(::JsonPrimitive) ?: JsonNull))
            )
        if (preferred == old) preferred = updated
        routes = routes.mapIndexed { i, route -> if (i == index) updated else route }
    }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text(L10n.text("common.chat_routing")) },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                Text(L10n.text("common.chat_route_explanation"))
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (loaded) {
                    BrandCheckbox(
                        enabled,
                        { enabled = !enabled },
                        L10n.text("common.chat_routing_enabled"),
                    )
                    Text(
                        L10n.text("common.chat_route_priority_help"),
                        style = MaterialTheme.typography.bodySmall,
                    )
                    BrandCheckbox(wait, { wait = !wait }, L10n.text("common.chat_wait_reset"))
                    BrandCheckbox(
                        returns,
                        { returns = !returns },
                        L10n.text("common.chat_return_preferred"),
                    )
                    BrandCheckbox(
                        defaults,
                        { defaults = !defaults },
                        L10n.text("common.chat_route_default"),
                    )
                    TextButton(onClick = { advanced = !advanced }) {
                        Text(L10n.text("common.settings"))
                    }
                    if (advanced) {
                        BrandCheckbox(
                            throttles,
                            { throttles = !throttles },
                            L10n.text("common.chat_route_throttle"),
                        )
                        BrandCheckbox(
                            outages,
                            { outages = !outages },
                            L10n.text("common.chat_route_errors"),
                        )
                        BrandCheckbox(
                            notifies,
                            { notifies = !notifies },
                            L10n.text("common.chat_route_notify"),
                        )
                        BrandCheckbox(auth, { auth = !auth }, L10n.text("common.chat_route_auth"))
                        BrandCheckbox(
                            failures,
                            { failures = !failures },
                            L10n.text("common.chat_route_agent_errors"),
                        )
                    }
                    Text(
                        L10n.text("common.chat_route_policy_help"),
                        style = MaterialTheme.typography.bodySmall,
                    )
                    if (returns) {
                        var preferredMenu by remember { mutableStateOf(false) }
                        Text(
                            L10n.text("common.chat_route_preferred_picker"),
                            style = MaterialTheme.typography.labelSmall,
                        )
                        Box {
                            TextButton(onClick = { preferredMenu = true }) {
                                Text(
                                    preferred?.let {
                                        listOf(
                                                it.routeText("backend"),
                                                it.routeText("model"),
                                                it.routeText("effort"),
                                            )
                                            .filter { value -> value.isNotBlank() }
                                            .joinToString(" · ")
                                    } ?: L10n.text("common.chat_route_current_preferred")
                                )
                            }
                            DropdownMenu(preferredMenu, { preferredMenu = false }) {
                                DropdownMenuItem(
                                    text = {
                                        Text(L10n.text("common.chat_route_current_preferred"))
                                    },
                                    onClick = {
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
                                ((chat["routing"] as? JsonObject)?.get("preferred") as? JsonObject)
                                    ?.routeText("backend")
                                    .orEmpty()
                                    .ifBlank { chat.routeText("backend") },
                            ),
                            style = MaterialTheme.typography.bodySmall,
                        )

                    Text(L10n.text("common.chat_route_order"))
                    routes.forEachIndexed { index, route ->
                        TsCard {
                            Text(
                                "${index+1}. ${agentLabel(route.routeText("backend"))}",
                                style = MaterialTheme.typography.titleSmall,
                            )
                            if (
                                route.routeText("backend") == "muse" &&
                                    chat.routeText("autonomy") != "bypass"
                            )
                                Text(
                                    L10n.text("common.chat_route_permissions"),
                                    color = MaterialTheme.colorScheme.error,
                                    style = MaterialTheme.typography.bodySmall,
                                )
                            val models =
                                (backends
                                        .firstOrNull {
                                            it.routeText("id") == route.routeText("backend")
                                        }
                                        ?.get("models") as? JsonArray)
                                    ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                                    .orEmpty()
                            Text(
                                L10n.text("android.chatagentpanel.model.5e2c614c"),
                                style = MaterialTheme.typography.labelSmall,
                            )
                            var menu by remember(route, index) { mutableStateOf(false) }
                            Box {
                                TextButton(onClick = { menu = true }) {
                                    Text(
                                        route.routeText("model").ifBlank {
                                            L10n.text("android.chatagentpanel.default.21b111cb")
                                        }
                                    )
                                }
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
                                var effortMenu by remember(route, index) { mutableStateOf(false) }
                                Text(
                                    L10n.text("android.chatagentpanel.effort.4387e5d3"),
                                    style = MaterialTheme.typography.labelSmall,
                                )
                                Box {
                                    TextButton(onClick = { effortMenu = true }) {
                                        Text(
                                            route.routeText("effort").ifBlank {
                                                L10n.text("android.chatagentpanel.default.21b111cb")
                                            }
                                        )
                                    }
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
                            Row {
                                TextButton(
                                    enabled = index > 0,
                                    onClick = {
                                        routes =
                                            routes.toMutableList().also {
                                                java.util.Collections.swap(it, index, index - 1)
                                            }
                                    },
                                ) {
                                    Text(L10n.text("common.move_up"))
                                }
                                TextButton(
                                    onClick = {
                                        if (preferred == routes[index]) preferred = null
                                        routes = routes.filterIndexed { i, _ -> i != index }
                                    }
                                ) {
                                    Text(L10n.text("common.remove"))
                                }
                            }
                        }
                    }
                    var history by remember { mutableStateOf(false) }
                    TextButton(
                        onClick = {
                            history = !history
                            if (history) loadHistory()
                        }
                    ) {
                        Text(L10n.text("common.chat_route_history"))
                    }
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
                                style = MaterialTheme.typography.labelMedium,
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
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                    if (history)
                        Row {
                            TextButton(enabled = !historyLoading, onClick = { loadHistory() }) {
                                Text(L10n.text("common.refresh"))
                            }
                            historyCursor?.let { cursor ->
                                TextButton(
                                    enabled = !historyLoading,
                                    onClick = { loadHistory(cursor) },
                                ) {
                                    Text(L10n.text("common.chat_route_older"))
                                }
                            }
                        }
                    var addMenu by remember { mutableStateOf(false) }
                    Box {
                        TextButton(enabled = routes.size < 8, onClick = { addMenu = true }) {
                            Text(L10n.text("common.add"))
                        }
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
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = loaded && !saving,
                onClick = {
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
            ) {
                Text(L10n.text("common.save"))
            }
        },
        dismissButton = { TextButton(onClick = dismiss) { Text(L10n.text("common.cancel")) } },
    )
}
