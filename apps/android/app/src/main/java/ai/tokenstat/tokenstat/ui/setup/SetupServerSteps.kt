// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.setup

import ai.tokenstat.tokenstat.ui.localization.L10n

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.ssh.SshHostPlatform
import ai.tokenstat.tokenstat.ui.ssh.SshSecrets
import ai.tokenstat.tokenstat.ui.ssh.rawToJsonBytes
import ai.tokenstat.tokenstat.ui.ssh.sshString
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlin.coroutines.coroutineContext

class SetupConnectState {
    var hostname by mutableStateOf("")
    var username by mutableStateOf("root")
    var label by mutableStateOf("")

    var pickedHostId by mutableStateOf<String?>(null)

    var credential: SetupCredential by mutableStateOf(SetupCredential.None)

    var password by mutableStateOf("")

    var fingerprint by mutableStateOf<String?>(null)
    var trusted by mutableStateOf(false)

    var check by mutableStateOf<JsonObject?>(null)

    var machineName by mutableStateOf("server")
    var agents: List<String> by mutableStateOf(listOf("claude_code"))

    var installSessionId by mutableStateOf<String?>(null)

    var finished by mutableStateOf<JsonObject?>(null)
    var expectedPeer by mutableStateOf<String?>(null)
    var manualInstall by mutableStateOf(false)
    var manualMachineKey by mutableStateOf("")

    var working by mutableStateOf(false)
    var failure by mutableStateOf<SetupFailure?>(null)

    var libraryHosts by mutableStateOf<List<JsonObject>?>(null)
    var libraryKeys by mutableStateOf<List<JsonObject>?>(null)

    suspend fun loadLibrary(model: AppViewModel) {
        if (libraryHosts == null) {
            libraryHosts = (model.core("ssh.host.list") as? JsonArray).orEmpty()
                .mapNotNull { it as? JsonObject }
        }
        if (libraryKeys == null) {
            libraryKeys = (model.core("ssh.key.list") as? JsonArray).orEmpty()
                .mapNotNull { it as? JsonObject }
        }
    }

    var job: Job? = null

    fun cancel() {
        job?.cancel()
        job = null
    }

    fun editServer(field: ServerField, value: String) {
        if (pickedHostId != null) {
            pickedHostId = null
            credential = SetupCredential.None
            password = ""
            resetServer()
        }
        when (field) {
            ServerField.HOSTNAME -> hostname = value
            ServerField.USERNAME -> username = value
            ServerField.LABEL -> label = value
        }
    }

    fun resolvedHost(hosts: List<JsonObject>): JsonObject {
        val picked = pickedHostId
        if (picked != null) {
            hosts.firstOrNull { it.sshString("id") == picked }?.let { return it }
        }
        return buildJsonObject {
            put("id", "")
            put("label", label.ifBlank { hostname.ifBlank { "server" } })
            put("hostname", hostname.trim())
            put("port", 22)
            put("username", username.trim().ifEmpty { "root" })
            put("initialDirectory", "~")
            put("hostKeys", buildJsonArray {})
        }
    }

    fun whereReady(): Boolean =
        pickedHostId != null || (hostname.trim().isNotEmpty() && username.trim().isNotEmpty())

    fun resetServer() {
        cancel()
        fingerprint = null
        trusted = false
        check = null
        finished = null
        expectedPeer = null
        manualInstall = false
        manualMachineKey = ""
        installSessionId = null
        failure = null
    }

    fun startManualInstall() {
        manualInstall = true
        expectedPeer = null
        manualMachineKey = ""
        failure = null
    }

    val canCheckMachine: Boolean
        get() = !manualInstall || expectedPeer != null ||
            SetupIdentity.normalize(manualMachineKey) != null

    suspend fun probe(model: AppViewModel, hosts: List<JsonObject>) {
        fingerprint = null
        trusted = false
        check = null
        runGuarded {
            val host = resolvedHost(hosts)
            val answer = model.core(
                "ssh.host.probe",
                buildJsonObject {
                    put("hostname", host.sshString("hostname") ?: "")
                    put("port", host["port"]?.jsonPrimitive?.intOrNull ?: 22)
                    put("username", host.sshString("username") ?: "root")
                    put("initialDirectory", host.sshString("initialDirectory") ?: "~")
                    put("hostKeys", buildJsonArray {})
                },
            ).jsonObject
            coroutineContext.ensureActive()
            fingerprint = answer.sshString("fingerprint")
                ?: throw IllegalStateException(L10n.text("android.setupserversteps.the_server_did_not_offer_a_host_key.3c1b0e56"))
        }
    }

