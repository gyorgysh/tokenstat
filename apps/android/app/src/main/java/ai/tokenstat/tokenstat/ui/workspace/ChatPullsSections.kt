// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.ForegroundEffect
import ai.tokenstat.tokenstat.core.readBounded
import ai.tokenstat.tokenstat.core.InputLimitExceeded
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.activity.compose.BackHandler
import androidx.compose.material3.Surface
import androidx.compose.foundation.layout.fillMaxHeight

import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.layout.height

import ai.tokenstat.tokenstat.ui.chrome.HideTabBar
import ai.tokenstat.tokenstat.ui.chrome.OwnSectionHeader
import androidx.compose.foundation.border
import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import android.provider.OpenableColumns
import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.IconButton
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.notifications.VisibleChat
import ai.tokenstat.tokenstat.ui.marks.HarnessMark
import ai.tokenstat.tokenstat.ui.persona.ChatPersona
import ai.tokenstat.tokenstat.ui.persona.PersonaMark
import ai.tokenstat.tokenstat.ui.persona.PersonaSheet
import ai.tokenstat.tokenstat.ui.persona.faceSeedFor
import ai.tokenstat.tokenstat.ui.persona.parseChatPersonaList
import ai.tokenstat.tokenstat.ui.persona.personaDefaultParams
import ai.tokenstat.tokenstat.ui.persona.personaScopeParams
import ai.tokenstat.tokenstat.ui.persona.personaSeed
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.RelativeTimeText
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsBrandSwitch
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.PickerChoice
import ai.tokenstat.tokenstat.ui.components.TsPickerField
import ai.tokenstat.tokenstat.ui.components.TsSearchField
import ai.tokenstat.tokenstat.ui.components.TsSimplePickerSheet
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.logic.ChatDelivery
import ai.tokenstat.tokenstat.ui.logic.ChatOutbox
import ai.tokenstat.tokenstat.ui.logic.ChatOutboxFailure
import ai.tokenstat.tokenstat.ui.logic.ChatOutboxRules
import ai.tokenstat.tokenstat.ui.logic.FileChatOutbox
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.LaunchChoice
import ai.tokenstat.tokenstat.ui.logic.QueuedAttachment
import ai.tokenstat.tokenstat.ui.logic.QueuedMessage
import ai.tokenstat.tokenstat.ui.logic.LaunchChoiceStore
import ai.tokenstat.tokenstat.ui.logic.LaunchDefaults
import ai.tokenstat.tokenstat.ui.logic.SharedPrefsLaunchChoice
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.logic.friendlyError
import ai.tokenstat.tokenstat.ui.logic.harnessName
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/// `str` comes from the shared workspace readers in `WorkspaceSections.kt`.

