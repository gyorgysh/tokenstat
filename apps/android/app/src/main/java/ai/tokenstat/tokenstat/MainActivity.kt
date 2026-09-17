// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.view.View
import android.view.ViewTreeObserver
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import ai.tokenstat.tokenstat.notifications.NotificationOpen
import ai.tokenstat.tokenstat.notifications.VisibleChat
import ai.tokenstat.tokenstat.ui.TokenstatApp
import ai.tokenstat.tokenstat.ui.logic.SplashHold

class MainActivity : ComponentActivity() {
    private val model: AppViewModel by viewModels()
    private val askNotifications =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        val launchedAt = SystemClock.uptimeMillis()
        super.onCreate(savedInstanceState)
        // Back to the app theme for the content. The manifest holds the
        // launch theme so the system draws the animated bars before the
        // first frame; without that wiring this is a harmless no-op.
        setTheme(R.style.Theme_Tokenstat)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            installLaunchSplash(launchedAt)
        }
        enableEdgeToEdge()
        // Without this the agent-attention notifications are dropped in
        // silence on 13+, which is exactly the delivery the app exists for.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        // A notification tap carries the push reason plus the machine id and
        // nothing else. Chat reasons wait in NotificationOpen until the
        // workspaces screen can resolve them. Anything else is dropped here,
        // and the app simply opens. Fresh launches only: the activity keeps
        // its intent across recreation, so without this a rotation re-offers
        // an already consumed tap.
        if (savedInstanceState == null) NotificationOpen.offerFromIntent(intent)
        setContent { TokenstatApp(model) }
    }

    /// The animated cold-start splash: the bars rise staggered on the theme
    /// paper (see `splash_bars_animated`), held for the same minimum as the
    /// iOS `LaunchSplashView` and leaving with the door fade. Below Android
    /// 12 there is no system splash to hold, and the app opens directly on
    /// the loading mark like iOS.
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
        // Hold the first frame until the splash minimum elapses, so a hot
        // start is not a one-frame flash like the iOS minimum splash.
        val content: View = findViewById(android.R.id.content)
        content.viewTreeObserver.addOnPreDrawListener(object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                if (!SplashHold.hold(SystemClock.uptimeMillis() - launchedAt)) {
                    content.viewTreeObserver.removeOnPreDrawListener(this)
                    return true
                }
                // Returning false cancels this draw; schedule another pass
                // so the gate re-checks instead of stalling the first frame.
                content.postInvalidateOnAnimation()
                return false
            }
        })
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Every return to a live app re-reads the account. That covers both
        // a notification tap, which carries the push reason plus the machine
        // id and nothing else, and the sign-in callback: nothing about the
        // token travels through the redirect, the device-flow poll picks it
        // up on its next turn, and this refresh covers the case where it
        // already did while the browser was in front. The tap itself waits
        // in NotificationOpen until the workspaces screen resolves it.
        NotificationOpen.offerFromIntent(intent)
        model.refresh()
    }

    override fun onStop() {
        super.onStop()
        // Nobody is looking at a transcript now, so chat pushes notify
        // again. Without this a backgrounded app would keep swallowing the
        // finished-turn banner for whatever was last open.
        VisibleChat.hidden()
    }

    override fun onResume() {
        super.onResume()
        // The tunnel nudge for coming back to the foreground, port of the
        // `scenePhase` handler in `ClientRootView`. A fresh or suspended
        // process holds no tunnel session, and without this the first dial
        // fails with "tunnel session is not running". Signed in only, like
        // there: nudging while logged out would only plant a tunnel error.
        if (model.state.value.signedIn) {
            lifecycleScope.launch { model.nudgeTunnelOnForeground() }
        }
    }
}
