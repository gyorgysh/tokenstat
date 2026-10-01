// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.setup

import ai.tokenstat.tokenstat.ui.localization.L10n

import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import ai.tokenstat.tokenstat.ui.components.ForegroundEffect
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/// How somebody gets a machine, asked once and answerable forever after.
///
/// Ported from `ClientSetupWizard.swift`. Not a modal that traps anybody:
/// every step can be left, and leaving lands on the numbers. Skip sits below
/// the three doors as a quiet button rather than a fourth card, so it never
/// reads as a fourth way to set up.
///
/// The server door walks the six provisioning steps (`SetupServerSteps`,
/// ported from `ClientSetupServerSteps`): which server, how to sign in, the
/// host key, the check, the install, and the wait. The draft resume card is
/// absent: setup left half-finished restarts from the address, and every
/// remote step re-asks the server rather than assuming.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SetupWizard(
    model: AppViewModel,
    state: ai.tokenstat.tokenstat.ClientState,
    onClose: () -> Unit,
    onOpenSsh: () -> Unit,
    onOpenWork: (hostId: String, folderId: String) -> Unit,
) {
    var path by remember { mutableStateOf(listOf<SetupStep>()) }
    val connect = remember { SetupConnectState() }
    BackHandler {
        if (path.isEmpty()) onClose() else path = path.dropLast(1)
    }
    val colors = LocalTsColors.current
    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text(L10n.text("android.setupwizard.set_up_a_machine.43e10e13")) },
                navigationIcon = {
                    TsSecondaryButton(label = L10n.text("common.close"), small = true, onClick = {
                        if (path.isEmpty()) onClose() else path = path.dropLast(1)
                    })
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
    ) { padding ->
        androidx.compose.foundation.layout.Box(Modifier.padding(padding)) {
            SetupStepBody(
                path.lastOrNull(),
                model,
                state,
                connect,
                onClose,
                onOpenSsh,
                onOpenWork,
                onDoor = { path = listOf(it) },
                onPush = { path = path + it },
                onPath = { path = it },
            )
        }
    }
}

@Composable
private fun SetupStepBody(
    step: SetupStep?,
    model: AppViewModel,
    state: ai.tokenstat.tokenstat.ClientState,
    connect: SetupConnectState,
    onClose: () -> Unit,
    onOpenSsh: () -> Unit,
    onOpenWork: (hostId: String, folderId: String) -> Unit,
    onDoor: (SetupStep) -> Unit,
    onPush: (SetupStep) -> Unit,
    onPath: (List<SetupStep>) -> Unit,
) {
    // A changed key is re-established from scratch: it has to be looked at,
    // not carried forward from a record that no longer fits the server.
    val onRecover: (SetupAction) -> Unit = { action ->
        if (action == SetupAction.REVIEW_FINGERPRINT) connect.resetServer()
        connect.failure = null
        recoverSetupPath(action)?.let { onPath(it) }
    }
    val onByHand: () -> Unit = { onPush(SetupStep.BY_HAND) }
        when (step) {
            null -> SetupDoors(state = state, onDoor = onDoor, onClose = onClose)
            SetupStep.MAC -> SetupMacDoor(model = model, state = state)
            SetupStep.CLOUD -> SetupCloudDoor(
                model = model,
                onPickServer = { onDoor(SetupStep.SERVER) },
                onNeedServer = { onPush(SetupStep.NEED_SERVER) },
            )
            SetupStep.NEED_SERVER -> SetupServerGuide(onHaveServer = { onDoor(SetupStep.SERVER) })
            SetupStep.SERVER -> SetupServerDoor(
                onConnect = { onDoor(SetupStep.WHERE) },
                onByHand = { onPush(SetupStep.BY_HAND) },
            )
            SetupStep.WHERE -> SetupWhereStep(
                model = model,
                connect = connect,
                onPush = onPush,
                onByHand = onByHand,
                onRecover = onRecover,
            )
            SetupStep.CREDENTIAL -> SetupCredentialStep(
                model = model,
                connect = connect,
                onPush = onPush,
                onRecover = onRecover,
            )
            SetupStep.FINGERPRINT -> SetupFingerprintStep(
                model = model,
                connect = connect,
                onPush = onPush,
                onRecover = onRecover,
            )
            SetupStep.CHECK -> SetupCheckStep(
                model = model,
                connect = connect,
                onPush = onPush,
                onByHand = onByHand,
                onRecover = onRecover,
            )
            SetupStep.INSTALL -> SetupInstallStep(
                model = model,
                state = state,
                connect = connect,
                onPush = onPush,
                onByHand = onByHand,
                onRecover = onRecover,
            )
            SetupStep.FINISH -> SetupFinishStep(
                model = model,
                connect = connect,
                onPush = onPush,
                onRecover = onRecover,
            )
            SetupStep.AGENT -> SetupAgentStep(
                model = model,
                state = state,
                connect = connect,
                onPush = onPush,
                onRecover = onRecover,
            )
            SetupStep.BY_HAND -> SetupByHand(
                model = model,
                onRanIt = {
                    connect.startManualInstall()
                    onPush(SetupStep.FINISH)
                },
            )
            SetupStep.PROJECT -> SetupProjectStep(
                model = model,
                state = state,
                onOpenWork = { hostId, folderId ->
                    onOpenWork(hostId, folderId)
                    onClose()
                },
                onNotNow = onClose,
            )
        }
}