@Composable
fun ChatSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    protocol: Long?,
    modifier: Modifier = Modifier,
    folderName: String = "",
    hostLabel: String = "",
    onChatOpened: (String) -> Unit = {},
    initialChatId: String? = null,
    openConversationOnAppear: Boolean = false,
    conversationNonce: Int = 0,
    machineId: String? = null,
) {
    val scope = rememberCoroutineScope()
    var chats by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var openId by remember(workspace) { mutableStateOf<String?>(null) }
    var creating by remember(workspace) { mutableStateOf(false) }
    var didOpenConversation by remember(workspace, openConversationOnAppear, conversationNonce) { mutableStateOf(false) }
    var events by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var approvals by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var error by remember(workspace) { mutableStateOf<String?>(null) }
    var loading by remember(workspace) { mutableStateOf(true) }
    var draft by remember(workspace) { mutableStateOf("") }
    /// Which conversations have a send in flight. Per conversation, because a
    /// send outlives a navigation: one unkeyed flag showed the spinner on
    /// whatever conversation was opened next.
    var sendingIds by remember(workspace) { mutableStateOf<Set<String>>(emptySet()) }
    val sending = openId?.let { it in sendingIds } == true
    var sendError by remember(workspace) { mutableStateOf<String?>(null) }
    var actionError by remember(workspace) { mutableStateOf<String?>(null) }
    var eventsError by remember(workspace) { mutableStateOf<String?>(null) }
    var search by remember { mutableStateOf("") }
    var agentFilter by remember { mutableStateOf("") }
    var runningOnly by remember { mutableStateOf(false) }
    var alphabetical by remember { mutableStateOf(false) }
    var filterOpen by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<JsonObject?>(null) }
    var showingSetup by remember { mutableStateOf(false) }
    // Agent, model and effort, one tap from the composer the way the iPhone
    // reaches them. The list lives here rather than in the sheet, because the
    // composer's summary line reads it too.
    var showingAgent by remember { mutableStateOf(false) }
    var backends by remember(peer) { mutableStateOf<List<JsonObject>>(emptyList()) }
    // Files chosen but not sent yet. They go up with the message rather than
    // on pick, so removing one before sending costs the host nothing.
    var staged by remember(workspace) { mutableStateOf<List<StagedAttachment>>(emptyList()) }
    var attachError by remember(workspace) { mutableStateOf<String?>(null) }
    /// Why a setup change did not take. The host refuses one while a turn is
    /// running, and a pill that snaps back explains nothing by itself.
    var setupError by remember(workspace) { mutableStateOf<String?>(null) }
    // A conversation opens on its latest turn and stays with it, the way the
    // Apple transcript does. Fresh per conversation, so opening another chat
    // starts pinned again rather than inheriting a scrollback.
    val follow = remember(openId) { TranscriptFollowState() }
    val listState = remember(openId) { LazyListState() }
    var autoScrolling by remember(openId) { mutableStateOf(false) }
    val context = LocalContext.current
    /// How the last conversation was set up, which is what a new one opens
    /// with. See `LaunchDefaults`.
    val launchChoice: LaunchChoiceStore = remember(context) { SharedPrefsLaunchChoice(context) }
    /// Messages waiting for the open turn. Durable, because they are somebody's
    /// own writing rather than a cache. See `ChatOutbox`.
    val outbox: ChatOutbox = remember(context) { FileChatOutbox(context) }
    /// Whether the last attempt to reach this host worked.
    ///
    /// Not the account's own connection state: that is only recomputed when
    /// something refreshes the account, so it still read "connected" with the
    /// radio off. The poll below asks this host every two seconds, and its
    /// answer is the truthful one.
    var hostReachable by remember(workspace) { mutableStateOf(true) }
    val offline = !hostReachable
    var queued by remember(workspace) { mutableStateOf<List<QueuedMessage>>(emptyList()) }
    /// Which queued messages this session may send without being asked again.
    ///
    /// A message somebody just pressed Send on is authorised. Messages found
    /// on disk at open are not, except the ones explicitly marked Send when
    /// connected: reopening the app is not the same as asking to send.
    var authorized by remember(workspace) { mutableStateOf<Set<String>>(emptySet()) }
    /// The message the composer is delivering on its first attempt. Twin of
    /// `ChatModel.deliveringFromComposer`: the strip draws `pending` rather
    /// than `queued`, so a healthy send never opens it.
    var deliveringFromComposer by remember(workspace) { mutableStateOf<String?>(null) }
    /// What the pending strip draws: everything genuinely waiting, which is
    /// to say everything except the send that is in flight right now. A
    /// refused or unconfirmed send clears the filter on its way out, so it
    /// appears the moment it really is pending. Twin of
    /// `ChatModel.pendingQueue`.
    val pendingQueue = ChatOutboxRules.pending(queued, deliveringFromComposer)
    // The document picker, which needs no storage permission: the user hands
    // us one file at a time and nothing else on the device is readable.
    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris ->
        if (uris.isNullOrEmpty()) return@rememberLauncherForActivityResult
        val conversation = openId
        scope.launch {
            attachError = null
            for (uri in uris) {
                val remaining = 24 * 1024 * 1024 - staged.sumOf { it.bytes }
                if (remaining <= 0) {
                    attachError = "Send or remove the staged files before adding more (24 MB total)."
                    break
                }
                val read = withContext(Dispatchers.IO) {
                    readAttachment(context, uri, minOf(ATTACHMENT_CAP, remaining))
                }
                if (openId != conversation) return@launch
                when (read) {
                    is AttachmentRead.Ok -> {
                        // Another picker result may have completed while this read suspended.
                        if (staged.sumOf { it.bytes } + read.attachment.bytes > 24 * 1024 * 1024) {
                            attachError = "Send or remove the staged files before adding more (24 MB total)."
                            break
                        }
                        staged = staged + read.attachment
                    }
                    is AttachmentRead.Failed -> { attachError = read.reason; break }
                }
            }
        }
    }

    suspend fun loadChats() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "chat.list", buildJsonObject { put("workspaceId", workspace) })
        }.onSuccess {
            chats = (it as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
            error = null
        }.onFailure { error = friendlyError(it.message).message }
        loading = false
    }
    // What the open conversation ended up set to, kept for the next new one.
    // Recorded from the record rather than from each control, so a setting
    // changed anywhere (composer, setup sheet, agent picker) is carried.
    // Twin of `ChatModel.saveLaunchChoice`. Written only when it changed:
    // the poll below runs every two seconds for as long as a chat is open.
    var lastLaunch by remember(workspace) { mutableStateOf<LaunchChoice?>(null) }
    fun rememberLaunch(chat: JsonObject?) {
        val backend = chat?.str("backend")?.ifBlank { null } ?: return
        val choice = LaunchChoice(
            backend = backend,
            model = chat.str("model")?.ifBlank { null },
            effort = chat.str("effort")?.ifBlank { null },
            mode = chat.str("mode")?.ifBlank { null } ?: LaunchDefaults.MODE,
            autonomy = chat.str("autonomy")?.ifBlank { null } ?: LaunchDefaults.AUTONOMY,
            // Empty, not null: no persona is a choice worth carrying.
            personaId = chat.str("personaId").orEmpty(),
        )
        if (choice == lastLaunch) return
        lastLaunch = choice
        launchChoice.write(choice)
    }
    // The list without the list chrome: the open conversation polls this so
    // its `running` flag (and the thinking indicator reading it) stays live.
    // `loadChats` would do, but it flashes the spinner and clears a sticky
    // list error on every pass.
    suspend fun refreshChats() {
        runCatching {
            model.workspaceSection(peer, "chat.list", buildJsonObject { put("workspaceId", workspace) })
        }.onSuccess {
            chats = (it as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
            hostReachable = true
        }.onFailure {
            hostReachable = false
        }
    }
    suspend fun loadEvents(id: String) {
        runCatching {
            model.workspaceSection(peer, "chat.events", buildJsonObject {
                put("id", id); put("offset", 0L)
            })
        }.onSuccess {
            val arr = (it as? JsonObject)?.get("events") as? JsonArray
                ?: (it as? JsonArray)
            events = arr?.filterIsInstance<JsonObject>() ?: emptyList()
            eventsError = null
        }.onFailure {
            // The poll retries on its own; the card says so and stays until
            // a poll lands or the person puts it away.
            if (eventsError == null) {
                eventsError = TunnelCopy.display(it.message ?: "The request failed.", hostLabel.ifBlank { "the host" }) +
                    " Still trying."
            }
        }
        runCatching {
            model.workspaceSection(peer, "chat.approvals", buildJsonObject { put("id", id) })
        }.onSuccess {
            approvals = (it as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
        }
    }
    // Create, then open what was created. A "New chat" button that lands
    // back on the list created the chat and hid it in the same motion.
    suspend fun createAndOpen() {
        if (creating) return
        creating = true
        // The agent list first. Without it there is nothing to check the
        // remembered agent against, and a new chat opened on the fallback
        // rather than on what the person was last working in. `ChatModel`
        // loads it in the same breath for the same reason.
        if (backends.isEmpty()) {
            runCatching {
                model.workspaceSection(peer, "chat.backends", buildJsonObject {})
            }.onSuccess { backends = asObjects(it) }
        }
        runCatching {
            val saved = launchChoice.read()
            val backendId = LaunchDefaults.backend(saved, backends)
            val backend = backends.firstOrNull { it.str("id") == backendId }
            model.workspaceSection(peer, "chat.create", buildJsonObject {
                put("workspaceId", workspace)
                put("backend", backendId)
                // What was last used, not what the host falls back to. The
                // host's `default_mode` is plan because that is the safe
                // reading of a record with no mode; a chat somebody just
                // asked for is a different thing, and planning at them is a
                // turn that does nothing they wanted. Twin of
                // `ChatModel.startChat`.
                put("mode", LaunchDefaults.mode(saved))
                put(
                    "autonomy",
                    LaunchDefaults.autonomy(saved, chatAgentForcesBypass(backends, backendId)),
                )
                LaunchDefaults.model(saved, backend)?.let { put("model", it) }
                LaunchDefaults.effort(saved, backend)?.let { put("effort", it) }
            }) as? JsonObject
        }.onSuccess { created ->
            val id = created?.str("id")
            loadChats()
            openId = id ?: chats.maxByOrNull {
                (it["updatedAtMs"] as? JsonPrimitive)?.longOrNull ?: 0L
            }?.str("id")
        }.onFailure { error = friendlyError(it.message).message }
        creating = false
    }
    // Instant, like the Apple chase: an animated walk through a lazy list
    // lands on estimated heights and stops short, so Jump takes one press.
    suspend fun scrollToEnd() {
        autoScrolling = true
        try {
            val last = listState.layoutInfo.totalItemsCount - 1
            if (last >= 0) listState.scrollToItem(last)
        } finally {
            autoScrolling = false
        }
    }
    suspend fun pinToLatest() {
        follow.jump()
        scrollToEnd()
    }
    fun outboxKey(id: String) = ChatOutboxRules.key(peer, workspace, id)

    /// Save a queue change, and say so when it is refused rather than letting
    /// the list quietly disagree with what is on disk. Published only when
    /// this conversation is still the open one: a send for chat A that lands
    /// after chat B was opened must not overwrite B's strip.
    suspend fun writeQueue(id: String, mutate: (MutableList<QueuedMessage>) -> Unit): Boolean =
        runCatching { outbox.update(outboxKey(id), mutate) }
            .onSuccess { if (id == openId) queued = it }
            .onFailure {
                sendError = (it as? ChatOutboxFailure)?.message
                    ?: "Pending messages could not be saved on this device."
            }
            .isSuccess

    /// Put a message in the queue. Written to disk before the host is asked,
    /// so a send that is interrupted leaves the words somewhere.
    suspend fun enqueue(id: String, text: String, files: List<QueuedAttachment>, whenConnected: Boolean): QueuedMessage? {
        val revision = chats.firstOrNull { it.str("id") == id }?.long("sendRevision")
        val item = QueuedMessage(
            id = java.util.UUID.randomUUID().toString(),
            text = text,
            attachments = files,
            expectedRevision = revision,
            whenConnected = whenConnected,
        )
        if (queued.size >= ChatOutboxRules.CAPACITY) {
            sendError = "This conversation already has ${ChatOutboxRules.CAPACITY} messages waiting."
            return null
        }
        if (!writeQueue(id) { it.add(item) }) return null
        // Pressing Send is the authorisation. Nothing else auto-sends.
        authorized = authorized + item.id
        return item
    }

    /// Ask the host whether it took a message whose send was never confirmed.
    /// Never a resend: an unknown receipt is not proof it was never sent.
    /// True when the receipt cleared the message, so the drain carries on
    /// while the host is free instead of waiting for the next poll.
    suspend fun checkReceipt(id: String, item: QueuedMessage): Boolean {
        if (!HostContracts.supportsReceipt(protocol)) {
            val computer = hostLabel.ifBlank { "this computer" }
            sendError = "Update $computer to check message delivery. It speaks protocol $protocol and needs " +
                "${HostContracts.RECEIPT_MIN_PROTOCOL} or later. Your pending copy stays here."
            return false
        }
        val receipt = runCatching {
            model.workspaceSection(peer, "chat.receipt", buildJsonObject {
                put("id", id); put("clientMessageId", item.id)
            }) as? JsonObject
        }.getOrElse {
            // A cancelled check is not a failed one. Navigating away mid-send
            // must leave the message where it was, not mark it failed.
            if (it is CancellationException) throw it
            sendError = TunnelCopy.display(it.message ?: "The request failed.", hostLabel.ifBlank { "the host" })
            return false
        }
        when (receipt?.str("state") ?: "unknown") {
            "accepted" -> {
                writeQueue(id) { list -> list.removeAll { it.id == item.id } }
                sendError = null
                loadEvents(id)
                refreshChats()
                return true
            }
            "needsRecovery" -> sendError =
                "The computer could not confirm whether this message started. Review the conversation before " +
                    "copying it into a new draft. Your pending copy stays here."
            else -> sendError =
                "Delivery is not confirmed. Check the conversation before copying this message into a new draft. " +
                    "An unknown receipt is not proof it was never sent."
        }
        return false
    }

    /// Hand one queued message to the host.
    ///
    /// Nothing leaves the queue before the host acknowledges it, and every
    /// outcome that is not a plain acceptance leaves the copy behind in a
    /// state that says what to do next. Port of `ChatModel.deliverQueued`.
    suspend fun deliver(item: QueuedMessage, stopCurrent: Boolean): Boolean {
        val id = openId ?: return false
        if (!HostContracts.supportsConfirmedSend(protocol)) {
            val computer = hostLabel.ifBlank { "this computer" }
            sendError = "Update $computer before sending. It speaks protocol $protocol and needs " +
                "${HostContracts.CONFIRMED_SEND_MIN_PROTOCOL} or later. Your draft stays here."
            return false
        }
        val key = outboxKey(id)
        if (!outbox.beginDelivery(key)) return false
        sendingIds = sendingIds + id
        try {
            if (item.needsReceipt) return checkReceipt(id, item)
            // The host refuses a send with no revision, and a message written
            // against a conversation nobody can name has to be looked at. A
            // review flag is not a revision either: an explicit retry must
            // re-aim the message rather than send it past the review.
            if (item.expectedRevision == null || item.delivery == ChatDelivery.NeedsReview) {
                writeQueue(id) { list ->
                    val at = list.indexOfFirst { it.id == item.id }
                    if (at >= 0) list[at] = list[at].copy(delivery = ChatDelivery.NeedsReview)
                }
                sendError = "Review the live conversation, then choose Use latest context. Your message has not been sent."
                return false
            }
            if (stopCurrent && chats.firstOrNull { it.str("id") == id }?.bol("running") == true) {
                runCatching {
                    model.workspaceSection(peer, "chat.stop", buildJsonObject { put("id", id) })
                }
                repeat(80) {
                    if (chats.firstOrNull { it.str("id") == id }?.bol("running") != true) return@repeat
                    refreshChats()
                    kotlinx.coroutines.delay(200)
                }
            }
            // The row stays editable through the stop wait above, so the words
            // may have changed since this message was picked up. The bytes
            // sent are the bytes saved, never the stale closure.
            val live = runCatching { outbox.items(key) }.getOrDefault(emptyList())
                .firstOrNull { it.id == item.id } ?: item
            // An edit after an attempt means the words changed, so the
            // delivery id changes with them: the old one may already have a
            // receipt on the host.
            val rotates = live.attemptedAtMs != null && live.delivery == ChatDelivery.Waiting
            val deliveryId = if (rotates) java.util.UUID.randomUUID().toString() else live.id
            val now = System.currentTimeMillis()
            val firstAttempt = if (rotates) now else (live.firstAttemptAtMs ?: live.attemptedAtMs ?: now)
            if (!writeQueue(id) { list ->
                    val at = list.indexOfFirst { it.id == item.id }
                    if (at >= 0) {
                        list[at] = list[at].copy(
                            id = deliveryId,
                            delivery = ChatDelivery.Sending,
                            firstAttemptAtMs = firstAttempt,
                            attemptedAtMs = now,
                        )
                    }
                }
            ) return false
            val sent = runCatching {
                model.workspaceSection(
                    peer,
                    "chat.send",
                    chatSendParams(
                        id, live.text, deliveryId, firstAttempt, live.expectedRevision,
                        live.attachments.map { it.id },
                    ),
                ) as? JsonObject
            }
            if (sent.isSuccess) {
                val revision = sent.getOrNull()?.long("sendRevision")
                runCatching {
                    val carried = outbox.update(outboxKey(id)) { list ->
                        val kept = ChatOutboxRules.accept(list.toList(), deliveryId, revision)
                        list.clear()
                        list.addAll(kept)
                    }
                    if (id == openId) queued = carried
                }
                authorized = authorized - deliveryId - item.id
                sendError = null
                loadEvents(id)
                refreshChats()
                return true
            }
            val failure = sent.exceptionOrNull()
            // A cancelled send is not a failed one. Navigating away mid-send
            // must leave the message where it was, not mark it failed.
            if (failure is CancellationException) throw failure
            val code = (failure as? ai.tokenstat.tokenstat.core.CoreFailure)?.code.orEmpty()
            writeQueue(id) { list ->
                val at = list.indexOfFirst { it.id == deliveryId }
                if (at >= 0) {
                    list[at] = list[at].copy(
                        delivery = when {
                            code == "conversation_changed" -> ChatDelivery.NeedsReview
                            ChatOutboxRules.deliveryUnknown(code, failure?.message) -> ChatDelivery.DeliveryUnknown
                            else -> ChatDelivery.Failed
                        },
                    )
                }
            }
            authorized = authorized - deliveryId
            sendError = if (ChatOutboxRules.deliveryUnknown(code, failure?.message)) {
                "The computer did not confirm delivery. Your queued copy stays here. Choose Check delivery before " +
                    "doing anything else."
            } else {
                TunnelCopy.display(failure?.message ?: "The request failed.", hostLabel.ifBlank { "the host" })
            }
            return false
        } finally {
            outbox.endDelivery(key)
            sendingIds = sendingIds - id
        }
    }

    /// Send what is waiting, oldest first, while the host will take it.
    suspend fun drainQueue() {
        val id = openId ?: return
        while (true) {
            if (sendingIds.isNotEmpty() || !hostReachable) return
            val next = queued.firstOrNull() ?: return
            if (next.id !in authorized) return
            if (chats.firstOrNull { it.str("id") == id }?.bol("running") == true) return
            if (!deliver(next, stopCurrent = false)) return
        }
    }

    suspend fun send(text: String) {
        val id = openId ?: return
        val clean = text.trim()
        if (clean.isEmpty() && staged.isEmpty()) return
        // Sending is engaging: follow is the default, so a new turn resumes
        // it even from a scrollback.
        pinToLatest()
        // Uploaded first, and only then queued: a message that names a file
        // the host does not have yet is worse than a slower send. A refused
        // attachment stops the send with the draft intact. The ids travel on
        // the message, so a queued one cannot pick up somebody else's files.
        val files = mutableListOf<QueuedAttachment>()
        for (attachment in staged) {
            val uploaded = runCatching {
                model.workspaceSection(peer, "chat.attach", buildJsonObject {
                    put("id", id)
                    put("name", attachment.name)
                    put("data", attachment.data)
                    attachment.mediaType?.let { put("mediaType", it) }
                }) as? JsonObject
            }
            val file = uploaded.getOrNull()
            if (uploaded.isFailure || file?.str("id") == null) {
                attachError = TunnelCopy.display(
                    uploaded.exceptionOrNull()?.message ?: "The attachment could not be sent.",
                    hostLabel.ifBlank { "the host" },
                )
                return
            }
            files.add(QueuedAttachment(file.str("id").orEmpty(), file.str("name") ?: attachment.name))
        }
        val item = enqueue(id, clean, files, whenConnected = false) ?: return
        draft = ""
        staged = emptyList()
        attachError = null
        sendError = null
        // Hidden while this first attempt is in flight, the way the Apple
        // strip hides it. A refusal clears this on the way out, so the
        // message appears the moment it really is pending.
        deliveringFromComposer = item.id
        try {
            drainQueue()
        } finally {
            deliveringFromComposer = null
        }
    }

    /// Stop the open turn so this message goes next, or check a delivery
    /// nobody could confirm, or re-aim one at the conversation as it is now.
    suspend fun sendNow(item: QueuedMessage) {
        val id = openId ?: return
        if (item.needsReceipt) {
            checkReceipt(id, item)
            return
        }
        if (item.delivery == ChatDelivery.NeedsReview) {
            val revision = chats.firstOrNull { it.str("id") == id }?.long("sendRevision")
            writeQueue(id) { list ->
                val at = list.indexOfFirst { it.id == item.id }
                if (at >= 0) {
                    list[at] = list[at].copy(delivery = ChatDelivery.Ready, expectedRevision = revision)
                }
            }
            return
        }
        authorized = authorized + item.id
        deliver(item, stopCurrent = true)
    }
    LaunchedEffect(workspace) { loadChats() }
    // A navigation that named a conversation: open exactly it, even when
    // this folder's list is already on screen.
    LaunchedEffect(initialChatId, workspace) {
        if (initialChatId != null) openId = initialChatId
    }
    // The launcher's promise: arriving to start work opens the conversation
    // worth returning to, or starts one when there is none.
    LaunchedEffect(loading, openConversationOnAppear, conversationNonce) {
        if (!openConversationOnAppear || didOpenConversation || loading || error != null) return@LaunchedEffect
        didOpenConversation = true
        if (chats.isEmpty()) {
            createAndOpen()
        } else {
            openId = chats.maxByOrNull {
                (it["updatedAtMs"] as? JsonPrimitive)?.longOrNull ?: 0L
            }?.str("id")
        }
    }
    LaunchedEffect(openId, peer) {
        if (openId == null || backends.isNotEmpty()) return@LaunchedEffect
        runCatching {
            model.workspaceSection(peer, "chat.backends", buildJsonObject {})
        }.onSuccess { backends = asObjects(it) }
    }
    // What the push service should stay quiet about: a turn finishing in
    // the transcript on screen needs no banner. Cleared on the way out, so
    // a backgrounded app still notifies.
    DisposableEffect(workspace) {
        onDispose { VisibleChat.hidden() }
    }
    // The watching heartbeat, port of `WatchingHeartbeat`: while this
    // conversation is on a foreground screen, the host holds a 30s lease
    // saying so and skips the finished-turn push. Renewed every 10s so one
    // dropped beat does not let a banner through; released on the way out,
    // and expired by the host when no release ever arrives. Without this a
    // phone driving a chat buzzes about the turn on its own screen.
    val watcherId = remember(workspace) { java.util.UUID.randomUUID().toString() }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var foreground by remember(lifecycle) { mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            foreground = event.targetState.isAtLeast(Lifecycle.State.RESUMED)
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(openId, machineId, foreground) {
        if (foreground && openId != null) VisibleChat.showing(machineId, openId)
        else VisibleChat.hidden()
    }
    LaunchedEffect(openId, peer, foreground) {
        val id = openId ?: return@LaunchedEffect
        if (!foreground) return@LaunchedEffect
        try {
            while (true) {
                runCatching {
                    model.workspaceSection(peer, "app.watching", buildJsonObject {
                        put("conversationId", id); put("watcherId", watcherId)
                    })
                }
                delay(10_000)
            }
        } finally {
            kotlinx.coroutines.withContext(NonCancellable) {
                runCatching {
                    model.workspaceSection(peer, "app.stoppedWatching", buildJsonObject {
                        put("conversationId", id); put("watcherId", watcherId)
                    })
                }
            }
        }
    }
    // What is already waiting for this conversation, from disk.
    LaunchedEffect(openId, peer, workspace) {
        val id = openId
        if (id == null) {
            queued = emptyList()
            authorized = emptySet()
            return@LaunchedEffect
        }
        val items = runCatching { outbox.items(outboxKey(id)) }
            .onFailure {
                sendError = (it as? ChatOutboxFailure)?.message
                    ?: "Pending messages could not be read on this device."
            }
            .getOrDefault(emptyList())
        queued = items
        // Reopening the app is not asking to send. Only messages explicitly
        // marked Send when connected resume on their own; the rest wait for
        // Send now, so nothing goes out that somebody has forgotten about.
        authorized = items
            .filter { it.whenConnected && it.delivery == ChatDelivery.Waiting }
            .map { it.id }
            .toSet()
    }
    ForegroundEffect(openId, peer, workspace) {
        val id = openId ?: return@ForegroundEffect
        onChatOpened(id)
        while (true) {
            loadEvents(id)
            refreshChats()
            rememberLaunch(chats.firstOrNull { it.str("id") == id })
            // The turn that was in the way may have finished. Read the flag
            // rather than the value composed with this effect: this loop
            // outlives the composition that started it.
            if (hostReachable) drainQueue()
            kotlinx.coroutines.delay(2000)
        }
    }

    val place = folderName.ifBlank { "this folder" }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        // Only the list wears the section label. A conversation is a screen
        // of its own and carries its own title.
        if (openId == null) SectionLabel("Conversations")
        if (!HostContracts.supportsChat(protocol)) {
            Text("Update the host to use chat (needs protocol 4).", style = MaterialTheme.typography.bodySmall)
            return
        }
        if (error != null) {
            StickyErrorCard(
                message = error!!,
                onRetry = { scope.launch { loadChats() } },
                onDismiss = { error = null },
            )
        }
        if (openId == null) {
            // Both as buttons on one baseline. A bordered chip beside a bare
            // text link, each sized by a different rule, sat at two
            // different heights and read as a mistake.
            Row(
                horizontalArrangement = Arrangement.spacedBy(Space.s),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TsAccentButton(
                    label = if (creating) "Starting…" else "New chat",
                    icon = ActionIcon.Create.vector,
                    small = true,
                    enabled = !creating,
                    onClick = { scope.launch { createAndOpen() } },
                )
                TsSecondaryButton(
                    label = "Refresh",
                    icon = ActionIcon.Refresh.vector,
                    small = true,
                    onClick = { scope.launch { loadChats() } },
                )
            }
            if (loading) { CircularProgressIndicator(Modifier, strokeWidth = 2.dp); return }
            if (chats.isEmpty()) {
                EmptyState(
                    Icons.Default.ChatBubbleOutline,
                    "Start a chat",
                    "Ask an agent to explore, plan, or work in $place.",
                    action = {
                        TsAccentButton(
                            label = if (creating) "Starting…" else "New chat",
                            small = true,
                            enabled = !creating,
                            onClick = { scope.launch { createAndOpen() } },
                        )
                    },
                )
                return
            }
            TsSearchField(prompt = "Titles, agents, or models", query = search, onQueryChange = { search = it }, modifier = Modifier.fillMaxWidth())
            ChatStatPanels(chats)
            val query = search.trim()
            val agentIds = chats.mapNotNull { it.str("backend") }.toSortedSet()
            val filtered = chats.filter {
                (query.isEmpty() ||
                    (it.str("title") ?: "").contains(query, ignoreCase = true) ||
                    (it.str("backend") ?: "").contains(query, ignoreCase = true) ||
                    (it.str("model") ?: "").contains(query, ignoreCase = true)) &&
                    (agentFilter.isEmpty() || it.str("backend") == agentFilter) &&
                    (!runningOnly || it.bol("running"))
            }
            val shown = if (alphabetical) filtered.sortedBy { (it.str("title") ?: "").lowercase() } else filtered
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box {
                    TsSecondaryButton(
                        label = "Filter & sort",
                        icon = ActionIcon.Filter.vector,
                        small = true,
                        onClick = { filterOpen = true },
                    )
                    DropdownMenu(expanded = filterOpen, onDismissRequest = { filterOpen = false }) {
                        ChatAgentMenuItem("All agents", agentFilter.isEmpty()) { agentFilter = ""; filterOpen = false }
                        agentIds.forEach { backend ->
                            ChatAgentMenuItem(harnessName(backend), agentFilter == backend) {
                                agentFilter = backend; filterOpen = false
                            }
                        }
                        HorizontalDivider()
                        DropdownMenuItem(
                            text = { Text("Running only") },
                            trailingIcon = { TsBrandSwitch(runningOnly, { runningOnly = it }) },
                            onClick = { runningOnly = !runningOnly; filterOpen = false },
                        )
                        HorizontalDivider()
                        ChatAgentMenuItem("Recent first", !alphabetical) { alphabetical = false; filterOpen = false }
                        ChatAgentMenuItem("Title A–Z", alphabetical) { alphabetical = true; filterOpen = false }
                    }
                }
                Text(
                    "${shown.size} shown",
                    style = TextStyle(fontSize = 12.sp),
                    color = LocalTsColors.current.textSecondary,
                )
            }
            if (shown.isEmpty()) {
                Text("No matching conversations. Adjust your search or filters.", style = MaterialTheme.typography.bodySmall)
                return
            }
            LazyColumn(contentPadding = PaddingValues(bottom = TabBarChrome.contentBottomInset), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(shown, key = { it.str("id") ?: it.hashCode().toString() }) { chat ->
                    val dismiss = rememberSwipeToDismissBoxState(
                        confirmValueChange = { value ->
                            if (value != SwipeToDismissBoxValue.Settled) pendingDelete = chat
                            false
                        },
                    )
                    SwipeToDismissBox(
                        state = dismiss,
                        enableDismissFromStartToEnd = false,
                        backgroundContent = {
                            Box(
                                Modifier
                                    .fillMaxSize()
                                    .clip(RoundedCornerShape(cardRadiusDp))
                                    .background(LocalTsColors.current.danger)
                                    .padding(16.dp),
                                contentAlignment = Alignment.CenterEnd,
                            ) {
                                Icon(Icons.Default.Delete, null, tint = Color.White)
                            }
                        },
                    ) {
                        TsCard(Modifier.fillMaxWidth().clickable { openId = chat.str("id") }) {
                            ChatRow(chat)
                        }
                    }
                }
            }
        } else {
            // A conversation is a push, not a tab: the bar goes away and Back
            // is the way out, which is what `clientTabBarHidden` does on iOS.
            // Claimed by the composition, so every exit restores it.
            HideTabBar()
            // Back returns to the list, the way the arrow beside the title
            // does. Without it the gesture reached the activity and closed
            // the app from inside a conversation.
            BackHandler {
                openId = null
                scope.launch { loadChats() }
            }
            // And the header: the section above only knows it is "Chat",
            // while this knows which conversation. Two headers with two back
            // arrows is what stacking them looked like.
            OwnSectionHeader()
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                IconButton(onClick = { openId = null; scope.launch { loadChats() } }) {
                    Icon(
                        Icons.AutoMirrored.Filled.ArrowBack,
                        "All conversations",
                        tint = LocalTsColors.current.textPrimary,
                    )
                }
                Column(Modifier.weight(1f)) {
                    Text(
                        chats.firstOrNull { it.str("id") == openId }?.str("title")?.ifBlank { null }
                            ?: "New chat",
                        style = MaterialTheme.typography.headlineSmall,
                        color = LocalTsColors.current.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        folderName.ifBlank { "Conversation" },
                        style = MaterialTheme.typography.bodySmall,
                        color = LocalTsColors.current.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                IconButton(onClick = { showingSetup = true }) {
                    Icon(
                        ActionIcon.Settings.vector,
                        "Chat setup",
                        tint = LocalTsColors.current.accent,
                    )
                }
            }
            if (actionError != null) {
                StickyErrorCard(
                    message = actionError!!,
                    onDismiss = { actionError = null },
                )
            }
            if (eventsError != null) {
                StickyErrorCard(
                    message = eventsError!!,
                    onDismiss = { eventsError = null },
                )
            }
            val pending = approvals.filter { it.str("decision").isNullOrBlank() }
            pending.forEach { approval ->
                ApprovalCard(
                    approval = approval,
                    onResolve = { choice ->
                        scope.launch {
                            runCatching {
                                model.workspaceSection(peer, "chat.resolveApproval", buildJsonObject {
                                    put("id", approval.str("id") ?: "")
                                    put("choice", choice)
                                })
                            }.onSuccess {
                                actionError = null
                                openId?.let { loadEvents(it) }
                            }.onFailure {
                                actionError = TunnelCopy.display(it.message ?: "The request failed.", hostLabel.ifBlank { "the host" })
                            }
                        }
                    },
                )
            }
            val openChat = chats.firstOrNull { it.str("id") == openId }
            val transcript = remember(events, openChat) {
                coalesceTranscript(
                    events,
                    defaultBackend = openChat?.str("backend"),
                    running = openChat?.bol("running") ?: true,
                )
            }
            // Fills, rather than wrapping: the composer below is docked to
            // the bottom edge the way every chat app docks it, instead of
            // floating at whatever height the transcript happened to end.
            if (transcript.isEmpty()) {
                // The character, the way the Apple clients open an empty
                // conversation with one. A blank rectangle above a composer
                // says the screen failed to load; the persona says it is
                // waiting for you.
                Column(
                    Modifier.weight(1f).fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    EmptyArt(EmptyArtKind.Chat)
                    Spacer(Modifier.height(Space.s))
                    Text(
                        "Ask about ${folderName.ifBlank { "this folder" }}",
                        style = MaterialTheme.typography.titleSmall,
                        color = LocalTsColors.current.textPrimary,
                    )
                    Text(
                        "Plan a change, explore the code, or set something running.",
                        style = MaterialTheme.typography.bodySmall,
                        color = LocalTsColors.current.textSecondary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = Space.l),
                    )
                }
            } else {
                val density = LocalDensity.current
                val busy = sending || openChat?.bol("running") == true
                val atBottom by remember(listState, density) {
                    derivedStateOf {
                        val info = listState.layoutInfo
                        val last = info.visibleItemsInfo.lastOrNull()
                        val thresholdPx = with(density) { TranscriptFollow.thresholdDp.toPx() }
                        isAtBottom(
                            lastVisibleIndex = last?.index,
                            totalItems = info.totalItemsCount,
                            distancePx = if (last == null) 0 else last.offset + last.size - info.viewportEndOffset,
                            thresholdPx = thresholdPx,
                        )
                    }
                }
                // The reader's own scrolls move the pin. Our pins must never
                // count as the reader leaving, or auto-follow would unpin
                // itself mid-stream.
                LaunchedEffect(atBottom, listState.isScrollInProgress) {
                    follow.note(atBottom, userScroll = listState.isScrollInProgress && !autoScrolling)
                }
                // A conversation opens on its latest turn, and a pinned
                // transcript stays on it as turns stream in. A hand on the
                // screen wins: while the reader is scrolling, no pin.
                // The running flag is a key too, not just the transcript: the
                // thinking indicator is its own row below the last turn, and
                // without this the list never scrolls it into view when a
                // turn starts with no new events yet.
                LaunchedEffect(transcript, openChat?.bol("running")) {
                    if (transcript.isNotEmpty() && follow.pinned &&
                        !(listState.isScrollInProgress && !autoScrolling)
                    ) {
                        scrollToEnd()
                    }
                }
                Box(Modifier.weight(1f)) {
                    LazyColumn(
                        Modifier.fillMaxSize(),
                        state = listState,
                        contentPadding = PaddingValues(bottom = Space.s),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        items(transcript, key = { it.id }) { item ->
                            TranscriptItemRow(
                                item = item,
                                model = model,
                                peer = peer,
                                chatId = openId ?: "",
                                hostLabel = hostLabel,
                                defaultAgentName = openChat?.str("backend")?.let { harnessName(it) } ?: "Agent",
                            )
                        }
                        // The turn in progress, with the conversation's own
                        // face at the same left edge as an agent reply, the
                        // way the Apple transcript keeps its character moving
                        // while you wait.
                        if (openChat?.bol("running") == true) {
                            item(key = "working") {
                                ChatWorkingIndicator(seed = personaSeed(openId ?: workspace))
                            }
                        }
                    }
                    follow.pill(busy)?.let { pill ->
                        TranscriptFollowPill(
                            pill = pill,
                            onResume = { scope.launch { pinToLatest() } },
                            onPause = { follow.pause() },
                            modifier = Modifier.align(Alignment.BottomCenter),
                        )
                    }
                }
            }
            if (sendError != null) {
                // One baseline for every action: a bordered chip beside a
                // bare text link sat at two heights, and Check delivery on
                // its own row below read as a second mistake.
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Banner(sendError!!, BannerSeverity.DANGER)
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        TsSecondaryButton(
                            label = "Try again",
                            small = true,
                            // A failed send leaves the queue unauthorised, so
                            // retrying asks again for exactly the head. A
                            // review flag still stops it there: retry re-aims
                            // through the sheet, never past it.
                            onClick = {
                                scope.launch {
                                    queued.firstOrNull()?.let { authorized = authorized + it.id }
                                    drainQueue()
                                }
                            },
                        )
                        TextButton(onClick = { sendError = null }) { Text("Dismiss") }
                    }
                }
            }
            attachError?.let { Banner(it, BannerSeverity.DANGER) }
            setupError?.let { message ->
                Banner(message, BannerSeverity.WARNING)
                TextButton(onClick = { setupError = null }) { Text("Dismiss") }
            }
            ChatQueueStrip(
                items = pendingQueue,
                // Paused when the next message is not one this session was
                // asked to send: a reopened queue waits to be told. Read
                // from what the strip shows, so the in-flight send hiding
                // above does not decide it.
                paused = pendingQueue.firstOrNull()?.let { it.id !in authorized } == true,
                offline = offline,
                onChange = { item, text ->
                    val id = openId ?: return@ChatQueueStrip
                    scope.launch {
                        writeQueue(id) { list ->
                            val at = list.indexOfFirst { it.id == item.id }
                            if (at >= 0 && list[at].canEdit) list[at] = list[at].copy(text = text)
                        }
                    }
                },
                onRemove = { item ->
                    val id = openId ?: return@ChatQueueStrip
                    authorized = authorized - item.id
                    scope.launch {
                        writeQueue(id) { list -> list.removeAll { it.id == item.id } }
                    }
                },
                onSendNow = { item -> scope.launch { sendNow(item) } },
                onMove = { from, to ->
                    val id = openId ?: return@ChatQueueStrip
                    scope.launch {
                        writeQueue(id) { list ->
                            val moved = ChatOutboxRules.moved(list.toList(), from, to)
                            list.clear()
                            list.addAll(moved)
                        }
                    }
                },
            )
            ChatComposer(
                chat = chats.firstOrNull { it.str("id") == openId },
                draft = draft,
                onDraft = { draft = it },
                hint = ai.tokenstat.tokenstat.ui.logic.ChatHint.hint(folderName, sending),
                sending = sending,
                staged = staged,
                onPick = { attachError = null; picker.launch(arrayOf("*/*")) },
                onRemove = { staged = staged - it },
                onSend = { scope.launch { send(draft) } },
                onStop = {
                    val id = openId ?: return@ChatComposer
                    scope.launch {
                        runCatching {
                            model.workspaceSection(peer, "chat.stop", buildJsonObject { put("id", id) })
                        }
                        sendingIds = sendingIds - id
                    }
                },
                backends = backends,
                onAgent = { showingAgent = true },
                launchMode = LaunchDefaults.mode(launchChoice.read()),
                offline = offline,
                onQueueWhenConnected = {
                    val id = openId ?: return@ChatComposer
                    // Text only: an attachment cannot be uploaded with no
                    // connection, and a message that names a file the host
                    // has never seen is not a message it can take.
                    scope.launch {
                        if (enqueue(id, draft.trim(), emptyList(), whenConnected = true) != null) {
                            draft = ""
                            sendError = null
                        }
                    }
                },
                onChange = { field, value ->
                    val id = openId ?: return@ChatComposer
                    scope.launch {
                        runCatching {
                            model.workspaceSection(peer, "chat.update", buildJsonObject {
                                put("id", id); put(field, value)
                            })
                        }.onSuccess {
                            setupError = null
                            loadChats()
                        }.onFailure {
                            // The host refuses a setup change while a turn is
                            // running. Swallowing that left the pill snapping
                            // back with nothing said: somebody pressing
                            // Execute saw Plan stay lit and no reason why.
                            setupError = TunnelCopy.display(
                                it.message ?: "The request failed.",
                                hostLabel.ifBlank { "the computer" },
                            )
                        }
                    }
                },
            )
        }
    }
    val doomed = pendingDelete
    if (doomed != null) {
        val host = hostLabel.ifBlank { "the computer" }
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete this chat?") },
            text = { Text("The transcript stays on $host until you delete it. This cannot be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    pendingDelete = null
                    scope.launch {
                        runCatching {
                            model.workspaceSection(peer, "chat.remove", buildJsonObject {
                                put("id", doomed.str("id") ?: "")
                            })
                        }
                        loadChats()
                    }
                }) { Text("Delete chat") }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Keep it") } },
        )
    }
    if (showingSetup) {
        val id = openId
        if (id != null) {
            ChatSetupDialog(
                model = model,
                peer = peer,
                workspace = workspace,
                chatId = id,
                hostLabel = hostLabel,
                chat = chats.firstOrNull { it.str("id") == id },
                backends = backends,
                onPickAgent = { showingAgent = true },
                onDismiss = { showingSetup = false },
                onChanged = { scope.launch { loadChats() } },
            )
        }
    }
    if (showingAgent) {
        val id = openId
        if (id != null) {
            ChatAgentSheet(
                model = model,
                peer = peer,
                chatId = id,
                chat = chats.firstOrNull { it.str("id") == id },
                hostLabel = hostLabel,
                protocol = protocol,
                locked = sending,
                backends = backends,
                onBackends = { backends = it },
                onChanged = { scope.launch { loadChats() } },
                onDismiss = { showingAgent = false },
            )
        }
    }
}

