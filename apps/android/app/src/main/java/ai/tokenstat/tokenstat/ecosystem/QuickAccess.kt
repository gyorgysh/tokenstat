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
    data class Request(val screen: String, val sequence: Long)
    private val pending = MutableStateFlow<Request?>(null)
    val request = pending.asStateFlow()
    fun offer(intent: Intent?) {
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