private const val SETUP_DOWNLOAD_URL = "https://tokenstat.ai/download"

/// For somebody who does not have a server yet. Ported from
/// `ClientSetupServerGuide.swift`: what it has to be, who takes the money,
/// and where to go and get one. tokenstat does not create servers and does
/// not bill for them.
@Composable
private fun SetupServerGuide(onHaveServer: () -> Unit) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Text(
            L10n.text("android.setupwizard.renting_a_server.f1a1e2a6"),
            style = TsType.title2.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            L10n.text("android.setupwizard.this_device_is_where_you_work_the_machine.2bf93b68"),
            style = TsType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        GuideSection(L10n.text("android.setupwizard.what_it_has_to_be.db0d043b")) {
            GuideRequirement(
                L10n.text("android.setupwizard.linux_with_systemd.02486325"),
                L10n.text("android.setupwizard.setup_uses_systemd_to_keep_the_helper_runn.08263b69"),
            )
            GuideRequirement(
                L10n.text("android.setupwizard.64_bit_intel_or_amd.6b85ad70"),
                L10n.text("android.setupwizard.the_standard_server_image_at_any_provider.0a8d231e"),
            )
            GuideRequirement(
                L10n.text("android.setupwizard.ssh_access.4755492e"),
                L10n.text("android.setupwizard.a_login_setup_can_use_a_password_or_an_ssh.0805316c"),
            )
        }
        GuideSection(L10n.text("android.setupwizard.what_size_is_enough.3ea0c00a")) {
            Text(
                L10n.text("android.setupwizard.the_coding_agent_your_project_and_any_loca.ea37ed75"),
                style = TsType.subheadline,
                color = colors.textSecondary,
            )
            GuideBullet(L10n.text("android.setupwizard.check_the_agent_s_system_requirements_and.9af69248"))
            GuideBullet(L10n.text("android.setupwizard.grow_when_the_projects_do_disk_and_memory.29b9c033"))
        }
        GuideSection(L10n.text("android.setupwizard.who_takes_the_money.7df75402")) {
            Text(L10n.text("android.setupwizard.three_separate_things_and_only_one_of_them.08df69a7"), style = TsType.subheadline)
            GuideBullet(L10n.text("android.setupwizard.the_provider_bills_you_for_the_server_mont.429cf30a"))
            GuideBullet(L10n.text("android.setupwizard.the_coding_agent_is_billed_by_whoever_make.efc06607"))
            GuideBullet(L10n.text("android.setupwizard.tokenstat_charges_for_its_own_plan_nothing.6a1be7f0"))
        }
        GuideSection(L10n.text("android.setupwizard.where_to_get_one.dead684a")) {
            Text(
                L10n.text("android.setupwizard.choose_a_provider_with_a_server_that_meets.67e8b16b"),
                style = TsType.subheadline,
                color = colors.textSecondary,
            )
            TsSecondaryButton(
                label = L10n.text("android.setupwizard.digitalocean.8db02fc9"),
                icon = ActionIcon.External.vector,
                onClick = {
                    runCatching {
                        CustomTabsIntent.Builder().build().launchUrl(
                            context,
                            "https://m.do.co/c/638545628ff0".toUri(),
                        )
                    }
                },
            )
            Text(
                L10n.text("android.setupwizard.the_digitalocean_link_is_a_referral_link_s.b3c5c9a2"),
                style = TsType.caption,
                color = colors.textSecondary,
            )
        }
        Text(
            L10n.text("android.setupwizard.come_back_here_when_the_server_exists_and.d77e7d9e"),
            style = TsType.caption,
            color = colors.textSecondary,
        )
        TsAccentButton(
            label = L10n.text("android.setupwizard.i_have_a_server_now.7af0bb61"),
            icon = ActionIcon.Next.vector,
            onClick = onHaveServer,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun GuideSection(title: String, content: @Composable () -> Unit) {
    val colors = LocalTsColors.current
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Text(title, style = TsType.subheadline.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
        TsCard { Column(verticalArrangement = Arrangement.spacedBy(Space.s)) { content() } }
    }
}

@Composable
private fun GuideRequirement(title: String, detail: String) {
    val colors = LocalTsColors.current
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Icon(ActionIcon.Approve.vector, null, tint = colors.accent)
            Text(title, style = TsType.body, color = colors.accent)
        }
        Text(detail, style = TsType.caption, color = colors.textSecondary)
    }
}

