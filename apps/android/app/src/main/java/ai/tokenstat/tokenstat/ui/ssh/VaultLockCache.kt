// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import ai.tokenstat.tokenstat.ui.localization.L10n

import android.content.Context
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.EnhancedEncryption
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import androidx.compose.ui.text.style.TextOverflow

data class VaultLockSnapshot(
    val created: Boolean,
    val locked: Boolean,
    val enrolled: Boolean,
    val recordCount: Int,
) {
    companion object {
        fun of(status: JsonObject?): VaultLockSnapshot? {
            if (status == null) return null
            if (status["unreachable"]?.let { (it as? JsonPrimitive)?.contentOrNull }
                ?.isNotBlank() == true
            ) {
                return null
            }
            return VaultLockSnapshot(
                created = (status["created"] as? JsonPrimitive)?.booleanOrNull == true,
                locked = (status["locked"] as? JsonPrimitive)?.booleanOrNull == true,
                enrolled = (status["enrolled"] as? JsonPrimitive)?.booleanOrNull == true,
                recordCount = (status["recordCount"] as? JsonPrimitive)?.intOrNull ?: 0,
            )
        }
    }

    fun detail(canWrite: Boolean): String? = when {
        !created -> if (canWrite) L10n.text("android.vaultlockcache.not_set_up.ef93782b") else L10n.text("android.vaultlockcache.not_syncing.c0737345")
        locked -> null
        else -> {
            val records = if (recordCount == 1) "1 record" else L10n.text("android.vaultlockcache.0_records.2cd6fd62", "${recordCount}")
            if (canWrite) records else L10n.text("android.vaultlockcache.0_not_syncing.b60c9633", "${records}")
        }
    }
}

object VaultLockCache {
    private const val STORE = "ai.tokenstat.ssh.vaultlock.v1"

    fun read(context: Context, owner: String): VaultLockSnapshot? {
        if (owner.isBlank()) return null
        val prefs = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
        if (prefs.getString("owner", null) != owner) return null
        if (!prefs.contains("created")) return null
        return VaultLockSnapshot(
            created = prefs.getBoolean("created", false),
            locked = prefs.getBoolean("locked", false),
            enrolled = prefs.getBoolean("enrolled", false),
            recordCount = prefs.getInt("records", 0),
        )
    }

    fun write(context: Context, owner: String, snapshot: VaultLockSnapshot?) {
        if (snapshot == null || owner.isBlank()) return
        context.getSharedPreferences(STORE, Context.MODE_PRIVATE).edit()
            .putString("owner", owner)
            .putBoolean("created", snapshot.created)
            .putBoolean("locked", snapshot.locked)
            .putBoolean("enrolled", snapshot.enrolled)
            .putInt("records", snapshot.recordCount)
            .apply()
    }
}

@Composable
fun VaultLockRow(
    owner: String,
    status: JsonObject?,
    canWrite: Boolean,
    unconfirmedRecovery: Boolean,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    val cached = remember(owner) { VaultLockCache.read(context, owner) }
    val live = remember(status) { VaultLockSnapshot.of(status) }
    if (live != null) {
        LaunchedEffect(owner, live) { VaultLockCache.write(context, owner, live) }
    }
    val shown = live ?: cached
    val checking = live == null
    TsCard(modifier = modifier.heightIn(min = 48.dp).clickable(onClick = onOpen)) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Icon(
                Icons.Default.EnhancedEncryption,
                contentDescription = null,
                tint = if (unconfirmedRecovery) colors.warning else colors.accent,
            )
            Spacer(Modifier.width(Space.s))
            Text(
                text = if (unconfirmedRecovery) L10n.text("android.vaultlockcache.recovery_code_not_confirmed.dc3c61fd") else L10n.text("android.vaultlockcache.encrypted_vault.31939e06"),
                style = TsType.body,
                color = if (unconfirmedRecovery) colors.warning else colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            when {
                unconfirmedRecovery -> Unit
                shown == null -> Text(
                    L10n.text("android.vaultlockcache.checking.a0ec28fd"),
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
                shown.locked && !unconfirmedRecovery -> VaultLockedBadge()
                shown.detail(canWrite) != null -> Text(
                    shown.detail(canWrite)!!,
                    style = TsType.caption,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (checking && shown != null && !unconfirmedRecovery) {
                Spacer(Modifier.width(Space.xs))
                Text(L10n.text("android.vaultlockcache.checking.a0ec28fd"), style = TsType.caption, color = colors.textTertiary)
            }
            Icon(Icons.Default.ChevronRight, contentDescription = null, tint = colors.textTertiary)
        }
    }
}

@Composable
private fun VaultLockedBadge() {
    val colors = LocalTsColors.current
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(colors.accentSoft)
            .padding(horizontal = 6.dp, vertical = 1.dp),
    ) {
        Text(L10n.text("android.vaultlockcache.locked.a424e33d"), style = TsType.caption, color = colors.accent)
    }
}
