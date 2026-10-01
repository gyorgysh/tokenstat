// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.setup

import ai.tokenstat.tokenstat.ui.localization.L10n

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
                L10n.text("android.setupconnectscreens.step_0_of_1.92f19534", "${number}", "${SETUP_CONNECT_TOTAL}"),
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
                TsSecondaryButton(label = L10n.text("android.setupconnectscreens.dismiss.48845bff"), small = true, onClick = onDismiss)
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
                    L10n.text("android.setupconnectscreens.sign_in_from_the_account_screen_then_conti.45d5f944"),
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            } else if (failure.action == SetupAction.UPDATE_MACHINE) {
                Text(
                    L10n.text("android.setupconnectscreens.update_tokenstat_on_that_machine_then_cont.f6294158"),
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
        title = L10n.text("android.setupconnectscreens.which_server.f723b68c"),
        subtitle = L10n.text("android.setupconnectscreens.choose_a_saved_server_or_enter_its_address.a9fb6642"),
        number = 1,
        failure = connect.failure,
        onDismissError = { connect.failure = null },
        onRecover = onRecover,
        footer = {
            TsAccentButton(
                label = L10n.text("android.setupconnectscreens.continue.31fbef16"),
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
                label = L10n.text("android.setupconnectscreens.set_up_with_a_terminal.c6e8442d"),
                onClick = onByHand,
                modifier = Modifier.fillMaxWidth(),
            )
        },
    ) {
        if (hosts.isNotEmpty()) {
            SetupSection(L10n.text("android.setupconnectscreens.saved_servers.4bf08480")) {
                hosts.forEach { host ->
                    val selected = connect.pickedHostId == host.sshString("id") && connect.pickedHostId != null
                    Row(
                        Modifier.fillMaxWidth().clickable { picked(host) }.padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Space.s),
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(host.sshString("label") ?: L10n.text("android.setupconnectscreens.server.aef7de28"), style = TsType.body, color = colors.textPrimary)
                            Text(
                                "${host.sshString("username") ?: L10n.text("android.setupconnectscreens.root.4813494d")}@${host.sshString("hostname") ?: ""}",
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
            if (hosts.isEmpty()) L10n.text("android.setupconnectscreens.the_server.442b5366")
            else if (connect.pickedHostId == null) L10n.text("android.setupconnectscreens.or_type_one.3c8afc53") else L10n.text("android.setupconnectscreens.type_another.0993d6bc"),
        ) {
            SetupLabeledField(L10n.text("android.setupconnectscreens.address.56ef8f20"), connect.hostname, "203.0.113.10") {
                connect.editServer(ServerField.HOSTNAME, it)
            }
            SetupLabeledField(L10n.text("android.setupconnectscreens.user.b512d97e"), connect.username, "root") {
                connect.editServer(ServerField.USERNAME, it)
            }
            SetupLabeledField(L10n.text("android.setupconnectscreens.name.dcd1d522"), connect.label, L10n.text("android.setupconnectscreens.cloud_one.ab0123af")) {
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
        title = L10n.text("android.setupconnectscreens.how_to_sign_in.6730dada"),
        subtitle = L10n.text("android.setupconnectscreens.a_key_from_your_vault_or_a_password_used_o.75f6b9b8"),
        number = 2,
        failure = connect.failure,
        onDismissError = { connect.failure = null },
        onRecover = onRecover,
        footer = {
            TsAccentButton(
                label = L10n.text("android.setupconnectscreens.continue.31fbef16"),
                icon = ActionIcon.Next.vector,
                onClick = { onPush(SetupStep.FINGERPRINT) },
                modifier = Modifier.fillMaxWidth(),
                enabled = ready,
            )
        },
    ) {
        if (keys.isEmpty()) {
            Text(
                L10n.text("android.setupconnectscreens.there_are_no_keys_in_your_vault_yet_add_on.c14f0501"),
                style = TsType.subheadline,
                color = colors.textSecondary,
            )
        } else {
            SetupSection(L10n.text("android.setupconnectscreens.keys_in_your_vault.32d8b1ef")) {
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
                            key.sshString("label") ?: L10n.text("android.setupconnectscreens.key.99a52df3"),
                            style = TsType.body,
                            color = colors.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        if (selected) Icon(ActionIcon.Done.vector, null, tint = colors.accent)
                    }
                }
            }
        }
        SetupSection(if (keys.isEmpty()) L10n.text("android.setupconnectscreens.a_password_this_time_only.0283f848") else L10n.text("android.setupconnectscreens.or_a_password_this_time_only.44e1c7da")) {
            OutlinedTextField(
                value = connect.password,
                onValueChange = {
                    connect.password = it
                    if (it.isNotEmpty()) connect.credential = SetupCredential.Password
                    else if (connect.credential == SetupCredential.Password) {
                        connect.credential = SetupCredential.None
                    }
                },
                placeholder = { Text(L10n.text("android.setupconnectscreens.password.e7cf3ef4")) },
                visualTransformation = PasswordVisualTransformation(),
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                L10n.text("android.setupconnectscreens.used_for_this_connection_and_dropped_when.43398559"),
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
        title = L10n.text("android.setupconnectscreens.is_this_your_server.1d76f188"),
        subtitle = L10n.text("android.setupconnectscreens.compare_this_fingerprint_with_your_server.f06f2526"),
        number = 3,
        failure = connect.failure,
        onDismissError = { connect.failure = null },
        onRecover = onRecover,
        footer = {
            if (connect.fingerprint == null) {
                if (connect.working) {
                    TsAccentButton(
                        label = L10n.text("common.stop"),
                        onClick = { connect.cancel() },
                        modifier = Modifier.fillMaxWidth(),
                    )
                } else {
                    TsAccentButton(
                        label = L10n.text("android.setupconnectscreens.ask_the_server.5d186479"),
                        icon = ActionIcon.Connect.vector,
                        onClick = { probe() },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            } else {
                TsAccentButton(
                    label = L10n.text("android.setupconnectscreens.this_is_my_server.22acffe8"),
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
                    label = L10n.text("android.setupconnectscreens.ask_again.0d9ad5ef"),
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
        SetupSection(L10n.text("android.setupconnectscreens.fingerprint.ba7af0b7")) {
            val pin = connect.fingerprint
            if (pin != null) {
                SelectionContainer {
                    Text(pin, style = TsType.mono(13), color = colors.textPrimary)
                }
                Text(
                    L10n.text("android.setupconnectscreens.compare_it_with_what_the_server_itself_rep.0f5fff76"),
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            } else if (connect.working) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    Text(L10n.text("android.setupconnectscreens.asking_the_server.fb689559"), style = TsType.subheadline, color = colors.textPrimary)
                }
                Text(
                    L10n.text("android.setupconnectscreens.an_address_that_is_wrong_takes_about_a_min.c355da67"),
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            } else {
                Text(L10n.text("android.setupconnectscreens.nothing_asked_yet.3f88b8bf"), style = TsType.subheadline, color = colors.textSecondary)
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
        title = L10n.text("android.setupconnectscreens.what_is_on_it.047811ac"),
        subtitle = L10n.text("android.setupconnectscreens.read_before_anything_is_written_nothing_on.f53dc6d5"),
        number = 4,
        failure = connect.failure,
        onDismissError = { connect.failure = null },
        onRecover = onRecover,
        footer = {
            if (connect.working) {
                TsAccentButton(
                    label = L10n.text("common.stop"),
                    onClick = { connect.cancel() },
                    modifier = Modifier.fillMaxWidth(),
                )
            } else if (ready) {
                TsAccentButton(
                    label = L10n.text("android.setupconnectscreens.install.569ca49f"),
                    icon = ActionIcon.Download.vector,
                    onClick = { onPush(SetupStep.INSTALL) },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = connect.machineName.trim().isNotEmpty(),
                )
            } else {
                TsAccentButton(
                    label = L10n.text("android.setupconnectscreens.check_again.fb7099ad"),
                    icon = ActionIcon.Refresh.vector,
                    onClick = { inspect() },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            TsSecondaryButton(
                label = L10n.text("android.setupconnectscreens.show_me_the_command_instead.1da2f134"),
                onClick = onByHand,
                modifier = Modifier.fillMaxWidth(),
            )
        },
    ) {
        if (check != null) {
            SetupSection(L10n.text("android.setupconnectscreens.the_machine.0cccf589")) {
                SetupFact(L10n.text("android.setupconnectscreens.operating_system.0fcabfe6"), check.sshString("distro") ?: check.sshString("os") ?: "unknown")
                SetupFact(L10n.text("android.setupconnectscreens.architecture.cd74053c"), check.sshString("arch") ?: "unknown")
                SetupFact(L10n.text("android.setupconnectscreens.signs_in_as.f6adc71c"), check.sshString("user") ?: "unknown")
                SetupFact(
                    L10n.text("android.setupconnectscreens.service_manager.ddd070d4"),
                    if ((check["systemd"] as? JsonPrimitive)?.booleanOrNull == true) "systemd" else L10n.text("android.setupconnectscreens.not_systemd.050cd421"),
                )
                val freeMb = check["diskFreeMb"]?.jsonPrimitive?.longOrNull
                SetupFact(L10n.text("android.setupconnectscreens.free_space.64cd989e"), freeMb?.let { "${it / 1024} GB" } ?: "unknown")
                if ((check["installed"] as? JsonPrimitive)?.booleanOrNull == true) {
                    SetupFact(L10n.text("android.setupconnectscreens.already_installed.9616d808"), L10n.text("android.setupconnectscreens.tokenstat_is_on_this_machine.3fc55e14"))
                }
            }
            if ((check["root"] as? JsonPrimitive)?.booleanOrNull == true) {
                // A fact next to the operating system version, not a warning
                // triangle. It is the trade being made, and it is the right
                // one for a machine that exists to do this work.
                SetupSection(L10n.text("android.setupconnectscreens.who_agents_run_as.fc7c9918")) {
                    Text(L10n.text("android.setupconnectscreens.agents_on_this_machine_will_run_as_root.d624b53a"), style = TsType.body, color = colors.textPrimary)
                    Text(
                        L10n.text("android.setupconnectscreens.that_is_the_same_authority_as_the_ssh_sess.27a3539a"),
                        style = TsType.caption,
                        color = colors.textSecondary,
                    )
                }
            }
            val blockers = (check["blockers"] as? JsonArray).orEmpty()
                .mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            if (blockers.isNotEmpty()) {
                SetupSection(L10n.text("android.setupconnectscreens.in_the_way.ec946c03")) {
                    blockers.forEach { Text(it, style = TsType.subheadline, color = colors.textPrimary) }
                }
            }
            SetupSection(L10n.text("android.setupconnectscreens.what_to_call_it.55325bff")) {
                SetupLabeledField(L10n.text("android.setupconnectscreens.name.dcd1d522"), connect.machineName, L10n.text("android.setupconnectscreens.cloud_one.ab0123af")) { connect.machineName = it }
                Text(
                    L10n.text("android.setupconnectscreens.this_is_the_name_on_your_account_and_what.4a9ec588"),
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
                Text(L10n.text("android.setupconnectscreens.looking_at_the_machine.2b29e9e2"), style = TsType.subheadline, color = colors.textPrimary)
            }
        }
        if (!ready && check != null && !connect.working) {
            Banner(
                L10n.text("android.setupconnectscreens.the_machine_is_not_ready_yet_read_what_is.80c89a1b"),
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
                    L10n.text("android.setupconnectscreens.installing_on_0.db18c0f3", "${connect.machineName}"),
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
                    hostLabel = L10n.text("android.setupconnectscreens.install_on_0.07c7ed2f", "${connect.machineName}"),
                    onClose = { watching = false },
                )
            }
            Column(
                Modifier.fillMaxWidth().padding(Space.m),
                verticalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                TsAccentButton(
                    label = L10n.text("android.setupconnectscreens.it_finished_check_the_machine.0c1b9b30"),
                    icon = ActionIcon.Next.vector,
                    onClick = { onPush(SetupStep.FINISH) },
                    modifier = Modifier.fillMaxWidth(),
                )
                TsSecondaryButton(
                    label = L10n.text("android.setupconnectscreens.it_failed_show_me_the_command.df0a4f0d"),
                    onClick = onByHand,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        return
    }
    SetupStepScaffold(
        title = L10n.text("android.setupconnectscreens.install.569ca49f"),
        subtitle = L10n.text("android.setupconnectscreens.tokenstat_mints_a_one_time_pairing_code_wr.f10f332e"),
        number = 5,
        failure = connect.failure,
        onDismissError = { connect.failure = null },
        onRecover = onRecover,
        footer = {
            if (sessionId != null) {
                TsAccentButton(
                    label = L10n.text("android.setupconnectscreens.watch_the_install.5aaf2482"),
                    onClick = { watching = true },
                    modifier = Modifier.fillMaxWidth(),
                )
                TsAccentButton(
                    label = L10n.text("android.setupconnectscreens.it_finished_check_the_machine.0c1b9b30"),
                    icon = ActionIcon.Next.vector,
                    onClick = { onPush(SetupStep.FINISH) },
                    modifier = Modifier.fillMaxWidth(),
                )
            } else {
                TsAccentButton(
                    label = if (connect.working) L10n.text("android.setupconnectscreens.starting.bbe5fc3b") else L10n.text("android.setupconnectscreens.start_the_install.40fb0ff5"),
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
                label = L10n.text("android.setupconnectscreens.i_would_rather_run_it_myself.73496e0e"),
                onClick = onByHand,
                modifier = Modifier.fillMaxWidth(),
            )
        },
    ) {
        SetupSection(L10n.text("android.setupconnectscreens.what_will_happen.d5b89826")) {
            SetupBullet(L10n.text("android.setupconnectscreens.the_cli_and_the_always_on_host_are_install.5c5da81f"))
            SetupBullet(
                L10n.text("android.setupconnectscreens.the_machine_signs_in_to_your_account_with.72be3ba6"),
            )
            SetupBullet(
                L10n.text("android.setupconnectscreens.this_device_is_allowed_to_open_the_work_he.47d6f496"),
            )
            SetupBullet(L10n.text("android.setupconnectscreens.it_stays_on_and_keeps_counting_which_costs.713e3511"))
        }
        SetupSection(L10n.text("android.setupconnectscreens.agents.279b44d2")) {
            SetupAgentChoice(
                id = "claude_code",
                name = L10n.text("android.setupconnectscreens.claude_code.246ef8c1"),
                detail = L10n.text("android.setupconnectscreens.anthropic_s_coding_agent_for_your_projects.27c15f70"),
                selected = connect.agents.contains("claude_code"),
                onToggle = { connect.toggleAgent("claude_code", it) },
            )
            SetupAgentChoice(
                id = "codex",
                name = L10n.text("android.setupconnectscreens.codex.616efbe9"),
                detail = L10n.text("android.setupconnectscreens.openai_s_coding_agent_for_your_projects.8a830857"),
                selected = connect.agents.contains("codex"),
                onToggle = { connect.toggleAgent("codex", it) },
            )
            Text(
                L10n.text("android.setupconnectscreens.choose_either_both_or_neither_you_can_inst.36b5f4ed"),
                style = TsType.caption,
                color = colors.textSecondary,
            )
            Text(
                L10n.text("android.setupconnectscreens.next_setup_helps_you_sign_in_to_your_agent.34acb358"),
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
        title = if (finished == null) L10n.text("android.setupconnectscreens.waiting_for_the_machine.9a2264c1") else L10n.text("android.setupconnectscreens.it_is_up.3f950bb2"),
        subtitle = if (finished == null) {
            L10n.text("android.setupconnectscreens.the_server_signs_in_joins_the_tunnel_and_a.2831dd5b")
        } else {
            L10n.text("android.setupconnectscreens.0_is_on_your_account_and_this_device_can_r.944d14db", "${connect.machineName}")
        },
        number = 6,
        failure = connect.failure,
        onDismissError = { connect.failure = null },
        onRecover = onRecover,
        footer = {
            if (finished == null) {
                TsAccentButton(
                    label = if (connect.working) L10n.text("android.setupconnectscreens.checking.ec963ffc") else L10n.text("android.setupconnectscreens.check_again.fb7099ad"),
                    icon = ActionIcon.Refresh.vector,
                    onClick = { check() },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !connect.working && connect.canCheckMachine,
                )
            } else {
                TsAccentButton(
                    label = L10n.text("android.setupconnectscreens.continue.31fbef16"),
                    icon = ActionIcon.Next.vector,
                    onClick = { onPush(SetupStep.AGENT) },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
    ) {
        if (connect.manualInstall && finished == null) {
            SetupSection(L10n.text("android.setupconnectscreens.confirm_the_installed_machine.835e82aa")) {
                Text(
                    L10n.text("android.setupconnectscreens.paste_the_full_machine_key_printed_at_the.11894974"),
                    style = TsType.subheadline,
                    color = colors.textSecondary,
                )
                OutlinedTextField(
                    value = connect.manualMachineKey,
                    onValueChange = { connect.manualMachineKey = it },
                    placeholder = { Text(L10n.text("android.setupconnectscreens.64_character_machine_key.90b955a9")) },
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
                Text(L10n.text("android.setupconnectscreens.waiting_for_the_machine.70f5bea0"), style = TsType.subheadline, color = colors.textPrimary)
            }
        }
        finished?.let { status ->
            val info = remember(status) { SetupProvisionInfo.of(status) }
            SetupSection(L10n.text("android.setupconnectscreens.this_machine.1b8548de")) {
                SetupFact(L10n.text("android.setupconnectscreens.signed_in.ca566c89"), info.signedInHandle ?: "yes")
                SetupFact(L10n.text("android.setupconnectscreens.always_on.044ba8a9"), if (info.alwaysOn) "on" else "off")
                SetupFact(L10n.text("android.setupconnectscreens.reachable.f94b5f3d"), if (info.tunnelOnline) "yes" else "connecting")
                SetupFact(L10n.text("android.setupconnectscreens.runs_as.dc98511e"), info.runsAs)
                SetupFact(L10n.text("android.setupconnectscreens.allowed_devices.748d1f2f"), "${info.allowedDevices}")
            }
            SetupSection(L10n.text("android.setupconnectscreens.what_is_next.8cfb34ce")) {
                Text(
                    if (info.anyAgentInstalled) {
                        L10n.text("android.setupconnectscreens.the_agent_is_on_the_machine_it_still_needs.10e35681")
                    } else {
                        L10n.text("android.setupconnectscreens.no_agent_is_on_the_machine_yet_the_next_st.ab8684b7")
                    },
                    style = TsType.subheadline,
                    color = colors.textPrimary,
                )
            }
        }
    }
}
