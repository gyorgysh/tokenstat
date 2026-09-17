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
import ai.tokenstat.tokenstat.ui.marks.HarnessMark
import ai.tokenstat.tokenstat.ui.ssh.sshString
import ai.tokenstat.tokenstat.ui.terminal.SshTerminalScreen
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/// Door two: a server, over the SSH session this phone opens itself. Ported
/// from `ClientSetupServerSteps.swift`.
///
/// One screen per step. Each of them can fail on its own, each failure has
/// its own sentence, and the one place where a mistake is permanent (trusting
/// a host key) is a screen rather than a row inside another one.
///
/// Eight steps: the six server steps, then the agent sign-in and the project.
/// The Apple client numbers the project seventh; the agent step is inserted
/// before it, exactly where the install and finish copy say the agent
/// sign-in happens next.
const val SETUP_CONNECT_TOTAL = 8

/// Every step looks the same: what this is, the thing to do, and one button.
/// A container rather than six copies, so the wizard reads as one flow.
@Composable
fun SetupStepScaffold(
    title: String,
    subtitle: String,
    number: Int,
    failure: SetupFailure?,
    onDismissError: () -> Unit,
    onRecover: ((SetupAction) -> Unit)?,
    footer: @Composable () -> Unit,
    content: @Composable () -> Unit,
) {
    val colors = LocalTsColors.current
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Column(
            Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Text(
                "Step $number of $SETUP_CONNECT_TOTAL",
                style = TsType.caption.copy(fontWeight = FontWeight.SemiBold),
                color = colors.accent,
            )
            Text(
                title,
                style = TsType.title2.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
                textAlign = TextAlign.Center,
            )
            Text(
                subtitle,
                style = TsType.body,
                color = colors.textSecondary,
                textAlign = TextAlign.Center,
            )
        }
        failure?.let { SetupFailureBanner(failure = it, onDismiss = onDismissError, onRecover = onRecover) }
        content()
        footer()
    }
}

