// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.legal

import ai.tokenstat.tokenstat.ui.components.TsBottomSheet
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.marks.FeatureMark
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsProminentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.components.TsType
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import com.google.android.play.core.review.ReviewManagerFactory

object ReviewPrompt {
    private const val FIRST_SEEN = "firstSeenAt"
    private const val LAST_ASKED = "lastAskedAt"
    private const val USES = "usesSinceAsk"
    private const val STOPPED = "never"
    private const val INTERVAL_MS = 14L * 24 * 3600 * 1000
    private const val SETTLE_MS = 7L * 24 * 3600 * 1000
    private const val USES_NEEDED = 5

    private fun prefs(context: Context) = context.getSharedPreferences("review", Context.MODE_PRIVATE)

    fun noteLaunch(context: Context, now: Long = System.currentTimeMillis()) {
        val prefs = prefs(context)
        if (!prefs.contains(FIRST_SEEN)) prefs.edit().putLong(FIRST_SEEN, now).apply()
    }

    fun noteUse(context: Context) {
        val prefs = prefs(context)
        prefs.edit().putInt(USES, prefs.getInt(USES, 0) + 1).apply()
    }

    fun isDue(context: Context, machines: Int, now: Long = System.currentTimeMillis()): Boolean {
        val prefs = prefs(context)
        if (!prefs.contains(FIRST_SEEN) || prefs.getBoolean(STOPPED, false) || machines <= 0) return false
        if (now - prefs.getLong(FIRST_SEEN, now) < SETTLE_MS || prefs.getInt(USES, 0) < USES_NEEDED) return false
        val last = prefs.getLong(LAST_ASKED, 0L)
        return last == 0L || now - last >= INTERVAL_MS
    }

    fun markAsked(context: Context, now: Long = System.currentTimeMillis()) {
        prefs(context).edit().putLong(LAST_ASKED, now).putInt(USES, 0).apply()
    }

    fun stop(context: Context) {
        prefs(context).edit().putBoolean(STOPPED, true).apply()
    }

    fun isStopped(context: Context) = prefs(context).getBoolean(STOPPED, false)

    fun requestPlayReview(activity: Activity) {
        val manager = ReviewManagerFactory.create(activity)
        manager.requestReviewFlow().addOnCompleteListener { request ->
            if (request.isSuccessful && !activity.isFinishing) {
                manager.launchReviewFlow(activity, request.result)
            }
        }
    }

    fun openListing(context: Context) {
        val id = context.packageName
        val market = Intent(Intent.ACTION_VIEW, "market://details?id=$id".toUri())
        try {
            context.startActivity(market)
        } catch (_: ActivityNotFoundException) {
            runCatching {
                context.startActivity(Intent(Intent.ACTION_VIEW, "https://play.google.com/store/apps/details?id=$id".toUri()))
            }
        }
    }
}

@Composable
fun RateCard(onOpen: () -> Unit) {
    val colors = LocalTsColors.current
    TsCard {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                FeatureMark("mark_license", size = 22)
                Text(
                    L10n.text("android.review.title"),
                    style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
            }
            Text(L10n.text("android.review.card_body"), style = TsType.body, color = colors.textSecondary)
            TsAccentButton(
                label = L10n.text("android.review.rate"),
                icon = ActionIcon.AppStore.vector,
                onClick = onOpen,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RateSheet(onDismiss: () -> Unit, onFeedback: () -> Unit) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    var stopped by remember { mutableStateOf(ReviewPrompt.isStopped(context)) }
    TsBottomSheet(onDismissRequest = onDismiss, containerColor = colors.background) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = Space.l).padding(bottom = Space.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            FeatureMark("mark_license", size = 56)
            Text(
                L10n.text("android.review.title"),
                style = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            Text(
                L10n.text("android.review.body"),
                style = TsType.body,
                color = colors.textSecondary,
                textAlign = TextAlign.Center,
            )
            TsProminentButton(
                label = L10n.text("android.review.rate"),
                icon = ActionIcon.AppStore.vector,
                onClick = {
                    ReviewPrompt.stop(context)
                    onDismiss()
                    ReviewPrompt.openListing(context)
                },
                modifier = Modifier.fillMaxWidth(),
            )
            TsSecondaryButton(
                label = L10n.text("android.review.feedback"),
                icon = ActionIcon.Comment.vector,
                onClick = {
                    ReviewPrompt.stop(context)
                    onDismiss()
                    onFeedback()
                },
                modifier = Modifier.fillMaxWidth(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TextButton(onClick = onDismiss) { Text(L10n.text("android.review.close"), color = colors.textSecondary) }
                if (!stopped) {
                    TextButton(onClick = {
                        ReviewPrompt.stop(context)
                        stopped = true
                        onDismiss()
                    }) { Text(L10n.text("android.review.never"), color = colors.textSecondary) }
                }
            }
            if (stopped) {
                Text(
                    L10n.text("android.review.stopped"),
                    style = TsType.caption,
                    color = colors.textTertiary,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}