@Composable
private fun GuideBullet(text: String) {
    val colors = LocalTsColors.current
    Row(
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Text("•", style = TsType.subheadline, color = colors.accent)
        Text(text, style = TsType.subheadline, color = colors.textPrimary)
    }
}

/// Door two: a server somebody already has.
///
/// Two routes: the provisioning steps, which ask which server and how to
/// sign in before anything is written, or the install line run by hand for
/// a server where handing over a key is not on.
@Composable
private fun SetupServerDoor(onConnect: () -> Unit, onByHand: () -> Unit) {
    val colors = LocalTsColors.current
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Text(
            L10n.text("android.setupwizard.a_server_you_have.25b36aee"),
            style = TsType.title2.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            L10n.text("android.setupwizard.connect_over_ssh_and_set_it_up_or_run_one.1455e3e0"),
            style = TsType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        SetupDoorCard(
            title = L10n.text("android.setupwizard.connect_over_ssh.3de5dfcd"),
            body = L10n.text("android.setupwizard.choose_a_server_and_how_to_sign_in_setup_v.b0864943"),
            requirement = null,
            icon = { Icon(ActionIcon.Source.vector, null, tint = colors.accent, modifier = Modifier.size(25.dp)) },
            onClick = onConnect,
        )
        SetupDoorCard(
            title = L10n.text("android.setupwizard.run_it_yourself.b3ab2275"),
            body = L10n.text("android.setupwizard.paste_one_command_into_a_terminal_on_the_s.e0f350fd"),
            requirement = null,
            icon = { Icon(ActionIcon.Copy.vector, null, tint = colors.accent, modifier = Modifier.size(25.dp)) },
            onClick = onByHand,
        )
    }
}