    suspend fun trust(model: AppViewModel, hosts: List<JsonObject>) {
        val pin = fingerprint ?: return
        runGuarded {
            val host = resolvedHost(hosts)
            val map = host.toMutableMap()
            map["hostKeys"] = buildJsonArray { add(JsonPrimitive(pin)) }
            if ((map["label"] as? JsonPrimitive)?.contentOrNull.isNullOrBlank()) {
                map["label"] = JsonPrimitive(map["hostname"]?.jsonPrimitive?.contentOrNull ?: "server")
            }
            val saved = model.core("ssh.host.save", JsonObject(map)).jsonObject
            coroutineContext.ensureActive()
            val id = saved.sshString("id") ?: host.sshString("id").orEmpty()
            pickedHostId = id
            trusted = true
            libraryHosts = (libraryHosts.orEmpty().filterNot { it.sshString("id") == id }) + saved
        }
    }

    suspend fun inspect(model: AppViewModel, context: Context, hosts: List<JsonObject>, keys: List<JsonObject>) {
        runGuarded {
            val host = resolvedHost(hosts)
            val auth = setupAuth(credential, password, keys, context)
            val answer = model.core(
                "ssh.provision.check",
                setupSessionParams(host, auth, rows = 24, cols = 100),
            ).jsonObject
            coroutineContext.ensureActive()
            check = answer
            SshHostPlatform.remember(context, answer, host)
            if (machineName == "server") {
                suggestMachineName(answer, machineName)?.let { machineName = it }
            }
        }
    }

    suspend fun install(
        model: AppViewModel,
        hosts: List<JsonObject>,
        keys: List<JsonObject>,
        context: Context,
        accountLabels: Set<String>,
    ) {
        runGuarded {
            val host = resolvedHost(hosts)
            val auth = setupAuth(credential, password, keys, context)
            val myKey = model.machineIdentity().sshString("key")
            machineName = availableMachineName(machineName, accountLabels)
            coroutineContext.ensureActive()
            val minted = model.core("account.pairingCode").jsonObject
            val code = minted.sshString("code")?.takeIf { it.isNotEmpty() }
                ?: throw IllegalStateException(L10n.text("android.setupserversteps.the_account_did_not_return_a_pairing_code.1776d60f"))
            coroutineContext.ensureActive()
            val staged = model.core(
                "ssh.provision.stageCode",
                setupSessionParams(host, auth, rows = 24, cols = 100).with("code", JsonPrimitive(code)),
            ).jsonObject
            val stageId = staged.sshString("stageId")
                ?: throw IllegalStateException(L10n.text("android.setupserversteps.missing_staging_receipt"))
            try {
                coroutineContext.ensureActive()
                val line = model.core(
                    "ssh.provision.line",
                    buildJsonObject {
                        if (myKey != null) put("allow", myKey)
                        put("name", machineName)
                        put("agents", buildJsonArray { agents.forEach { add(JsonPrimitive(it)) } })
                        put("printInvite", false)
                        put("codeFile", true)
                    },
                ).jsonObject
                val oneLine = line.sshString("oneLine")?.takeIf { it.isNotBlank() }
                    ?: throw IllegalStateException(L10n.text("android.setupserversteps.the_host_did_not_compose_an_install_line.26c6ebcc"))
                coroutineContext.ensureActive()
                val opened = model.core(
                    "ssh.session.open",
                    setupSessionParams(host, auth, rows = 24, cols = 100).with(
                        "label",
                        JsonPrimitive("Install on $machineName"),
                    ),
                ).jsonObject
                val id = opened.sshString("id")
                    ?: throw IllegalStateException(L10n.text("android.setupserversteps.the_session_opened_without_an_id.09911388"))
                coroutineContext.ensureActive()
                delay(700)
                coroutineContext.ensureActive()
                model.core(
                    "ssh.session.write",
                    buildJsonObject {
                        put("id", id)
                        put("data", rawToJsonBytes("$oneLine\n".toByteArray(Charsets.UTF_8)))
                    },
                )
                installSessionId = id
            } catch (e: Exception) {
                installSessionId = null
                withContext(kotlinx.coroutines.NonCancellable) {
                    runCatching {
                        model.core(
                            "ssh.provision.clearCode",
                            setupSessionParams(host, auth, rows = 24, cols = 100).with("stageId", JsonPrimitive(stageId)),
                        )
                    }
                }
                throw e
            }
        }
    }

