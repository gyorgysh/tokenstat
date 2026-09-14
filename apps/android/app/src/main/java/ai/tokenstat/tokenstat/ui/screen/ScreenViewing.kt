// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import ai.tokenstat.tokenstat.R

/// The ongoing "watching" notice posted while the screen viewer is up.
///
/// A screen session keeps flowing while the phone sits in a pocket, and the
/// relay meters it. Saying so on screen is the honest counterpart of the
/// Apple viewer's keep-awake picture: this device is spending something.
/// Dismissed when the viewer closes. If notifications are not granted the
/// post is skipped rather than requested; viewing never depends on it.
object ScreenViewing {
    private const val CHANNEL = "screen-viewing"
    private const val ID = 41

    fun show(context: Context, hostLabel: String) {
        if (ActivityCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Screen viewing", NotificationManager.IMPORTANCE_LOW)
        )
        manager.notify(
            ID,
            NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Watching $hostLabel")
                .setContentText("The screen session is live and using data.")
                .setOngoing(true)
                .build(),
        )
    }

    fun hide(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(ID)
    }
}