/// The same install, run by the person instead of by the app. Ported from
/// `ClientSetupByHand.swift`.
///
/// The pairing code is on screen here, and that is acceptable only because
/// it is single use and short lived.
@Composable
private fun SetupByHand(model: AppViewModel, onRanIt: () -> Unit) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf<String?>(null) }
    var expiresMinutes by remember { mutableStateOf(0L) }
    var line by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var copied by remember { mutableStateOf(false) }

    fun prepare() {
        if (line != null || working) return
        scope.launch {
            working = true
            error = null
            runCatching {
                // This device's public key, granted at install time. Absent
                // on a fresh install, and the line works without it.
                val allow = runCatching {
                    model.core("machine.identity").jsonObject["key"]?.jsonPrimitive?.contentOrNull
                }.getOrNull()
                val minted = model.core("account.pairingCode").jsonObject
                val text = minted["code"]?.jsonPrimitive?.contentOrNull.orEmpty()
                if (text.isEmpty()) throw CoreClientFailure(L10n.text("android.setupwizard.the_account_did_not_return_a_pairing_code.1776d60f"))
                val minutes = (minted["expiresIn"]?.jsonPrimitive?.longOrNull ?: 900) / 60
                val install = model.core("ssh.provision.line", buildJsonObject {
                    if (allow != null) put("allow", allow)
                    put("printInvite", false)
                    put("codeFile", false)
                    put("code", text)
                }).jsonObject
                Triple(text, minutes, install["annotated"]?.jsonPrimitive?.contentOrNull.orEmpty())
            }.onSuccess { (text, minutes, annotated) ->
                code = text
                expiresMinutes = minutes
                line = annotated
            }.onFailure { error = SetupFailure.readable(it) }
            working = false
        }
    }
    LaunchedEffect(Unit) { prepare() }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Text(
            L10n.text("android.setupwizard.run_it_yourself.b3ab2275"),
            style = TsType.title2.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            L10n.text("android.setupwizard.paste_this_into_a_terminal_on_the_server_t.f90ccb47"),
            style = TsType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        if (error != null) Banner(error!!, BannerSeverity.DANGER)
        if (code != null) {
            TsCard {
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text(L10n.text("android.setupwizard.your_pairing_code.4385c97f"), style = TsType.subheadline.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
                    SelectionContainer {
                        Text(code!!, style = TsType.mono(22, FontWeight.SemiBold), color = colors.textPrimary)
                    }
                    Text(
                        L10n.text("android.setupwizard.good_for_0_minutes_and_for_one_machine_it.ee887227", "${expiresMinutes}"),
                        style = TsType.caption,
                        color = colors.textSecondary,
                    )
                }
            }
        }
        if (line != null) {
            TsCard {
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text(L10n.text("android.setupwizard.on_the_server.3f5514e0"), style = TsType.subheadline.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
                    SelectionContainer {
                        Text(
                            line!!,
                            style = TsType.mono(13),
                            color = colors.textPrimary,
                            modifier = Modifier.horizontalScroll(rememberScrollState()),
                        )
                    }
                }
            }
        } else if (working) {
            Text(L10n.text("android.setupwizard.preparing_the_command.dc40c381"), style = TsType.subheadline, color = colors.textSecondary)
        }
        Text(
            L10n.text("android.setupwizard.the_machine_signs_itself_in_with_that_code.63c89f28"),
            style = TsType.caption,
            color = colors.textSecondary,
        )
        TsAccentButton(
            label = if (copied) L10n.text("android.setupwizard.copied.8d525e5f") else L10n.text("android.setupwizard.copy_the_command.5a677843"),
            icon = if (copied) ActionIcon.Done.vector else ActionIcon.Copy.vector,
            onClick = {
                val text = line ?: return@TsAccentButton
                val manager = context.getSystemService(android.content.ClipboardManager::class.java) ?: return@TsAccentButton
                manager.setPrimaryClip(android.content.ClipData.newPlainText("tokenstat", text))
                copied = true
            },
            modifier = Modifier.fillMaxWidth(),
            enabled = line != null && !working,
        )
        TsSecondaryButton(
            label = L10n.text("android.setupwizard.generate_a_new_code.01dcaf62"),
            icon = ActionIcon.Refresh.vector,
            onClick = {
                line = null
                code = null
                copied = false
                prepare()
            },
            modifier = Modifier.fillMaxWidth(),
            enabled = !working,
        )
        TsSecondaryButton(
            label = L10n.text("android.setupwizard.i_ran_it_check_my_account.db748611"),
            icon = ActionIcon.Next.vector,
            onClick = onRanIt,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

private class CoreClientFailure(message: String) : Exception(message)

/// Step eight: the project, which is the point of all of it. Ported from
/// `ClientSetupProjectStep.swift`.
///
/// Setup used to end on a machine and an empty folder list. This ends inside
/// a project. Cloning and picking a folder are the same two screens the
/// workspace list offers, reached from here so that nobody has to find them
/// afterwards.
///
/// Gap: the Apple client opens the folder with a first tour task already
/// typed and not sent. This client has no composer prefill, so the folder
/// opens with an empty message box.
@Composable
private fun SetupProjectStep(
    model: AppViewModel,
    state: ai.tokenstat.tokenstat.ClientState,
    onOpenWork: (hostId: String, folderId: String) -> Unit,
    onNotNow: () -> Unit,
) {
    val colors = LocalTsColors.current
    val machines = remember(state.account) { setupMachines(state.account) }
    var peer by remember { mutableStateOf(machines.singleOrNull()?.setupPeer()) }
    var route by remember { mutableStateOf<ProjectRoute?>(null) }
    BackHandler(enabled = route != null) { route = null }
    val hostLabel = machines.find { it.setupPeer() == peer }?.setupHostLabel() ?: L10n.text("android.setupwizard.the_machine.0bb5c22e")
    val hostId = machines.find { it.setupPeer() == peer }?.setupMachineId()
    when (route) {
        ProjectRoute.CLONE -> if (peer != null) {
            ai.tokenstat.tokenstat.ui.workspace.CloneRepositoryScreen(
                model = model,
                peer = peer!!,
                hostLabel = hostLabel,
                onClose = { route = null },
                onCloned = { id ->
                    if (hostId != null) onOpenWork(hostId, id)
                },
            )
            return
        }
        ProjectRoute.EXISTING -> if (peer != null) {
            ai.tokenstat.tokenstat.ui.workspace.RegisterFolderScreen(
                model = model,
                peer = peer!!,
                hostName = hostLabel,
                onClose = { route = null },
                onRegistered = { id ->
                    if (hostId != null) onOpenWork(hostId, id)
                },
            )
            return
        }
        null -> Unit
    }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Text(
            L10n.text("android.setupwizard.choose_a_project.8ba607b1"),
            style = TsType.title2.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
        )
        Text(
            L10n.text("android.setupwizard.the_agent_works_inside_one_folder_at_a_tim.ff4e99e5"),
            style = TsType.body,
            color = colors.textSecondary,
        )
        if (machines.isEmpty()) {
            Banner(
                L10n.text("android.setupwizard.no_machines_on_this_account_yet_run_the_in.7f8619a1"),
                BannerSeverity.WARNING,
            )
        }
        if (machines.size > 1) {
            TsCard {
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text(L10n.text("android.setupwizard.machine.8f1cc42d"), style = TsType.caption, color = colors.textSecondary)
                    machines.forEach { machine ->
                        Row(
                            Modifier.fillMaxWidth().clickable { peer = machine.setupPeer() }.padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(Space.s),
                        ) {
                            Text(
                                machine.setupHostLabel(),
                                style = TsType.body,
                                color = if (machine.setupPeer() == peer) colors.accent else colors.textPrimary,
                                modifier = Modifier.weight(1f),
                            )
                            if (machine.setupPeer() == peer) Icon(ActionIcon.Done.vector, null, tint = colors.accent)
                        }
                    }
                }
            }
        }
        SetupDoorCard(
            title = L10n.text("android.setupwizard.clone_a_repository.749e5d4d"),
            body = L10n.text("android.setupwizard.tokenstat_runs_git_on_the_machine_and_regi.1c501f13"),
            requirement = null,
            icon = { Icon(ActionIcon.Download.vector, null, tint = colors.accent, modifier = Modifier.size(25.dp)) },
            onClick = { route = ProjectRoute.CLONE },
        )
        SetupDoorCard(
            title = L10n.text("android.setupwizard.a_folder_already_on_the_machine.d5432a67"),
            body = L10n.text("android.setupwizard.browse_the_machine_s_disk_and_register_a_f.e316c912"),
            requirement = null,
            icon = { Icon(ActionIcon.Source.vector, null, tint = colors.accent, modifier = Modifier.size(25.dp)) },
            onClick = { route = ProjectRoute.EXISTING },
        )
        Text(
            L10n.text("android.setupwizard.whichever_you_choose_the_machine_opens_wit.cc343316"),
            style = TsType.caption,
            color = colors.textSecondary,
        )
        TsSecondaryButton(label = L10n.text("android.setupwizard.not_now.a0e63d7c"), onClick = onNotNow, modifier = Modifier.fillMaxWidth())
    }
}