    suspend fun waitForMachine(model: AppViewModel, hosts: List<JsonObject>, keys: List<JsonObject>, context: Context) {
        runGuarded {
            if (expectedPeer == null) {
                if (manualInstall) {
                    expectedPeer = SetupIdentity.normalize(manualMachineKey)
                        ?: throw ai.tokenstat.tokenstat.core.CoreFailure(
                            "identity_required",
                            L10n.text("android.setupserversteps.paste_the_full_machine_key_printed_by_the.c44766a5"),
                        )
                } else {
                    val host = resolvedHost(hosts)
                    val auth = setupAuth(credential, password, keys, context)
                    val answer = model.core(
                        "ssh.provision.identity",
                        setupSessionParams(host, auth, rows = 24, cols = 100),
                    ).jsonObject
                    coroutineContext.ensureActive()
                    expectedPeer = answer.sshString("key")
                        ?: throw IllegalStateException(L10n.text("android.setupserversteps.the_server_did_not_answer_with_an_identity.45212d47"))
                }
            }
            val peer = expectedPeer ?: return@runGuarded
            runCatching { model.pairPeer(peer, machineName) }
            val deadline = System.currentTimeMillis() + 180_000
            while (System.currentTimeMillis() < deadline) {
                coroutineContext.ensureActive()
                val fresh = model.core("account.status").jsonObject
                coroutineContext.ensureActive()
                val machines = (fresh["machines"] as? JsonArray).orEmpty()
                    .mapNotNull { it as? JsonObject }
                val present = machines.any { machine ->
                    val kind = machine.sshString("kind")
                    (kind == null || kind != "client") &&
                        SetupIdentity.matches(machine.sshString("publicIdentity") ?: "", peer)
                }
                if (present) {
                    val status = model.workspaceSection(peer, "host.provisionStatus", buildJsonObject {}).jsonObject
                    coroutineContext.ensureActive()
                    if (!SetupIdentity.matches(status.sshString("machineKey") ?: "", peer)) {
                        throw ai.tokenstat.tokenstat.core.CoreFailure(
                            "identity_mismatch",
                            L10n.text("android.setupserversteps.the_machine_answered_with_a_different_iden.b83fb7ed"),
                        )
                    }
                    finished = status
                    model.refresh()
                    return@runGuarded
                }
                delay(3_000)
            }
            throw ai.tokenstat.tokenstat.core.CoreFailure(
                "setup_pending",
                L10n.text("android.setupserversteps.this_machine_has_not_appeared_on_your_acco.727d062b"),
            )
        }
    }

    private suspend fun runGuarded(body: suspend () -> Unit) {
        if (working) return
        working = true
        failure = null
        job = coroutineContext[Job]
        try {
            body()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            failure = SetupFailure.from(e)
        } finally {
            working = false
            job = null
        }
    }
}

enum class ServerField { HOSTNAME, USERNAME, LABEL }

private fun JsonObject.with(key: String, value: kotlinx.serialization.json.JsonElement): JsonObject =
    JsonObject(toMutableMap().also { it[key] = value })

fun setupAuthPayload(
    credential: SetupCredential,
    password: String,
    key: JsonObject?,
    pem: String?,
): JsonObject {
    return when (credential) {
        is SetupCredential.None -> throw SetupAuthMissing(L10n.text("android.setupserversteps.choose_how_to_sign_in_to_this_server.ef643f08"))
        is SetupCredential.Password -> {
            if (password.isEmpty()) throw SetupAuthMissing(L10n.text("android.setupserversteps.enter_the_password_for_this_server.baf1babf"))
            buildJsonObject {
                put("kind", "password")
                put("password", password)
            }
        }
        is SetupCredential.Key -> {
            if (key == null) throw SetupAuthMissing(L10n.text("android.setupserversteps.that_key_is_no_longer_in_your_vault.c88cbd34"))
            val ref = key.sshString("secretRef").orEmpty()
            if (ref.startsWith("agent:")) {
                buildJsonObject {
                    put("kind", "agent")
                    put("fingerprint", ref.removePrefix("agent:"))
                }
            } else {
                if (pem.isNullOrEmpty()) {
                    throw SetupAuthMissing(L10n.text("android.setupserversteps.that_key_has_no_private_material_on_this_d.d0045bd3"))
                }
                buildJsonObject {
                    put("kind", "privateKey")
                    put("pem", pem)
                }
            }
        }
    }
}

