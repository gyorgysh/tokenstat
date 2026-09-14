// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.browser

/// Which URLs the port-forwarded browser may load, ported from Apple
/// `ClientWebView.allows`.
///
/// The tunnel proxy answers on this device's own loopback, so host
/// localhost resolves through the tunnel and never touches anything else.
/// Only web pages belong here: allowing a mailto:, tel: or custom scheme
/// stalls on a navigation the view cannot perform, so everything else is
/// refused.
///
/// Kept free of Android imports so unit tests pin the same answers.
object BrowserPolicy {
    fun allows(url: String?): Boolean {
        if (url.isNullOrBlank()) return false
        val parsed = runCatching { java.net.URI(url.trim()) }.getOrNull() ?: return false
        val scheme = parsed.scheme?.lowercase() ?: return false
        if (scheme == "about") return true
        val host = parsed.host?.lowercase() ?: return false
        if (host == "127.0.0.1" || host == "localhost") {
            return scheme == "http" || scheme == "https"
        }
        return scheme == "https" &&
            (host == "tokenstat.ai" || host.endsWith(".tokenstat.ai"))
    }

    /// The address-bar title: the host, or the product name when the URL
    /// has none. Mirrors the Apple navigation title fallback.
    fun title(url: String?): String =
        runCatching { java.net.URI(url?.trim().orEmpty()).host }.getOrNull()
            ?.takeIf { it.isNotBlank() } ?: "tokenstat.ai"
}