private enum class ProjectRoute { CLONE, EXISTING }


@Composable
private fun SetupDoors(
    state: ai.tokenstat.tokenstat.ClientState,
    onDoor: (SetupStep) -> Unit,
    onClose: () -> Unit,
) {
    val colors = LocalTsColors.current
    val tier = state.account?.get("tier")?.jsonPrimitive?.contentOrNull?.lowercase()
    val canRemote = state.account?.get("canRemote")?.jsonPrimitive?.booleanOrNull
    val paywalled = if (canRemote != null) !canRemote else tier != "patron" && tier != "legend"
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Text(
            L10n.text("android.setupwizard.how_do_you_want_to_work.f00e4112"),
            style = TsType.title2.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            L10n.text("android.setupwizard.tokenstat_runs_agents_on_a_machine_that_st.ba177299"),
            style = TsType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        // The computer first: no token, no rental, nothing to buy. The doors
        // below it both assume a server.
        SetupDoorCard(
            title = L10n.text("android.setupwizard.on_my_mac.8282732a"),
            body = L10n.text("android.setupwizard.install_the_desktop_app_on_the_computer_yo.adea6dec"),
            requirement = null,
            icon = { Icon(Icons.Default.Laptop, null, tint = colors.accent, modifier = Modifier.size(25.dp)) },
            onClick = { onDoor(SetupStep.MAC) },
        )
        SetupDoorCard(
            title = L10n.text("android.setupwizard.on_a_server_i_have.70b31f4d"),
            body = L10n.text("android.setupwizard.connect_over_ssh_and_set_it_up_tokenstat_i.8fa4f9e0"),
            requirement = if (paywalled) L10n.text("android.setupwizard.reaching_it_needs_patron.c628ad97") else null,
            icon = { Icon(Icons.Default.Dns, null, tint = colors.accent, modifier = Modifier.size(25.dp)) },
            onClick = { onDoor(SetupStep.SERVER) },
        )
        SetupDoorCard(
            title = L10n.text("android.setupwizard.on_a_cloud_machine.304af746"),
            body = L10n.text("android.setupwizard.a_vps_or_a_dedicated_server_import_the_one.0e3b5c2d"),
            requirement = if (paywalled) L10n.text("android.setupwizard.reaching_it_needs_patron.c628ad97") else null,
            icon = { Icon(Icons.Default.Cloud, null, tint = colors.accent, modifier = Modifier.size(25.dp)) },
            onClick = { onDoor(SetupStep.CLOUD) },
        )
        // Leaving, without pretending it is a setup choice. A fourth card
        // wore the same surface as the three doors and read as a fourth way
        // to set up. A quiet bordered button says what it is.
        TsSecondaryButton(
            label = L10n.text("android.setupwizard.skip_for_now.b58eb52c"),
            onClick = onClose,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            L10n.text("android.setupwizard.go_to_your_account_and_your_numbers_usage.fb973c15"),
            style = TsType.caption,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            L10n.text("android.setupwizard.nothing_here_is_permanent_every_door_can_b.7027fa6d"),
            style = TsType.caption,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun SetupDoorCard(
    title: String,
    body: String,
    requirement: String?,
    icon: @Composable () -> Unit,
    onClick: () -> Unit,
) {
    val colors = LocalTsColors.current
    TsCard(Modifier.clickable(onClick = onClick)) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(Space.m)) {
            icon()
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, style = TsType.headline, color = colors.textPrimary)
                Text(body, style = TsType.subheadline, color = colors.textSecondary)
                if (requirement != null) {
                    Text(
                        requirement,
                        style = TsType.caption.copy(fontWeight = FontWeight.Medium),
                        color = colors.accent,
                    )
                }
            }
            Icon(ActionIcon.Disclosure.vector, null, tint = colors.textTertiary)
        }
    }
}

