// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat

import android.app.Application
import android.os.Build
import ai.tokenstat.tokenstat.core.CoreClient
import ai.tokenstat.tokenstat.notifications.PushRegistrar
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class TokenstatApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        CoreClient.initialize(
            dataDir = noBackupFilesDir.resolve("tokenstat"),
            cacheDir = cacheDir.resolve("tokenstat"),
            deviceName = Build.MODEL.ifBlank { "Android" },
        )
        PushRegistrar.init(this)
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            runCatching {
                val seed = noBackupFilesDir.resolve("PriceBookSeed.json")
                if (!seed.exists()) assets.open("PriceBookSeed.json").use { input ->
                    seed.outputStream().use(input::copyTo)
                }
                CoreClient.call("pricing.seed", buildJsonObject { put("path", seed.absolutePath) })
                CoreClient.call("pricing.refresh")
            }
        }
    }
}
