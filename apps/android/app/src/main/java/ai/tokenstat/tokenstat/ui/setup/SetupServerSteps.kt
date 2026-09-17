// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.setup

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

/// Setting up a machine from this phone, one step at a time. Ported from
/// `ClientSetupModel.swift`.
///
/// This is the provisioning plane, and it has one rule: it may install and
/// enroll, and it may not do work. The moment the server is a peer, setup is
/// finished and hands over to the agent and project steps, which use the same
/// tunnel methods every other machine uses.
///
/// Nothing here is a second copy of anything. The saved servers and keys are
/// the SSH library's, the install line is composed by the host so every
/// surface shows the same one, and the check is the host's verdict rather
/// than this screen's reading of raw facts.
class SetupConnectState {
    /// Where. A draft record, saved to the library only once it is trusted:
    /// a half-typed address is not a server somebody owns.
    var hostname by mutableStateOf("")
    var username by mutableStateOf("root")
    var label by mutableStateOf("")

    /// A saved server picked instead of typing one.
    var pickedHostId by mutableStateOf<String?>(null)

    /// How to sign in. Resolved into an auth payload per call, because the
    /// private key lives in this device's vault and nowhere else.
    var credential: SetupCredential by mutableStateOf(SetupCredential.None)

    /// Typed once, used once, never stored.
    var password by mutableStateOf("")

    var fingerprint by mutableStateOf<String?>(null)
    var trusted by mutableStateOf(false)

    var check by mutableStateOf<JsonObject?>(null)

    /// What this machine will be called on the account.
    var machineName by mutableStateOf("server")
    var agents: List<String> by mutableStateOf(listOf("claude_code"))

    /// The install shell, once the line is typed into it. Watching it is the
    /// install step's whole second half.
    var installSessionId by mutableStateOf<String?>(null)

    /// The machine's own answer, once it is a peer. The finish step reads
    /// this rather than believing what scrolled past in the terminal.
    var finished by mutableStateOf<JsonObject?>(null)
    var expectedPeer by mutableStateOf<String?>(null)
    var manualInstall by mutableStateOf(false)
    var manualMachineKey by mutableStateOf("")

    var working by mutableStateOf(false)
    var failure by mutableStateOf<SetupFailure?>(null)

    /// The saved servers and keys, loaded once and shared by every step.
    /// Nothing here is a second copy: trusting a host key writes through to
    /// the same library the SSH screen reads.
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

    /// The probe, check, install or wait in flight, so Stop has something to
    /// stop. A TCP connect to a host that is not answering sits there until
    /// the socket times out, which is around a minute, and for that whole
    /// minute the step must still do something when asked to stop.
    var job: Job? = null

    fun cancel() {
        job?.cancel()
        job = null
    }

    /// Typing another server must stop referring to a saved record. Clear its
    /// identity too, so confirming the new fingerprint creates a new row.
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

    /// The host record as it stands, whether picked or typed.
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

    /// Re-entering the address step invalidates every result tied to it.
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