/// The three fact cards the iOS list leads with: Conversations, Running,
/// Agents. Figure first in accent, caption below, mark trailing.
@Composable
private fun ChatStatPanels(chats: List<JsonObject>) {
    val colors = LocalTsColors.current
    val panels = listOf(
        Triple("Conversations", chats.size.toString(), Icons.Default.ChatBubbleOutline),
        Triple("Running", chats.count { it.bol("running") }.toString(), Icons.Default.Bolt),
        Triple("Agents", chats.mapNotNull { it.str("backend") }.toSet().size.toString(), Icons.Default.Person),
    )
    // Figure and glyph share the top row, label spans the width underneath,
    // the way the Apple tiles are built. Sitting the glyph beside the label
    // instead left "Conversations" competing with it for room in a third of
    // the screen, and it lost: the tile read "Conversation".
    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
        panels.forEach { (label, value, mark) ->
            TsCard(Modifier.weight(1f)) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            value,
                            style = TsType.numeric(20, FontWeight.Medium),
                            color = colors.accent,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Box(
                            Modifier
                                .size(26.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .background(colors.accentSoft),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(mark, null, tint = colors.accent, modifier = Modifier.size(15.dp))
                        }
                    }
                    Text(
                        label,
                        style = TsType.caption2,
                        color = colors.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

@Composable
private fun ChatAgentMenuItem(label: String, checked: Boolean, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(label) },
        leadingIcon = if (checked) ({ Icon(Icons.Default.Check, null) }) else null,
        onClick = onClick,
    )
}

/// One conversation row like the iOS list: harness mark, running dot,
/// two-line title, agent and Plan/Execute in accent, relative time, chevron.
@Composable
private fun ChatRow(chat: JsonObject) {
    val colors = LocalTsColors.current
    val mode = if (chat.str("mode") == "plan") "Plan" else "Execute"
    val atMs = chat["lastMessageAtMs"]?.jsonPrimitive?.longOrNull
        ?: chat["updatedAtMs"]?.jsonPrimitive?.longOrNull
    Row(
        Modifier.padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        HarnessMark(chat.str("backend") ?: "?", size = 28.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (chat.bol("running")) {
                    Canvas(Modifier.size(7.dp)) { drawCircle(colors.accent) }
                }
                Text(
                    chat.str("title") ?: "Untitled",
                    style = MaterialTheme.typography.titleSmall,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                "${harnessName(chat.str("backend") ?: "?")} · $mode",
                style = MaterialTheme.typography.bodySmall,
                color = colors.accent,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (atMs != null) {
                RelativeTimeText(atMs, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary, compact = true)
            }
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = colors.controlGlyph)
    }
}

/// A tool approval awaiting an answer: verb, preview, and Allow, Always
/// allow, Deny. Decided approvals read back their outcome instead.
@Composable
internal fun ApprovalCard(approval: JsonObject, onResolve: (String) -> Unit) {
    val verb = approval.str("verb") ?: "Approval"
    val preview = approval.str("preview") ?: ""
    val pending = approval.str("decision").isNullOrBlank()
    val colors = LocalTsColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            Text(
                if (pending) "Needs an answer" else "Decided",
                style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                color = if (pending) colors.warning else colors.textSecondary,
                modifier = Modifier.weight(1f),
            )
            Text(
                verb,
                style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium),
                color = colors.accent,
            )
        }
        if (preview.isNotBlank()) {
            Text(preview, style = TsType.mono(12), color = colors.textPrimary, maxLines = 5)
        }
        if (pending) {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TsAccentButton(label = "Allow", small = true, onClick = { onResolve("allow") })
                TsSecondaryButton(label = "Always allow", small = true, onClick = { onResolve("allowAlways") })
                TsSecondaryButton(label = "Deny", small = true, onClick = { onResolve("deny") })
            }
        } else {
            Text(
                approval.str("decision") ?: "",
                style = TextStyle(fontSize = 12.sp),
                color = colors.textSecondary,
            )
        }
    }
}