/// Door one: the computer somebody already works on.
///
/// The phone cannot do any of the three steps, so this screen's job is to be
/// checkable rather than instructive. It watches the account, and each step
/// ticks itself off as it happens.
@Composable
private fun SetupMacDoor(model: AppViewModel, state: ai.tokenstat.tokenstat.ClientState) {
    val context = LocalContext.current
    val colors = LocalTsColors.current
    val machines = state.account?.get("machines") as? JsonArray ?: JsonArray(emptyList())
    var arrived by remember(machines) {
        mutableStateOf(
            machines.map { it.jsonObject }.firstOrNull { machine ->
                val platform = machine.get("platform")?.jsonPrimitive?.contentOrNull?.lowercase().orEmpty()
                machine.get("kind")?.jsonPrimitive?.contentOrNull != "client" &&
                    (platform.contains("macos") || platform.contains("darwin"))
            },
        )
    }
    var sharing by remember { mutableStateOf(false) }
    if (sharing) {
        LaunchedEffect(Unit) {
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, SETUP_DOWNLOAD_URL)
            }
            context.startActivity(Intent.createChooser(send, L10n.text("android.setupwizard.send_it_to_my_computer.3260803b")))
            sharing = false
        }
    }
    // Nothing is written and nothing is installed: this is a screen
    // watching, which is the only thing a phone can honestly do here.
    ForegroundEffect(model) {
        val deadline = System.currentTimeMillis() + 600_000
        while (arrived == null && System.currentTimeMillis() < deadline) {
            model.refresh().join()
            delay(5_000)
        }
    }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Text(
            L10n.text("android.setupwizard.your_computer.49361195"),
            style = TsType.title2.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            L10n.text("android.setupwizard.three_things_all_of_them_on_the_computer_t.63c1a537"),
            style = TsType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        SetupNumberedStep(
            number = 1,
            title = L10n.text("android.setupwizard.install_tokenstat_on_the_computer.8d9833fb"),
            body = L10n.text("android.setupwizard.send_the_download_link_to_the_computer_sha.8aa03041"),
            done = arrived != null,
            actionTitle = if (arrived == null) L10n.text("android.setupwizard.send_it_to_my_computer.3260803b") else null,
            onAction = { sharing = true },
        )
        val arrivedLabel = arrived?.get("label")?.jsonPrimitive?.contentOrNull
        SetupNumberedStep(
            number = 2,
            title = L10n.text("android.setupwizard.sign_in_to_this_account.d3d7f116"),
            body = if (arrivedLabel != null) L10n.text("android.setupwizard.0_is_on_your_account.5704eab4", "${arrivedLabel}")
            else L10n.text("android.setupwizard.open_it_there_and_sign_in_with_the_same_ac.d3ddaa5f"),
            done = arrived != null,
            actionTitle = null,
            onAction = {},
        )
        SetupNumberedStep(
            number = 3,
            title = L10n.text("android.setupwizard.let_this_device_in.35808989"),
            body = L10n.text("android.setupwizard.folders_and_terminals_are_only_open_to_dev.e9f4d10a"),
            done = false,
            actionTitle = null,
            onAction = {},
        )
        if (arrived != null) {
            Text(
                L10n.text("android.setupwizard.one_step_is_left_and_it_happens_on_the_com.6a5d8111"),
                style = TsType.caption,
                color = colors.textSecondary,
            )
        }
    }
}

