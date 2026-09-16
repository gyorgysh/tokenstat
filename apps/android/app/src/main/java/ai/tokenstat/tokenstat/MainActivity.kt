// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.core.content.ContextCompat
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import ai.tokenstat.tokenstat.ui.TokenstatApp

class MainActivity : ComponentActivity() {
    private val model: AppViewModel by viewModels()
    private val askNotifications =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Without this the agent-attention notifications are dropped in
        // silence on 13+, which is exactly the delivery the app exists for.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        setContent { TokenstatApp(model) }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        // Every return to a live app re-reads the account. That covers both
        // a notification tap, which carries the push reason plus the machine
        // id and nothing else, and the sign-in callback: nothing about the
        // token travels through the redirect, the device-flow poll picks it
        // up on its next turn, and this refresh covers the case where it
        // already did while the browser was in front.
        model.refresh()
    }
}
