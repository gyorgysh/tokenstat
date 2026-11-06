// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import ai.tokenstat.tokenstat.notifications.PushRegistrar
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@Composable
internal fun DeviceNotificationsCard(
    readEnabled: () -> Boolean = { PushRegistrar.isOn() },
    updateEnabled: suspend (Boolean) -> Unit = { if (it) PushRegistrar.enable() else PushRegistrar.disable() },
    sendTest: suspend () -> String? = { PushRegistrar.test() },
    notificationAccess: (Context) -> Boolean = { NotificationManagerCompat.from(it).areNotificationsEnabled() },
) {
    val context = LocalContext.current
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    var enabled by remember { mutableStateOf(readEnabled()) }
    var allowed by remember { mutableStateOf(notificationAccess(context)) }
    var declined by rememberSaveable { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    ForegroundEffect {
        allowed = notificationAccess(context)
        enabled = readEnabled()
    }
    fun change(on: Boolean) {
        busy = true
        scope.launch {
            try {
                updateEnabled(on)
                error = null
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                error = failure.message
            } finally {
                enabled = readEnabled()
                busy = false
            }
        }
    }
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        allowed = notificationAccess(context)
        declined = !granted
        if (granted && allowed) change(true) else busy = false
    }
    TsCard(title = L10n.text("android.tokenstatapp.notifications.78801183"), mark = "mark_device") {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                val label = L10n.text("android.tokenstatapp.notify_this_device.961006a8")
                Text(label,
                    style = TsType.body, color = colors.textPrimary, modifier = Modifier.weight(1f))
                TsBrandSwitch(checked = enabled, enabled = !busy, modifier = Modifier.semantics { contentDescription = label }, onCheckedChange = { on ->
                    allowed = notificationAccess(context)
                    if (!on || allowed) {
                        change(on)
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        busy = true
                        request.launch(Manifest.permission.POST_NOTIFICATIONS)
                    } else {
                        declined = true
                    }
                })
            }
            Text(L10n.text("android.tokenstatapp.when_an_agent_run_or_a_chat_on_one_of_your.210bf09c"),
                style = TsType.caption, color = colors.textSecondary)
            if (!allowed && (enabled || declined)) {
                Text(L10n.text("android.notifications.permission_blocked"), style = TsType.caption, color = colors.warning)
                TsSecondaryButton(label = L10n.text("android.notifications.open_settings"), icon = ActionIcon.Settings.vector,
                    small = true, onClick = {
                        runCatching {
                            context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName))
                        }.onFailure { error = it.message }
                    })
            }
            if (enabled && allowed) {
                TsSecondaryButton(label = L10n.text("android.tokenstatapp.send_a_test.edc01436"),
                    icon = ActionIcon.Send.vector, small = true, onClick = {
                        if (!busy) scope.launch {
                            busy = true
                            try { error = sendTest() }
                            catch (cancelled: CancellationException) { throw cancelled }
                            catch (failure: Exception) { error = failure.message }
                            finally { busy = false }
                        }
                    })
            }
            error?.let { Text(it, style = TsType.caption, color = colors.warning) }
        }
    }
}
