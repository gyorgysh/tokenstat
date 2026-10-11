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
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.serialization.json.*
import java.text.DateFormat
import java.util.Date

private fun JsonObject.routeText(key:String):String = (this[key] as? JsonPrimitive)?.contentOrNull.orEmpty()

@Composable
internal fun ChatRoutingControls(chat: JsonObject, backends: List<JsonObject>,
    call: suspend (String, JsonObject) -> JsonElement, onChanged: () -> Unit) {
    val scope = rememberCoroutineScope()
    var showing by remember(chat.routeText("id")) { mutableStateOf(false) }
    var error by remember(chat.routeText("id")) { mutableStateOf<String?>(null) }
    val state = chat["routing"] as? JsonObject
    val policy = state?.get("policy") as? JsonObject
    val limit = state?.get("limit") as? JsonObject
    fun apply(method: String, extra: JsonObject) {
        scope.launch {
            runCatching { call(method, buildJsonObject {
                put("id",chat.routeText("id")); chat["sendRevision"]?.let { put("expectedRevision",it) }
                extra.forEach { (key,value) -> put(key,value) }
            }) }.onSuccess { error = null; onChanged() }.onFailure { error = it.message }
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        if (limit != null) TsCard {
            Text(if (limit.routeText("kind") == "usage") L10n.text("common.chat_limit_reached", limit.routeText("provider")) else L10n.text("common.chat_throttled", limit.routeText("provider")), style = MaterialTheme.typography.titleSmall)
            val reset = (limit["resetsAtMs"] as? JsonPrimitive)?.longOrNull
            Text(if (reset == null) L10n.text("common.chat_reset_unknown") else L10n.text("common.chat_resets_at",DateFormat.getDateTimeInstance(DateFormat.MEDIUM,DateFormat.SHORT).format(Date(reset))))
            state?.routeText("note")?.takeIf { it.isNotBlank() }?.let { Text(it) }
            if (state?.bol("needsDeliveryCheck") == true) Text(L10n.text("common.chat_route_delivery"))
            if (reset != null) BrandCheckbox(checked = policy?.bol("waitForReset") == true, onToggle = {
                val changed = JsonObject(policy.orEmpty() + ("waitForReset" to JsonPrimitive(policy?.bol("waitForReset") != true)))
                apply("chat.routing",buildJsonObject { put("routing",changed) })
            }, label = L10n.text("common.chat_wait_reset"))
            Row {
                TextButton(enabled = !chat.bol("running") && state?.bol("needsDeliveryCheck") != true, onClick = {apply("chat.routeAction",buildJsonObject {put("choice","resume")})}) { Text(L10n.text("common.chat_route_retry")) }
                TextButton(onClick = {apply("chat.routeAction",buildJsonObject {put("choice","cancel")})}) {Text(L10n.text("common.cancel"))}
            }
        }
        TextButton(onClick = {showing = true}) {Text(L10n.text("common.chat_routing"))}
        error?.let {Text(it,color = MaterialTheme.colorScheme.error)}
    }
    if (showing) ChatRoutingDialog(chat, backends, call, {showing = false}, onChanged)
}

@Composable
private fun ChatRoutingDialog(chat:JsonObject, backends:List<JsonObject>, call:suspend(String,JsonObject)->JsonElement, dismiss:()->Unit, changed:()->Unit) {
    val scope = rememberCoroutineScope()
    var enabled by remember {mutableStateOf(false)}
    var wait by remember {mutableStateOf(false)}
    var returns by remember {mutableStateOf(false)}
    var defaults by remember {mutableStateOf(false)}
    var routes by remember {mutableStateOf<List<JsonObject>>(emptyList())}
    var loaded by remember {mutableStateOf(false)}
    var saving by remember {mutableStateOf(false)}
    var error by remember {mutableStateOf<String?>(null)}
    LaunchedEffect(chat.routeText("id")) {
        runCatching {
            val protocol = call("protocol",buildJsonObject {}) as? JsonObject
            val number = HostContracts.protocolOf(protocol)
            if (number == null || number < 34) throw IllegalStateException(L10n.text("common.chat_route_unavailable"))
            call("chat.routing",buildJsonObject {put("id",chat.routeText("id"))}) as JsonObject
        }.onSuccess {
            val policy = it["policy"] as? JsonObject
            enabled = policy?.bol("enabled") == true; wait = policy?.bol("waitForReset") == true; returns = policy?.bol("returnPreferred") == true; defaults = policy?.bol("useAsDefault") == true
            routes = (policy?.get("routes") as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty(); loaded = true
        }.onFailure {error = it.message}
    }
    AlertDialog(onDismissRequest=dismiss,title={Text(L10n.text("common.chat_routing"))},text={
        Column(Modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(Space.s)) {
            Text(L10n.text("common.chat_route_explanation"))
            error?.let {Text(it,color=MaterialTheme.colorScheme.error)}
            if (loaded) {
                BrandCheckbox(enabled,{enabled=!enabled},L10n.text("common.chat_routing_enabled"))
                BrandCheckbox(wait,{wait=!wait},L10n.text("common.chat_wait_reset"))
                BrandCheckbox(returns,{returns=!returns},L10n.text("common.chat_return_preferred"))
                BrandCheckbox(defaults,{defaults=!defaults},L10n.text("common.chat_route_default"))
                Text(L10n.text("common.chat_route_order"))
                routes.forEachIndexed {index,route ->
                    Column {
                        Text("${index+1}. ${route.routeText("backend")}")
                        val models = (backends.firstOrNull {it.routeText("id")==route.routeText("backend")}?.get("models") as? JsonArray)?.mapNotNull{(it as? JsonPrimitive)?.contentOrNull}.orEmpty()
                        var menu by remember(route,index) {mutableStateOf(false)}
                        Box {
                            TextButton(onClick={menu=true}) {Text(route.routeText("model").ifBlank{L10n.text("android.chatagentpanel.default.21b111cb")})}
                            DropdownMenu(menu,{menu=false}) {
                                (listOf("")+models).forEach {model -> DropdownMenuItem(text={Text(model.ifBlank{L10n.text("android.chatagentpanel.default.21b111cb")})},onClick={
                                    routes=routes.mapIndexed {i,r->if(i==index) buildJsonObject {put("backend",r.routeText("backend"));if(model.isNotBlank())put("model",model)}else r};menu=false
                                })}
                            }
                        }
                        Row {
                            TextButton(enabled=index>0,onClick={routes=routes.toMutableList().also{java.util.Collections.swap(it,index,index-1)}}){Text(L10n.text("common.move_up"))}
                            TextButton(onClick={routes=routes.filterIndexed{i,_->i!=index}}){Text(L10n.text("common.remove"))}
                        }
                    }
                }
                var addMenu by remember {mutableStateOf(false)}
                Box {
                    TextButton(enabled=routes.size<8,onClick={addMenu=true}){Text(L10n.text("common.add"))}
                    DropdownMenu(addMenu,{addMenu=false}) {
                        backends.filter{it.routeText("id")!="sh"&&it["installed"]!=JsonPrimitive(false)}.forEach {backend->
                            DropdownMenuItem(text={Text(backend.routeText("label"))},onClick={routes=routes+buildJsonObject{put("backend",backend.routeText("id"))};addMenu=false})
                        }
                    }
                }
            }
        }
    },confirmButton={TextButton(enabled=loaded&&!saving,onClick={saving=true;scope.launch {
        runCatching {call("chat.routing",buildJsonObject {
            put("id",chat.routeText("id"));chat["sendRevision"]?.let{put("expectedRevision",it)}
            put("routing",buildJsonObject {put("enabled",enabled);put("waitForReset",wait);put("returnPreferred",returns);put("useAsDefault",defaults);put("routes",JsonArray(routes))})
        })}.onSuccess{changed();dismiss()}.onFailure{error=it.message};saving=false
    }}){Text(L10n.text("common.save"))}},dismissButton={TextButton(onClick=dismiss){Text(L10n.text("common.cancel"))}})
}
