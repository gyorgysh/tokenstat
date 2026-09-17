// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.setup

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ClientState
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.marks.HarnessMark
import ai.tokenstat.tokenstat.ui.ssh.sshString
import ai.tokenstat.tokenstat.ui.terminal.TerminalScreen
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

internal fun JsonObject.setupPeer(): String? =
    get("publicIdentity")?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() }

internal fun JsonObject.setupMachineId(): String? =
    get("id")?.jsonPrimitive?.contentOrNull

internal fun JsonObject.setupHostLabel(): String =
    get("label")?.jsonPrimitive?.contentOrNull?.ifEmpty { null }
        ?: get("displayName")?.jsonPrimitive?.contentOrNull?.ifEmpty { null }
        ?: "Host"

/// The machines setup can work with: hosts with a connection key. A record
/// from before the server knew client kinds carries no kind and would
/// otherwise list this phone as a machine to set up.
internal fun setupMachines(account: JsonObject?): List<JsonObject> =
    (account?.get("machines") as? JsonArray ?: JsonArray(emptyList()))
        .mapNotNull { it as? JsonObject }
        .filter {
            it.get("kind")?.jsonPrimitive?.contentOrNull != "client" &&
                !it.setupPeer().isNullOrEmpty()
        }

/// Step seven: the agent is on the machine, and now it needs its own
/// sign-in.
///
/// The install and finish steps both promise this screen: "the next step
/// installs one and signs it in". It reads `launcher.catalog` for each
/// agent's readiness, installs what is missing, and hands a sign-in to a
/// terminal on the machine that runs it, through `launcher.signIn`. The id
/// is all that travels; the command lives in the host's hardcoded table, so
/// this cannot become a way to run something.
@Composable
fun SetupAgentStep(
    model: AppViewModel,
    state: ClientState,
    connect: SetupConnectState,
    onPush: (SetupStep) -> Unit,
    onRecover: (SetupAction) -> Unit,
) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    val dark = isSystemInDarkTheme()
    val machines = remember(state.account) { setupMachines(state.account) }
    val peer = connect.expectedPeer ?: machines.singleOrNull()?.setupPeer()
    val hostLabel = machines.find { it.setupPeer() == peer }?.setupHostLabel()
        ?: connect.machineName.ifBlank { "the machine" }
    val protocol = remember(connect.finished) {
        connect.finished?.let { SetupProvisionInfo.of(it).protocol }
    }
    var agents by remember { mutableStateOf<List<SetupAgent>?>(null) }
    var failure by remember { mutableStateOf<SetupFailure?>(null) }
    var working by remember { mutableStateOf(false) }
    var signInSession by remember { mutableStateOf<String?>(null) }
    var installing by remember { mutableStateOf<String?>(null) }
    var installOutput by remember { mutableStateOf<String?>(null) }

    fun load() {
        val key = peer ?: return
        scope.launch {
            working = true
            failure = null
            runCatching { model.workspaceSection(key, "launcher.catalog", buildJsonObject {}) }
                .onSuccess { element ->
                    agents = (element as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.let(SetupAgent::of) }
                }
                .onFailure { failure = SetupFailure.from(it) }
            working = false
        }
    }
    LaunchedEffect(peer) {
        if (peer != null && agents == null) load()
    }

    val signing = signInSession
    if (signing != null && peer != null) {
        // The agent's own sign-in, in a terminal on the machine that runs
        // it. Closing it returns here and re-reads readiness, so a
        // completed sign-in lands as Signed in rather than as a guess.
        TerminalScreen(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            workspaceId = "",
            existingSessionId = signing,
            onClose = {
                signInSession = null
                load()
            },
        )
        return
    }

    SetupStepScaffold(
        title = "Sign in to your agent",
        subtitle = "The agent runs on the machine, so it signs in there. Installed is not ready: each agent still needs its own account.",
        number = 7,
        failure = failure,
        onDismissError = { failure = null },
        onRecover = onRecover,
        footer = {
            TsAccentButton(
                label = "Continue",
                icon = ActionIcon.Next.vector,
                onClick = { onPush(SetupStep.PROJECT) },
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                "You can also install and sign in later from the machine's page.",
                style = TsType.caption,
                color = colors.textSecondary,
            )
        },
    ) {
        if (peer == null) {
            Banner(
                "No machines on this account yet. Run the install first, then sign in to an agent.",
                BannerSeverity.WARNING,
            )
            return@SetupStepScaffold
        }
        HostContracts.updateMessage("Signing in to an agent", hostLabel, protocol, AGENT_SIGN_IN_MIN_PROTOCOL)?.let {
            Banner(it, BannerSeverity.WARNING)
        }
        val list = agents
        if (list == null) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                if (working) CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                Text(
                    if (working) "Asking the machine…" else "Nothing asked yet.",
                    style = TsType.subheadline,
                    color = colors.textSecondary,
                )
            }
            if (!working) {
                TsSecondaryButton(label = "Check again", icon = ActionIcon.Refresh.vector, onClick = { load() })
            }
            return@SetupStepScaffold
        }
        if (list.isEmpty()) {
            Text(
                "The machine offers no agents to sign in to.",
                style = TsType.subheadline,
                color = colors.textSecondary,
            )
            return@SetupStepScaffold
        }
        list.forEach { agent ->
            TsCard {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    HarnessMark(id = agent.id, size = 40.dp)
                    Column(Modifier.weight(1f)) {
                        Text(agent.name, style = TsType.body, color = colors.textPrimary)
                        Text(
                            agent.readiness.summary(),
                            style = TsType.caption,
                            color = if (agent.readiness == AgentReadiness.SIGNED_IN) colors.accent else colors.textSecondary,
                        )
                    }
                    when {
                        !agent.installed -> TsAccentButton(
                            label = if (installing == agent.id) "Installing…" else "Install",
                            small = true,
                            enabled = installing == null,
                            onClick = {
                                installing = agent.id
                                installOutput = null
                                failure = null
                                scope.launch {
                                    runCatching {
                                        model.workspaceSection(
                                            peer,
                                            "launcher.install",
                                            buildJsonObject { put("id", agent.id) },
                                        ).jsonObject
                                    }.onSuccess { answer ->
                                        installing = null
                                        val ok = (answer["ok"] as? JsonPrimitive)?.booleanOrNull == true
                                        installOutput = (answer["output"] as? JsonPrimitive)?.contentOrNull
                                            ?.takeIf { it.isNotBlank() }
                                        if (ok) load()
                                        else if (installOutput == null) {
                                            installOutput = "The installer did not say why it failed."
                                        }
                                    }.onFailure {
                                        failure = SetupFailure.from(it)
                                        installing = null
                                    }
                                }
                            },
                        )
                        agent.canSignIn(protocol) -> TsAccentButton(
                            label = "Sign in",
                            small = true,
                            onClick = {
                                failure = null
                                scope.launch {
                                    runCatching {
                                        model.workspaceSection(
                                            peer,
                                            "launcher.signIn",
                                            buildJsonObject {
                                                put("id", agent.id)
                                                put("rows", 30)
                                                put("cols", 90)
                                                put("dark", dark)
                                            },
                                        ).jsonObject
                                    }.onSuccess { info ->
                                        val id = info.sshString("id")
                                        if (id != null) signInSession = id
                                        else failure = SetupFailure("The machine did not open a sign-in terminal.", action = SetupAction.RETRY)
                                    }.onFailure { failure = SetupFailure.from(it) }
                                }
                            },
                        )
                        agent.readiness == AgentReadiness.SIGNED_IN ->
                            Icon(ActionIcon.Done.vector, "Signed in", tint = colors.accent)
                    }
                }
            }
        }
        installOutput?.let { output ->
            TsCard {
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text("Installer output", style = TsType.caption, color = colors.textSecondary)
                    SelectionContainer {
                        Text(
                            output.takeLast(2000),
                            style = TsType.mono(11),
                            color = colors.textPrimary,
                            modifier = Modifier.horizontalScroll(rememberScrollState()),
                        )
                    }
                }
            }
        }
        TsSecondaryButton(
            label = if (working) "Checking…" else "Check again",
            icon = ActionIcon.Refresh.vector,
            onClick = { load() },
            enabled = !working,
        )
    }
}