/// What failed, what it changed, and the one thing to do next. Ported from
/// `SetupFailureBanner`: the recovery action navigates, the two that happen
/// elsewhere (signing in to the account, updating the machine) say so in
/// words, and retry is the screen's own button rather than a second one.
@Composable
fun SetupFailureBanner(
    failure: SetupFailure,
    onDismiss: () -> Unit,
    onRecover: ((SetupAction) -> Unit)?,
) {
    val colors = LocalTsColors.current
    TsCard {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(Space.s),
                verticalAlignment = Alignment.Top,
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(failure.explanation, style = TsType.subheadline, color = colors.textPrimary)
                    failure.changed?.let {
                        Text(it, style = TsType.caption, color = colors.textSecondary)
                    }
                    failure.details?.let {
                        Text(it, style = TsType.mono(11), color = colors.textTertiary)
                    }
                }
                TsSecondaryButton(label = "Dismiss", small = true, onClick = onDismiss)
            }
            val step = failure.action.step()
            if (step != null && onRecover != null) {
                TsAccentButton(
                    label = failure.action.title(),
                    small = true,
                    onClick = { onRecover(failure.action) },
                )
            } else if (failure.action == SetupAction.SIGN_IN_ACCOUNT) {
                Text(
                    "Sign in from the account screen, then continue here.",
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            } else if (failure.action == SetupAction.UPDATE_MACHINE) {
                Text(
                    "Update tokenstat on that machine, then continue here.",
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun SetupSection(title: String, content: @Composable () -> Unit) {
    val colors = LocalTsColors.current
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Text(title, style = TsType.subheadline.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
        TsCard { Column(verticalArrangement = Arrangement.spacedBy(Space.s)) { content() } }
    }
}

@Composable
private fun SetupFact(label: String, value: String) {
    val colors = LocalTsColors.current
    Row(Modifier.fillMaxWidth()) {
        Text(label, style = TsType.subheadline, color = colors.textSecondary)
        Spacer(Modifier.weight(1f))
        Text(value, style = TsType.subheadline, color = colors.textPrimary)
    }
}

@Composable
private fun SetupLabeledField(title: String, value: String, placeholder: String, onChange: (String) -> Unit) {
    val colors = LocalTsColors.current
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(title, style = TsType.caption, color = colors.textSecondary)
        OutlinedTextField(
            value = value,
            onValueChange = onChange,
            placeholder = { Text(placeholder) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

// MARK: - 1. Which server

@Composable
fun SetupWhereStep(
    model: AppViewModel,
    connect: SetupConnectState,
    onPush: (SetupStep) -> Unit,
    onByHand: () -> Unit,
    onRecover: (SetupAction) -> Unit,
) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) {
        connect.resetServer()
        runCatching { connect.loadLibrary(model) }
            .onFailure { connect.failure = SetupFailure.from(it) }
    }
    val hosts = connect.libraryHosts.orEmpty()
    // Carry the saved record's own credential over, so somebody who has
    // connected to this server before does not choose a key twice.
    fun picked(host: JsonObject) {
        if (connect.pickedHostId == host.sshString("id")) {
            connect.pickedHostId = null
            connect.credential = SetupCredential.None
            return
        }
        connect.password = ""
        connect.credential = SetupCredential.None
        connect.pickedHostId = host.sshString("id")
        val ref = host.sshString("credentialId") ?: host.sshString("keyId") ?: host.sshString("identity")
        if (ref != null && connect.libraryKeys.orEmpty().any { it.sshString("id") == ref }) {
            connect.credential = SetupCredential.Key(ref)
        }
        if (connect.machineName == "server") {
            host.sshString("label")?.takeIf { it.isNotBlank() }?.let { connect.machineName = it }
        }
    }
    SetupStepScaffold(
        title = "Which server",
        subtitle = "Choose a saved server or enter its address. Connect securely over SSH with your own credentials.",
        number = 1,
        failure = connect.failure,
        onDismissError = { connect.failure = null },
        onRecover = onRecover,
        footer = {
            TsAccentButton(
                label = "Continue",
                icon = ActionIcon.Next.vector,
                onClick = {
                    if (connect.pickedHostId == null && connect.label.isBlank()) {
                        connect.label = connect.hostname.trim()
                    }
                    onPush(SetupStep.CREDENTIAL)
                },
                modifier = Modifier.fillMaxWidth(),
                enabled = connect.whereReady(),
            )
            TsSecondaryButton(
                label = "Set up with a terminal",
                onClick = onByHand,
                modifier = Modifier.fillMaxWidth(),
            )
        },
    ) {
        if (hosts.isNotEmpty()) {
            SetupSection("Saved servers") {
                hosts.forEach { host ->
                    val selected = connect.pickedHostId == host.sshString("id") && connect.pickedHostId != null
                    Row(
                        Modifier.fillMaxWidth().clickable { picked(host) }.padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Space.s),
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(host.sshString("label") ?: "Server", style = TsType.body, color = colors.textPrimary)
                            Text(
                                "${host.sshString("username") ?: "root"}@${host.sshString("hostname") ?: ""}",
                                style = TsType.caption,
                                color = colors.textSecondary,
                            )
                        }
                        if (selected) Icon(ActionIcon.Done.vector, null, tint = colors.accent)
                    }
                }
            }
        }
        SetupSection(
            if (hosts.isEmpty()) "The server"
            else if (connect.pickedHostId == null) "Or type one" else "Type another",
        ) {
            SetupLabeledField("Address", connect.hostname, "203.0.113.10") {
                connect.editServer(ServerField.HOSTNAME, it)
            }
            SetupLabeledField("User", connect.username, "root") {
                connect.editServer(ServerField.USERNAME, it)
            }
            SetupLabeledField("Name", connect.label, "cloud one") {
                connect.editServer(ServerField.LABEL, it)
            }
        }
    }
}

// MARK: - 2. How to sign in

@Composable
fun SetupCredentialStep(
    model: AppViewModel,
    connect: SetupConnectState,
    onPush: (SetupStep) -> Unit,
    onRecover: (SetupAction) -> Unit,
) {
    val colors = LocalTsColors.current
    LaunchedEffect(Unit) {
        runCatching { connect.loadLibrary(model) }
            .onFailure { connect.failure = SetupFailure.from(it) }
    }
    val keys = connect.libraryKeys.orEmpty()
    val ready = connect.credential.ready(connect.password)
    SetupStepScaffold(
        title = "How to sign in",
        subtitle = "A key from your vault, or a password used once for this connection and never written down.",
        number = 2,
        failure = connect.failure,
        onDismissError = { connect.failure = null },
        onRecover = onRecover,
        footer = {
            TsAccentButton(
                label = "Continue",
                icon = ActionIcon.Next.vector,
                onClick = { onPush(SetupStep.FINGERPRINT) },
                modifier = Modifier.fillMaxWidth(),
                enabled = ready,
            )
        },
    ) {
        if (keys.isEmpty()) {
            Text(
                "There are no keys in your vault yet. Add one on the SSH screen, or use a password this time.",
                style = TsType.subheadline,
                color = colors.textSecondary,
            )
        } else {
            SetupSection("Keys in your vault") {
                keys.forEach { key ->
                    val selected = connect.credential == SetupCredential.Key(key.sshString("id") ?: "")
                    Row(
                        Modifier.fillMaxWidth().clickable {
                            connect.credential = SetupCredential.Key(key.sshString("id") ?: "")
                            connect.password = ""
                        }.padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Space.s),
                    ) {
                        Text(
                            key.sshString("label") ?: "Key",
                            style = TsType.body,
                            color = colors.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        if (selected) Icon(ActionIcon.Done.vector, null, tint = colors.accent)
                    }
                }
            }
        }
        SetupSection(if (keys.isEmpty()) "A password, this time only" else "Or a password, this time only") {
            OutlinedTextField(
                value = connect.password,
                onValueChange = {
                    connect.password = it
                    if (it.isNotEmpty()) connect.credential = SetupCredential.Password
                    else if (connect.credential == SetupCredential.Password) {
                        connect.credential = SetupCredential.None
                    }
                },
                placeholder = { Text("Password") },
                visualTransformation = PasswordVisualTransformation(),
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                "Used for this connection and dropped when the wizard closes. It is never saved to the vault or to this device.",
                style = TsType.caption,
                color = colors.textSecondary,
            )
        }
    }
}

// MARK: - 3. The host key

@Composable
fun SetupFingerprintStep(
    model: AppViewModel,
    connect: SetupConnectState,
    onPush: (SetupStep) -> Unit,
    onRecover: (SetupAction) -> Unit,
) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    fun probe() {
        scope.launch { connect.probe(model, connect.libraryHosts.orEmpty()) }
    }
    LaunchedEffect(Unit) {
        if (connect.fingerprint == null && !connect.working) probe()
    }
    SetupStepScaffold(
        title = "Is this your server?",
        subtitle = "Compare this fingerprint with your server before continuing. It identifies the machine that will receive your credentials.",
        number = 3,
        failure = connect.failure,
        onDismissError = { connect.failure = null },
        onRecover = onRecover,
        footer = {
            if (connect.fingerprint == null) {
                if (connect.working) {
                    TsAccentButton(
                        label = "Stop",
                        onClick = { connect.cancel() },
                        modifier = Modifier.fillMaxWidth(),
                    )
                } else {
                    TsAccentButton(
                        label = "Ask the server",
                        icon = ActionIcon.Connect.vector,
                        onClick = { probe() },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            } else {
                TsAccentButton(
                    label = "This is my server",
                    icon = ActionIcon.Approve.vector,
                    onClick = {
                        scope.launch {
                            connect.trust(model, connect.libraryHosts.orEmpty())
                            if (connect.trusted) onPush(SetupStep.CHECK)
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !connect.working,
                )
                TsSecondaryButton(
                    label = "Ask again",
                    icon = ActionIcon.Refresh.vector,
                    onClick = {
                        connect.fingerprint = null
                        probe()
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
    ) {
        SetupSection("Fingerprint") {
            val pin = connect.fingerprint
            if (pin != null) {
                SelectionContainer {
                    Text(pin, style = TsType.mono(13), color = colors.textPrimary)
                }
                Text(
                    "Compare it with what the server itself reports. On the machine, `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` prints it.",
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            } else if (connect.working) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    Text("Asking the server…", style = TsType.subheadline, color = colors.textPrimary)
                }
                Text(
                    "An address that is wrong takes about a minute to give up, because nothing answers to say so.",
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            } else {
                Text("Nothing asked yet.", style = TsType.subheadline, color = colors.textSecondary)
            }
        }
    }
}

// MARK: - 4. What is on the machine

@Composable
fun SetupCheckStep(
    model: AppViewModel,
    connect: SetupConnectState,
    onPush: (SetupStep) -> Unit,
    onByHand: () -> Unit,
    onRecover: (SetupAction) -> Unit,
) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    fun inspect() {
        scope.launch {
            connect.inspect(model, context, connect.libraryHosts.orEmpty(), connect.libraryKeys.orEmpty())
        }
    }
    LaunchedEffect(Unit) {
        if (connect.check == null && !connect.working) inspect()
    }
    val check = connect.check
    val ready = (check?.get("ready") as? JsonPrimitive)?.booleanOrNull == true
    SetupStepScaffold(
        title = "What is on it",
        subtitle = "Read before anything is written. Nothing on the server changes on this screen.",
        number = 4,
        failure = connect.failure,
        onDismissError = { connect.failure = null },
        onRecover = onRecover,
        footer = {
            if (connect.working) {
                TsAccentButton(
                    label = "Stop",
                    onClick = { connect.cancel() },
                    modifier = Modifier.fillMaxWidth(),
                )
            } else if (ready) {
                TsAccentButton(
                    label = "Install",
                    icon = ActionIcon.Download.vector,
                    onClick = { onPush(SetupStep.INSTALL) },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = connect.machineName.trim().isNotEmpty(),
                )
            } else {
                TsAccentButton(
                    label = "Check again",
                    icon = ActionIcon.Refresh.vector,
                    onClick = { inspect() },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            TsSecondaryButton(
                label = "Show me the command instead",
                onClick = onByHand,
                modifier = Modifier.fillMaxWidth(),
            )
        },
    ) {
        if (check != null) {
            SetupSection("The machine") {
                SetupFact("Operating system", check.sshString("distro") ?: check.sshString("os") ?: "unknown")
                SetupFact("Architecture", check.sshString("arch") ?: "unknown")
                SetupFact("Signs in as", check.sshString("user") ?: "unknown")
                SetupFact(
                    "Service manager",
                    if ((check["systemd"] as? JsonPrimitive)?.booleanOrNull == true) "systemd" else "not systemd",
                )
                val freeMb = check["diskFreeMb"]?.jsonPrimitive?.longOrNull
                SetupFact("Free space", freeMb?.let { "${it / 1024} GB" } ?: "unknown")
                if ((check["installed"] as? JsonPrimitive)?.booleanOrNull == true) {
                    SetupFact("Already installed", "tokenstat is on this machine")
                }
            }
            if ((check["root"] as? JsonPrimitive)?.booleanOrNull == true) {
                // A fact next to the operating system version, not a warning
                // triangle. It is the trade being made, and it is the right
                // one for a machine that exists to do this work.
                SetupSection("Who agents run as") {
                    Text("Agents on this machine will run as root.", style = TsType.body, color = colors.textPrimary)
                    Text(
                        "That is the same authority as the SSH session you just opened, " +
                            "so agents can access system files as well as your projects. " +
                            "Each agent's own approval settings still apply.",
                        style = TsType.caption,
                        color = colors.textSecondary,
                    )
                }
            }
            val blockers = (check["blockers"] as? JsonArray).orEmpty()
                .mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            if (blockers.isNotEmpty()) {
                SetupSection("In the way") {
                    blockers.forEach { Text(it, style = TsType.subheadline, color = colors.textPrimary) }
                }
            }
            SetupSection("What to call it") {
                SetupLabeledField("Name", connect.machineName, "cloud one") { connect.machineName = it }
                Text(
                    "This is the name on your account, and what you tap to reach it.",
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            }
        } else if (connect.working) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                Text("Looking at the machine…", style = TsType.subheadline, color = colors.textPrimary)
            }
        }
        if (!ready && check != null && !connect.working) {
            Banner(
                "The machine is not ready yet. Read what is in the way above, fix it on the server, then check again.",
                BannerSeverity.WARNING,
            )
        }
    }
}

// MARK: - 5. Install

@Composable
fun SetupInstallStep(
    model: AppViewModel,
    state: ClientState,
    connect: SetupConnectState,
    onPush: (SetupStep) -> Unit,
    onByHand: () -> Unit,
    onRecover: (SetupAction) -> Unit,
) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val sessionId = connect.installSessionId
    var watching by remember(sessionId) { mutableStateOf(sessionId != null) }
    if (sessionId != null && watching) {
        // A real terminal, not a spinner. People trust an installer they can
        // watch, and every support conversation about a failed install starts
        // with this text.
        Column(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = Space.m, vertical = Space.s),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                Text(
                    "Installing on ${connect.machineName}",
                    style = TsType.subheadline,
                    color = colors.textSecondary,
                    modifier = Modifier.weight(1f),
                )
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
            }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                SshTerminalScreen(
                    model = model,
                    sessionId = sessionId,
                    hostLabel = "Install on ${connect.machineName}",
                    onClose = { watching = false },
                )
            }
            Column(
                Modifier.fillMaxWidth().padding(Space.m),
                verticalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                TsAccentButton(
                    label = "It finished, check the machine",
                    icon = ActionIcon.Next.vector,
                    onClick = { onPush(SetupStep.FINISH) },
                    modifier = Modifier.fillMaxWidth(),
                )
                TsSecondaryButton(
                    label = "It failed, show me the command",
                    onClick = onByHand,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        return
    }
    SetupStepScaffold(
        title = "Install",
        subtitle = "tokenstat mints a one-time pairing code, writes it to a private file on the server, and runs the installer. You watch the whole thing.",
        number = 5,
        failure = connect.failure,
        onDismissError = { connect.failure = null },
        onRecover = onRecover,
        footer = {
            if (sessionId != null) {
                TsAccentButton(
                    label = "Watch the install",
                    onClick = { watching = true },
                    modifier = Modifier.fillMaxWidth(),
                )
                TsAccentButton(
                    label = "It finished, check the machine",
                    icon = ActionIcon.Next.vector,
                    onClick = { onPush(SetupStep.FINISH) },
                    modifier = Modifier.fillMaxWidth(),
                )
            } else {
                TsAccentButton(
                    label = if (connect.working) "Starting…" else "Start the install",
                    icon = ActionIcon.Download.vector,
                    onClick = {
                        scope.launch {
                            val labels = (state.account?.get("machines") as? JsonArray).orEmpty()
                                .mapNotNull { (it as? JsonObject)?.sshString("label") }.toSet()
                            connect.install(
                                model,
                                connect.libraryHosts.orEmpty(),
                                connect.libraryKeys.orEmpty(),
                                context,
                                labels,
                            )
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !connect.working,
                )
            }
            TsSecondaryButton(
                label = "I would rather run it myself",
                onClick = onByHand,
                modifier = Modifier.fillMaxWidth(),
            )
        },
    ) {
        SetupSection("What will happen") {
            SetupBullet("The CLI and the always-on host are installed.")
            SetupBullet(
                "The machine signs in to your account with a code that expires in fifteen minutes and works once.",
            )
            SetupBullet(
                "This device is allowed to open the work here, granted over this SSH session rather than through our servers.",
            )
            SetupBullet("It stays on and keeps counting, which costs whatever the server costs.")
        }
        SetupSection("Agents") {
            SetupAgentChoice(
                id = "claude_code",
                name = "Claude Code",
                detail = "Anthropic's coding agent for your projects.",
                selected = connect.agents.contains("claude_code"),
                onToggle = { connect.toggleAgent("claude_code", it) },
            )
            SetupAgentChoice(
                id = "codex",
                name = "Codex",
                detail = "OpenAI's coding agent for your projects.",
                selected = connect.agents.contains("codex"),
                onToggle = { connect.toggleAgent("codex", it) },
            )
            Text(
                "Choose either, both, or neither. You can install more later.",
                style = TsType.caption,
                color = colors.textSecondary,
            )
            Text(
                "Next, setup helps you sign in to your agent and choose a project. You can also do either later from the machine's page.",
                style = TsType.caption,
                color = colors.textSecondary,
            )
        }
    }
}

private fun SetupConnectState.toggleAgent(id: String, selected: Boolean) {
    agents = if (selected) {
        if (agents.contains(id)) agents else agents + id
    } else {
        agents.filterNot { it == id }
    }
}

@Composable
private fun SetupBullet(text: String) {
    val colors = LocalTsColors.current
    Row(
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Text("•", style = TsType.subheadline, color = colors.accent)
        Text(text, style = TsType.subheadline, color = colors.textPrimary)
    }
}

@Composable
private fun SetupAgentChoice(id: String, name: String, detail: String, selected: Boolean, onToggle: (Boolean) -> Unit) {
    val colors = LocalTsColors.current
    Row(
        Modifier.fillMaxWidth().clickable { onToggle(!selected) }.padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        HarnessMark(id = id, size = 40.dp)
        Column(Modifier.weight(1f)) {
            Text(name, style = TsType.body, color = colors.textPrimary)
            Text(detail, style = TsType.caption, color = colors.textSecondary)
        }
        Checkbox(
            checked = selected,
            onCheckedChange = onToggle,
            colors = CheckboxDefaults.colors(
                checkedColor = colors.accent,
                uncheckedColor = colors.textTertiary,
                checkmarkColor = androidx.compose.ui.graphics.Color.White,
            ),
        )
    }
}

// MARK: - 6. Finish

@Composable
fun SetupFinishStep(
    model: AppViewModel,
    connect: SetupConnectState,
    onPush: (SetupStep) -> Unit,
    onRecover: (SetupAction) -> Unit,
) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val finished = connect.finished
    fun check() {
        scope.launch {
            connect.waitForMachine(model, connect.libraryHosts.orEmpty(), connect.libraryKeys.orEmpty(), context)
        }
    }
    LaunchedEffect(Unit) {
        if (finished == null && !connect.working && connect.canCheckMachine) check()
    }
    SetupStepScaffold(
        title = if (finished == null) "Waiting for the machine" else "It is up",
        subtitle = if (finished == null) {
            "The server signs in, joins the tunnel and answers. This takes a few seconds."
        } else {
            "${connect.machineName} is on your account and this device can reach it."
        },
        number = 6,
        failure = connect.failure,
        onDismissError = { connect.failure = null },
        onRecover = onRecover,
        footer = {
            if (finished == null) {
                TsAccentButton(
                    label = if (connect.working) "Checking…" else "Check again",
                    icon = ActionIcon.Refresh.vector,
                    onClick = { check() },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !connect.working && connect.canCheckMachine,
                )
            } else {
                TsAccentButton(
                    label = "Continue",
                    icon = ActionIcon.Next.vector,
                    onClick = { onPush(SetupStep.AGENT) },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
    ) {
        if (connect.manualInstall && finished == null) {
            SetupSection("Confirm the installed machine") {
                Text(
                    "Paste the full machine key printed at the end of the installer, or run tokenstat host identity on the server. This selects the exact machine, even when two servers have the same name.",
                    style = TsType.subheadline,
                    color = colors.textSecondary,
                )
                OutlinedTextField(
                    value = connect.manualMachineKey,
                    onValueChange = { connect.manualMachineKey = it },
                    placeholder = { Text("64-character machine key") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !connect.working && connect.expectedPeer == null,
                )
            }
        }
        if (connect.working && finished == null) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                Text("Waiting for the machine…", style = TsType.subheadline, color = colors.textPrimary)
            }
        }
        finished?.let { status ->
            val info = remember(status) { SetupProvisionInfo.of(status) }
            SetupSection("This machine") {
                SetupFact("Signed in", info.signedInHandle ?: "yes")
                SetupFact("Always on", if (info.alwaysOn) "on" else "off")
                SetupFact("Reachable", if (info.tunnelOnline) "yes" else "connecting")
                SetupFact("Runs as", info.runsAs)
                SetupFact("Allowed devices", "${info.allowedDevices}")
            }
            SetupSection("What is next") {
                Text(
                    if (info.anyAgentInstalled) {
                        "The agent is on the machine. It still needs its own sign-in, which is the next step."
                    } else {
                        "No agent is on the machine yet. The next step installs one and signs it in."
                    },
                    style = TsType.subheadline,
                    color = colors.textPrimary,
                )
            }
        }
    }
}
