// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.browser

object BrowserPolicy {
    fun allows(url: String?): Boolean {
        if (url.isNullOrBlank()) return false
        val parsed = runCatching { java.net.URI(url.trim()) }.getOrNull() ?: return false
        val scheme = parsed.scheme?.lowercase() ?: return false
        if (scheme == "about") return true
        val host = parsed.host?.lowercase() ?: return false
        if (host == "127.0.0.1" || host == "localhost") {
            return (scheme == "http" || scheme == "https") && parsed.rawUserInfo == null &&
                (parsed.port == -1 || parsed.port in 1..65535)
        }
        return scheme == "https" &&
            (host == "tokenstat.ai" || host.endsWith(".tokenstat.ai"))
    }

    fun title(url: String?): String =
        runCatching { java.net.URI(url?.trim().orEmpty()).host }.getOrNull()
            ?.takeIf { it.isNotBlank() } ?: "tokenstat.ai"
}
