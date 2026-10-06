// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.app.PendingIntent
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.quicksettings.TileService
import ai.tokenstat.tokenstat.MainActivity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

object QuickAccess {
    const val ACTION = "ai.tokenstat.tokenstat.OPEN_SCREEN"
    private const val EXTRA = "screen"
    private val screens = setOf("home", "workspaces", "insights", "machines", "ssh", "account", "search")
    data class Request(val screen: String, val sequence: Long, val projectId: String? = null, val owner: String? = null)
    private val pending = MutableStateFlow<Request?>(null)
    val request = pending.asStateFlow()
    fun offer(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND) {
            val destination = SystemShare.offer(intent) ?: return
            if (destination == "workspaces") pending.value = Request("workspaces", System.nanoTime())
            else pending.value = Request("workspaces", System.nanoTime(), destination.removePrefix("project."))
            return
        }
        val url = intent?.data
        if (intent?.action == Intent.ACTION_VIEW && url?.scheme == "tokenstat" && url.host == "project") {
            if (!url.isHierarchical || url.userInfo != null || url.port != -1 || url.fragment != null
                || url.queryParameterNames != setOf("owner") || url.getQueryParameters("owner").size != 1) return
            val id = url.pathSegments.singleOrNull()?.takeIf { it.matches(Regex("[0-9a-f]{64}")) } ?: return
            val owner = url.getQueryParameter("owner")?.takeIf { it.matches(Regex("[0-9a-f]{64}")) } ?: return
            pending.value = Request("workspaces", System.nanoTime(), id, owner)
            return
        }
        if (intent?.action != ACTION) return
        val screen = intent.getStringExtra(EXTRA)?.takeIf { it in screens } ?: return
        pending.value = Request(screen, System.nanoTime())
    }
    fun take(request: Request) { pending.compareAndSet(request, null) }
    fun intent(context: Context, screen: String) = Intent(context, MainActivity::class.java).apply {
        action = ACTION
        putExtra(EXTRA, screen.takeIf { it in screens } ?: "home")
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
    }
    fun pendingIntent(context: Context, screen: String): PendingIntent = PendingIntent.getActivity(
        context, screen.hashCode(), intent(context, screen), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

class WorkspacesTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        qsTile?.apply { state = android.service.quicksettings.Tile.STATE_INACTIVE; updateTile() }
    }
    override fun onClick() {
        super.onClick()
        val open = {
            if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(QuickAccess.pendingIntent(this, "workspaces"))
            else openLegacy()
        }
        if (isLocked) unlockAndRun(open) else open()
    }
    // Android 9–13 have no PendingIntent overload. The caller gates this
    // compatibility path so it cannot run on Android 14 or later.
    @SuppressLint("StartActivityAndCollapseDeprecated")
    @Suppress("DEPRECATION")
    private fun openLegacy() = startActivityAndCollapse(QuickAccess.intent(this, "workspaces"))
}