    /// Ask the server for its host key, before any credential is offered.
    ///
    /// The one screen in this wizard where a mistake is permanent, which is
    /// why it is a step of its own rather than a line in another one.
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
                ?: throw IllegalStateException("The server did not offer a host key.")
        }
    }

    /// Keep the fingerprint, and the server with it.
    ///
    /// This is where a typed address becomes a saved one: trusting a host key
    /// is the moment somebody says this server is theirs.
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
            // The next step reads the record just written, with its id.
            libraryHosts = (libraryHosts.orEmpty().filterNot { it.sshString("id") == id }) + saved
        }
    }

    /// What the server is, before anything is written to it. One fixed script
    /// on its own channel, so nothing appears in the person's shell and
    /// nothing on the server changes.
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

    /// Mint a code, put it on the server as a private file, and type the line.
    ///
    /// The code never reaches the command line: there it would land in the
    /// shell history and, briefly, in `/proc`. It goes down its own channel
    /// into a 0600 file, and the line names that file.
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
                ?: throw IllegalStateException("The account did not return a pairing code.")
            coroutineContext.ensureActive()
            model.core(
                "ssh.provision.stageCode",
                setupSessionParams(host, auth, rows = 24, cols = 100).with("code", JsonPrimitive(code)),
            )
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
                    ?: throw IllegalStateException("The host did not compose an install line.")
                coroutineContext.ensureActive()
                val opened = model.core(
                    "ssh.session.open",
                    setupSessionParams(host, auth, rows = 24, cols = 100).with(
                        "label",
                        JsonPrimitive("Install on $machineName"),
                    ),
                ).jsonObject
                val id = opened.sshString("id")
                    ?: throw IllegalStateException("The session opened without an id.")
                coroutineContext.ensureActive()
                // A moment for the shell to draw its prompt. Typing into a
                // shell that has not started echoing yet loses the first
                // characters.
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
                runCatching {
                    model.core(
                        "ssh.provision.clearCode",
                        setupSessionParams(host, auth, rows = 24, cols = 100),
                    )
                }
                throw e
            }
        }
    }

    /// Ask the machine itself whether it is set up, over the tunnel it now
    /// has. Polled rather than assumed: the installer's output scrolling past
    /// is not the same as a machine that answers.
    suspend fun waitForMachine(model: AppViewModel, hosts: List<JsonObject>, keys: List<JsonObject>, context: Context) {
        runGuarded {
            if (expectedPeer == null) {
                if (manualInstall) {
                    expectedPeer = SetupIdentity.normalize(manualMachineKey)
                        ?: throw ai.tokenstat.tokenstat.core.CoreFailure(
                            "identity_required",
                            "Paste the full machine key printed by the installer.",
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
                        ?: throw IllegalStateException("The server did not answer with an identity.")
                }
            }
            val peer = expectedPeer ?: return@runGuarded
            // The key arrived over the verified SSH session, which is the
            // same consent as typing it by hand. Approve it here so the
            // tunnel calls below are not refused as unapproved.
            runCatching { model.pairPeer(peer, machineName) }
            val deadline = System.currentTimeMillis() + 180_000
            while (System.currentTimeMillis() < deadline) {
                coroutineContext.ensureActive()
                // A fresh response, not the app's retained snapshot.
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
                            "The machine answered with a different identity. Reconnect and verify the server.",
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
                "This machine has not appeared on your account yet. Check that the install finished, then try again.",
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

/// One auth payload, built from the chosen credential and the private
/// material already loaded for it. Pure, so unit tests pin the same answers.
///
/// Built on this device because only this device can open the vault. A
/// password is used for the connection and never written anywhere. Ported
/// from `ClientSetupModel.authPayload`.
fun setupAuthPayload(
    credential: SetupCredential,
    password: String,
    key: JsonObject?,
    pem: String?,
): JsonObject {
    return when (credential) {
        is SetupCredential.None -> throw SetupAuthMissing("Choose how to sign in to this server.")
        is SetupCredential.Password -> {
            if (password.isEmpty()) throw SetupAuthMissing("Enter the password for this server.")
            buildJsonObject {
                put("kind", "password")
                put("password", password)
            }
        }
        is SetupCredential.Key -> {
            if (key == null) throw SetupAuthMissing("That key is no longer in your vault.")
            val ref = key.sshString("secretRef").orEmpty()
            if (ref.startsWith("agent:")) {
                buildJsonObject {
                    put("kind", "agent")
                    put("fingerprint", ref.removePrefix("agent:"))
                }
            } else {
                if (pem.isNullOrEmpty()) {
                    throw SetupAuthMissing("That key has no private material on this device.")
                }
                buildJsonObject {
                    put("kind", "privateKey")
                    put("pem", pem)
                }
            }
        }
    }
}

/// Resolve the chosen credential into an auth payload, loading the private
/// half off the main thread. The suspend half of [setupAuthPayload].
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

/// Everything `ssh.session.open` and the provision calls need about a host,
/// in one place. Ported from `Bridge.sessionParams`.
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

/// A name somebody would recognise, offered rather than imposed: the
/// distro's first word, when the machine is still called "server".
fun suggestMachineName(check: JsonObject, current: String): String? {
    if (current != "server") return null
    return check.sshString("distro")?.split(" ")?.firstOrNull()
        ?.takeIf { it.isNotBlank() }?.lowercase()
}

/// The finish step's facts, read from `host.provisionStatus`.
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

/// Where a recovery action goes.
///
/// One table for the whole wizard rather than a closure per screen: the
/// answer to "the fingerprint changed" is the fingerprint screen wherever
/// somebody was standing when it happened. Every destination is reached
/// through the address, so the stack is built rather than pushed onto:
/// arriving at the credential screen with no way back to the address would
/// be a dead end of its own. Ported from `recover` in
/// `ClientSetupServerSteps.swift`.
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
