// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.browser

import ai.tokenstat.tokenstat.ui.logic.ProjectOwner
import java.net.URI
import kotlinx.serialization.Serializable

/// The endpoint on the paired computer, independent of a temporary listener.
@ConsistentCopyVisibility
data class BrowserTarget private constructor(
    val scheme: String,
    val host: String,
    val port: Int,
    val suffix: String,
) {
    val url: String get() = "$scheme://$host:$port$suffix"
    val endpoint: String get() = "$host:$port"

    fun through(listenerUrl: String): String? {
        val listener = parseUri(listenerUrl) ?: return null
        if (!loopback(listener.host) || listener.port !in 1..65535) return null
        return "$scheme://${listener.host}:${listener.port}$suffix"
    }

    companion object {
        fun port(port: Int): BrowserTarget? = parse("http://127.0.0.1:$port/")

        fun parse(url: String?): BrowserTarget? {
            val parsed = parseUri(url) ?: return null
            val scheme = parsed.scheme?.lowercase() ?: return null
            if (scheme != "http" && scheme != "https") return null
            val host = parsed.host?.lowercase() ?: return null
            if (!loopback(host) || parsed.rawUserInfo != null) return null
            val port = if (parsed.port == -1) { if (scheme == "https") 443 else 80 } else parsed.port
            if (port !in 1..65535) return null
            return BrowserTarget(scheme, host, port, suffix(parsed))
        }
    }
}

data class BrowserBridge(val target: BrowserTarget, val listenerUrl: String) {
    /// Browser redirects contain the local proxy address. Translate them back
    /// before displaying or remembering the page on the paired computer.
    fun original(url: String?): BrowserTarget? {
        val parsed = parseUri(url) ?: return null
        val listener = parseUri(listenerUrl) ?: return null
        if (!loopback(parsed.host) || parsed.port != listener.port || parsed.rawUserInfo != null) return null
        val scheme = parsed.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return null
        return BrowserTarget.parse("$scheme://${target.host}:${target.port}${suffix(parsed)}")
    }
}

/// One pushed browser owns its listeners and retains its opening context even
/// if the project selection behind it changes.
data class BrowserOpenRequest(
    val peer: String,
    val workspace: String,
    val owner: ProjectOwner?,
    val target: BrowserTarget,
    val lease: BrowserListenerPool.Lease,
) {
    val listenerUrl: String get() = lease.listenerUrl
}

object BrowserHistory {
    const val CAPACITY = 8

    @Serializable
    data class State(val lastTarget: String? = null, val recentPorts: List<Int> = emptyList())

    fun clean(state: State): State {
        val target = BrowserTarget.parse(state.lastTarget)
        val ports = (listOfNotNull(target?.port) + state.recentPorts)
            .filter { it in 1..65535 }.distinct().take(CAPACITY)
        return State(target?.url, ports)
    }

    fun record(state: State, target: BrowserTarget): State =
        clean(State(target.url, listOf(target.port) + state.recentPorts))

    /// Legacy global state is only an initial field suggestion. Reading it
    /// never copies another project's history into this project's store.
    fun initial(state: State, legacyPort: Int?): BrowserTarget =
        BrowserTarget.parse(state.lastTarget) ?: BrowserTarget.port(legacyPort ?: 3000)
        ?: BrowserTarget.port(3000)!!

    fun forPort(state: State, port: Int): BrowserTarget? =
        BrowserTarget.parse(state.lastTarget)?.takeIf { it.port == port } ?: BrowserTarget.port(port)
}

private fun parseUri(url: String?): URI? {
    val value = url?.trim()?.takeIf { it.isNotEmpty() && it.length <= 8192 && it.none(Char::isISOControl) }
        ?: return null
    return runCatching { URI(value) }.getOrNull()
}

private fun loopback(host: String?): Boolean =
    host?.lowercase() == "127.0.0.1" || host?.lowercase() == "localhost"

private fun suffix(uri: URI): String =
    uri.rawPath.orEmpty().ifEmpty { "/" } +
        (uri.rawQuery?.let { "?$it" } ?: "") + (uri.rawFragment?.let { "#$it" } ?: "")
