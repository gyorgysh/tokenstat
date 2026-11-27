// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat

import ai.tokenstat.tokenstat.ui.localization.L10n

import android.app.Application
import android.os.Build
import android.util.Log
import ai.tokenstat.tokenstat.core.CoreClient
import ai.tokenstat.tokenstat.notifications.PushRegistrar
import ai.tokenstat.tokenstat.ui.logic.AccountIdentityPins
import androidx.core.content.edit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class TokenstatApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val identities = getSharedPreferences("accountIdentities", MODE_PRIVATE)
        AccountIdentityPins.activate(object : AccountIdentityPins.Store {
            override fun read() = identities.all.mapNotNull { (id, value) -> (value as? String)?.let { id to it } }.toMap()
            override fun write(pins: Map<String, String>) =
                identities.edit { pins.forEach { (id, identity) -> putString(id, identity) } }
        })
        CoreClient.initialize(
            dataDir = noBackupFilesDir.resolve("tokenstat"),
            cacheDir = cacheDir.resolve("tokenstat"),
            deviceName = Build.MODEL.ifBlank { L10n.text("android.tokenstatapplication.android.6d612a86") },
        )
        PushRegistrar.init(this)
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            runCatching { ai.tokenstat.tokenstat.ui.ssh.SshSecrets.migrate(this@TokenstatApplication) }
            runCatching {
                val seed = noBackupFilesDir.resolve("PriceBookSeed.json")
                if (!seed.exists()) assets.open("PriceBookSeed.json").use { input ->
                    seed.outputStream().use(input::copyTo)
                }
                CoreClient.call("pricing.seed", buildJsonObject { put("path", seed.absolutePath) })
                CoreClient.call("pricing.refresh")
            }.onFailure {
                Log.w("ts-pricing", "price refresh failed, money is priced against the old book", it)
            }
        }
    }
}