/// Chat setup: who answers, which persona, and the instructions behind the
/// conversation. Agent, model and effort sit behind one field that opens the
/// picker holding all three, the same way the Apple setup screen reaches them.
@Composable
private fun ChatSetupDialog(
    model: AppViewModel,
    peer: String,
    workspace: String,
    chatId: String,
    hostLabel: String,
    chat: JsonObject?,
    backends: List<JsonObject>,
    onPickAgent: () -> Unit,
    onDismiss: () -> Unit,
    onChanged: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var brief by remember { mutableStateOf<String?>(null) }
    var added by remember { mutableStateOf<String?>(null) }
    var channel by remember { mutableStateOf<String?>(null) }
    var personas by remember { mutableStateOf<List<ChatPersona>>(emptyList()) }
    var defaultId by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(true) }
    var showingPersonas by remember { mutableStateOf(false) }
    var pickingPersona by remember { mutableStateOf(false) }
    var pickingDefault by remember { mutableStateOf(false) }

    suspend fun load() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "chat.instructions", buildJsonObject { put("id", chatId) })
        }.onSuccess { element ->
            // `chat.instructions` answers {brief, added, channel}. Reading it
            // for an "instructions" key that was never there fell through to
            // `toString`, which put the raw JSON on screen, escapes and all.
            val obj = element as? JsonObject
            brief = obj?.str("brief")
            added = obj?.str("added")
            channel = obj?.str("channel")
        }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        runCatching {
            model.workspaceSection(peer, "chat.personas", personaScopeParams(workspace))
        }.onSuccess { element ->
            val (list, current) = parseChatPersonaList(element)
            personas = list
            defaultId = current
        }
        loading = false
    }
    LaunchedEffect(chatId) { load() }

    /// This conversation's own persona, which is the id and the brief written
    /// together: the host keeps the text on the chat, so a persona edited
    /// later does not silently rewrite a conversation already under way.
    fun applyPersona(persona: ChatPersona?) {
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "chat.update", buildJsonObject {
                    put("id", chatId)
                    put("personaId", persona?.id ?: "")
                    put("systemPrompt", persona?.systemPrompt ?: "")
                })
            }.onSuccess { onChanged() }
                .onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        }
    }

    fun updateChat(field: String, value: String) {
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "chat.update", buildJsonObject {
                    put("id", chatId); put(field, value)
                })
            }.onSuccess { onChanged() }
                .onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        }
    }

    fun setDefault(persona: ChatPersona?) {
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "chat.personaDefault", personaDefaultParams(workspace, persona?.id ?: ""))
            }.onSuccess { defaultId = persona?.id }
                .onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        }
    }

    val colors = LocalTsColors.current
    val chatPersona = personas.firstOrNull { it.id == chat?.str("personaId") }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        // A sheet with a surface under it. Without one the dialog drew its
        // text straight over the conversation: two paragraphs of instructions
        // interleaved with the persona and the composer, unreadable, and
        // nothing on screen said which taps belonged to which layer.
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = colors.background,
            tonalElevation = 0.dp,
            shadowElevation = 12.dp,
            modifier = Modifier
                .fillMaxWidth(0.94f)
                .fillMaxHeight(0.86f),
        ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(Space.m)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Chat setup",
                    style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                TsSecondaryButton(label = "Done", icon = ActionIcon.Done.vector, small = true, onClick = onDismiss)
            }
            if (error != null) Banner(error!!, BannerSeverity.DANGER)
            if (loading) {
                Text("Loading…", color = colors.textSecondary)
            } else {
                // Who answers, in one field. The three settings behind it are
                // one list with one filter, rather than three dropdowns that
                // each hold a scroll of their own.
                Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    SectionLabel("Agent")
                    TsPickerField(
                        summary = chatAgentSummary(backends, chat),
                        onOpen = onPickAgent,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                // The persona picker, with the chosen one's face beside it.
                // The face is the point of the row: a name in a list is a
                // setting, and a character sitting next to it is the thing
                // you recognise from the transcript.
                Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        SectionLabel("Persona", modifier = Modifier.weight(1f))
                        TsSecondaryButton(
                            label = "Edit personas",
                            icon = ActionIcon.Persona.vector,
                            small = true,
                            onClick = { showingPersonas = true },
                        )
                    }
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(Space.s),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        PersonaMark(
                            seed = chatPersona?.let { faceSeedFor(it) } ?: personaSeed(chatId),
                            size = 30.dp,
                        )
                        TsPickerField(
                            summary = chatPersona?.name ?: "No persona",
                            onOpen = { pickingPersona = true },
                            modifier = Modifier.weight(1f),
                        )
                    }
                    Text(
                        "Sent to whichever agent this chat is on. It is never part of your message.",
                        style = TsType.caption,
                        color = colors.textSecondary,
                    )
                }
                // Plan against Execute and Ask against Bypass, the same
                // controls the composer carries. The iPhone setup edits
                // them too: settings matter most before you commit.
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    SectionLabel("How it works")
                    ChatSegmented(
                        options = listOf("plan" to "Plan", "execute" to "Execute"),
                        selected = chat?.str("mode")?.ifBlank { null } ?: LaunchDefaults.MODE,
                        enabled = chat?.bol("running") != true,
                        onSelect = { updateChat("mode", it) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (chatAgentForcesBypass(backends, chat?.str("backend").orEmpty())) {
                        ChatSegmented(
                            options = listOf("bypass" to "Bypass"),
                            selected = "bypass",
                            enabled = false,
                            onSelect = {},
                            modifier = Modifier.fillMaxWidth(),
                        )
                    } else {
                        ChatSegmented(
                            options = listOf("standard" to "Ask", "bypass" to "Bypass"),
                            selected = if (chat?.str("autonomy") == "bypass") "bypass" else "standard",
                            enabled = chat?.bol("running") != true,
                            onSelect = { updateChat("autonomy", it) },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
                // What the person wrote, and what tokenstat adds, kept apart:
                // only one of the two is theirs to change.
                Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    SectionLabel("Brief")
                    Text(
                        brief?.ifBlank { null } ?: "No brief. The agent gets the folder and your messages.",
                        style = TextStyle(fontSize = 14.sp),
                        color = colors.textSecondary,
                    )
                }
                added?.ifBlank { null }?.let {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                        SectionLabel("What tokenstat adds")
                        Text(it, style = TextStyle(fontSize = 13.sp), color = colors.textSecondary)
                        Text(
                            when (channel) {
                                "systemPrompt" -> "Sent as the system prompt."
                                "turnPrefix" -> "This agent takes no system prompt, so it goes in front of each turn."
                                else -> ""
                            },
                            style = TextStyle(fontSize = 12.sp),
                            color = colors.textTertiary,
                        )
                    }
                }
                HorizontalDivider(color = colors.border)
                // Which persona new chats in this folder inherit, including
                // none. A row rather than a mark on whichever persona is open,
                // so there is a way to say "none of them".
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            "New chats here",
                            style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Medium),
                            color = colors.textPrimary,
                        )
                        Text(
                            "Existing conversations keep whatever they already have.",
                            style = TsType.caption,
                            color = colors.textSecondary,
                        )
                    }
                    TsPickerField(
                        summary = personas.firstOrNull { it.id == defaultId }?.name ?: "No persona",
                        onOpen = { pickingDefault = true },
                    )
                }
            }
        }
        }
    }
    if (pickingPersona) {
        TsSimplePickerSheet(
            title = "Persona",
            choices = personaPickerChoices(personas, defaultId),
            isSelected = { it == (chat?.str("personaId") ?: "") },
            prompt = "Filter personas",
            emptyMessage = "No personas yet. Edit personas to write one.",
            onPick = { id -> applyPersona(personas.firstOrNull { it.id == id }) },
            onDismiss = { pickingPersona = false },
        )
    }
    if (pickingDefault) {
        TsSimplePickerSheet(
            title = "New chats here",
            choices = personaPickerChoices(personas, defaultId),
            isSelected = { it == (defaultId ?: "") },
            prompt = "Filter personas",
            emptyMessage = "No personas yet. Edit personas to write one.",
            onPick = { id -> setDefault(personas.firstOrNull { it.id == id }) },
            onDismiss = { pickingDefault = false },
        )
    }
    if (showingPersonas) {
        PersonaSheet(
            model = model,
            peer = peer,
            workspaceId = workspace,
            onDismiss = { showingPersonas = false; scope.launch { load() } },
        )
    }
}

