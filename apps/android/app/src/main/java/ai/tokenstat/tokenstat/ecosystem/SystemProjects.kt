// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.util.AtomicFile
import androidx.appsearch.app.*
import androidx.appsearch.localstorage.LocalStorage
import androidx.appsearch.platformstorage.PlatformStorage
import ai.tokenstat.tokenstat.MainActivity
import ai.tokenstat.tokenstat.R
import java.security.MessageDigest
import kotlinx.coroutines.*
import com.google.common.util.concurrent.ListenableFuture
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*

@Serializable
data class SystemProject(val id: String, val owner: String, val hostId: String, val peer: String,
                         val workspaceId: String, val name: String, val hostName: String) {
    val uri: Uri get() = Uri.Builder().scheme("tokenstat").authority("project").appendPath(id)
        .appendQueryParameter("owner", owner).build()
}

/** Local metadata only. Serial publication prevents stale indexing from surviving logout. */
object SystemProjects {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private val json = Json { ignoreUnknownKeys = true }
    @Volatile var owner: String? = null; private set
    @Volatile private var generation = 0L
    @Volatile private var projects = emptyList<SystemProject>()
    @Volatile private var publication: Job? = null
    private var machines = emptyMap<String, Pair<String, String>>()
    private fun file(context: Context) = AtomicFile(context.noBackupFilesDir.resolve("system-projects.json"))
    private fun digest(text: String) = MessageDigest.getInstance("SHA-256").digest(text.toByteArray())
        .joinToString("") { "%02x".format(it) }
    private fun peerValid(peer: String) = peer.matches(Regex("[0-9a-f]{64}"))
    private fun workspaceValid(id: String) = id.isNotBlank() && id.toByteArray(Charsets.UTF_8).size <= 256
    private fun JsonObject.text(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull.orEmpty()

    @Synchronized fun verify(context: Context, account: JsonObject) {
        val next = UsageSnapshot.owner(account)
        if (owner != next) {
            if (owner != null) SystemShare.clear()
            generation++; owner = next; projects = emptyList()
        }
        machines = (account["machines"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
            .filter { it.text("trustState") != "revoked" && peerValid(it.text("publicIdentity"))
                && it.text("id").isNotBlank() && it.text("id").length <= 128 }
            .associate { it.text("publicIdentity") to (it.text("id") to it.text("label")) }
        if (next == null) { clear(context); return }
        if (projects.isEmpty()) projects = runCatching {
            file(context).openRead().use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(output.size() + count <= 256 * 1024)
                    output.write(buffer, 0, count)
                }
                val bytes = output.toByteArray()
                json.decodeFromString<List<SystemProject>>(bytes.toString(Charsets.UTF_8))
            }
        }.getOrDefault(emptyList())
        projects = projects.filter { it.owner == next && machines.containsKey(it.peer) && workspaceValid(it.workspaceId)
            && it.name.isNotBlank() && it.name.length <= 120 && it.id == digest("$next\u0000${it.peer}\u0000${it.workspaceId}")
        }.distinctBy { it.id }.take(100).map { project ->
            val machine = machines.getValue(project.peer)
            project.copy(hostId = machine.first, hostName = machine.second.take(120))
        }
        publish(context)
    }
    @Synchronized fun clear(context: Context) {
        generation++; owner = null; machines = emptyMap(); projects = emptyList()
        runCatching { file(context).delete() }
        SystemShare.clear()
        publish(context)
    }
    @Synchronized fun replace(context: Context, peer: String, folders: JsonArray, observed: String?) {
        if (observed == null || observed != owner) return
        val machine = machines[peer] ?: return
        val fresh = folders.take(100).mapNotNull { it as? JsonObject }.mapNotNull { folder ->
            val id = folder.text("id"); val name = folder.text("name").take(120)
            if (!workspaceValid(id) || name.isBlank() || (folder["exists"] as? JsonPrimitive)?.booleanOrNull == false) null
            else SystemProject(digest("$observed\u0000$peer\u0000$id"), observed, machine.first, peer, id, name, machine.second.take(120))
        }
        projects = (projects.filter { it.peer != peer } + fresh).distinctBy { it.id }.take(100)
        publish(context)
    }
    fun find(id: String, expectedOwner: String? = owner): SystemProject? =
        projects.firstOrNull { owner != null && it.owner == owner && (expectedOwner == null || it.owner == expectedOwner) && it.id == id }
    fun search(query: String): List<SystemProject> = projects.filter {
        it.owner == owner && (query.isBlank() || it.name.contains(query.trim(), true) || it.hostName.contains(query.trim(), true))
    }.take(20)
    fun openIntent(context: Context, project: SystemProject) = Intent(context, MainActivity::class.java).apply {
        action = Intent.ACTION_VIEW; data = project.uri
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
    }
    fun pin(context: Context, id: String): Boolean = runCatching {
        val project = find(id) ?: return false
        val manager = context.getSystemService(ShortcutManager::class.java) ?: return false
        manager.isRequestPinShortcutSupported && manager.requestPinShortcut(shortcut(context, project, 0), null)
    }.getOrDefault(false)
    fun idFor(peer: String, workspace: String): String? = projects.firstOrNull { it.owner == owner && it.peer == peer && it.workspaceId == workspace }?.id
    @Synchronized fun opened(context: Context, peer: String, workspace: String) {
        val project = projects.firstOrNull { it.owner == owner && it.peer == peer && it.workspaceId == workspace } ?: return
        if (projects.firstOrNull() == project) return
        projects = listOf(project) + projects.filter { it.id != project.id }
        runCatching { context.getSystemService(ShortcutManager::class.java)?.reportShortcutUsed("project.${project.id}") }
        publish(context)
    }

    private fun shortcut(context: Context, project: SystemProject, rank: Int) = ShortcutInfo.Builder(context, "project.${project.id}")
        .setShortLabel(project.name).setLongLabel("${project.name} · ${project.hostName}".take(160))
        .setIcon(Icon.createWithResource(context, R.drawable.ic_notification))
        .setIntent(openIntent(context, project)).setCategories(setOf("ai.tokenstat.project.share"))
        .setRank(rank).apply { if (Build.VERSION.SDK_INT >= 29) setLongLived(true) }.build()

    private fun publish(context: Context) {
        val app = context.applicationContext
        val observed = ++generation
        val snapshot = projects
        publication = scope.launch {
            mutex.withLock {
                if (observed != generation) return@withLock
                val atomic = file(app)
                runCatching {
                    if (snapshot.isEmpty()) atomic.delete() else {
                        val output = atomic.startWrite()
                        try {
                            val bytes = json.encodeToString(snapshot).toByteArray()
                            require(bytes.size <= 256 * 1024)
                            output.write(bytes); atomic.finishWrite(output)
                        }
                        catch (error: Exception) { atomic.failWrite(output); throw error }
                    }
                }
                if (observed != generation) { atomic.delete(); return@withLock }
                runCatching {
                    val manager = app.getSystemService(ShortcutManager::class.java) ?: return@runCatching
                    val known = if (Build.VERSION.SDK_INT >= 30) manager.getShortcuts(ShortcutManager.FLAG_MATCH_DYNAMIC or ShortcutManager.FLAG_MATCH_PINNED or ShortcutManager.FLAG_MATCH_CACHED) else manager.pinnedShortcuts + manager.dynamicShortcuts
                    val stale = known.filter { it.id.startsWith("project.") && snapshot.none { p -> "project.${p.id}" == it.id } }
                    if (stale.isNotEmpty()) manager.disableShortcuts(stale.map { it.id })
                    if (Build.VERSION.SDK_INT >= 30) manager.removeLongLivedShortcuts(stale.map { it.id })
                    manager.removeDynamicShortcuts(stale.map { it.id })
                    manager.enableShortcuts(snapshot.map { "project.${it.id}" })
                    // Manifest shortcuts share the launcher's per-activity limit.
                    val limit = (manager.maxShortcutCountPerActivity - manager.manifestShortcuts.size).coerceAtLeast(0)
                    val targets = snapshot.take(limit).mapIndexed { rank, project -> shortcut(app, project, rank) }
                    fun same(left: ShortcutInfo, right: ShortcutInfo) = left.id == right.id && left.rank == right.rank
                        && left.shortLabel?.toString() == right.shortLabel?.toString()
                        && left.longLabel?.toString() == right.longLabel?.toString()
                        && left.intent?.filterEquals(right.intent) == true
                    val dynamic = manager.dynamicShortcuts
                    val changed = targets.size != dynamic.size || targets.any { target -> dynamic.none { same(it, target) } }
                    val updates = snapshot.mapIndexed { rank, project -> shortcut(app, project, rank) }
                        .filter { target -> known.any { it.id == target.id && !same(it, target) } }
                    // A throttled replacement must leave existing valid shortcuts intact. Cleanup above is not throttled.
                    if (!manager.isRateLimitingActive) {
                        if (changed) manager.setDynamicShortcuts(targets)
                        if (updates.isNotEmpty()) manager.updateShortcuts(updates)
                    }
                }
                index(app, snapshot, observed)
            }
        }
    }
    /** Await best-effort removal before logout returns; restricted devices never block sign-out. */
    suspend fun flush() { withTimeoutOrNull(5_000) { publication?.join() } }

    private suspend fun index(context: Context, snapshot: List<SystemProject>, observed: Long) {
        var session: AppSearchSession? = null
        try {
            session = if (Build.VERSION.SDK_INT >= 31) runCatching {
                PlatformStorage.createSearchSessionAsync(PlatformStorage.SearchContext.Builder(context, "tokenstat-projects").build()).await()
            }.getOrNull() else null
            val active = session ?: LocalStorage.createSearchSessionAsync(LocalStorage.SearchContext.Builder(context, "tokenstat-projects").build()).await()
            session = active
            val schema = AppSearchSchema.Builder("Project")
                .addProperty(AppSearchSchema.StringPropertyConfig.Builder("name").setCardinality(AppSearchSchema.PropertyConfig.CARDINALITY_OPTIONAL)
                    .setTokenizerType(AppSearchSchema.StringPropertyConfig.TOKENIZER_TYPE_PLAIN).setIndexingType(AppSearchSchema.StringPropertyConfig.INDEXING_TYPE_PREFIXES).build())
                .addProperty(AppSearchSchema.StringPropertyConfig.Builder("host").setCardinality(AppSearchSchema.PropertyConfig.CARDINALITY_OPTIONAL)
                    .setTokenizerType(AppSearchSchema.StringPropertyConfig.TOKENIZER_TYPE_PLAIN).setIndexingType(AppSearchSchema.StringPropertyConfig.INDEXING_TYPE_PREFIXES).build())
                .addProperty(AppSearchSchema.StringPropertyConfig.Builder("url").setCardinality(AppSearchSchema.PropertyConfig.CARDINALITY_OPTIONAL).build()).build()
            active.setSchemaAsync(SetSchemaRequest.Builder().addSchemas(schema).setSchemaTypeDisplayedBySystem("Project", true).build()).await()
            active.removeAsync("", SearchSpec.Builder().build()).await()
            if (observed == generation && snapshot.isNotEmpty()) active.putAsync(PutDocumentsRequest.Builder().addGenericDocuments(snapshot.map {
                GenericDocument.Builder<GenericDocument.Builder<*>>(it.owner, it.id, "Project")
                    .setTtlMillis(24 * 60 * 60 * 1000L)
                    .setPropertyString("name", it.name).setPropertyString("host", it.hostName).setPropertyString("url", it.uri.toString()).build()
            }).build()).await()
            // Account changes may happen while IPC is suspended. Remove any late publication before releasing the serial writer.
            if (observed != generation) active.removeAsync("", SearchSpec.Builder().build()).await()
            active.requestFlushAsync().await()
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { /* Search integration is optional on restricted devices. */ }
        finally { session?.close() }
    }
    private suspend fun <T> ListenableFuture<T>.await(): T = suspendCancellableCoroutine { continuation ->
        addListener({
            if (continuation.isActive) {
                try { continuation.resume(get()) }
                catch (error: Exception) { continuation.resumeWithException(error.cause ?: error) }
            }
        }, java.util.concurrent.Executor { it.run() })
        continuation.invokeOnCancellation { cancel(false) }
    }
}