@Composable
private fun SetupNumberedStep(
    number: Int,
    title: String,
    body: String,
    done: Boolean,
    actionTitle: String?,
    onAction: () -> Unit,
) {
    val colors = LocalTsColors.current
    TsCard {
        Row(
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Text(
                if (done) L10n.text("common.done") else "$number",
                style = TsType.headline,
                color = if (done) colors.accent else colors.textSecondary,
            )
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, style = TsType.headline, color = colors.textPrimary)
                Text(body, style = TsType.subheadline, color = colors.textSecondary)
                if (actionTitle != null) {
                    Spacer(Modifier.height(4.dp))
                    TsAccentButton(label = actionTitle, small = true, onClick = onAction)
                }
            }
        }
    }
}

/// Door three: a machine somebody already rents. Reading an inventory, and
/// nothing else. Creating a machine is out of scope: a write-scoped provider
/// token on a phone can spend somebody's money.
@Composable
private fun SetupCloudDoor(
    model: AppViewModel,
    onPickServer: () -> Unit,
    onNeedServer: () -> Unit,
) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var token by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("root") }
    var imported by remember { mutableStateOf<Int?>(null) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Text(
            L10n.text("android.setupwizard.a_cloud_machine.e66ba82a"),
            style = TsType.title2.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            L10n.text("android.setupwizard.import_an_existing_server_from_your_provid.24352ead"),
            style = TsType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        SetupDoorCard(
            title = L10n.text("android.setupwizard.i_do_not_have_one_yet.1bfb41c7"),
            body = L10n.text("android.setupwizard.what_a_machine_has_to_be_who_bills_you_for.b01df46d"),
            requirement = null,
            icon = { Icon(ActionIcon.Next.vector, null, tint = colors.accent) },
            onClick = onNeedServer,
        )
        if (error != null) Banner(error!!, BannerSeverity.DANGER)
        TsCard {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                Text(L10n.text("android.setupwizard.read_only_api_token.8a4f07c1"), style = TsType.caption, color = colors.textSecondary)
                androidx.compose.material3.OutlinedTextField(
                    value = token,
                    onValueChange = { token = it },
                    placeholder = { Text(L10n.text("android.setupwizard.paste_your_digitalocean_token.2e2aa61f")) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                TsSecondaryButton(
                    label = L10n.text("android.setupwizard.where_to_find_the_token.625cfc6d"),
                    small = true,
                    onClick = {
                        runCatching {
                            CustomTabsIntent.Builder().build().launchUrl(
                                context,
                                "https://cloud.digitalocean.com/account/api/tokens".toUri(),
                            )
                        }
                    },
                )
                Text(L10n.text("android.setupwizard.ssh_username.04940ab1"), style = TsType.caption, color = colors.textSecondary)
                androidx.compose.material3.OutlinedTextField(
                    value = username,
                    onValueChange = { username = it },
                    placeholder = { Text(L10n.text("android.setupwizard.ssh_username.04940ab1")) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    L10n.text("android.setupwizard.only_the_droplet_list_is_read_the_token_is.d730f946"),
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            }
        }
        if (imported != null) {
            Text(
                if (imported == 1) L10n.text("android.setupwizard.one_server_is_in_your_library_pick_it_on_t.3984faae")
                else L10n.text("android.setupwizard.0_servers_are_in_your_library_pick_one_on.85b3ca0e", "${imported}"),
                style = TsType.subheadline,
                color = colors.textPrimary,
            )
        }
        if (imported == null) {
            TsAccentButton(
                label = if (working) L10n.text("android.setupwizard.reading_the_list.0fd8ea35") else L10n.text("android.setupwizard.read_my_servers.0e3c3c94"),
                onClick = {
                    scope.launch {
                        working = true
                        error = null
                        runCatching {
                            model.core("ssh.provider.digitalOcean.import", buildJsonObject {
                                put("token", token)
                                put("username", username.trim())
                            }).jsonObject
                        }.onSuccess { answer ->
                            val count = answer["imported"]?.jsonPrimitive?.contentOrNull?.toIntOrNull()
                            if ((count ?: 0) <= 0) {
                                error = L10n.text("android.setupwizard.no_servers_were_found_check_the_account_to.e590f2d6")
                            } else {
                                // The token was a credential and its job is
                                // done. It is never written to the archive.
                                token = ""
                                imported = count
                            }
                        }.onFailure { error = SetupFailure.readable(it) }
                        working = false
                    }
                },
                modifier = Modifier.fillMaxWidth(),
                enabled = !working && token.isNotEmpty() && username.trim().isNotEmpty(),
            )
        } else {
            TsAccentButton(
                label = L10n.text("android.setupwizard.pick_a_server.3ff63c9e"),
                onClick = onPickServer,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