/// The personas a picker offers, with "No persona" first because choosing
/// none is a real answer rather than the absence of one. The folder default
/// is named on its row, so a list of four names says which one a new chat
/// would have started with.
internal fun personaPickerChoices(
    personas: List<ChatPersona>,
    defaultId: String?,
): List<PickerChoice<String>> =
    listOf(PickerChoice("", "No persona", detail = "The agent answers as itself")) +
        personas.map {
            PickerChoice(
                value = it.id,
                label = it.name,
                detail = if (it.id == defaultId) "Default for new chats here" else null,
            )
        }


/// Installed agents as id-to-label pairs, the way the Apple agent picker
/// lists them. Uninstalled entries stay out: picking one would fail.
internal fun chatBackendOptions(backends: List<JsonObject>): List<Pair<String, String>> =
    backends.mapNotNull { backend ->
        val id = backend.str("id") ?: return@mapNotNull null
        if ((backend["installed"] as? JsonPrimitive)?.booleanOrNull == false) return@mapNotNull null
        id to (backend.str("label")?.ifBlank { null } ?: backend.str("name")?.ifBlank { null } ?: id)
    }

internal fun stringList(backend: JsonObject?, key: String): List<String> =
    (backend?.get(key) as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()

/// The agent's models, keeping the conversation's current one even when the
/// host no longer lists it, so the picker never hides what is set.
internal fun chatModelOptions(backend: JsonObject?, current: String?): List<String> {
    val listed = stringList(backend, "models")
    val clean = current?.ifBlank { null }
    return if (clean != null && clean !in listed) listed + clean else listed
}

/// The agent's efforts, with the same keep-what-is-set rule as the models.
internal fun chatEffortOptions(backend: JsonObject?, current: String?): List<String> {
    val listed = stringList(backend, "efforts")
    val clean = current?.ifBlank { null }
    return if (clean != null && clean !in listed) listed + clean else listed
}

/// The body for one `chat.send` call. `expectedRevision` is the open
/// conversation's `sendRevision`: the host rejects a receipted send without
/// it (`send_upgrade_required`), so every send carrying a client message id
/// would fail. Omitted when unknown, mirroring the Apple client.
internal fun chatSendParams(
    id: String,
    text: String,
    messageId: String,
    createdAtMs: Long,
    sendRevision: Long?,
    attachmentIds: List<String> = emptyList(),
): JsonObject = buildJsonObject {
    put("id", id); put("text", text)
    put("clientMessageId", messageId)
    put("clientMessageCreatedAtMs", createdAtMs)
    if (sendRevision != null) put("expectedRevision", sendRevision)
    // Named on the message rather than left to the conversation, so a queued
    // message cannot arrive carrying files somebody attached after it.
    if (attachmentIds.isNotEmpty()) {
        put("attachmentIds", kotlinx.serialization.json.buildJsonArray {
            attachmentIds.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) }
        })
    }
}

