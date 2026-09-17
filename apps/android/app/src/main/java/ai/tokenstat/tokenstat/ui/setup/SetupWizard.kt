// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.setup

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
                title = { Text("Set up a machine") },
                navigationIcon = {
                    TsSecondaryButton(label = "Close", small = true, onClick = {
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
            SetupStep.MAC -> SetupMacDoor(state = state)
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
            "Renting a server",
            style = TsType.title2.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            "This device is where you work. The machine is what runs the agent, holds your projects and stays on when you close this. A small rented Linux server is the usual way to have one.",
            style = TsType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        GuideSection("What it has to be") {
            GuideRequirement(
                "Linux with systemd",
                "Setup uses systemd to keep the helper running, including after a reboot.",
            )
            GuideRequirement(
                "64-bit Intel or AMD",
                "The standard server image at any provider.",
            )
            GuideRequirement(
                "SSH access",
                "A login setup can use: a password or an SSH key. Root works, and so does an ordinary user that can write to its own home directory.",
            )
        }
        GuideSection("What size is enough") {
            Text(
                "The coding agent, your project and any local models determine how much memory, disk space and processing power you need.",
                style = TsType.subheadline,
                color = colors.textSecondary,
            )
            GuideBullet("Check the agent's system requirements and leave room for your project's builds and tests.")
            GuideBullet("Grow when the projects do. Disk and memory follow your checkouts and models, not us.")
        }
        GuideSection("Who takes the money") {
            Text("Three separate things, and only one of them is ours.", style = TsType.subheadline)
            GuideBullet("The provider bills you for the server, monthly or by the hour, until you delete it. Deleting the machine is how the charge stops, and that happens in their console, not here.")
            GuideBullet("The coding agent is billed by whoever makes it, through the account you sign in to on the machine.")
            GuideBullet("tokenstat charges for its own plan. Nothing here buys a server and nothing here includes agent usage.")
        }
        GuideSection("Where to get one") {
            Text(
                "Choose a provider with a server that meets the requirements above. Setup can import DigitalOcean servers on this device, and any other server works with its SSH address. You create and manage the server in the provider's own account.",
                style = TsType.subheadline,
                color = colors.textSecondary,
            )
            TsSecondaryButton(
                label = "DigitalOcean",
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
                "The DigitalOcean link is a referral link. Same price for you, credit for the project.",
                style = TsType.caption,
                color = colors.textSecondary,
            )
        }
        Text(
            "Come back here when the server exists and you have its address. Nothing on this screen has to be finished in one sitting.",
            style = TsType.caption,
            color = colors.textSecondary,
        )
        TsAccentButton(
            label = "I have a server now",
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
            "A server you have",
            style = TsType.title2.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            "Connect over SSH and set it up, or run one command yourself. Either way the machine signs in to this account and comes back paired.",
            style = TsType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        SetupDoorCard(
            title = "Connect over SSH",
            body = "Choose a server and how to sign in. Setup verifies it, checks it, and installs tokenstat while you watch.",
            requirement = null,
            icon = { Icon(ActionIcon.Source.vector, null, tint = colors.accent, modifier = Modifier.size(25.dp)) },
            onClick = onConnect,
        )
        SetupDoorCard(
            title = "Run it yourself",
            body = "Paste one command into a terminal on the server. For a server that matters, or whenever handing over an SSH key is not on.",
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
                if (text.isEmpty()) throw CoreClientFailure("The account did not return a pairing code.")
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
            "Run it yourself",
            style = TsType.title2.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            "Paste this into a terminal on the server. tokenstat waits here for the machine to appear on your account.",
            style = TsType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        if (error != null) Banner(error!!, BannerSeverity.DANGER)
        if (code != null) {
            TsCard {
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text("Your pairing code", style = TsType.subheadline.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
                    SelectionContainer {
                        Text(code!!, style = TsType.mono(22, FontWeight.SemiBold), color = colors.textPrimary)
                    }
                    Text(
                        "Good for $expiresMinutes minutes and for one machine. It is already in the command below.",
                        style = TsType.caption,
                        color = colors.textSecondary,
                    )
                }
            }
        }
        if (line != null) {
            TsCard {
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text("On the server", style = TsType.subheadline.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
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
            Text("Preparing the command…", style = TsType.subheadline, color = colors.textSecondary)
        }
        Text(
            "The machine signs itself in with that code, and lets this device open its work. Nothing about it goes through a browser.",
            style = TsType.caption,
            color = colors.textSecondary,
        )
        TsAccentButton(
            label = if (copied) "Copied" else "Copy the command",
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
            label = "Generate a new code",
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
            label = "I ran it, check my account",
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
    val hostLabel = machines.find { it.setupPeer() == peer }?.setupHostLabel() ?: "the machine"
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
            "Choose a project",
            style = TsType.title2.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
        )
        Text(
            "The agent works inside one folder at a time. Bring a repository down onto the machine, or point at a folder it already has.",
            style = TsType.body,
            color = colors.textSecondary,
        )
        if (machines.isEmpty()) {
            Banner(
                "No machines on this account yet. Run the install first, then choose a project.",
                BannerSeverity.WARNING,
            )
        }
        if (machines.size > 1) {
            TsCard {
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text("Machine", style = TsType.caption, color = colors.textSecondary)
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
            title = "Clone a repository",
            body = "tokenstat runs git on the machine and registers the folder when it finishes. You watch the whole thing, so a passphrase or an unknown host key is something you can answer.",
            requirement = null,
            icon = { Icon(ActionIcon.Download.vector, null, tint = colors.accent, modifier = Modifier.size(25.dp)) },
            onClick = { route = ProjectRoute.CLONE },
        )
        SetupDoorCard(
            title = "A folder already on the machine",
            body = "Browse the machine's disk and register a folder that is there. Nothing is copied and nothing is changed.",
            requirement = null,
            icon = { Icon(ActionIcon.Source.vector, null, tint = colors.accent, modifier = Modifier.size(25.dp)) },
            onClick = { route = ProjectRoute.EXISTING },
        )
        Text(
            "Whichever you choose, the machine opens with a first task written into the message box. Nothing is sent until you send it.",
            style = TsType.caption,
            color = colors.textSecondary,
        )
        TsSecondaryButton(label = "Not now", onClick = onNotNow, modifier = Modifier.fillMaxWidth())
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
            "How do you want to work?",
            style = TsType.title2.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            "tokenstat runs agents on a machine that stays on. It can be a computer you own or a server you rent.",
            style = TsType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        // The computer first: no token, no rental, nothing to buy. The doors
        // below it both assume a server.
        SetupDoorCard(
            title = "On my Mac",
            body = "Install the desktop app on the computer you work on, sign in to this account, and let this device in.",
            requirement = null,
            icon = { Icon(Icons.Default.Laptop, null, tint = colors.accent, modifier = Modifier.size(25.dp)) },
            onClick = { onDoor(SetupStep.MAC) },
        )
        SetupDoorCard(
            title = "On a server I have",
            body = "Connect over SSH and set it up. tokenstat installs itself, signs the machine in and comes back paired.",
            requirement = if (paywalled) "Reaching it needs patron" else null,
            icon = { Icon(Icons.Default.Dns, null, tint = colors.accent, modifier = Modifier.size(25.dp)) },
            onClick = { onDoor(SetupStep.SERVER) },
        )
        SetupDoorCard(
            title = "On a cloud machine",
            body = "A VPS or a dedicated server. Import the ones you have, or find out what to rent if you have none yet.",
            requirement = if (paywalled) "Reaching it needs patron" else null,
            icon = { Icon(Icons.Default.Cloud, null, tint = colors.accent, modifier = Modifier.size(25.dp)) },
            onClick = { onDoor(SetupStep.CLOUD) },
        )
        // Leaving, without pretending it is a setup choice. A fourth card
        // wore the same surface as the three doors and read as a fourth way
        // to set up. A quiet bordered button says what it is.
        TsSecondaryButton(
            label = "Skip for now",
            onClick = onClose,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            "Go to your account and your numbers. Usage from machines you already have keeps arriving on its own, and a machine can be connected later from Devices.",
            style = TsType.caption,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            "Nothing here is permanent. Every door can be left, and leaving lands on your numbers, which keep arriving whatever you choose.",
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
private fun SetupMacDoor(state: ai.tokenstat.tokenstat.ClientState) {
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
            context.startActivity(Intent.createChooser(send, "Send it to my computer"))
            sharing = false
        }
    }
    // Nothing is written and nothing is installed: this is a screen
    // watching, which is the only thing a phone can honestly do here.
    LaunchedEffect(Unit) {
        val deadline = System.currentTimeMillis() + 600_000
        while (arrived == null && System.currentTimeMillis() < deadline) {
            delay(5_000)
        }
    }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Text(
            "Your computer",
            style = TsType.title2.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            "Three things, all of them on the computer. This screen watches your account and ticks each one off as it happens.",
            style = TsType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        SetupNumberedStep(
            number = 1,
            title = "Install tokenstat on the computer",
            body = "Send the download link to the computer. Share it or message it to yourself, then open it there.",
            done = arrived != null,
            actionTitle = if (arrived == null) "Send it to my computer" else null,
            onAction = { sharing = true },
        )
        val arrivedLabel = arrived?.get("label")?.jsonPrimitive?.contentOrNull
        SetupNumberedStep(
            number = 2,
            title = "Sign in to this account",
            body = if (arrivedLabel != null) "$arrivedLabel is on your account."
            else "Open it there and sign in with the same account this device uses.",
            done = arrived != null,
            actionTitle = null,
            onAction = {},
        )
        SetupNumberedStep(
            number = 3,
            title = "Let this device in",
            body = "Folders and terminals are only open to devices that computer has allowed. Ask from Workspaces, and say yes on the computer.",
            done = false,
            actionTitle = null,
            onAction = {},
        )
        if (arrived != null) {
            Text(
                "One step is left and it happens on the computer: when this device asks to open a folder, say yes there.",
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
                if (done) "Done" else "$number",
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
            "A cloud machine",
            style = TsType.title2.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            "Import an existing server from your provider, then connect over SSH. No servers are created and nothing is purchased.",
            style = TsType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        SetupDoorCard(
            title = "I do not have one yet",
            body = "What a machine has to be, who bills you for it, and where people rent one. Nothing there spends money.",
            requirement = null,
            icon = { Icon(ActionIcon.Next.vector, null, tint = colors.accent) },
            onClick = onNeedServer,
        )
        if (error != null) Banner(error!!, BannerSeverity.DANGER)
        TsCard {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                Text("Read-only API token", style = TsType.caption, color = colors.textSecondary)
                androidx.compose.material3.OutlinedTextField(
                    value = token,
                    onValueChange = { token = it },
                    placeholder = { Text("Paste your DigitalOcean token") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                TsSecondaryButton(
                    label = "Where to find the token",
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
                Text("SSH username", style = TsType.caption, color = colors.textSecondary)
                androidx.compose.material3.OutlinedTextField(
                    value = username,
                    onValueChange = { username = it },
                    placeholder = { Text("SSH username") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    "Only the droplet list is read. The token is used once and is not saved.",
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            }
        }
        if (imported != null) {
            Text(
                if (imported == 1) "One server is in your library. Pick it on the next screen."
                else "$imported servers are in your library. Pick one on the next screen.",
                style = TsType.subheadline,
                color = colors.textPrimary,
            )
        }
        if (imported == null) {
            TsAccentButton(
                label = if (working) "Reading the list…" else "Read my servers",
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
                                error = "No servers were found. Check the account token or enter a server address instead."
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
                label = "Pick a server",
                onClick = onPickServer,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
