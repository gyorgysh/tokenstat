// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.core

internal class NativeBridge private constructor() {
    companion object {
        init { System.loadLibrary("tokenstat_ffi") }

        @JvmStatic external fun nativeInit(dataDir: String, cacheDir: String, deviceName: String): String
        @JvmStatic external fun nativeCall(method: String, params: String): String
    }
}
