// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.theme

import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp

object Space {
    val xs = Dp(4f)
    val s = Dp(8f)
    val m = Dp(12f)
    val l = Dp(20f)
    val xl = Dp(32f)
}

val cardRadius = Dp(14f)

val cardPadding = Dp(16f)

object TsMotion {
    const val arriveMillis = 220

    const val pulseMillis = 950

    const val breatheMillis = 1100

    const val doorMillis = 280

    const val toastMillis = 250

    val easeInOut = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)

    fun <T> arrive() = tween<T>(arriveMillis, easing = LinearEasing)

    fun <T> door() = tween<T>(doorMillis, easing = easeInOut)

    fun <T> introSpring() = spring<T>(
        dampingRatio = 0.78f,
        stiffness = Spring.StiffnessLow,
        visibilityThreshold = null,
    )

    fun <T> tunedSpring(responseSecs: Float, dampingRatio: Float) = spring<T>(
        dampingRatio = dampingRatio,
        stiffness = (2f * kotlin.math.PI.toFloat() / responseSecs).let { it * it },
        visibilityThreshold = null,
    )
}

@Composable
fun rememberReduceMotion(): Boolean {
    val resolver = LocalContext.current.contentResolver
    var reduced by remember(resolver) {
        mutableStateOf(Settings.Global.getFloat(
            resolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) == 0f)
    }
    DisposableEffect(resolver) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                reduced = Settings.Global.getFloat(
                    resolver,
                    Settings.Global.ANIMATOR_DURATION_SCALE,
                    1f,
                ) == 0f
            }
        }
        resolver.registerContentObserver(
            Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE),
            false,
            observer,
        )
        onDispose { resolver.unregisterContentObserver(observer) }
    }
    return reduced
}

@Composable
fun riseInPx(): Int {
    val density = LocalDensity.current
    return with(density) { Space.xs.roundToPx() }
}

@Composable
fun smoothEnter(reduceMotion: Boolean): EnterTransition {
    val rise = riseInPx()
    return if (reduceMotion) fadeIn(TsMotion.arrive())
    else fadeIn(TsMotion.arrive()) + slideInVertically(TsMotion.arrive()) { rise }
}
