// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.core.CoreFailure
import ai.tokenstat.tokenstat.ui.components.*
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

/** Local discovery needs neither directory access nor a reachable publisher.
 * No request is resent, forgotten or turned into a new review by listing it. */
@Composable internal fun TeamAskRecoveryList(storage: TeamAskRecoveryStore, calls: TeamCalls, onBack: () -> Unit) {
    val scope = rememberCoroutineScope(); val colors = LocalTsColors.current
    var entries by remember(storage, calls) { mutableStateOf<List<TeamAskRecoveryStore.Entry>>(emptyList()) }
    var next by remember(storage, calls) { mutableStateOf<String?>(null) }
    var busy by remember(storage, calls) { mutableStateOf(false) }
    var loaded by remember(storage, calls) { mutableStateOf(false) }
    var unreadable by remember(storage, calls) { mutableStateOf(false) }
    var error by remember(storage, calls) { mutableStateOf(false) }
    suspend fun load(more: Boolean) {
        if (busy) return
        busy = true; error = false
        try {
            val origin = calls.origin ?: error("account_changed"); val person = calls.person ?: error("account_changed")
            val page = withContext(Dispatchers.IO) { storage.list(origin, person, if (more) next else null) }
            entries = if (more) (entries + page.entries).distinctBy { it.target } else page.entries
            next = page.next; unreadable = (more && unreadable) || page.unreadable; loaded = true
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { error = true }
        finally { busy = false }
    }
    LaunchedEffect(storage, calls) { load(false) }
    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TsSecondaryButton(L10n.text("common.back"), icon = ActionIcon.Back.vector, onClick = onBack)
        Text(L10n.text("common.teams.saved_asks"), style = TsType.cardTitle, color = colors.textPrimary)
        Text(L10n.text("common.teams.saved_asks_detail"), color = colors.textSecondary)
        if (error || unreadable) Text(L10n.text("common.teams.saved_asks_unreadable"), color = colors.warning)
        TsSecondaryButton(L10n.text("common.refresh"), enabled = !busy, icon = ActionIcon.Refresh.vector, onClick = { scope.launch { load(false) } })
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (loaded && entries.isEmpty() && next == null && !unreadable) item { Text(L10n.text("common.teams.no_saved_asks")) }
            items(entries, key = { it.target.toString() }) { entry ->
                key(entry.snapshot.saved.revision) { SavedAskRow(storage, calls, entry) }
            }
            if (next != null) item { TsSecondaryButton(L10n.text("common.teams.load_more"), enabled = !busy, icon = ActionIcon.More.vector, onClick = { scope.launch { load(true) } }) }
        }
    }
}

@Composable private fun SavedAskRow(storage: TeamAskRecoveryStore, calls: TeamCalls, entry: TeamAskRecoveryStore.Entry) {
    val scope = rememberCoroutineScope(); val clipboard = LocalClipboard.current; val colors = LocalTsColors.current
    var opened by remember { mutableStateOf(false) }
    var active by remember { mutableStateOf(true) }
    DisposableEffect(Unit) { onDispose { active = false } }
    val model = remember(storage, calls, entry.target) {
        TeamAskModel(storage, entry.target, entry.snapshot.saved.label) { method, input ->
            if (!active) throw CancellationException()
            val t = entry.target
            require(t.origin == calls.origin && t.person == calls.person)
            require(method in setOf("team.chat.ask", "team.chat.ask.status", "team.chat.ask.stop"))
            try {
                calls.call("teams.ask", buildJsonObject {
                    put("target", buildJsonObject { put("organization", t.organization); put("repository", t.repository); put("checkout", t.checkout); put("share", t.share) })
                    put("method", method); put("params", input)
                }).also { if (!active) throw CancellationException() }
            } catch (failure: CoreFailure) {
                if (method == "team.chat.ask" && failure.code in setOf("team_run_review_changed", "invalid_ask")) throw TeamAskNotAccepted(failure.message.orEmpty())
                throw failure
            }
        }
    }
    TsCard(title = entry.snapshot.saved.label.ifBlank { L10n.text("common.teams.saved_asks") }) {
        Text(entry.snapshot.record.text, color = colors.textPrimary)
        TsSecondaryButton(L10n.text("common.teams.copy_ask"), icon = ActionIcon.Copy.vector, onClick = {
            scope.launch { clipboard.setClipEntry(ClipEntry(android.content.ClipData.newPlainText("", entry.snapshot.record.text))) }
        })
        if (!opened) TsSecondaryButton(L10n.text("common.teams.recover_ask"), icon = ActionIcon.Restore.vector, onClick = {
            opened = true; scope.launch { model.restore() }
        })
        else {
            model.error?.let { Text(askMessage(it, entry.snapshot.saved.label), color = colors.warning) }
            if (model.fence != null) {
                TsSecondaryButton(L10n.text("common.refresh"), enabled = !model.busy, icon = ActionIcon.Refresh.vector, onClick = { scope.launch { model.check() } })
                TsSecondaryButton(L10n.text("common.teams.stop_agent"), enabled = !model.stopping, icon = ActionIcon.Stop.vector, onClick = { scope.launch { model.stop() } })
            } else if (model.pending) TsAccentButton(L10n.text("common.teams.retry_same_ask"), enabled = model.canAsk, icon = ActionIcon.Run.vector, onClick = { scope.launch { model.ask() } })
            else if (model.loaded) Text(L10n.text("common.teams.ask_resolved"), color = colors.textSecondary)
            if (!model.loaded) TsSecondaryButton(L10n.text("common.teams.load_saved_ask"), enabled = !model.busy, icon = ActionIcon.Refresh.vector, onClick = { scope.launch { model.restore(true) } })
        }
    }
}