suspend fun setupAuth(
    credential: SetupCredential,
    password: String,
    keys: List<JsonObject>,
    context: Context,
): JsonObject {
    val record = (credential as? SetupCredential.Key)?.let { chosen ->
        keys.firstOrNull { it.sshString("id") == chosen.id }
    }
    val ref = record?.sshString("secretRef").orEmpty()
    val pem = if (ref.isNotEmpty() && !ref.startsWith("agent:")) {
        withContext(kotlinx.coroutines.Dispatchers.IO) { SshSecrets.get(context, ref) }
    } else {
        null
    }
    return setupAuthPayload(credential, password, record, pem)
}

class SetupAuthMissing(message: String) : Exception(message)

fun setupSessionParams(host: JsonObject, auth: JsonObject, rows: Int, cols: Int): JsonObject =
    buildJsonObject {
        put("hostname", host.sshString("hostname") ?: "")
        put("port", host["port"]?.jsonPrimitive?.intOrNull ?: 22)
        put("username", host.sshString("username") ?: "root")
        put("initialDirectory", host.sshString("initialDirectory") ?: "~")
        val keys = (host["hostKeys"] as? JsonArray)?.mapNotNull {
            (it as? JsonPrimitive)?.contentOrNull
        }.orEmpty()
        put("hostKeys", buildJsonArray { keys.forEach { add(JsonPrimitive(it)) } })
        put("rows", rows)
        put("cols", cols)
        put("auth", auth)
    }

fun suggestMachineName(check: JsonObject, current: String): String? {
    if (current != "server") return null
    return check.sshString("distro")?.split(" ")?.firstOrNull()
        ?.takeIf { it.isNotBlank() }?.lowercase()
}

data class SetupProvisionInfo(
    val signedInHandle: String?,
    val alwaysOn: Boolean,
    val tunnelOnline: Boolean,
    val runsAs: String,
    val allowedDevices: Int,
    val anyAgentInstalled: Boolean,
    val protocol: Long?,
) {
    companion object {
        fun of(status: JsonObject): SetupProvisionInfo {
            val account = status["account"] as? JsonObject
            val runsAs = status["runsAs"] as? JsonObject
            val tunnel = status["tunnel"] as? JsonObject
            val agents = (status["agents"] as? JsonArray).orEmpty()
                .mapNotNull { it as? JsonObject }
            return SetupProvisionInfo(
                signedInHandle = account?.sshString("handle"),
                alwaysOn = (status["alwaysOn"] as? JsonPrimitive)?.booleanOrNull == true,
                tunnelOnline = (tunnel?.get("online") as? JsonPrimitive)?.booleanOrNull == true,
                runsAs = runsAs?.sshString("name") ?: "unknown",
                allowedDevices = status["allowedDevices"]?.jsonPrimitive?.intOrNull ?: 0,
                anyAgentInstalled = agents.any {
                    (it["installed"] as? JsonPrimitive)?.booleanOrNull == true
                },
                protocol = status["protocolVersion"]?.jsonPrimitive?.longOrNull
                    ?: status["protocolVersion"]?.jsonPrimitive?.contentOrNull?.toLongOrNull()
                    ?: status["protocol"]?.jsonPrimitive?.longOrNull,
            )
        }
    }
}

fun recoverSetupPath(action: SetupAction): List<SetupStep>? = when (action.step()) {
    SetupStep.WHERE -> listOf(SetupStep.WHERE)
    SetupStep.CREDENTIAL -> listOf(SetupStep.WHERE, SetupStep.CREDENTIAL)
    SetupStep.INSTALL -> listOf(SetupStep.WHERE, SetupStep.CREDENTIAL, SetupStep.CHECK, SetupStep.INSTALL)
    SetupStep.FINISH -> listOf(
        SetupStep.WHERE, SetupStep.CREDENTIAL, SetupStep.CHECK, SetupStep.INSTALL, SetupStep.FINISH,
    )
    SetupStep.AGENT -> listOf(
        SetupStep.WHERE, SetupStep.CREDENTIAL, SetupStep.CHECK, SetupStep.INSTALL,
        SetupStep.FINISH, SetupStep.AGENT,
    )
    else -> action.step()?.let { listOf(it) }
}