private val pullScopes = listOf(
    "All" to "all",
    "Mine" to "mine",
    "Assigned" to "assigned",
    "Review requested" to "reviewRequested",
)

private val pullStates = listOf("Open" to "open", "Merged" to "merged", "Closed" to "closed")

/// Pull requests for this folder: availability first (a paired client can
/// inspect, never connect), then scope and state filters, then rows with
/// the same counts the Apple list shows. Detail opens over the list.
@Composable
fun PullsSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    protocol: Long?,
    modifier: Modifier = Modifier,
    folderName: String = "",
    hostLabel: String = "",
) {
    val scope = rememberCoroutineScope()
    var availability by remember(workspace) { mutableStateOf<JsonObject?>(null) }
    var pulls by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var error by remember(workspace) { mutableStateOf<String?>(null) }
    var loading by remember(workspace) { mutableStateOf(true) }
    var scopeName by remember { mutableStateOf("all") }
    var stateName by remember { mutableStateOf("open") }
    var openNumber by remember { mutableStateOf<Long?>(null) }

    suspend fun load() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "pulls.availability", buildJsonObject { put("workspaceId", workspace) }) as? JsonObject
        }.onSuccess { availability = it }
        runCatching {
            model.workspaceSection(peer, "pulls.list", buildJsonObject {
                put("workspaceId", workspace); put("scope", scopeName); put("state", stateName); put("limit", 30)
            })
        }.onSuccess {
            val arr = (it as? JsonObject)?.get("pulls") as? JsonArray ?: (it as? JsonArray)
            pulls = arr?.filterIsInstance<JsonObject>() ?: emptyList()
            error = null
        }.onFailure { error = friendlyError(it.message).message }
        loading = false
    }
    LaunchedEffect(workspace, scopeName, stateName) { load() }
    val opened = openNumber
    if (opened != null) {
        PullDetailPage(
            model = model,
            peer = peer,
            workspace = workspace,
            hostLabel = hostLabel,
            number = opened,
            modifier = modifier,
            // The row that was tapped already knows the title and the author,
            // so the loading page can show them instead of a bare spinner.
            summary = pulls.firstOrNull { it.long("number") == opened },
            onBack = { openNumber = null; scope.launch { load() } },
        )
        return
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        // The pushed header says "Pull requests" already.
        if (!HostContracts.supportsPulls(protocol)) {
            Text("Update the host to read pull requests (needs protocol 3).", style = MaterialTheme.typography.bodySmall)
            return
        }
        val available = availability
        if (available != null && (available.str("state") ?: "") != "ready") {
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(cardRadiusDp))
                    .background(LocalTsColors.current.panel)
                    .padding(Space.m),
                verticalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                Text(
                    "Bring the review into tokenstat",
                    style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                    color = LocalTsColors.current.textPrimary,
                )
                Text(
                    "Read the conversation, inspect the same diff as Changes, follow checks, and review without losing the workspace around it.",
                    style = TextStyle(fontSize = 12.sp),
                    color = LocalTsColors.current.textSecondary,
                )
                Text(
                    "tokenstat only sees repositories selected for its GitHub App installation.",
                    style = TextStyle(fontSize = 12.sp),
                    color = LocalTsColors.current.textSecondary,
                )
            }
            return
        }
        if (error != null) {
            StickyErrorCard(
                message = error!!,
                onRetry = { scope.launch { load() } },
                onDismiss = { error = null },
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            pullScopes.forEach { (label, value) ->
                if (value == scopeName) {
                    TsAccentButton(label = label, small = true, onClick = {})
                } else {
                    TsSecondaryButton(label = label, small = true, onClick = { scopeName = value })
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            pullStates.forEach { (label, value) ->
                if (value == stateName) {
                    TsAccentButton(label = label, small = true, onClick = {})
                } else {
                    TsSecondaryButton(label = label, small = true, onClick = { stateName = value })
                }
            }
        }
        Text(
            "${pulls.size} shown",
            style = TextStyle(fontSize = 12.sp),
            color = LocalTsColors.current.textSecondary,
        )
        if (loading) { CircularProgressIndicator(Modifier, strokeWidth = 2.dp); return }
        if (pulls.isEmpty() && error == null) {
            EmptyState(Icons.Default.ChatBubbleOutline, "No open pulls", "Connect GitHub on the host to review here.")
            return
        }
        LazyColumn(contentPadding = PaddingValues(bottom = TabBarChrome.contentBottomInset), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(pulls, key = { it.get("number")?.jsonPrimitive?.longOrNull?.toString() ?: it.hashCode().toString() }) { pr ->
                val number = pr.get("number")?.jsonPrimitive?.longOrNull ?: return@items
                TsCard(Modifier.clickable { openNumber = number }) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(
                            "#$number ${pr.str("title") ?: ""}",
                            style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium),
                            color = LocalTsColors.current.textPrimary,
                        )
                        Text(
                            "${pr.str("headRef") ?: pr.str("head") ?: ""} → ${pr.str("baseRef") ?: pr.str("base") ?: ""}",
                            style = TsType.mono(12),
                            color = LocalTsColors.current.textSecondary,
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            pr.get("additions")?.jsonPrimitive?.longOrNull?.let {
                                Text("+$it", style = TsType.numeric(12), color = LocalTsColors.current.diffAdded)
                            }
                            pr.get("deletions")?.jsonPrimitive?.longOrNull?.let {
                                Text("−$it", style = TsType.numeric(12), color = LocalTsColors.current.diffRemoved)
                            }
                            pr.get("changedFiles")?.jsonPrimitive?.longOrNull?.let {
                                Text("$it files", style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                            }
                            pr.str("state")?.takeIf { it.isNotBlank() }?.let {
                                Text(it, style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                            }
                            if (pr.bol("draft")) {
                                Text("Draft", style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A file chosen in the composer and not yet sent. The bytes are carried as
/// base64 because that is what `chat.attach` takes, and they are held only
/// until the message goes.
data class StagedAttachment(
    val name: String,
    val data: String,
    val mediaType: String?,
    val bytes: Int,
)

/// What reading a picked file produced. A failure carries a sentence rather
/// than an exception: the composer shows it and the person picks again.
sealed interface AttachmentRead {
    data class Ok(val attachment: StagedAttachment) : AttachmentRead

    data class Failed(val reason: String) : AttachmentRead
}

/// The host refuses anything larger, so refuse it here instead of spending a
/// person's connection on a transfer that cannot land. Matches
/// `ATTACHMENT_CAP` in `tokenstat-host::chat`.
private const val ATTACHMENT_CAP = 12 * 1024 * 1024

/// Read one picked document into a staged attachment.
///
/// Off the main thread: a picked file can be megabytes, and both the read and
/// the base64 pass are long enough to drop frames.
internal fun readAttachment(context: android.content.Context, uri: android.net.Uri, byteLimit: Int = ATTACHMENT_CAP): AttachmentRead {
    val resolver = context.contentResolver
    val name = runCatching {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }.getOrNull() ?: uri.lastPathSegment ?: "Attachment"
    val bytes = try {
        resolver.openInputStream(uri)?.use { it.readBounded(byteLimit) }
            ?: return AttachmentRead.Failed("$name could not be read.")
    } catch (_: InputLimitExceeded) {
        return AttachmentRead.Failed(if (byteLimit < ATTACHMENT_CAP)
            "Send or remove the staged files before adding $name (24 MB total)."
        else "$name is larger than 12 MB, which is the most a chat can carry.")
    } catch (_: Exception) {
        return AttachmentRead.Failed("$name could not be read.")
    }
    if (bytes.isEmpty()) return AttachmentRead.Failed("$name is empty.")
    if (bytes.size > ATTACHMENT_CAP) {
        return AttachmentRead.Failed("$name is larger than 12 MB, which is the most a chat can carry.")
    }
    return AttachmentRead.Ok(
        StagedAttachment(
            name = name,
            data = Base64.encodeToString(bytes, Base64.NO_WRAP),
            mediaType = runCatching { resolver.getType(uri) }.getOrNull(),
            bytes = bytes.size,
        ),
    )
}

/// The turn in progress, with the conversation's own face at the same left
/// edge as an agent reply. Port of `ChatWorkingIndicator`.
@Composable
private fun ChatWorkingIndicator(seed: ULong, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = Space.m, vertical = Space.xs),
    ) {
        PersonaMark(seed = seed, size = 26.dp)
        Text(
            "Thinking…",
            style = TsType.caption,
            color = colors.textSecondary,
        )
    }
}

/// The docked composer, built like the one on iPhone: what the message will
/// be answered by on top, then how much rope the agent has, then the field
/// itself with the paperclip beside it.
///
/// The controls are above the field rather than behind a menu because they
/// change what the next message does. Plan against Execute is the difference
/// between being told and being acted on, and that is not a preference to go
/// hunting for.
@Composable
private fun ChatComposer(
    chat: JsonObject?,
    draft: String,
    onDraft: (String) -> Unit,
    hint: String,
    sending: Boolean,
    staged: List<StagedAttachment>,
    onPick: () -> Unit,
    onRemove: (StagedAttachment) -> Unit,
    onSend: () -> Unit,
    onStop: () -> Unit,
    onChange: (String, String) -> Unit,
    backends: List<JsonObject>,
    onAgent: () -> Unit,
    /// What a new conversation would open in, for the moment before one is
    /// selected. See `LaunchDefaults`.
    launchMode: String,
    /// Whether this device can reach the host at all.
    offline: Boolean = false,
    /// Keep the draft and send it once there is a connection again.
    onQueueWhenConnected: () -> Unit = {},
) {
    val colors = LocalTsColors.current
    // A conversation says what mode it is in. With none open yet, this reads
    // what a new one would open in, which is the last choice and never plan.
    val mode = chat?.str("mode")?.ifBlank { null } ?: launchMode
    // The value is "standard", not "ask": the host only treats "standard"
    // as ask-with-approvals, and anything else that is not "bypass" runs
    // without the approval plumbing. The label stays Ask.
    val autonomy = if (chat?.str("autonomy") == "bypass") "bypass" else "standard"
    // An agent with no approval protocol of its own runs on Bypass or not at
    // all. Twin of `isBypassOnly` in `ChatSetupHeader.swift`.
    val bypassOnly = chatAgentForcesBypass(backends, chat?.str("backend").orEmpty())
    // The host refuses a setup change while a turn is running, so the pills
    // say so rather than accepting a press it will reject. `sending` alone
    // was this screen's own flag and went false long before the turn did.
    val locked = sending || chat?.bol("running") == true
    // An agent that can only run on Bypass is put on it, the way the Apple
    // header enforces it on appear and on every change of agent.
    LaunchedEffect(bypassOnly, autonomy, locked) {
        if (bypassOnly && autonomy != "bypass" && !locked) onChange("autonomy", "bypass")
    }
    // Five lines is the right height for a message and the wrong one for a
    // brief. The toggle sits at the top right of the bar, away from send,
    // the way the iPhone composer grows its field.
    var expanded by remember { mutableStateOf(false) }
    val keyboard = LocalSoftwareKeyboardController.current
    val focus = LocalFocusManager.current
    TsCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            // Nothing can be sent right now, so the offer is to keep it. The
            // twin of the button `ClientChatComposer` shows over a saved copy.
            if (offline) {
                TsSecondaryButton(
                    label = "Send when connected",
                    icon = ActionIcon.Scheduled.vector,
                    small = true,
                    enabled = draft.isNotBlank(),
                    onClick = onQueueWhenConnected,
                )
            }
            // Agent, model and effort in one line, which opens the picker
            // holding exactly those three. The same field the iPhone puts in
            // its composer: the settings that change what the next message
            // does are one tap away, not behind the whole setup screen.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.xs),
                modifier = Modifier.fillMaxWidth(),
            ) {
                TsPickerField(
                    summary = chatAgentSummary(backends, chat),
                    onOpen = onAgent,
                    enabled = !sending,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = { expanded = !expanded }) {
                    Icon(
                        if (expanded) ActionIcon.ExitFullScreen.vector else ActionIcon.EnterFullScreen.vector,
                        if (expanded) "Shrink the message box" else "Expand the message box",
                        tint = colors.accent,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                ChatSegmented(
                    options = listOf("plan" to "Plan", "execute" to "Execute"),
                    selected = mode,
                    enabled = !locked,
                    onSelect = { onChange("mode", it) },
                    modifier = Modifier.weight(1f),
                )
                if (bypassOnly) {
                    // One option, same control. A lone capsule would read as
                    // something else beside the mode pills, while this is the
                    // same control with its choice made by the agent. Never
                    // enabled: there is nothing to switch to.
                    ChatSegmented(
                        options = listOf("bypass" to "Bypass"),
                        selected = "bypass",
                        enabled = false,
                        onSelect = {},
                        modifier = Modifier.weight(1f),
                    )
                } else {
                    ChatSegmented(
                        options = listOf("standard" to "Ask", "bypass" to "Bypass"),
                        selected = autonomy,
                        enabled = !locked,
                        onSelect = { onChange("autonomy", it) },
                        modifier = Modifier.weight(1f),
                    )
                }
            }
            // Staged files sit above the field, each with its own way out, so
            // a wrong pick is one tap to undo rather than a sent message.
            staged.forEach { attachment ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.xs),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(cardRadiusDp))
                        .background(colors.accentSoft)
                        .padding(horizontal = Space.s, vertical = 6.dp),
                ) {
                    Icon(ActionIcon.Attach.vector, null, tint = colors.accent, modifier = Modifier.size(15.dp))
                    Text(
                        attachment.name,
                        style = TsType.caption,
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    Text(attachmentSize(attachment.bytes), style = TsType.caption2, color = colors.textSecondary)
                    IconButton(onClick = { onRemove(attachment) }, modifier = Modifier.size(24.dp)) {
                        Icon(
                            ActionIcon.Dismiss.vector,
                            "Remove ${attachment.name}",
                            tint = colors.textSecondary,
                            modifier = Modifier.size(15.dp),
                        )
                    }
                }
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.xs),
            ) {
                IconButton(onClick = onPick, enabled = !sending) {
                    Icon(
                        ActionIcon.Attach.vector,
                        "Attach a file",
                        tint = if (sending) colors.textTertiary else colors.accent,
                    )
                }
                OutlinedTextField(
                    draft,
                    onDraft,
                    Modifier.weight(1f),
                    placeholder = { Text(hint) },
                    maxLines = if (expanded) 18 else 5,
                )
                if (sending) {
                    IconButton(onClick = onStop) {
                        Icon(ActionIcon.Stop.vector, "Stop", tint = colors.danger)
                    }
                } else {
                    IconButton(
                        onClick = {
                            // The answer is the point of sending, and it
                            // arrives under the keyboard. Twin of
                            // `ClientChatComposer.sendTapped`, which puts the
                            // keyboard away before it sends.
                            keyboard?.hide()
                            focus.clearFocus()
                            expanded = false
                            onSend()
                        },
                        enabled = draft.isNotBlank() || staged.isNotEmpty(),
                    ) {
                        Icon(
                            ActionIcon.Send.vector,
                            "Send",
                            tint = if (draft.isNotBlank() || staged.isNotEmpty()) colors.accent else colors.textTertiary,
                        )
                    }
                }
            }
        }
    }
}

private fun attachmentSize(bytes: Int): String = when {
    bytes >= 1024 * 1024 -> "%.1f MB".format(bytes / (1024.0 * 1024.0))
    bytes >= 1024 -> "${bytes / 1024} KB"
    else -> "$bytes B"
}

/// Two choices, one of them on. The iOS composer's paired controls: a
/// bordered capsule with the live half filled, rather than a switch, because
/// neither side is the "off" one.
@Composable
private fun ChatSegmented(
    options: List<Pair<String, String>>,
    selected: String,
    enabled: Boolean,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalTsColors.current
    // Its own outline. Two borderless pairs side by side on the same card
    // read as one four-way control, and "Execute Ask" is not a thing anyone
    // should have to work out is two answers.
    Row(
        modifier
            .clip(RoundedCornerShape(10.dp))
            .border(1.dp, colors.border, RoundedCornerShape(10.dp))
            .padding(2.dp),
    ) {
        options.forEach { (value, label) ->
            val on = value == selected
            Box(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (on) colors.accentSoft else Color.Transparent)
                    .clickable(enabled = enabled && !on) { onSelect(value) }
                    .padding(vertical = 7.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label,
                    style = TsType.caption.copy(
                        fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                    ),
                    color = when {
                        on -> colors.accent
                        enabled -> colors.textSecondary
                        else -> colors.textTertiary
                    },
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}
