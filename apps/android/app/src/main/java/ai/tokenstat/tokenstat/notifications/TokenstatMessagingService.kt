// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import androidx.core.app.NotificationCompat
import ai.tokenstat.tokenstat.MainActivity
import ai.tokenstat.tokenstat.R
import com.google.firebase.messaging.FirebaseMessagingService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/// Delivers pushes the server addressed to this device.
///
/// The payload carries a fixed reason plus a machine id only, never free
/// text: the banner is composed here from the reason, and anything off the
/// allowlist is dropped rather than rendered. Tapping a chat or waiting-run
/// delivery carries the machine id into the app so the refreshed directory
/// can resolve it; every other reason only informs.
class TokenstatMessagingService : FirebaseMessagingService() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onNewToken(token: String) {
        PushRegistrar.persist(token)
        serviceScope.launch { PushRegistrar.refresh() }
    }

    override fun onMessageReceived(message: com.google.firebase.messaging.RemoteMessage) {
        // The data map is the whole payload. A server-composed notification
        // body or title would be free text riding somebody else's server, so
        // both are ignored on purpose: only reason plus machine are read.
        val delivery = PushPayload.parse(message.data) ?: return
        if (VisibleChat.suppresses(delivery.reason, delivery.machine)) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Agent updates", NotificationManager.IMPORTANCE_DEFAULT),
        )
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_REASON, delivery.reason)
            delivery.machine?.let { putExtra(EXTRA_MACHINE, it) }
        }
        val pending = PendingIntent.getActivity(
            this,
            delivery.reason.hashCode() xor (delivery.machine?.hashCode() ?: 0),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        manager.notify(
            delivery.reason.hashCode() xor (delivery.machine?.hashCode() ?: 0),
            NotificationCompat.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(PushPayload.title(delivery.reason))
                .setContentText(PushPayload.body(delivery.reason))
                .setAutoCancel(true)
                .setContentIntent(pending)
                .build(),
        )
    }

    companion object {
        const val CHANNEL = "agent-updates"
        const val EXTRA_REASON = "ai.tokenstat.pushReason"
        const val EXTRA_MACHINE = "ai.tokenstat.pushMachine"
    }
}
