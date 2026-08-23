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
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class TokenstatMessagingService : FirebaseMessagingService() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onNewToken(token: String) {
        PushRegistrar.persist(token)
        serviceScope.launch { PushRegistrar.refresh() }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Agent updates", NotificationManager.IMPORTANCE_DEFAULT)
        )
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            message.data["route"]?.let { putExtra("route", it) }
        }
        val pending = PendingIntent.getActivity(
            this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val title = message.notification?.title ?: message.data["title"] ?: "tokenstat"
        val body = message.notification?.body ?: message.data["body"] ?: "One of your agents needs attention."
        manager.notify(
            message.messageId?.hashCode() ?: body.hashCode(),
            NotificationCompat.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(body)
                .setAutoCancel(true)
                .setContentIntent(pending)
                .build(),
        )
    }

    private companion object { const val CHANNEL = "agent-updates" }
}
