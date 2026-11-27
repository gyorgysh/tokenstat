// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat

import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.view.View
import android.view.ViewTreeObserver
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.annotation.RequiresApi
import androidx.core.view.WindowCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import ai.tokenstat.tokenstat.notifications.NotificationOpen
import ai.tokenstat.tokenstat.notifications.VisibleChat
import ai.tokenstat.tokenstat.ui.TokenstatApp
import ai.tokenstat.tokenstat.ui.logic.SplashHold
import ai.tokenstat.tokenstat.ui.theme.AppAppearance

class MainActivity : ComponentActivity() {
    private val model: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        val launchedAt = SystemClock.uptimeMillis()
        super.onCreate(savedInstanceState)
        AppAppearance.load(this)
        setTheme(R.style.Theme_Tokenstat)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            installLaunchSplash(launchedAt)
        }
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (savedInstanceState == null) {
            NotificationOpen.offerFromIntent(intent)
            ai.tokenstat.tokenstat.ecosystem.QuickAccess.offer(intent)
        }
        setContent { TokenstatApp(model) }
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private fun installLaunchSplash(launchedAt: Long) {
        splashScreen.setOnExitAnimationListener { splashView ->
            val animationsOff = Settings.Global.getFloat(
                contentResolver,
                Settings.Global.ANIMATOR_DURATION_SCALE,
                1f,
            ) == 0f
            if (animationsOff) {
                splashView.remove()
                return@setOnExitAnimationListener
            }
            splashView.animate()
                .alpha(0f)
                .setDuration(SplashHold.exitMs)
                .withEndAction { splashView.remove() }
                .start()
        }
        val content: View = findViewById(android.R.id.content)
        content.viewTreeObserver.addOnPreDrawListener(object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                if (!SplashHold.hold(SystemClock.uptimeMillis() - launchedAt)) {
                    content.viewTreeObserver.removeOnPreDrawListener(this)
                    return true
                }
                content.postInvalidateOnAnimation()
                return false
            }
        })
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        NotificationOpen.offerFromIntent(intent)
        ai.tokenstat.tokenstat.ecosystem.QuickAccess.offer(intent)
        model.refresh()
    }

    override fun onStop() {
        super.onStop()
        VisibleChat.hidden()
        model.chatDrafts.flush()
    }

    override fun onResume() {
        super.onResume()
        if (model.state.value.signedIn) {
            lifecycleScope.launch { model.nudgeTunnelOnForeground() }
        }
    }
}
